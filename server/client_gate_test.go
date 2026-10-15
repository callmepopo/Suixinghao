package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// pongBeforeData reports whether the client sees its pong before the first
// data message. The App waits for that pong before it starts reading (as iOS
// delivers a pong only after earlier unread data), so data first = deadlock.
func pongBeforeData(t *testing.T, gated bool) bool {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, e := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer c.Close()
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		var gate *clientGate
		if gated {
			gate = newClientGate(c)
		}
		go func() {
			defer cancel()
			for {
				if _, _, e := c.ReadMessage(); e != nil {
					return
				}
				if gate != nil {
					gate.open()
				}
			}
		}()
		if gate != nil && !gate.wait(ctx, 3*time.Second) {
			return
		}
		// An active call: module audio is pushed at once.
		for i := 0; i < 20 && ctx.Err() == nil; i++ {
			if c.WriteMessage(websocket.BinaryMessage, make([]byte, 320)) != nil {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
	}))
	defer srv.Close()
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	time.Sleep(150 * time.Millisecond) // the App pings only after its open callback
	pong := false
	c.SetPongHandler(func(string) error { pong = true; return nil })
	if err := c.WriteControl(websocket.PingMessage, []byte("p"), time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, _, err := c.ReadMessage(); err != nil {
		t.Fatal(err)
	}
	return pong
}

// 10-15 12:49 15Pro: reconnect mid-call, socket ready, App never got its pong
// and gave up after 10 s; SE3 11:23 crashed on the same stalled pong.
func TestReconnectSendsPongBeforeCallAudio(t *testing.T) {
	if pongBeforeData(t, false) {
		t.Fatal("control: an ungated server should queue audio ahead of the pong")
	}
	if !pongBeforeData(t, true) {
		t.Fatal("gated server must answer the ping before pushing audio")
	}
}

func TestClientGateOpensWithoutPing(t *testing.T) {
	g := &clientGate{ready: make(chan struct{})}
	g.open()
	g.open()
	if !g.wait(context.Background(), time.Second) {
		t.Fatal("opened gate must pass")
	}
	start := time.Now()
	g2 := &clientGate{ready: make(chan struct{})}
	if !g2.wait(context.Background(), 50*time.Millisecond) || time.Since(start) < 40*time.Millisecond {
		t.Fatal("silent client (browser) must pass after the limit")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if (&clientGate{ready: make(chan struct{})}).wait(ctx, time.Second) {
		t.Fatal("ended stream must stop")
	}
}
