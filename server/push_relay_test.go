package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func relayTestRequest(p *pushRelay, key, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "https://relay.example.org/push-relay/v1/push", strings.NewReader(body))
	if key != "" {
		r.Header.Set("Authorization", "Bearer "+key)
	}
	w := httptest.NewRecorder()
	p.ServeHTTP(w, r)
	return w
}
func relayFixture() (*pushRelay, string, *int) {
	key := "sxr_" + strings.Repeat("1", 64)
	calls := new(int)
	p := newPushRelay("production", func(context.Context, relayPush) (int, string, error) { *calls++; return 200, "", nil })
	p.Grants = func() ([]relayGrant, error) {
		return []relayGrant{{Hash: relayDigest(key), Environment: "production"}}, nil
	}
	return p, key, calls
}
func relayBody(kind, call string) string {
	b, _ := json.Marshal(relayPush{Kind: kind, Token: strings.Repeat("a", 64), Environment: "production", CallID: call})
	return string(b)
}

func TestRelayScopeValidationAndRevocation(t *testing.T) {
	p, key, calls := relayFixture()
	valid := relayBody("voip", strings.Repeat("b", 32))
	for _, tc := range []struct {
		name, key, body string
		want            int
	}{
		{"anonymous", "", valid, 401}, {"wrong backend", "sxr_" + strings.Repeat("2", 64), valid, 401},
		{"arbitrary topic", key, strings.TrimSuffix(valid, "}") + `,"topic":"other.app"}`, 400},
		{"arbitrary payload", key, strings.TrimSuffix(valid, "}") + `,"payload":{"aps":{"alert":"content"}}}`, 400},
		{"wrong environment", key, strings.Replace(valid, "production", "sandbox", 1), 400},
		{"invalid call ID", key, relayBody("voip", "123"), 400},
		{"SMS with call ID", key, relayBody("sms", strings.Repeat("b", 32)), 400},
		{"unknown kind", key, relayBody("background", ""), 400},
		{"trailing document", key, valid + ` {}`, 400},
		{"bad token", key, strings.Replace(valid, strings.Repeat("a", 64), "not-a-token", 1), 400},
		{"odd token", key, strings.Replace(valid, strings.Repeat("a", 64), strings.Repeat("a", 65), 1), 400},
		{"accepted", key, valid, 200},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := relayTestRequest(p, tc.key, tc.body).Code; got != tc.want {
				t.Fatalf("status %d, want %d", got, tc.want)
			}
		})
	}
	if *calls != 1 {
		t.Fatalf("invalid requests reached provider: %d", *calls)
	}
	p.Grants = func() ([]relayGrant, error) { return []relayGrant{}, nil }
	if got := relayTestRequest(p, key, valid).Code; got != 401 {
		t.Fatalf("revoked tenant got %d", got)
	}
	if *calls != 1 {
		t.Fatal("revoked tenant reached provider")
	}
}
func TestRelayDedupRateLimitAndExpiry(t *testing.T) {
	p, key, calls := relayFixture()
	now := time.Now()
	p.Now = func() time.Time { return now }
	body := relayBody("voip", strings.Repeat("b", 32))
	for i := 0; i < 2; i++ {
		if got := relayTestRequest(p, key, body).Code; got != 200 {
			t.Fatal(got)
		}
	}
	if *calls != 1 {
		t.Fatal("duplicate delivered")
	}
	for i := 1; i < 20; i++ {
		req := relayBody("voip", fmtRelayCall(i))
		if got := relayTestRequest(p, key, req).Code; got != 200 {
			t.Fatal(got)
		}
	}
	if got := relayTestRequest(p, key, relayBody("voip", fmtRelayCall(20))).Code; got != 429 {
		t.Fatal("push quota not enforced", got)
	}
	now = now.Add(time.Minute)
	if got := relayTestRequest(p, key, relayBody("sms", "")).Code; got != 200 {
		t.Fatal(got)
	}
	if got := relayTestRequest(p, key, relayBody("sms", "")).Code; got != 200 {
		t.Fatal(got)
	}
	if *calls != 21 {
		t.Fatal("SMS dedup failed", *calls)
	}
	now = now.Add(6 * time.Minute)
	if got := relayTestRequest(p, key, body).Code; got != 200 {
		t.Fatal(got)
	}
	if *calls != 22 {
		t.Fatal("expiry did not clear dedup", *calls)
	}
}
func fmtRelayCall(n int) string {
	return strings.Repeat("0", 30) + string("0123456789abcdef"[n/16]) + string("0123456789abcdef"[n%16])
}
func TestRelayParallelDuplicateAndSanitizedErrors(t *testing.T) {
	p, key, _ := relayFixture()
	entered := make(chan struct{})
	release := make(chan struct{})
	var wg sync.WaitGroup
	p.Send = func(context.Context, relayPush) (int, string, error) {
		close(entered)
		<-release
		return 400, "private-token-or-url", nil
	}
	body := relayBody("voip", strings.Repeat("b", 32))
	wg.Add(1)
	go func() {
		defer wg.Done()
		w := relayTestRequest(p, key, body)
		if w.Code != 502 || strings.Contains(w.Body.String(), "private-token") {
			t.Error("upstream response was not sanitized")
		}
	}()
	<-entered
	if got := relayTestRequest(p, key, body).Code; got != 409 {
		t.Error("pending duplicate reached provider", got)
	}
	close(release)
	wg.Wait()
	p.Send = func(context.Context, relayPush) (int, string, error) { return 200, "", nil }
	if got := relayTestRequest(p, key, body).Code; got != 200 {
		t.Fatal("failed delivery cannot retry", got)
	}
}
func TestRelayGrantIssueAndRevoke(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VOICE_WEB_RELAY_GRANTS_FILE", filepath.Join(dir, "grants.json"))
	output := filepath.Join(dir, "credential")
	if err := relayCommand(context.Background(), []string{"relay-issue", "synthetic backend", "production", output}); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	grants, err := loadRelayGrants()
	if err != nil || len(grants) != 1 {
		t.Fatal("grant missing")
	}
	if relayCredential("Bearer "+strings.TrimSpace(string(raw))) != grants[0].Hash {
		t.Fatal("credential mismatch")
	}
	info, _ := os.Stat(output)
	if info.Mode().Perm() != 0600 {
		t.Fatal("unsafe output mode")
	}
	stored, _ := os.ReadFile(relayGrantsPath())
	if bytes.Contains(stored, bytes.TrimSpace(raw)) {
		t.Fatal("stored plaintext credential")
	}
	if err := relayCommand(context.Background(), []string{"relay-issue", "synthetic backend", "production", output}); err == nil {
		t.Fatal("overwrote existing credential")
	}
	if err := relayCommand(context.Background(), []string{"relay-revoke", grants[0].ID}); err != nil {
		t.Fatal(err)
	}
	grants, _ = loadRelayGrants()
	if len(grants) != 0 {
		t.Fatal("grant not revoked")
	}
}

