package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func appTestSetup(t *testing.T) (http.Handler, string) {
	t.Helper()
	t.Setenv("VOICE_WEB_APP_KEYS_FILE", filepath.Join(t.TempDir(), "keys.json"))
	admin := "test-admin-session-with-enough-length"
	sessions.Store(admin, time.Now().Add(time.Hour))
	t.Cleanup(func() { sessions.Delete(admin) })
	return routes(), admin
}
func appTestRequest(h http.Handler, method, path, key, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if key != "" {
		r.Header.Set("Authorization", "Bearer "+key)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func issueTestKey(t *testing.T, h http.Handler, admin string) (string, string) {
	t.Helper()
	w := appTestRequest(h, "POST", "/voice-test/app-keys", admin, `{"name":"test phone"}`)
	if w.Code != 201 {
		t.Fatalf("issue status %d", w.Code)
	}
	var result struct {
		ID  string `json:"id"`
		Key string `json:"key"`
	}
	if json.Unmarshal(w.Body.Bytes(), &result) != nil || result.Key == "" {
		t.Fatal("issue response")
	}
	return result.ID, result.Key
}
func TestAppKeyLifecycleAndRevocation(t *testing.T) {
	h, admin := appTestSetup(t)
	id, key := issueTestKey(t, h, admin)
	disk, err := os.ReadFile(appKeysPath())
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(disk), key) {
		t.Fatal("plaintext key persisted")
	}
	info, _ := os.Stat(appKeysPath())
	if info.Mode().Perm() != 0600 {
		t.Fatal("key file permissions")
	}
	listed := appTestRequest(h, "GET", "/voice-test/app-keys", admin, "")
	if listed.Code != 200 || strings.Contains(listed.Body.String(), "hash") || strings.Contains(listed.Body.String(), key) {
		t.Fatal("key listing leaks secret")
	}
	for _, bad := range []string{"", admin, "hdk_" + strings.Repeat("0", 64)} {
		if w := appTestRequest(h, "POST", "/voice-test/app/session", bad, "{}"); w.Code != 401 && w.Code != 403 {
			t.Fatalf("bad app auth %d", w.Code)
		}
	}
	w := appTestRequest(h, "POST", "/voice-test/app/session", key, "{}")
	if w.Code != 200 {
		t.Fatalf("session status %d", w.Code)
	}
	var result struct {
		Token   string `json:"token"`
		Expires int    `json:"expires_in"`
	}
	json.Unmarshal(w.Body.Bytes(), &result)
	if result.Expires < 3600 {
		t.Fatal("app session shorter than maximum call")
	}
	t.Cleanup(func() { sessions.Delete(result.Token); appSessionParents.Delete(result.Token) })
	if w := appTestRequest(h, "GET", "/voice-test/status", result.Token, ""); w.Code != 200 {
		t.Fatalf("status %d", w.Code)
	}
	if w := appTestRequest(h, "GET", "/voice-test/app-keys", result.Token, ""); w.Code != 401 {
		t.Fatal("app session can administer keys")
	}
	if w := appTestRequest(h, "POST", "/voice-test/app-keys", key, `{"name":"unauthorized"}`); w.Code != 401 {
		t.Fatal("app key can issue keys")
	}
	if w := appTestRequest(h, "DELETE", "/voice-test/app-keys?id="+id, admin, ""); w.Code != 204 {
		t.Fatalf("revoke %d", w.Code)
	}
	if w := appTestRequest(h, "GET", "/voice-test/status", result.Token, ""); w.Code != 401 {
		t.Fatal("revoked session still works")
	}
	if w := appTestRequest(h, "POST", "/voice-test/app/session", key, "{}"); w.Code != 401 {
		t.Fatal("revoked key still works")
	}
	if w := appTestRequest(h, "GET", "/voice-test/status", admin, ""); w.Code != 200 {
		t.Fatal("web session broken")
	}
}
func TestAppProxyAllowlistAndCredentialIsolation(t *testing.T) {
	h, admin := appTestSetup(t)
	_, key := issueTestKey(t, h, admin)
	oldUp, oldConfig, oldClient := upstream, configPath, client
	t.Cleanup(func() { upstream = oldUp; configPath = oldConfig; client = oldClient })
	configPath = filepath.Join(t.TempDir(), "config.yaml")
	os.WriteFile(configPath, []byte("web:\n  password: test-signing-material\n"), 0600)
	calls := 0
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") || strings.Contains(auth, key) {
			t.Error("app key forwarded upstream")
		}
		if r.URL.Query().Has("token") {
			t.Error("unexpected query forwarded")
		}
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/devices" {
			w.Write([]byte(`{"devices":[]}`))
			return
		}
		if r.URL.Path == "/api/sms/contacts" {
			w.Write([]byte(`[]`))
			return
		}
		if r.URL.Path == "/api/sms/send" {
			w.Write([]byte(`{"parts_total":1}`))
			return
		}
		t.Error("unexpected upstream path")
		w.WriteHeader(404)
	}))
	defer fake.Close()
	upstream = fake.URL
	client = fake.Client()
	client.Timeout = 5 * time.Second
	for _, path := range []string{"/devices", "/sms/contacts?token=must-not-forward"} {
		if w := appTestRequest(h, "GET", "/voice-test/app"+path, key, ""); w.Code != 200 {
			t.Fatalf("proxy %d", w.Code)
		}
	}
	if w := appTestRequest(h, "POST", "/voice-test/app/sms/send", key, `{"device_id":"demo","phone":"+8613800000000","message":"test fixture"}`); w.Code != 200 {
		t.Fatalf("send %d", w.Code)
	}
	before := calls
	for _, path := range []string{"/settings", "/devices/demo/actions/at"} {
		if w := appTestRequest(h, "GET", "/voice-test/app"+path, key, ""); w.Code != 404 {
			t.Fatal("path outside allowlist")
		}
	}
	if w := appTestRequest(h, "POST", "/voice-test/app/sms/send", key, `{"cmd":"AT"}`); w.Code != 400 {
		t.Fatal("unexpected body field")
	}
	if w := appTestRequest(h, "DELETE", "/voice-test/app/sms/thread", key, ""); w.Code != 400 {
		t.Fatal("unexpected method")
	}
	r := httptest.NewRequest("GET", origin+"/voice-test/app/devices", nil)
	r.Header.Set("Authorization", "Bearer "+key)
	r.Header.Set("Origin", "https://untrusted.invalid")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("cross origin accepted")
	}
	if calls != before {
		t.Fatal("rejected request reached upstream")
	}
}

