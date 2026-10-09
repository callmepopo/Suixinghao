package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func fakeController(t *testing.T) (*controller, *[]string, *string) {
	t.Helper()
	oldAT, oldRoute, oldOn, oldOff := phoneAT, moduleRoute, mediaOn, mediaOff
	commands := []string{}
	state := "\r\nOK\r\n"
	phoneAT = func(_, c string) (string, error) {
		commands = append(commands, c)
		if c == "AT+CLCC" {
			return state, nil
		}
		return "OK", nil
	}
	moduleRoute = func(a string) error { commands = append(commands, "route:"+a); return nil }
	mediaOn = func(string) error { commands = append(commands, "media:on"); return nil }
	mediaOff = func() { commands = append(commands, "media:off") }
	t.Cleanup(func() { phoneAT, moduleRoute, mediaOn, mediaOff = oldAT, oldRoute, oldOn, oldOff })
	return &controller{view: phoneView{State: "idle"}}, &commands, &state
}
func TestPassiveIncomingDoesNotAnswer(t *testing.T) {
	p, cmd, s := fakeController(t)
	*s = `+CLCC: 2,1,4,0,0,"+8613800000000"`
	p.tick()
	if p.view.State != "ringing" || p.view.CallID == "" {
		t.Fatal("missing incoming event")
	}
	if len(*cmd) != 1 {
		t.Fatal("passive monitor wrote hardware")
	}
}
func TestOwnedCallLifecycle(t *testing.T) {
	p, cmd, s := fakeController(t)
	p.owned = true
	p.owner = "x"
	p.audioOwner = "x"
	p.started = time.Now()
	*s = "+CLCC: 1,0,0,0,0"
	p.tick()
	if !p.view.Media || p.run == "" {
		t.Fatal("no active media")
	}
	first := strings.Join(*cmd, ",")
	if !strings.Contains(first, "route:start,media:on") {
		t.Fatal("wrong route sequence")
	}
	*s = "OK"
	p.tick()
	if p.owned || p.view.Media || p.run != "" {
		t.Fatal("media leaked after hangup")
	}
	if !strings.Contains(strings.Join(*cmd, ","), "media:off,route:stop") {
		t.Fatal("release order")
	}
}
func TestControlFailureRetriesHangup(t *testing.T) {
	p, cmd, _ := fakeController(t)
	p.owned = true
	p.owner = "x"
	p.audioOwner = "x"
	p.run = "test"
	phoneAT = func(_, c string) (string, error) { *cmd = append(*cmd, c); return "", errors.New("offline") }
	for i := 0; i < 3; i++ {
		p.tick()
	}
	if !p.ending || p.run != "" || !strings.Contains(strings.Join(*cmd, ","), "ATH") {
		t.Fatal("did not fail closed and retain retry")
	}
}
func TestDisconnectedAudioEndsOwnedCall(t *testing.T) {
	p, cmd, s := fakeController(t)
	p.owned = true
	p.owner = "x"
	p.started = time.Now()
	*s = "+CLCC: 1,0,0,0,0"
	p.tick()
	if p.owned || !strings.Contains(strings.Join(*cmd, ","), "ATH") {
		t.Fatal("orphaned call")
	}
}
func TestStaleCallCannotBeAnswered(t *testing.T) {
	p, _, s := fakeController(t)
	_ = p
	*s = "+CLCC: 1,1,4,0,0"
	key := "stale-case"
	sessions.Store(key, time.Now().Add(time.Minute))
	defer sessions.Delete(key)
	phone.Lock()
	phone.audioOwner = key
	phone.view = phoneView{State: "idle"}
	phone.Unlock()
	defer func() { phone.Lock(); phone.audioOwner = ""; phone.view = phoneView{State: "idle"}; phone.Unlock() }()
	r := httptest.NewRequest("POST", origin+"/voice-test/phone", strings.NewReader(`{"action":"answer","call_id":"old"}`))
	r.Host = "voice.example.org:40443"
	r.Header.Set("Origin", origin)
	r.Header.Set("Authorization", "Bearer "+key)
	w := httptest.NewRecorder()
	phoneAction(w, r)
	if w.Code != http.StatusConflict {
		t.Fatal(w.Code)
	}
}

