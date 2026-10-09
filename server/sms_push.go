package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Standard APNs tokens are distinct from PushKit VoIP tokens. Neither a phone
// number nor SMS content is stored here or sent in a notification.
type smsPushDevice struct {
	KeyHash string    `json:"key_hash"`
	Token   string    `json:"token"`
	Sandbox bool      `json:"sandbox"`
	Updated time.Time `json:"updated_at"`
}

type smsContactSnapshot struct {
	Peer      string `json:"peer"`
	ICCID     string `json:"iccid"`
	IMSI      string `json:"imsi"`
	DeviceID  string `json:"device_id"`
	LastSMSID uint64 `json:"last_sms_id"`
}

var smsPushMu sync.Mutex
var smsAlertSend = sendSMSAlerts

func smsPushTokensPath() string {
	if path := os.Getenv("VOICE_WEB_SMS_PUSH_TOKENS_FILE"); path != "" {
		return path
	}
	return dataPath("sms-push-tokens.json")
}

func smsCursorPath() string {
	if path := os.Getenv("VOICE_WEB_SMS_CURSOR_FILE"); path != "" {
		return path
	}
	return dataPath("sms-push-cursor.json")
}

func privateJSON(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".sms-push-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0600); err != nil {
		f.Close()
		return err
	}
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

func loadSMSPushDevices() ([]smsPushDevice, error) {
	data, err := os.ReadFile(smsPushTokensPath())
	if os.IsNotExist(err) {
		return []smsPushDevice{}, nil
	}
	if err != nil {
		return nil, err
	}
	var devices []smsPushDevice
	err = json.Unmarshal(data, &devices)
	return devices, err
}