func TestAppProxyMarksOnlyScopedSMSThreadRead(t *testing.T) {
	h, admin := appTestSetup(t)
	_, key := issueTestKey(t, h, admin)
	oldUp, oldConfig, oldClient := upstream, configPath, client
	t.Cleanup(func() { upstream = oldUp; configPath = oldConfig; client = oldClient })
	configPath = filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(configPath, []byte("web:\n  password: synthetic-signing-material\n"), 0600); err != nil {
		t.Fatal(err)
	}
	calls := 0
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != "PATCH" || r.URL.Path != "/api/sms/thread" || r.URL.Query().Get("iccid") != "synthetic-card" ||
			r.URL.Query().Get("peer") != "synthetic-peer" || r.URL.Query().Has("token") ||
			!strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") || strings.Contains(r.Header.Get("Authorization"), key) {
			t.Error("read marker escaped its scope")
		}
		var body map[string]uint64
		if json.NewDecoder(r.Body).Decode(&body) != nil || len(body) != 1 || body["through_id"] != 42 {
			t.Error("read boundary was not forwarded")
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok","unread_count":0}`))
	}))
	defer fake.Close()
	upstream, client = fake.URL, fake.Client()
	path := "/voice-test/app/sms/thread?iccid=synthetic-card&peer=synthetic-peer&token=private"
	for _, body := range []string{`{}`, `{"through_id":0}`, `{"through_id":42,"extra":1}`} {
		if got := appTestRequest(h, "PATCH", path, key, body).Code; got != 400 {
			t.Fatalf("unsafe marker accepted: %d", got)
		}
	}
	if calls != 0 {
		t.Fatal("rejected marker reached upstream")
	}
	if got := appTestRequest(h, "PATCH", path, admin, `{"through_id":42}`).Code; got != 401 {
		t.Fatalf("admin marked SMS: %d", got)
	}
	w := appTestRequest(h, "PATCH", path, key, `{"through_id":42}`)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"unread_count":0`) || calls != 1 {
		t.Fatalf("scoped read marker failed: status=%d calls=%d", w.Code, calls)
	}
}

func TestAppSMSDeletionScopeAndAuthentication(t *testing.T) {
	h, admin := appTestSetup(t)
	_, key := issueTestKey(t, h, admin)
	oldUp, oldConfig, oldClient := upstream, configPath, client
	t.Cleanup(func() { upstream = oldUp; configPath = oldConfig; client = oldClient })
	configPath = filepath.Join(t.TempDir(), "config.yaml")
	os.WriteFile(configPath, []byte("web:\n  password: test-signing-material\n"), 0600)
	calls := 0
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != "DELETE" || strings.Contains(r.Header.Get("Authorization"), key) {
			t.Error("unsafe delete forwarding")
		}
		switch r.URL.Path {
		case "/api/sms/thread":
			if r.URL.Query().Get("iccid") != "synthetic-card" || r.URL.Query().Get("peer") != "+synthetic-peer" {
				t.Error("incorrect SIM/thread scope")
			}
		case "/api/sms/messages/42":
		default:
			t.Error("unexpected delete target")
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	}))
	defer fake.Close()
	upstream, client = fake.URL, fake.Client()
	for _, path := range []string{"/sms/thread", "/sms/thread?peer=x", "/sms/thread?iccid=a&imsi=b&peer=x", "/sms/messages/0", "/sms/messages/00", "/sms/messages/bad", "/sms/messages/42/extra"} {
		if got := appTestRequest(h, "DELETE", "/voice-test/app"+path, key, "").Code; got != 400 {
			t.Fatalf("invalid deletion accepted: %s %d", path, got)
		}
	}
	for _, token := range []string{"", admin} {
		if got := appTestRequest(h, "DELETE", "/voice-test/app/sms/messages/42", token, "").Code; got != 401 && got != 403 {
			t.Fatal("delete without App Key")
		}
	}
	if calls != 0 {
		t.Fatal("rejected deletion reached upstream")
	}
	for _, path := range []string{"/sms/thread?iccid=synthetic-card&peer=%2Bsynthetic-peer", "/sms/messages/42"} {
		if got := appTestRequest(h, "DELETE", "/voice-test/app"+path, key, "").Code; got != 200 {
			t.Fatalf("delete status %d", got)
		}
	}
	if calls != 2 {
		t.Fatal("deletion not forwarded exactly once")
	}
}