func TestDTMFInActiveCall(t *testing.T) {
	_, cmd, s := fakeController(t)
	*s = "+CLCC: 1,0,0,0,0" // active
	key := "dtmf-test-key"
	sessions.Store(key, time.Now().Add(time.Minute))
	defer sessions.Delete(key)

	phone.Lock()
	phone.owned = true
	phone.owner = key
	phone.audioOwner = key
	phone.view = phoneView{State: "active", CallID: "call-123"}
	phone.Unlock()
	defer func() {
		phone.Lock()
		phone.owned = false
		phone.owner = ""
		phone.audioOwner = ""
		phone.view = phoneView{State: "idle"}
		phone.Unlock()
	}()

	// 1. Invalid digit should return 400
	for _, bad := range []string{"", "12", ";ATH", "X", " "} {
		r := httptest.NewRequest("POST", origin+"/voice-test/phone", strings.NewReader(`{"action":"dtmf","call_id":"call-123","digit":"`+bad+`"}`))
		r.Host = "voice.example.org:40443"
		r.Header.Set("Origin", origin)
		r.Header.Set("Authorization", "Bearer "+key)
		w := httptest.NewRecorder()
		phoneAction(w, r)
		if w.Code != http.StatusBadRequest {
			t.Fatalf("bad digit %q gave code %d, want 400", bad, w.Code)
		}
	}

	// 2. Wrong call_id should return 409
	{
		r := httptest.NewRequest("POST", origin+"/voice-test/phone", strings.NewReader(`{"action":"dtmf","call_id":"wrong-call","digit":"1"}`))
		r.Host = "voice.example.org:40443"
		r.Header.Set("Origin", origin)
		r.Header.Set("Authorization", "Bearer "+key)
		w := httptest.NewRecorder()
		phoneAction(w, r)
		if w.Code != http.StatusConflict {
			t.Fatalf("wrong call_id gave code %d, want 409", w.Code)
		}
	}

	// 3. Valid digits 1, *, #, a should send AT+VTS=...
	for _, tt := range []struct {
		input, wantCmd, wantMsg string
	}{
		{"1", "AT+VTS=1", "已发送按键 1"},
		{"*", "AT+VTS=*", "已发送按键 *"},
		{"#", "AT+VTS=#", "已发送按键 #"},
		{"a", "AT+VTS=A", "已发送按键 A"},
	} {
		*cmd = nil
		r := httptest.NewRequest("POST", origin+"/voice-test/phone", strings.NewReader(`{"action":"dtmf","call_id":"call-123","digit":"`+tt.input+`"}`))
		r.Host = "voice.example.org:40443"
		r.Header.Set("Origin", origin)
		r.Header.Set("Authorization", "Bearer "+key)
		w := httptest.NewRecorder()
		phoneAction(w, r)
		if w.Code != http.StatusOK {
			t.Fatalf("digit %s returned %d: %s", tt.input, w.Code, w.Body.String())
		}
		if !strings.Contains(strings.Join(*cmd, ","), tt.wantCmd) {
			t.Fatalf("commands %v did not contain %s", *cmd, tt.wantCmd)
		}
		if phone.view.Message != tt.wantMsg {
			t.Fatalf("got message %q want %q", phone.view.Message, tt.wantMsg)
		}
	}

	// 4. When call is idle, DTMF must be rejected with 409
	*s = "OK" // modem idle
	r := httptest.NewRequest("POST", origin+"/voice-test/phone", strings.NewReader(`{"action":"dtmf","call_id":"call-123","digit":"1"}`))
	r.Host = "voice.example.org:40443"
	r.Header.Set("Origin", origin)
	r.Header.Set("Authorization", "Bearer "+key)
	w := httptest.NewRecorder()
	phoneAction(w, r)
	if w.Code != http.StatusConflict {
		t.Fatalf("idle DTMF gave code %d, want 409", w.Code)
	}
}