func appSMSPushToken(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !allowedOrigin(r) {
		w.WriteHeader(403)
		return
	}
	hash := appRequestHash(r)
	if hash == "" {
		w.WriteHeader(401)
		return
	}
	if r.Method != "POST" && r.Method != "DELETE" {
		w.WriteHeader(405)
		return
	}
	smsPushMu.Lock()
	defer smsPushMu.Unlock()
	devices, err := loadSMSPushDevices()
	if err != nil {
		w.WriteHeader(503)
		return
	}
	kept := make([]smsPushDevice, 0, len(devices)+1)
	for _, device := range devices {
		if device.KeyHash != hash {
			kept = append(kept, device)
		}
	}
	if r.Method == "POST" {
		var input struct {
			Token       string `json:"token"`
			Environment string `json:"environment"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&input) != nil ||
			!voipTokenPattern.MatchString(input.Token) ||
			(input.Environment != "sandbox" && input.Environment != "production") {
			w.WriteHeader(400)
			return
		}
		token := strings.ToLower(input.Token)
		// One device token belongs to only one App Key at a time.
		filtered := kept[:0]
		for _, device := range kept {
			if device.Token != token {
				filtered = append(filtered, device)
			}
		}
		kept = append(filtered, smsPushDevice{KeyHash: hash, Token: token,
			Sandbox: input.Environment == "sandbox", Updated: time.Now().UTC()})
	}
	if err := privateJSON(smsPushTokensPath(), kept); err != nil {
		w.WriteHeader(503)
		return
	}
	w.WriteHeader(204)
}

func purgeSMSPushForHash(hash string) {
	smsPushMu.Lock()
	defer smsPushMu.Unlock()
	devices, err := loadSMSPushDevices()
	if err != nil {
		log.Printf("撤销 Key 后清理短信通知令牌失败: %v", err)
		return
	}
	kept := make([]smsPushDevice, 0, len(devices))
	for _, device := range devices {
		if device.KeyHash != hash {
			kept = append(kept, device)
		}
	}
	if err := privateJSON(smsPushTokensPath(), kept); err != nil {
		log.Printf("撤销 Key 后清理短信通知令牌失败: %v", err)
	}
}

func activeSMSPushDevices() ([]smsPushDevice, error) {
	smsPushMu.Lock()
	devices, err := loadSMSPushDevices()
	smsPushMu.Unlock()
	if err != nil {
		return nil, err
	}
	active := make([]smsPushDevice, 0, len(devices))
	for _, device := range devices {
		if appHashActive(device.KeyHash) {
			active = append(active, device)
		}
	}
	return active, nil
}

func removeSMSPushDevice(target smsPushDevice) {
	smsPushMu.Lock()
	defer smsPushMu.Unlock()
	devices, err := loadSMSPushDevices()
	if err != nil {
		return
	}
	kept := make([]smsPushDevice, 0, len(devices))
	for _, device := range devices {
		if device.KeyHash != target.KeyHash || device.Token != target.Token {
			kept = append(kept, device)
		}
	}
	_ = privateJSON(smsPushTokensPath(), kept)
}

func (p *apnsProvider) sendSMSAlert(ctx context.Context, device smsPushDevice) (int, string, error) {
	jwt, err := p.jwt()
	if err != nil {
		return 0, "", err
	}
	if _, err := hex.DecodeString(device.Token); err != nil {
		return 0, "", err
	}
	payload, _ := json.Marshal(map[string]any{"aps": map[string]any{
		"alert": map[string]string{"title": "随行号", "body": "收到新短信，点开查看"},
		"sound": "default",
	}})
	host := "https://api.push.apple.com"
	if device.Sandbox {
		host = "https://api.sandbox.push.apple.com"
	}
	req, err := http.NewRequestWithContext(ctx, "POST", host+"/3/device/"+device.Token, bytes.NewReader(payload))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-topic", p.bundleID)
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-expiration", fmt.Sprint(time.Now().Add(time.Hour).Unix()))
	req.Header.Set("apns-collapse-id", "hideck-new-sms")
	req.Header.Set("content-type", "application/json")
	response, err := p.client.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer response.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(response.Body, 1024))
	var result struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(data, &result)
	return response.StatusCode, result.Reason, nil
}

func sendSMSAlerts(ctx context.Context) error {
	devices, err := activeSMSPushDevices()
	if err != nil {
		return err
	}
	for _, device := range devices {
		requestCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
		status, reason, err := dispatchSMS(requestCtx, device)
		cancel()
		if err != nil {
			return err
		}
		if status == 200 {
			log.Print("新短信通知已由 APNs 接收")
			continue
		}
		if status == 410 || reason == "BadDeviceToken" || reason == "Unregistered" {
			removeSMSPushDevice(device)
			continue
		}
		return fmt.Errorf("APNs HTTP %d %s", status, reason)
	}
	return nil
}

func loadSMSCursor() (uint64, bool, error) {
	data, err := os.ReadFile(smsCursorPath())
	if os.IsNotExist(err) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	var state struct {
		LastSMSID uint64 `json:"last_sms_id"`
	}
	err = json.Unmarshal(data, &state)
	return state.LastSMSID, true, err
}

func saveSMSCursor(id uint64) error {
	return privateJSON(smsCursorPath(), struct {
		LastSMSID uint64 `json:"last_sms_id"`
	}{id})
}

func fetchSMSJSON(ctx context.Context, path string, value any) error {
	token, err := backendToken()
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, "GET", upstream+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", token)
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return fmt.Errorf("HiDeck SMS HTTP %d", response.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(response.Body, 2<<20)).Decode(value)
}

func smsThreadQuery(contact smsContactSnapshot) string {
	query := url.Values{"peer": {contact.Peer}, "limit": {"100"}}
	if contact.ICCID != "" {
		query.Set("iccid", contact.ICCID)
	} else if contact.IMSI != "" {
		query.Set("imsi", contact.IMSI)
	} else if contact.DeviceID != "" {
		query.Set("device_id", contact.DeviceID)
	}
	return "/api/sms/thread?" + query.Encode()
}

func checkNewSMS(ctx context.Context) error {
	var contacts []smsContactSnapshot
	if err := fetchSMSJSON(ctx, "/api/sms/contacts?limit=200", &contacts); err != nil {
		return err
	}
	cursor, initialized, err := loadSMSCursor()
	if err != nil {
		return err
	}
	latest := cursor
	for _, contact := range contacts {
		if contact.LastSMSID > latest {
			latest = contact.LastSMSID
		}
	}
	if !initialized {
		return saveSMSCursor(latest)
	}
	if latest == cursor {
		return nil
	}
	incoming := false
	for _, contact := range contacts {
		if contact.LastSMSID <= cursor {
			continue
		}
		var messages []struct {
			ID   uint64 `json:"id"`
			Type int    `json:"type"`
		}
		if err := fetchSMSJSON(ctx, smsThreadQuery(contact), &messages); err != nil {
			return err
		}
		for _, message := range messages {
			if message.ID > cursor && message.Type == 1 {
				incoming = true
				break
			}
		}
	}
	if incoming {
		if err := smsAlertSend(ctx); err != nil {
			return err
		}
	}
	return saveSMSCursor(latest)
}

func watchSMS(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		attempt, cancel := context.WithTimeout(ctx, 8*time.Second)
		if err := checkNewSMS(attempt); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("短信通知检查失败: %v", err)
		}
		cancel()
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
