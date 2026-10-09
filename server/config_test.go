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

func TestRecordingDefaultsOnAndPersists(t *testing.T) {
	old := os.Getenv("VOICE_WEB_RECORDING_FILE")
	defer os.Setenv("VOICE_WEB_RECORDING_FILE", old)
	path := filepath.Join(t.TempDir(), "recording.json")
	os.Setenv("VOICE_WEB_RECORDING_FILE", path)

	if !recordingEnabled() {
		t.Fatal("missing config must default to recording enabled")
	}
	if e := setRecording(false); e != nil {
		t.Fatalf("setRecording: %v", e)
	}
	if recordingEnabled() {
		t.Fatal("disabled state not persisted")
	}
	b, e := os.ReadFile(path)
	if e != nil || !strings.Contains(string(b), "false") {
		t.Fatalf("config file %q err %v", string(b), e)
	}
	fi, _ := os.Stat(path)
	if fi.Mode().Perm() != 0600 {
		t.Fatalf("config permissions %v", fi.Mode().Perm())
	}
	if e := setRecording(true); e != nil || !recordingEnabled() {
		t.Fatalf("re-enable failed: %v", e)
	}
	// 损坏的文件按默认开启处理，避免静默停止录音。
	os.WriteFile(path, []byte("{not json"), 0600)
	if !recordingEnabled() {
		t.Fatal("corrupt config must fall back to enabled")
	}
}

func TestRecordingActionAuthAndToggle(t *testing.T) {
	old := os.Getenv("VOICE_WEB_RECORDING_FILE")
	defer os.Setenv("VOICE_WEB_RECORDING_FILE", old)
	os.Setenv("VOICE_WEB_RECORDING_FILE", filepath.Join(t.TempDir(), "recording.json"))

	r := httptest.NewRequest("GET", origin+"/voice-test/recording", nil)
	r.Host = "voice.example.org"
	r.Header.Set("Origin", "https://voice.example.org")
	w := httptest.NewRecorder()
	recordingAction(w, r)
	if w.Code != 401 {
		t.Fatalf("unauthenticated status %d", w.Code)
	}

	key := "test-session-key"
	sessions.Store(key, time.Now().Add(time.Minute))
	defer sessions.Delete(key)
	body := strings.NewReader(`{"enabled":false}`)
	r = httptest.NewRequest("POST", origin+"/voice-test/recording", body)
	r.Host = "voice.example.org"
	r.Header.Set("Origin", "https://voice.example.org")
	r.Header.Set("Authorization", "Bearer "+key)
	w = httptest.NewRecorder()
	recordingAction(w, r)
	if w.Code != 200 {
		t.Fatalf("toggle status %d", w.Code)
	}
	var got struct {
		Enabled bool `json:"enabled"`
	}
	if json.Unmarshal(w.Body.Bytes(), &got) != nil || got.Enabled {
		t.Fatalf("toggle response %q", w.Body.String())
	}
	if recordingEnabled() {
		t.Fatal("toggle did not persist")
	}
}

// 浏览器同源 fetch 不带 Origin，只带会话 Cookie；这类请求必须放行（此前误判 403）。
func TestSameOriginBrowserWithoutOriginHeader(t *testing.T) {
	key := "cookie-only-not-a-real-session"

	r := httptest.NewRequest("GET", origin+"/voice-test/status", nil)
	r.Host = "voice.example.org:40443"
	r.AddCookie(&http.Cookie{Name: "voice_test", Value: key})
	if !allowedOrigin(r) {
		t.Fatal("same-origin browser request with session cookie must be allowed")
	}

	// 无 Origin、无 Cookie、无 Bearer 必须拒绝
	bare := httptest.NewRequest("GET", origin+"/voice-test/status", nil)
	bare.Host = "voice.example.org:40443"
	if allowedOrigin(bare) {
		t.Fatal("anonymous request must be rejected")
	}

	// 跨源仍然拒绝
	cross := httptest.NewRequest("GET", origin+"/voice-test/status", nil)
	cross.Host = "voice.example.org:40443"
	cross.Header.Set("Origin", "https://evil.example")
	cross.AddCookie(&http.Cookie{Name: "voice_test", Value: key})
	if allowedOrigin(cross) {
		t.Fatal("cross-origin request must be rejected")
	}

	// 敏感路径（session/login）无 Origin、无 Bearer 时不允许用 Cookie 绕过
	sess := httptest.NewRequest("POST", origin+"/voice-test/session", nil)
	sess.Host = "voice.example.org:40443"
	sess.AddCookie(&http.Cookie{Name: "voice_test", Value: key})
	if allowedOrigin(sess) {
		t.Fatal("session exchange must still require a bearer token")
	}
}
