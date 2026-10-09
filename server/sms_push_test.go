package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSMSPushTokenBoundToAppKey(t *testing.T) {
	h, admin := appTestSetup(t)
	t.Setenv("VOICE_WEB_VOIP_TOKENS_FILE", filepath.Join(t.TempDir(), "voip.json"))
	t.Setenv("VOICE_WEB_SMS_PUSH_TOKENS_FILE", filepath.Join(t.TempDir(), "sms-push.json"))
	id, key := issueTestKey(t, h, admin)
	token := strings.Repeat("ab", 32)
	path := "/voice-test/app/sms-push-token"
	if got := appTestRequest(h, "POST", path, admin, `{"token":"`+token+`","environment":"sandbox"}`).Code; got != 401 {
		t.Fatalf("admin token registered: %d", got)
	}
	if got := appTestRequest(h, "POST", path, key, `{"token":"bad","environment":"sandbox"}`).Code; got != 400 {
		t.Fatalf("invalid token accepted: %d", got)
	}
	if got := appTestRequest(h, "POST", path, key, `{"token":"`+token+`","environment":"sandbox"}`).Code; got != 204 {
		t.Fatalf("token registration: %d", got)
	}
	devices, err := loadSMSPushDevices()
	if err != nil || len(devices) != 1 || devices[0].Token != token || !devices[0].Sandbox {
		t.Fatal("SMS token not stored")
	}
	info, err := os.Stat(smsPushTokensPath())
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("SMS token file must be private")
	}
	if got := appTestRequest(h, "DELETE", "/voice-test/app-keys?id="+id, admin, "").Code; got != 204 {
		t.Fatalf("key revocation: %d", got)
	}
	devices, err = loadSMSPushDevices()
	if err != nil || len(devices) != 0 {
		t.Fatal("revocation retained SMS token")
	}
}

func TestSMSWatcherBaselinesAndOnlyNotifiesIncoming(t *testing.T) {
	oldUp, oldClient, oldConfig, oldSend := upstream, client, configPath, smsAlertSend
	t.Cleanup(func() { upstream, client, configPath, smsAlertSend = oldUp, oldClient, oldConfig, oldSend })
	t.Setenv("VOICE_WEB_SMS_CURSOR_FILE", filepath.Join(t.TempDir(), "cursor.json"))
	configPath = filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(configPath, []byte("web:\n  password: synthetic-signing-material\n"), 0600); err != nil {
		t.Fatal(err)
	}
	latest, kind := 10, 1
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/sms/contacts" {
			json.NewEncoder(w).Encode([]map[string]any{{"peer": "synthetic-peer", "iccid": "synthetic-card", "last_sms_id": latest}})
			return
		}
		if r.URL.Path == "/api/sms/thread" {
			json.NewEncoder(w).Encode([]map[string]any{{"id": latest, "type": kind}})
			return
		}
		w.WriteHeader(404)
	}))
	defer fake.Close()
	upstream, client = fake.URL, fake.Client()
	count := 0
	smsAlertSend = func(context.Context) error { count++; return nil }
	ctx := context.Background()
	if err := checkNewSMS(ctx); err != nil || count != 0 {
		t.Fatal("existing messages must become baseline")
	}
	latest = 11
	if err := checkNewSMS(ctx); err != nil || count != 1 {
		t.Fatal("new inbound message must notify once")
	}
	if err := checkNewSMS(ctx); err != nil || count != 1 {
		t.Fatal("same message notified twice")
	}
	latest, kind = 12, 2
	if err := checkNewSMS(ctx); err != nil || count != 1 {
		t.Fatal("outgoing message must not notify")
	}
	info, err := os.Stat(smsCursorPath())
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("cursor file must be private")
	}
}

type inspectSMSAlertTransport struct{ t *testing.T }

func (p inspectSMSAlertTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.URL.Host != "api.sandbox.push.apple.com" || r.Header.Get("apns-push-type") != "alert" ||
		r.Header.Get("apns-topic") != "example.app" || r.Header.Get("apns-collapse-id") == "" {
		p.t.Error("SMS APNs headers")
	}
	data, _ := io.ReadAll(r.Body)
	if strings.Contains(string(data), "synthetic-peer") || strings.Contains(string(data), "synthetic-body") ||
		!strings.Contains(string(data), "收到新短信") {
		p.t.Error("SMS notification payload privacy")
	}
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("")), Header: make(http.Header)}, nil
}

func TestSMSAlertUsesPlainNotificationTopic(t *testing.T) {
	provider := &apnsProvider{cachedJWT: "synthetic", issuedAt: time.Now(), bundleID: "example.app",
		client: &http.Client{Transport: inspectSMSAlertTransport{t}}}
	status, _, err := provider.sendSMSAlert(context.Background(), smsPushDevice{Token: strings.Repeat("ab", 32), Sandbox: true})
	if err != nil || status != 200 {
		t.Fatal("SMS APNs alert request failed")
	}
}
