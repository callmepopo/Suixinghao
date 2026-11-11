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
		case "AT+QCSQ":
			return "+QCSQ: \"LTE\",71,-101,135,-10", nil
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
	if queries.Load() != 3 || diagnosticCache.view.NetworkStatus != "漫游已注册" || diagnosticCache.view.SIMStatus != "就绪" || *diagnosticCache.view.SignalRSSI != 21 ||
		*diagnosticCache.view.SignalSINR != 7 || *diagnosticCache.view.SignalRSRP != -101 {
		t.Fatal("sampling/cache failed")
	}
}

func TestIdleSamplingFallsBackToCSQ(t *testing.T) {
	oldAT, oldView := phoneAT, phone.view
	defer func() {
		phoneAT = oldAT
		phone.view = oldView
		diagnosticCache.next = time.Time{}
		diagnosticCache.phase = 0
		diagnosticCache.noQCSQ = false
	}()
	var sent []string
	phoneAT = func(_, command string) (string, error) {
		sent = append(sent, command)
		switch command {
		case "AT+CPIN?":
			return "+CPIN: READY", nil
		case "AT+CEREG?":
			return "+CEREG: 0,1", nil
		case "AT+CSQ":
			return "+CSQ: 18,99", nil
		}
		return "", errors.New("ERROR")
	}
	phone.view = phoneView{State: "idle", Available: true}
	diagnosticCache.next, diagnosticCache.phase, diagnosticCache.noQCSQ = time.Time{}, 0, false
	for i := 0; i < 3; i++ {
		sampleNetworkIdle()
	}
	if !diagnosticCache.noQCSQ || diagnosticCache.view.SignalSINR != nil {
		t.Fatal("QCSQ failure not remembered")
	}
	diagnosticCache.next = time.Time{}
	for i := 0; i < 3; i++ {
		sampleNetworkIdle()
	}
	if sent[len(sent)-1] != "AT+CSQ" || *diagnosticCache.view.SignalRSSI != 18 || diagnosticCache.view.SignalSINR != nil {
		t.Fatalf("fallback failed: %v", sent)
	}
}

func TestCSQFromRSSI(t *testing.T) {
	for _, c := range []struct{ in, want int }{{71, 21}, {-71, 21}, {-51, 31}, {-120, 0}} {
		if got := csqFromRSSI(intPtr(c.in)); got == nil || *got != c.want {
			t.Fatalf("%d -> %v", c.in, got)
		}
	}
	if csqFromRSSI(nil) != nil || csqFromRSSI(intPtr(0)) != nil {
		t.Fatal("missing RSSI should stay empty")
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
