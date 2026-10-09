package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

const origin = "https://voice.example.org:40443"

// Never let ordinary unit tests write to a developer's actual service state.
func TestMain(m *testing.M) {
	directory, err := os.MkdirTemp("", "sxh-server-tests-")
	if err != nil {
		panic(err)
	}
	for name, file := range map[string]string{
		"VOICE_WEB_APP_KEYS_FILE":           "app-keys.json",
		"VOICE_WEB_RECORDING_FILE":          "recording.json",
		"VOICE_WEB_VOIP_TOKENS_FILE":        "voip-tokens.json",
		"VOICE_WEB_SMS_PUSH_TOKENS_FILE":    "sms-push-tokens.json",
		"VOICE_WEB_SMS_CURSOR_FILE":         "sms-push-cursor.json",
		"VOICE_WEB_CONNECTION_HISTORY_FILE": "connection-history.json",
	} {
		if err := os.Setenv(name, directory+"/"+file); err != nil {
			panic(err)
		}
	}
	if err := os.Setenv("VOICE_WEB_DATA_DIR", directory); err != nil {
		panic(err)
	}
	callFlag, recordRoot = dataPath("call.active"), dataPath("recordings")
	code := m.Run()
	os.RemoveAll(directory)
	os.Exit(code)
}

func TestAudioAuthorization(t *testing.T) {
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/devices" || r.Header.Get("Authorization") != "Bearer valid" {
			w.WriteHeader(401)
			return
		}
		w.WriteHeader(200)
	}))
	defer fake.Close()
	old := upstream
	upstream = fake.URL
	defer func() { upstream = old }()
	for _, tt := range []struct {
		name, origin, auth string
		code               int
	}{{"cross origin", "https://other.example", "Bearer valid", 403}, {"missing token", origin, "", 401}, {"bad token", origin, "Bearer invalid", 401}, {"valid", origin, "Bearer valid", 200}} {
		t.Run(tt.name, func(t *testing.T) {
			r := httptest.NewRequest("POST", origin+"/voice-test/session", nil)
			r.Header.Set("Origin", tt.origin)
			r.Header.Set("Authorization", tt.auth)
			w := httptest.NewRecorder()
			session(w, r)
			if w.Code != tt.code {
				t.Fatalf("status %d", w.Code)
			}
			if tt.code == 200 {
				cs := w.Result().Cookies()
				if len(cs) != 1 || !cs[0].Secure || !cs[0].HttpOnly || cs[0].SameSite != http.SameSiteStrictMode {
					t.Fatal("cookie protection")
				}
				r.AddCookie(cs[0])
				r.Header.Del("Authorization")
				if !permitted(r) {
					t.Fatal("valid session rejected")
				}
				sessions.Store(cs[0].Value, time.Now().Add(-time.Second))
				if permitted(r) {
					t.Fatal("expired session accepted")
				}
			}
		})
	}
}
func TestStreamRejectsBeforeAudio(t *testing.T) {
	r := httptest.NewRequest("GET", origin+"/voice-test/stream", nil)
	r.Header.Set("Origin", origin)
	w := httptest.NewRecorder()
	stream(w, r)
	if w.Code != 401 {
		t.Fatalf("status %d", w.Code)
	}
}

func TestSameOriginAcceptsPortAndDefaultPort(t *testing.T) {
	allowedOrigins["https://allowed.example.org"] = true
	defer delete(allowedOrigins, "https://allowed.example.org")
	for _, tt := range []struct {
		name, origin, host string
		want               bool
	}{
		{"explicit port", "https://voice.example.org:40443", "voice.example.org:40443", true},
		{"default port origin", "https://voice.example.org", "voice.example.org:443", true},
		{"no host port", "https://voice.example.org", "voice.example.org", true},
		{"trailing slash", "https://voice.example.org:40443/", "voice.example.org:40443", true},
		{"other port", "https://voice.example.org:8443", "voice.example.org:40443", false},
		{"other host", "https://evil.example", "voice.example.org:40443", false},
		{"suffix lookalike", "https://voice.example.org.evil.example", "voice.example.org:40443", false},
		{"http origin", "http://voice.example.org", "voice.example.org:40443", false},
		{"missing origin", "", "voice.example.org:40443", false},
		{"injected host", "https://other.example", "voice.example.org/x", false},
		{"whitelisted origin", "https://allowed.example.org", "voice.example.org/x", true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", origin+"/voice-test/status", nil)
			r.Host = tt.host
			if tt.origin != "" {
				r.Header.Set("Origin", tt.origin)
			}
			if got := sameOrigin(r); got != tt.want {
				t.Fatalf("sameOrigin=%v want %v", got, tt.want)
			}
		})
	}
}

// 浏览器会话必须同时给 Cookie 和响应体 token：页面从 443 打开而反代在 :40443 时，
// 浏览器会丢弃跨源 Set-Cookie，此时页面只能用会话内存里的 Bearer。
func TestBrowserSessionSetsCookieAndReturnsToken(t *testing.T) {
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	defer fake.Close()
	old := upstream
	upstream = fake.URL
	defer func() { upstream = old }()
	r := httptest.NewRequest("POST", origin+"/voice-test/session", nil)
	r.Host = "voice.example.org"
	r.Header.Set("Origin", "https://voice.example.org")
	r.Header.Set("Authorization", "Bearer valid")
	w := httptest.NewRecorder()
	session(w, r)
	if w.Code != 200 {
		t.Fatalf("status %d", w.Code)
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Path != "/voice-test" || !cookies[0].Secure || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatalf("cookie %+v", cookies)
	}
	var body struct {
		Ready bool   `json:"ready"`
		Token string `json:"token"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || !body.Ready {
		t.Fatalf("body %q err %v", w.Body.String(), err)
	}
	if body.Token != cookies[0].Value {
		t.Fatal("body token and cookie must be the same session")
	}
}
