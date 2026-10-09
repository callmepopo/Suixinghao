package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDialNumberBoundary(t *testing.T) {
	for _, tt := range []struct {
		input, want string
		valid       bool
	}{
		{"13800000000", "+8613800000000", true},
		{" +441234567890 ", "+441234567890", true},
		{"110", "110", true},
		{"10086", "10086", true},
		{"95347", "95347", true},
		{"123456", "123456", true},
		{"01012345678", "01012345678", true},
		{"057112345678", "057112345678", true},
		{"23456789", "23456789", true},
		{"4001234567", "4001234567", true},
		{"8001234567", "8001234567", true},
		{"12", "12", false},
		{"1234567890123", "1234567890123", false},
		{"13800000000;ATH", "13800000000;ATH", false},
		{"10086;ATH", "10086;ATH", false},
		{"4001234567\nAT+CFUN=0", "4001234567\nAT+CFUN=0", false},
		{"+8613800000000\rAT+CFUN=0", "+8613800000000\rAT+CFUN=0", false},
		{"+00000000", "+00000000", false},
		{"", "", false},
	} {
		got := normalizeNumber(tt.input)
		if got != tt.want || dialNumber.MatchString(got) != tt.valid {
			t.Errorf("number boundary failed: %q", tt.input)
		}
	}
}
func TestVoiceStateIgnoresDataCalls(t *testing.T) {
	for _, tt := range []struct{ response, want string }{
		{"\r\nOK\r\n", "idle"},
		{"+CLCC: 1,0,0,1,0", "idle"},
		{"+CLCC: 1,0,2,0,0", "dialing"},
		{"+CLCC: 1,1,4,0,0", "ringing"},
		{"+CLCC: 1,1,5,0,0", "ringing"},
		{"+CLCC: 1,0,1,0,0", "busy"},
		{"+CLCC: 1,0,0,1,0\n+CLCC: 2,1,0,0,0", "active"},
	} {
		if got := voiceState(tt.response); got != tt.want {
			t.Errorf("got %s want %s", got, tt.want)
		}
	}
}
func TestPhoneRejectsUnauthorizedWithoutDeviceAccess(t *testing.T) {
	old := phoneAT
	defer func() { phoneAT = old }()
	phoneAT = func(string, string) (string, error) { t.Fatal("unauthorized request reached modem"); return "", nil }
	key := "phone-boundary-test"
	sessions.Store(key, time.Now().Add(time.Minute))
	defer sessions.Delete(key)
	for _, tt := range []struct {
		method, site, cookie string
		code                 int
	}{
		{"GET", origin, key, 405},
		{"POST", "https://other.example", key, 403},
		{"POST", origin, "", 401},
		{"POST", origin, key, 409}, // Valid login, but no owned sound session.
	} {
		r := httptest.NewRequest(tt.method, origin+"/voice-test/phone", strings.NewReader(`{"action":"dial","number":"13800000000"}`))
		r.Header.Set("Origin", tt.site)
		if tt.cookie != "" {
			r.AddCookie(&http.Cookie{Name: "voice_test", Value: tt.cookie})
		}
		w := httptest.NewRecorder()
		phoneAction(w, r)
		if w.Code != tt.code {
			t.Errorf("got %d want %d", w.Code, tt.code)
		}
	}
}
