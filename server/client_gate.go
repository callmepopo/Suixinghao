package main

import (
	"context"
	"errors"
	"net"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// clientGate holds server-to-client data until the client has spoken. iOS
// URLSessionWebSocketTask hands a pong to the App only after earlier unread
// data messages, while the App starts reading only after that pong: pushing call
// audio first (a reconnect during an active call) deadlocks the handshake.
type clientGate struct {
	once  sync.Once
	ready chan struct{}
}

func newClientGate(c *websocket.Conn) *clientGate {
	g := &clientGate{ready: make(chan struct{})}
	c.SetPingHandler(func(data string) error {
		// Same as gorilla's default handler, then release data after the pong.
		err := c.WriteControl(websocket.PongMessage, []byte(data), time.Now().Add(time.Second))
		g.open()
		var ne net.Error
		if err == nil || errors.Is(err, websocket.ErrCloseSent) || (errors.As(err, &ne) && ne.Timeout()) {
			return nil
		}
		return err
	})
	return g
}

// open releases data; also called on the first client message (browser test
// clients cannot send ping frames).
func (g *clientGate) open() { g.once.Do(func() { close(g.ready) }) }

// wait returns false only when ctx ends; after limit it proceeds anyway.
func (g *clientGate) wait(ctx context.Context, limit time.Duration) bool {
	t := time.NewTimer(limit)
	defer t.Stop()
	select {
	case <-g.ready:
	case <-t.C:
	case <-ctx.Done():
		return false
	}
	return true
}
