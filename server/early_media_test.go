package main

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// Run the test binary as fake ALSA processes, exercising actual stream pipes.
func TestEarlyAudioProcessHelper(t *testing.T) {
	if os.Getenv("SXH_FAKE_AUDIO") != "1" {
		return
	}
	if os.Getenv("SXH_FAKE_MODE") == "capture" {
		for {
			if _, err := os.Stdout.Write(bytes.Repeat([]byte{7}, 320)); err != nil {
				os.Exit(0)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	f, err := os.OpenFile(os.Getenv("SXH_FAKE_PLAY_FILE"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		os.Exit(1)
	}
	io.Copy(f, os.Stdin)
	f.Close()
	os.Exit(0)
}

func TestEarlyMediaPipesAndRecordingBoundary(t *testing.T) {
	dir := t.TempDir()
	bin, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for name, mode := range map[string]string{"arecord": "capture", "aplay": "playback"} {
		script := "#!/bin/sh\nexport SXH_FAKE_MODE=" + mode + "\nexec '" + strings.ReplaceAll(bin, "'", "'\\''") + "' -test.run='^TestEarlyAudioProcessHelper$'\n"
		if err := os.WriteFile(filepath.Join(dir, name), []byte(script), 0700); err != nil {
			t.Fatal(err)
		}
	}
	playFile := filepath.Join(dir, "play.raw")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("SXH_FAKE_AUDIO", "1")
	t.Setenv("SXH_FAKE_PLAY_FILE", playFile)
	oldFlag, oldRoot := callFlag, recordRoot
	callFlag = filepath.Join(dir, "call.active")
	recordRoot = filepath.Join(dir, "recordings")
	defer func() { callFlag, recordRoot = oldFlag, oldRoot }()
	phone.Lock()
	oldView, oldRun, oldPeer, oldDirection := phone.view, phone.run, phone.peer, phone.direction
	run := "20261009-120000-0000-拨打"
	phone.view = phoneView{State: "dialing", Available: true, Media: true}
	phone.run = run
	phone.peer = "0000"
	phone.direction = "拨打"
	phone.publish()
	phone.Unlock()
	defer func() {
		phone.Lock()
		phone.view, phone.run, phone.peer, phone.direction = oldView, oldRun, oldPeer, oldDirection
		phone.publish()
		phone.Unlock()
	}()
	if err := os.WriteFile(callFlag, []byte(run), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	mic := make(chan []byte, 10)
	done := make(chan error, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, e := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if e != nil {
			done <- e
			return
		}
		defer c.Close()
		done <- runAudio(ctx, c, mic, run, nil, &audioStats{})
	}))
	defer srv.Close()
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	kind, frame, err := c.ReadMessage()
	if err != nil || kind != websocket.BinaryMessage || !bytes.Equal(frame, bytes.Repeat([]byte{7}, 320)) {
		t.Fatalf("pre-answer downlink failed: %v", err)
	}
	wait := func(check func() bool) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if check() {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("audio boundary timed out")
	}
	mic <- bytes.Repeat([]byte{42}, 320)
	wait(func() bool { b, _ := os.ReadFile(playFile); return len(b) >= 320 })
	b, _ := os.ReadFile(playFile)
	if !bytes.Equal(b, make([]byte, len(b))) {
		t.Fatal("microphone leaked before answer")
	}
	if _, err := os.Stat(recordRoot); !os.IsNotExist(err) {
		t.Fatal("pre-answer recording created")
	}
	phone.Lock()
	phone.view.State = "active"
	phone.publish()
	phone.Unlock()
	mic <- bytes.Repeat([]byte{42}, 320)
	wait(func() bool { b, _ := os.ReadFile(playFile); return bytes.Contains(b, bytes.Repeat([]byte{42}, 320)) })
	wait(func() bool {
		files, _ := filepath.Glob(filepath.Join(recordRoot, "*", "*.wav"))
		return len(files) >= 2
	})
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("audio workers did not stop")
	}
}
