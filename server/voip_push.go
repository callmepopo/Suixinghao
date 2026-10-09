package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// VoIP tokens are secret routing addresses. Keep them outside the web root,
// bound to the App Key that registered them, and remove them with that key.
type voipDevice struct {
	KeyHash string    `json:"key_hash"`
	Token   string    `json:"token"`
	Sandbox bool      `json:"sandbox"`
	Updated time.Time `json:"updated_at"`
}

var voipMu sync.Mutex
var voipTokenPattern = regexp.MustCompile(`^[0-9a-fA-F]{64,256}$`)
var incomingPushes = make(chan string, 8)
var providerMu sync.Mutex
var providers = map[bool]*apnsProvider{}

func voipDevicesPath() string {
	if value := os.Getenv("VOICE_WEB_VOIP_TOKENS_FILE"); value != "" {
		return value
	}
	return dataPath("voip-tokens.json")
}

func loadVoIPDevices() ([]voipDevice, error) {
	data, err := os.ReadFile(voipDevicesPath())
	if os.IsNotExist(err) {
		return []voipDevice{}, nil
	}
	if err != nil {
		return nil, err
	}
	var devices []voipDevice
	if err := json.Unmarshal(data, &devices); err != nil {
		return nil, err
	}
	return devices, nil
}

func saveVoIPDevices(devices []voipDevice) error {
	path := voipDevicesPath()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	data, err := json.Marshal(devices)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".voip-tokens-*")
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

