// Local simulator acceptance: loopback audio sink, no carrier or Unraid access.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	device := flag.String("simulator", "", "booted simulator UUID")
	bundle := flag.String("bundle", "com.junpo.suixinghao", "installed simulator App bundle identifier")
	flag.Parse()
	if *device == "" {
		return errors.New("simulator UUID required")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer listener.Close()
	var mu sync.Mutex
	count, nonzero, invalid := 0, 0, 0
	var connection *websocket.Conn
	mux := http.NewServeMux()
	mux.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		json.NewEncoder(w).Encode(map[string]int{"frames": count, "nonzero": nonzero})
	})
	mux.HandleFunc("/disconnect", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		c := connection
		mu.Unlock()
		if c != nil {
			c.Close()
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/voice-test/stream", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer local-test" {
			http.Error(w, "unauthorized", 401)
			return
		}
		upgrader := websocket.Upgrader{}
		c, e := upgrader.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer c.Close()
		mu.Lock()
		connection = c
		mu.Unlock()
		c.SetReadLimit(320)
		c.SetReadDeadline(time.Now().Add(45 * time.Second))
		for {
			kind, data, e := c.ReadMessage()
			if e != nil {
				return
			}
			mu.Lock()
			if kind != websocket.BinaryMessage || len(data) != 320 {
				invalid++
			} else {
				count++
				for _, v := range data {
					if v != 0 {
						nonzero++
						break
					}
				}
			}
			mu.Unlock()
		}
	})
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	defer server.Close()
	go server.Serve(listener)
	container, e := exec.Command("xcrun", "simctl", "get_app_container", *device, *bundle, "data").Output()
	if e != nil {
		return errors.New("app unavailable")
	}
	report := filepath.Join(strings.TrimSpace(string(container)), "Documents", "local-voice-result.json")
	os.Remove(report)
	defer os.Remove(report)
	progress := filepath.Join(filepath.Dir(report), "local-voice-progress.json")
	os.Remove(progress)
	defer os.Remove(progress)
	exec.Command("xcrun", "simctl", "terminate", *device, *bundle).Run()
	cmd := exec.Command("xcrun", "simctl", "launch", *device, *bundle, "--local-voice-check")
	cmd.Env = append(os.Environ(), "SIMCTL_CHILD_SXH_LOCAL_AUDIO_URL=http://"+listener.Addr().String())
	if cmd.Run() != nil {
		return errors.New("simulator launch failed")
	}
	fmt.Println("local simulator test started; microphone permission may appear; no carrier call")
	for i := 0; i < 120; i++ {
		if data, e := os.ReadFile(report); e == nil {
			var result map[string]any
			if json.Unmarshal(data, &result) != nil {
				return errors.New("invalid report")
			}
			mu.Lock()
			result["sink_frames"] = count
			result["sink_nonzero_frames"] = nonzero
			result["sink_invalid_frames"] = invalid
			valid := count > 50 && nonzero > 0 && invalid == 0
			mu.Unlock()
			output, _ := json.Marshal(result)
			fmt.Println(string(output))
			if result["ok"] != true || !valid {
				return errors.New("local voice acceptance incomplete")
			}
			return nil
		}
		time.Sleep(time.Second)
	}
	// Kill only our test App on timeout, so capture cannot keep running.
	exec.Command("xcrun", "simctl", "terminate", *device, *bundle).Run()
	return errors.New("local acceptance timeout; test app stopped")
}
