// Native Swift WebSocket acceptance on loopback. No microphone or hardware access.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"github.com/gorilla/websocket"
	"net"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"
)

type observation struct {
	Frames, Metadata, Invalid int
	First, Last               time.Time
}

func main() {
	binary := flag.String("native", "", "compiled audio-check executable")
	seconds := flag.Int("seconds", 60, "duration, 5..120 seconds")
	legacy := flag.Bool("legacy", false, "do not advertise diagnostics support")
	flag.Parse()
	if *binary == "" || *seconds < 5 || *seconds > 120 {
		fmt.Fprintln(os.Stderr, "native executable and valid duration required")
		os.Exit(1)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	var mu sync.Mutex
	var observations []*observation
	mux := http.NewServeMux()
	mux.HandleFunc("/voice-test/stream", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer local-test" {
			w.WriteHeader(401)
			return
		}
		upgrader := websocket.Upgrader{}
		if !*legacy {
			upgrader.Subprotocols = []string{"sxh.audio-diagnostics.v1"}
		}
		c, e := upgrader.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer c.Close()
		fmt.Fprintln(os.Stderr, "Loopback socket opened")
		item := &observation{}
		mu.Lock()
		observations = append(observations, item)
		mu.Unlock()
		c.SetReadLimit(2048)
		for {
			kind, data, e := c.ReadMessage()
			if e != nil {
				fmt.Fprintln(os.Stderr, "Loopback read ended:", e)
				return
			}
			now := time.Now()
			mu.Lock()
			if kind == websocket.BinaryMessage && len(data) == 320 {
				item.Frames++
				if item.First.IsZero() {
					item.First = now
				}
				item.Last = now
			} else if kind == websocket.TextMessage && !*legacy {
				var payload map[string]any
				if json.Unmarshal(data, &payload) == nil && payload["type"] == "audio_stats" {
					item.Metadata++
				} else {
					item.Invalid++
				}
			} else {
				item.Invalid++
			}
			mu.Unlock()
		}
	})
	server := &http.Server{Handler: mux}
	go server.Serve(listener)
	defer server.Close()
	cmd := exec.Command(*binary, "--local-voice-check", "--loopback", "http://"+listener.Addr().String(), fmt.Sprint(*seconds))
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(observations) != 2 {
		fmt.Fprintln(os.Stderr, "reconnect count mismatch")
		os.Exit(1)
	}
	first := observations[0]
	expected := *seconds * 50
	rate := float64(first.Frames-1) / first.Last.Sub(first.First).Seconds()
	ok := first.Invalid == 0 && first.Frames >= expected-expected/100 && first.Frames <= expected+expected/100 && observations[1].Frames > 0 && observations[1].Frames < 20
	if *legacy {
		ok = ok && first.Metadata == 0
	} else {
		ok = ok && first.Metadata >= *seconds/5-1
	}
	json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": ok, "seconds": *seconds, "frames": first.Frames, "fps": rate, "metadata": first.Metadata, "invalid": first.Invalid, "legacy": *legacy, "reconnect_frames": observations[1].Frames})
	if !ok {
		os.Exit(1)
	}
}