func appVoIPToken(w http.ResponseWriter, r *http.Request) {
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
	voipMu.Lock()
	defer voipMu.Unlock()
	devices, err := loadVoIPDevices()
	if err != nil {
		w.WriteHeader(503)
		return
	}
	if r.Method == "DELETE" {
		kept := make([]voipDevice, 0, len(devices))
		for _, device := range devices {
			if device.KeyHash != hash {
				kept = append(kept, device)
			}
		}
		if err := saveVoIPDevices(kept); err != nil {
			w.WriteHeader(503)
			return
		}
		w.WriteHeader(204)
		return
	}
	var input struct {
		Token       string `json:"token"`
		Environment string `json:"environment"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&input) != nil || !voipTokenPattern.MatchString(input.Token) ||
		(input.Environment != "sandbox" && input.Environment != "production") {
		w.WriteHeader(400)
		return
	}
	token := strings.ToLower(input.Token)
	kept := make([]voipDevice, 0, len(devices)+1)
	for _, device := range devices {
		if device.KeyHash != hash && device.Token != token {
			kept = append(kept, device)
		}
	}
	kept = append(kept, voipDevice{KeyHash: hash, Token: token, Sandbox: input.Environment == "sandbox", Updated: time.Now().UTC()})
	if err := saveVoIPDevices(kept); err != nil {
		w.WriteHeader(503)
		return
	}
	w.WriteHeader(204)
}

func queueIncomingPush(callID string) {
	select {
	case incomingPushes <- callID:
	default:
		log.Print("VoIP 推送队列已满")
	}
}

func runIncomingPushes(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case callID := <-incomingPushes:
			sendIncomingPushes(ctx, callID)
		}
	}
}

func activeVoIPDevices() ([]voipDevice, error) {
	voipMu.Lock()
	devices, err := loadVoIPDevices()
	voipMu.Unlock()
	if err != nil {
		return nil, err
	}
	active := make([]voipDevice, 0, len(devices))
	for _, device := range devices {
		if appHashActive(device.KeyHash) {
			active = append(active, device)
		}
	}
	return active, nil
}

func purgeVoIPForHash(hash string) {
	voipMu.Lock()
	defer voipMu.Unlock()
	devices, err := loadVoIPDevices()
	if err != nil {
		log.Printf("撤销 Key 后清理 VoIP 令牌失败: %v", err)
		return
	}
	if len(devices) == 0 {
		return
	}
	kept := make([]voipDevice, 0, len(devices))
	for _, device := range devices {
		if device.KeyHash != hash {
			kept = append(kept, device)
		}
	}
	if err := saveVoIPDevices(kept); err != nil {
		log.Printf("撤销 Key 后清理 VoIP 令牌失败: %v", err)
	}
}

func sendIncomingPushes(ctx context.Context, callID string) {
	devices, err := activeVoIPDevices()
	if err != nil {
		log.Printf("VoIP 令牌读取失败: %v", err)
		return
	}
	if len(devices) == 0 {
		return
	}
	for _, device := range devices {
		requestCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
		status, reason, err := dispatchVoIP(requestCtx, device, callID)
		cancel()
		if err != nil {
			log.Printf("VoIP 推送失败: %v", err)
			continue
		}
		if status == 200 {
			log.Print("VoIP 推送已由 APNs 接收")
			continue
		}
		log.Printf("VoIP 推送被 APNs 拒绝: HTTP %d %s", status, reason)
		if status == 410 || reason == "BadDeviceToken" || reason == "Unregistered" {
			removeVoIPDevice(device)
		}
	}
}

func removeVoIPDevice(target voipDevice) {
	voipMu.Lock()
	defer voipMu.Unlock()
	devices, err := loadVoIPDevices()
	if err != nil {
		return
	}
	kept := make([]voipDevice, 0, len(devices))
	for _, device := range devices {
		if device.KeyHash != target.KeyHash || device.Token != target.Token {
			kept = append(kept, device)
		}
	}
	if err := saveVoIPDevices(kept); err != nil {
		log.Printf("失效 VoIP 令牌清理失败: %v", err)
	}
}

type apnsProvider struct {
	key                     *ecdsa.PrivateKey
	keyID, teamID, bundleID string
	client                  *http.Client
	mu                      sync.Mutex
	cachedJWT               string
	issuedAt                time.Time
}

func providerFor(sandbox bool) (*apnsProvider, error) {
	providerMu.Lock()
	defer providerMu.Unlock()
	if provider := providers[sandbox]; provider != nil {
		return provider, nil
	}
	provider, err := newAPNsProvider(sandbox)
	if err == nil {
		providers[sandbox] = provider
	}
	return provider, err
}

func newAPNsProvider(sandbox bool) (*apnsProvider, error) {
	prefix := "VOICE_WEB_APNS_PRODUCTION_"
	if sandbox {
		prefix = "VOICE_WEB_APNS_SANDBOX_"
	}
	path := os.Getenv(prefix + "KEY_FILE")
	keyID := os.Getenv(prefix + "KEY_ID")
	// Existing dual-environment keys can use the original shared settings.
	if path == "" && keyID == "" {
		path = os.Getenv("VOICE_WEB_APNS_KEY_FILE")
		keyID = os.Getenv("VOICE_WEB_APNS_KEY_ID")
	}
	teamID := os.Getenv("VOICE_WEB_APNS_TEAM_ID")
	bundleID := os.Getenv("VOICE_WEB_APNS_BUNDLE_ID")
	if path == "" || keyID == "" || teamID == "" || bundleID == "" {
		return nil, fmt.Errorf("缺少 APNs 配置")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	key, err := x509.ParsePKCS8PrivateKey(pemBody(data))
	if err != nil {
		return nil, err
	}
	ec, ok := key.(*ecdsa.PrivateKey)
	if !ok || ec.Curve.Params().BitSize != 256 {
		return nil, fmt.Errorf("APNs 密钥类型无效")
	}
	return &apnsProvider{key: ec, keyID: keyID, teamID: teamID, bundleID: bundleID,
		client: &http.Client{Timeout: 4 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

func pemBody(data []byte) []byte {
	const begin = "-----BEGIN PRIVATE KEY-----"
	const end = "-----END PRIVATE KEY-----"
	s := string(data)
	a, b := strings.Index(s, begin), strings.Index(s, end)
	if a < 0 || b <= a {
		return nil
	}
	decoded, _ := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(s[a+len(begin):b]), ""))
	return decoded
}

func (p *apnsProvider) jwt() (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cachedJWT != "" && time.Since(p.issuedAt) < 40*time.Minute {
		return p.cachedJWT, nil
	}
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": p.keyID})
	now := time.Now()
	claims, _ := json.Marshal(map[string]any{"iss": p.teamID, "iat": now.Unix()})
	encode := base64.RawURLEncoding.EncodeToString
	message := encode(header) + "." + encode(claims)
	digest := sha256.Sum256([]byte(message))
	r, s, err := ecdsa.Sign(rand.Reader, p.key, digest[:])
	if err != nil {
		return "", err
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	p.cachedJWT = message + "." + encode(signature)
	p.issuedAt = now
	return p.cachedJWT, nil
}

func (p *apnsProvider) send(ctx context.Context, device voipDevice, callID string) (int, string, error) {
	jwt, err := p.jwt()
	if err != nil {
		return 0, "", err
	}
	payload, _ := json.Marshal(map[string]any{"aps": map[string]any{}, "call_id": callID})
	host := "https://api.push.apple.com"
	if device.Sandbox {
		host = "https://api.sandbox.push.apple.com"
	}
	if _, err := hex.DecodeString(device.Token); err != nil {
		return 0, "", err
	}
	req, err := http.NewRequestWithContext(ctx, "POST", host+"/3/device/"+device.Token, bytes.NewReader(payload))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-push-type", "voip")
	req.Header.Set("apns-topic", p.bundleID+".voip")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-expiration", "0")
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
