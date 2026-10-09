package main

import (
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestConnectionSummaryAndRecovery(t *testing.T) {
	now := historyNow()
	events := []connectionEvent{
		{ID: "online", At: now - 300, Layer: "phone", State: "online"},
		{ID: "down", At: now - 240, Layer: "phone", State: "offline", Kind: "network_down", Reason: "no_network"},
		{ID: "up", At: now - 210, Layer: "phone", Kind: "network_up"},
		{ID: "retry1", At: now - 208, Layer: "phone", Kind: "retry"},
		{ID: "retry2", At: now - 206, Layer: "phone", Kind: "retry"},
		{ID: "connected", At: now - 205, Layer: "phone", State: "online", Kind: "connected"},
		{ID: "background", At: now - 200, Layer: "phone", State: "unknown", Kind: "observer_stop"},
	}
	s := summarizeConnections(events, "phone", now-86400, now)
	if s.Online != 65 || s.Offline != 35 || s.Unknown != 86300 || s.Interruptions != 1 || s.Rate == nil || math.Abs(*s.Rate-0.65) > 0.00001 {
		t.Fatalf("wrong summary: %+v", s)
	}
	o := connectionOutages(events)
	if len(o) != 1 || o[0].Incomplete || o[0].Attempts != 2 || *o[0].End-*o[0].NetworkRestored != 5 {
		t.Fatalf("wrong outage: %+v", o)
	}
}

func TestObservationGapIsUnknown(t *testing.T) {
	now := historyNow()
	events := []connectionEvent{{ID: "down", At: now - 300, Layer: "phone", State: "offline"}, {ID: "return", At: now - 100, Layer: "phone", State: "online"}}
	s := summarizeConnections(events, "phone", now-86400, now)
	if s.Offline != 90 || s.Online != 90 || s.Unknown != 86220 {
		t.Fatalf("gap counted as online/offline: %+v", s)
	}
	o := connectionOutages(events)
	if len(o) != 1 || !o[0].Incomplete || o[0].End != nil {
		t.Fatal("gap must not produce an exact recovery duration")
	}
	if s := summarizeConnections(nil, "module", now-86400, now); s.Rate != nil || s.Coverage != 0 {
		t.Fatal("missing data must not be 0% or 100% availability")
	}
}

func TestHistoryPersistenceIsolationAndValidation(t *testing.T) {
	h, admin := appTestSetup(t)
	old := histories
	path := filepath.Join(t.TempDir(), "history.json")
	histories = &historyStore{path: path}
	t.Cleanup(func() { histories = old })
	id1, key1 := issueTestKey(t, h, admin)
	_, key2 := issueTestKey(t, h, admin)
	e := connectionEvent{ID: randomHistoryID(), At: historyNow() - 10, Layer: "phone", Kind: "network_down", State: "offline", Reason: "no_network"}
	body, _ := json.Marshal(map[string]any{"events": []connectionEvent{e}})
	for i := 0; i < 2; i++ {
		w := appTestRequest(h, "POST", "/voice-test/app/connection-history", key1, string(body))
		if w.Code != 200 {
			t.Fatalf("upload: %d", w.Code)
		}
	}
	if len(histories.events) != 1 || histories.events[0].Owner != id1 {
		t.Fatal("retry duplicated data or wrong owner")
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("private persistence required")
	}
	reloaded := &historyStore{path: path}
	if events, err := reloaded.snapshot(id1); err != nil || len(events) != 1 {
		t.Fatal("restart lost history")
	}
	for _, key := range []string{key1, key2} {
		w := appTestRequest(h, "GET", "/voice-test/app/connection-history", key, "")
		if w.Code != 200 {
			t.Fatalf("read: %d", w.Code)
		}
		var v connectionHistoryView
		if json.Unmarshal(w.Body.Bytes(), &v) != nil {
			t.Fatal("invalid JSON")
		}
		if key == key1 && len(v.Events) != 1 {
			t.Fatal("missing own events")
		}
		if key == key2 && len(v.Events) != 0 {
			t.Fatal("another Key leaked phone history")
		}
		for _, event := range v.Events {
			if event.Owner != "" {
				t.Fatal("owner exposed")
			}
		}
	}
	if w := appTestRequest(h, "GET", "/voice-test/app/connection-history", admin, ""); w.Code != 401 {
		t.Fatal("web session must not read private phone events")
	}
	if w := appTestRequest(h, "PUT", "/voice-test/app/connection-history", key1, ""); w.Code != 405 {
		t.Fatal("method guard")
	}
	e.Reason = "a secret or raw error"
	body, _ = json.Marshal(map[string]any{"events": []connectionEvent{e}})
	if w := appTestRequest(h, "POST", "/voice-test/app/connection-history", key1, string(body)); w.Code != 400 {
		t.Fatal("arbitrary text accepted")
	}
	e.Reason = "no_network"
	e.At = historyNow() + 600
	body, _ = json.Marshal(map[string]any{"events": []connectionEvent{e}})
	if w := appTestRequest(h, "POST", "/voice-test/app/connection-history", key1, string(body)); w.Code != 400 {
		t.Fatal("future clock accepted")
	}
	if w := appTestRequest(h, "POST", "/voice-test/app/connection-history", key1, `{"events":[],"secret":"bad"}`); w.Code != 400 {
		t.Fatal("unknown field accepted")
	}
	if w := appTestRequest(h, "DELETE", "/voice-test/app-keys?id="+id1, admin, ""); w.Code != 204 {
		t.Fatal("revoke failed")
	}
	if w := appTestRequest(h, "GET", "/voice-test/app/connection-history", key1, ""); w.Code != 401 {
		t.Fatal("revoked key can read history")
	}
}

func TestHistoryCorruptFileAndConcurrentIngestion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "history.json")
	if err := os.WriteFile(path, []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	s := &historyStore{path: path}
	if s.ingest([]connectionEvent{{ID: "one", At: historyNow()}}, true) == nil {
		t.Fatal("corrupt history overwritten")
	}
	b, _ := os.ReadFile(path)
	if string(b) != "broken" {
		t.Fatal("original corrupt file must be preserved")
	}
	s = &historyStore{path: filepath.Join(t.TempDir(), "history.json")}
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 20; j++ {
				if err := s.ingest([]connectionEvent{{ID: randomHistoryID(), At: historyNow(), Layer: "module", State: "online"}}, false); err != nil {
					t.Error(err)
				}
				if _, err := s.snapshot("owner"); err != nil {
					t.Error(err)
				}
			}
		}()
	}
	wg.Wait()
	if len(s.events) != 200 {
		t.Fatal("concurrent collection lost events")
	}
}