type relayRoundTripper func(*http.Request) (*http.Response, error)

func (f relayRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestRelayClientConfigurationAndFixedPayload(t *testing.T) {
	key := "sxr_" + strings.Repeat("3", 64)
	file := filepath.Join(t.TempDir(), "credential")
	_ = os.WriteFile(file, []byte(key), 0600)
	t.Setenv("VOICE_WEB_PUSH_RELAY_KEY_FILE", file)
	t.Setenv("VOICE_WEB_PUSH_RELAY_URL", "https://relay.example.org/push-relay/v1/push")
	previous := relayHTTPClient
	defer func() { relayHTTPClient = previous }()
	requests := 0
	relayHTTPClient = &http.Client{Transport: relayRoundTripper(func(r *http.Request) (*http.Response, error) {
		requests++
		if r.Header.Get("Authorization") != "Bearer "+key {
			t.Error("missing backend credential")
		}
		var payload map[string]any
		_ = json.NewDecoder(r.Body).Decode(&payload)
		if len(payload) != 4 || payload["kind"] != "voip" || payload["environment"] != "production" {
			t.Error("unexpected forwarded payload")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"apns_status":200}`)), Header: make(http.Header)}, nil
	})}
	status, _, err := dispatchVoIP(context.Background(), voipDevice{Token: strings.Repeat("a", 64)}, strings.Repeat("b", 32))
	if status != 200 || err != nil || requests != 1 {
		t.Fatal("relay forwarding failed")
	}
	for _, endpoint := range []string{"http://relay.example.org/push-relay/v1/push", "https://user:secret@relay.example.org/", "https://relay.example.org/?key=secret"} {
		t.Setenv("VOICE_WEB_PUSH_RELAY_URL", endpoint)
		if _, _, err = dispatchVoIP(context.Background(), voipDevice{}, ""); err == nil {
			t.Error("unsafe relay URL accepted")
		}
	}
	if requests != 1 {
		t.Fatal("unsafe URL reached network")
	}
	t.Setenv("VOICE_WEB_PUSH_RELAY_URL", "https://relay.example.org/push-relay/v1/push")
	relayHTTPClient = &http.Client{Transport: relayRoundTripper(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 502, Body: io.NopCloser(strings.NewReader(`{"apns_status":400,"reason":"private response data"}`)), Header: make(http.Header)}, nil
	})}
	_, reason, err := dispatchVoIP(context.Background(), voipDevice{}, "")
	if err != nil || reason != "ProviderRejected" {
		t.Fatal("untrusted relay reason was not sanitized")
	}
}
