package main

import (
	"encoding/json"
	"errors"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestDiagnosticsAuthAndNoModemAccess(t *testing.T) {
	old := phoneAT
	defer func() { phoneAT = old }()
	phoneAT = func(string, string) (string, error) { t.Fatal("HTTP diagnostics must use cache"); return "", nil }
	for _, authorized := range []bool{false, true} {
		key := "diagnostic-test"
		if authorized {
			sessions.Store(key, time.Now().Add(time.Minute))
			defer sessions.Delete(key)
		}
		r := httptest.NewRequest("GET", origin+"/voice-test/diagnostics", nil)
		r.Header.Set("Origin", origin)
		if authorized {
			r.Header.Set("Authorization", "Bearer "+key)
		}
		w := httptest.NewRecorder()
		phoneDiagnostics(w, r)
		if !authorized && w.Code != 401 {
			t.Fatal(w.Code)
		}
		if authorized {
			var v diagnosticView
			if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &v) != nil || v.ServerVersion == "" {
				t.Fatal(w.Body.String())
			}
		}
	}
}

func TestIdleSamplingSkipsCallsAndUsesCache(t *testing.T) {
	oldAT, oldView := phoneAT, phone.view
	defer func() {
		phoneAT = oldAT
		phone.view = oldView
		diagnosticCache.next = time.Time{}
		diagnosticCache.phase = 0
	}()
	var queries atomic.Int32
	phoneAT = func(_, command string) (string, error) {
		queries.Add(1)
		switch command {
		case "AT+CPIN?":
			return "+CPIN: READY", nil
		case "AT+CEREG?":
			return "+CEREG: 0,5", nil
		case "AT+CSQ":
			return "+CSQ: 21,99", nil
		}
		return "", errors.New("unexpected write")
	}
	phone.view = phoneView{State: "active", Available: true}
	sampleNetworkIdle()
	if queries.Load() != 0 {
		t.Fatal("queried during call")
	}
	phone.view.State = "idle"
	diagnosticCache.next = time.Time{}
	diagnosticCache.phase = 0
	sampleNetworkIdle()
	sampleNetworkIdle()
	sampleNetworkIdle()
	sampleNetworkIdle()
	if queries.Load() != 3 || diagnosticCache.view.NetworkStatus != "漫游已注册" || diagnosticCache.view.SIMStatus != "就绪" || *diagnosticCache.view.SignalRSSI != 21 {
		t.Fatal("sampling/cache failed")
	}
}

func TestStatusSnapshotDoesNotWaitForRouteAndMarksStale(t *testing.T) {
	p := &controller{view: phoneView{State: "active", Available: true, CallID: "original", ObservedAt: time.Now().Add(-10 * time.Second).UTC().Format(time.RFC3339Nano)}}
	p.publish()
	p.Lock()
	defer p.Unlock()
	started := time.Now()
	v := p.snapshot()
	if time.Since(started) > 100*time.Millisecond || v.Available || v.CallID != "original" {
		t.Fatal("snapshot blocked or stale state was trusted")
	}
}
