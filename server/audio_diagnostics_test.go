package main

import (
	"bytes"
	"encoding/json"
	"github.com/gorilla/websocket"
	"log"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestAudioMetadataBoundsRateAndIsolation(t *testing.T) {
	payload := []byte(`{"type":"audio_stats","version":1,"segment":"12345678-1234-1234-1234-123456789abc","elapsed_ms":5000,"sent_frames":250}`)
	now := time.Now()
	a, b := &audioStats{}, &audioStats{}
	if !a.acceptClient(payload, now) || a.acceptClient(payload, now.Add(time.Second)) || b.client != nil {
		t.Fatal("rate/isolation")
	}
	if !a.acceptClient(payload, now.Add(5*time.Second)) {
		t.Fatal("valid next summary")
	}
	var base map[string]any
	json.Unmarshal(payload, &base)
	for name, value := range map[string]any{"number": "private", "sent_frames": -1, "elapsed_ms": 86400001, "segment": "private", "version": 2} {
		clone := map[string]any{}
		for k, v := range base {
			clone[k] = v
		}
		clone[name] = value
		data, _ := json.Marshal(clone)
		if b.acceptClient(data, now) {
			t.Fatalf("accepted invalid %s", name)
		}
	}
	if b.acceptClient(bytes.Repeat([]byte(" "), 2049), now) || b.acceptClient([]byte(`{"type":null}`), now) {
		t.Fatal("invalid metadata")
	}
}

func TestAudioCountersResetAndRealtimeStderr(t *testing.T) {
	s := &audioStats{}
	s.begin("one")
	s.arrival("one", false, 3)
	s.arrival("one", true, 8)
	s.discardStartup()
	s.output(true)
	s.output(false)
	s.arrival("future", false, 1)
	if s.up != 2 || s.dropped != 1 || s.queuePeak != 8 || s.written != 1 || s.startupDiscarded != 1 {
		t.Fatal("counts")
	}
	var output bytes.Buffer
	old := log.Writer()
	log.SetOutput(&output)
	defer log.SetOutput(old)
	w := &audioStderr{stats: s, device: "playback"}
	w.Write([]byte("under"))
	if s.underruns != 0 {
		t.Fatal("incomplete line")
	}
	w.Write([]byte("run!!! private-content\n"))
	if s.underruns != 1 || s.firstUnderrun.IsZero() || !strings.Contains(output.String(), "kind=underrun") || strings.Contains(output.String(), "private-content") {
		t.Fatal("event must be immediate and sanitized")
	}
	w.Write(bytes.Repeat([]byte("x"), 100000))
	if len(w.pending) > 1024 {
		t.Fatal("unbounded stderr")
	}
	w.finish()
	w.Write([]byte("overrun\n"))
	if s.overruns != 1 || s.lastOverrun.IsZero() {
		t.Fatal("overrun")
	}
	s.summary(true)
	if !strings.Contains(output.String(), "underrun_first_at") || !strings.Contains(output.String(), `"final":true`) {
		t.Fatal("final summary")
	}
	s.begin("two")
	if s.segment != 2 || s.up != 0 || s.underruns != 0 || s.client != nil || !s.firstUnderrun.IsZero() {
		t.Fatal("new call inherited counts")
	}
}

func TestAudioConcurrentCounters(t *testing.T) {
	s := &audioStats{}
	s.begin("call")
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 1000; j++ {
				s.output(true)
			}
		}()
	}
	wg.Wait()
	if s.written != 4000 {
		t.Fatal("lost concurrent count")
	}
}

func TestStreamMetadataCompatibilityWithoutHardware(t *testing.T) {
	oldFlag := callFlag
	callFlag = filepath.Join(t.TempDir(), "absent")
	defer func() { callFlag = oldFlag }()
	key := "audio-local-test-with-enough-length"
	sessions.Store(key, time.Now().Add(time.Minute))
	defer sessions.Delete(key)
	srv := httptest.NewServer(routes())
	defer srv.Close()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/voice-test/stream"
	c, resp, err := websocket.DefaultDialer.Dial(url, map[string][]string{"Authorization": {"Bearer invalid-test-session-long-enough"}})
	if err == nil {
		c.Close()
		t.Fatal("unauthenticated audio")
	}
	if resp.StatusCode != 401 {
		t.Fatal(resp.StatusCode)
	}
	header := map[string][]string{"Authorization": {"Bearer " + key}, "Sec-WebSocket-Protocol": {"sxh.audio-diagnostics.v1"}}
	c, resp, err = websocket.DefaultDialer.Dial(url, header)
	if err != nil {
		t.Fatal(err)
	}
	if resp.Header.Get("Sec-WebSocket-Protocol") != "sxh.audio-diagnostics.v1" {
		t.Fatal("capability")
	}
	for _, data := range []string{"ping", `{"type":"audio_stats","number":"private"}`, `{"type":"audio_stats","version":1,"segment":"12345678-1234-1234-1234-123456789abc","elapsed_ms":5000,"sent_frames":250}`} {
		if c.WriteMessage(websocket.TextMessage, []byte(data)) != nil {
			t.Fatal("metadata")
		}
	}
	if c.WriteMessage(websocket.BinaryMessage, make([]byte, 320)) != nil {
		t.Fatal("legacy PCM")
	}
	pong := make(chan struct{}, 1)
	c.SetPongHandler(func(string) error { pong <- struct{}{}; return nil })
	c.WriteMessage(websocket.PingMessage, []byte("check"))
	done := make(chan struct{})
	go func() { defer close(done); c.ReadMessage() }()
	select {
	case <-pong:
	case <-time.After(2 * time.Second):
		t.Fatal("metadata interrupted audio")
	}
	c.Close()
	<-done
}