func TestHistoryOriginAndSizeGuards(t *testing.T) {
	h, admin := appTestSetup(t)
	_, key := issueTestKey(t, h, admin)
	r := httptest.NewRequest("GET", origin+"/voice-test/app/connection-history", nil)
	r.Header.Set("Authorization", "Bearer "+key)
	r.Header.Set("Origin", "https://untrusted.example")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusForbidden {
		t.Fatal("origin guard")
	}
}

func TestHistoryIncrementalJournalAndInterruptedAppend(t *testing.T) {
	path := filepath.Join(t.TempDir(), "history.json")
	s := &historyStore{path: path}
	first := connectionEvent{ID: randomHistoryID(), At: historyNow(), Layer: "module", State: "online"}
	second := connectionEvent{ID: randomHistoryID(), At: historyNow(), Layer: "module", State: "offline"}
	if err := s.ingest([]connectionEvent{first}, true); err != nil {
		t.Fatal(err)
	}
	base, _ := os.ReadFile(path)
	if err := s.ingest([]connectionEvent{second}, true); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(path)
	if string(after) != string(base) {
		t.Fatal("normal append rewrote full history")
	}
	f, err := os.OpenFile(path+".journal", os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString(`{"interrupted"`)
	f.Close()
	reloaded := &historyStore{path: path}
	events, err := reloaded.snapshot("device")
	if err != nil || len(events) != 2 {
		t.Fatal("interrupted append lost acknowledged events")
	}
	if err = reloaded.ingest([]connectionEvent{second}, true); err != nil {
		t.Fatal(err)
	}
	if len(reloaded.events) != 2 {
		t.Fatal("replayed journal duplicated event")
	}
}

func BenchmarkHistoryThirtyDaySummary(b *testing.B) {
	now := historyNow()
	events := make([]connectionEvent, 0, 129600)
	for i := 0; i < 43200; i++ {
		for _, layer := range []string{"phone", "module", "network"} {
			events = append(events, connectionEvent{At: now - float64((43200-i)*60), Layer: layer, State: "online"})
		}
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for _, layer := range []string{"phone", "module", "network"} {
			summarizeConnections(events, layer, now-86400, now)
		}
	}
}
