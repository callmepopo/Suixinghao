package main

import (
	"bufio"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestEventStreamInitialAndChangedSnapshot(t *testing.T) {
	key := "events-test"
	sessions.Store(key, time.Now().Add(time.Minute))
	defer sessions.Delete(key)
	phone.Lock()
	old := phone.view
	phone.view = phoneView{State: "idle", Sequence: 1}
	phone.Unlock()
	defer func() { phone.Lock(); phone.view = old; phone.Unlock() }()
	server := httptest.NewServer(http.HandlerFunc(phoneEvents))
	defer server.Close()
	req, _ := http.NewRequest("GET", server.URL, nil)
	req.Header.Set("Origin", origin)
	req.Host = "voice.example.org:40443"
	req.Header.Set("Authorization", "Bearer "+key)
	client := &http.Client{Timeout: 5 * time.Second}
	resp, e := client.Do(req)
	if e != nil {
		t.Fatal(e)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatal(resp.StatusCode)
	}
	scan := bufio.NewScanner(resp.Body)
	initial := false
	changed := false
	for scan.Scan() {
		line := scan.Text()
		if strings.HasPrefix(line, "data:") && !initial {
			if !strings.Contains(line, `"state":"idle"`) {
				t.Fatal(line)
			}
			initial = true
			phone.Lock()
			phone.view = phoneView{State: "ringing", CallID: "new", Sequence: 2}
			phone.Unlock()
		} else if strings.HasPrefix(line, "data:") && initial {
			changed = strings.Contains(line, `"state":"ringing"`)
			break
		}
	}
	if !initial || !changed {
		t.Fatal("event updates missing")
	}
}
func TestNativeLoginAndNoCrossOrigin(t *testing.T) {
	old := upstream
	defer func() { upstream = old }()
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/auth/login" {
			t.Fatal("wrong login route")
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"token":"upstream-test"}`))
	}))
	defer fake.Close()
	upstream = fake.URL
	r := httptest.NewRequest("POST", origin+"/login", strings.NewReader(`{"username":"test","password":"test-password"}`))
	w := httptest.NewRecorder()
	nativeLogin(w, r)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "expires_at") {
		t.Fatal("native session missing")
	}
	r = httptest.NewRequest("POST", origin+"/login", strings.NewReader(`{"username":"test","password":"test-password"}`))
	r.Header.Set("Origin", "https://other.invalid")
	w = httptest.NewRecorder()
	nativeLogin(w, r)
	if w.Code != 403 {
		t.Fatal("cross origin accepted")
	}
}
