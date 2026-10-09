package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Only manually enrolled backends can use the publisher's fixed App topic.
// The relay never stores device tokens, audio, phone numbers or SMS content.
type relayGrant struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Hash        string `json:"hash"`
	Environment string `json:"environment"`
}
type relayPush struct {
	Kind        string `json:"kind"`
	Token       string `json:"token"`
	Environment string `json:"environment"`
	CallID      string `json:"call_id,omitempty"`
}
type relayResult struct {
	Status int    `json:"apns_status"`
	Reason string `json:"reason,omitempty"`
}

var relayCallID = regexp.MustCompile(`^[a-f0-9]{32}$`)

func relayGrantsPath() string {
	return envOrDefault("VOICE_WEB_RELAY_GRANTS_FILE", dataPath("relay-grants.json"))
}
func loadRelayGrants() ([]relayGrant, error) {
	b, err := os.ReadFile(relayGrantsPath())
	if os.IsNotExist(err) {
		return []relayGrant{}, nil
	}
	if err != nil {
		return nil, err
	}
	var grants []relayGrant
	err = json.Unmarshal(b, &grants)
	if len(grants) > 1000 {
		return nil, errors.New("relay grant limit exceeded")
	}
	return grants, err
}
func relayDigest(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}
func relayCredential(header string) string {
	if !strings.HasPrefix(header, "Bearer sxr_") {
		return ""
	}
	key := strings.TrimPrefix(header, "Bearer ")
	if len(key) != 68 {
		return ""
	}
	if _, err := hex.DecodeString(key[4:]); err != nil {
		return ""
	}
	return relayDigest(key)
}

type relayWindow struct {
	Start            time.Time
	Requests, Pushes int
}
type relayDelivery struct {
	At   time.Time
	Done bool
}
type pushRelay struct {
	Environment string
	Grants      func() ([]relayGrant, error)
	Send        func(context.Context, relayPush) (int, string, error)
	Now         func() time.Time
	mu          sync.Mutex
	windows     map[string]relayWindow
	deliveries  map[string]relayDelivery
	slots       chan struct{}
}

func newPushRelay(environment string, send func(context.Context, relayPush) (int, string, error)) *pushRelay {
	return &pushRelay{Environment: environment, Grants: loadRelayGrants, Send: send, Now: time.Now,
		windows: map[string]relayWindow{}, deliveries: map[string]relayDelivery{}, slots: make(chan struct{}, 8)}
}
func (p *pushRelay) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.URL.Path == "/push-relay/health" && r.Method == "GET" {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "version": releaseVersion, "environment": p.Environment})
		return
	}
	if r.URL.Path != "/push-relay/v1/push" {
		http.NotFound(w, r)
		return
	}
	if r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	if r.URL.RawQuery != "" {
		w.WriteHeader(400)
		return
	}
	hash := relayCredential(r.Header.Get("Authorization"))
	if hash == "" {
		w.WriteHeader(401)
		return
	}
	grants, err := p.Grants()
	if err != nil {
		w.WriteHeader(503)
		return
	}
	valid := false
	for _, g := range grants {
		if subtle.ConstantTimeCompare([]byte(g.Hash), []byte(hash)) == 1 && g.Environment == p.Environment {
			valid = true
		}
	}
	if !valid {
		w.WriteHeader(401)
		return
	}
	now := p.Now()
	p.mu.Lock()
	for id, window := range p.windows {
		if now.Sub(window.Start) > 10*time.Minute {
			delete(p.windows, id)
		}
	}
	window := p.windows[hash]
	if now.Sub(window.Start) >= time.Minute {
		window = relayWindow{Start: now}
	}
	window.Requests++
	p.windows[hash] = window
	p.mu.Unlock()
	if window.Requests > 120 {
		w.Header().Set("Retry-After", "60")
		w.WriteHeader(429)
		return
	}
	var input relayPush
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(&struct{}{}) != io.EOF || input.Environment != p.Environment ||
		!voipTokenPattern.MatchString(input.Token) || len(input.Token)%2 != 0 || (input.Kind != "voip" && input.Kind != "sms") ||
		(input.Kind == "voip" && !relayCallID.MatchString(input.CallID)) || (input.Kind == "sms" && input.CallID != "") {
		w.WriteHeader(400)
		return
	}
	input.Token = strings.ToLower(input.Token)
	// Deduplication uses token digests; raw routing tokens are transient only.
	deliveryID := relayDigest(hash + "\x00" + input.Token + "\x00" + input.Kind + "\x00" + input.CallID)
	p.mu.Lock()
	for id, d := range p.deliveries {
		if now.Sub(d.At) > 5*time.Minute {
			delete(p.deliveries, id)
		}
	}
	if d, ok := p.deliveries[deliveryID]; ok && (input.Kind == "voip" || now.Sub(d.At) < 10*time.Second) {
		p.mu.Unlock()
		if d.Done {
			relayReply(w, 200, 200, "")
		} else {
			w.WriteHeader(409)
		}
		return
	}
	window = p.windows[hash]
	if window.Pushes >= 20 || len(p.deliveries) >= 20000 {
		p.mu.Unlock()
		w.Header().Set("Retry-After", "60")
		w.WriteHeader(429)
		return
	}
	window.Pushes++
	p.windows[hash] = window
	p.deliveries[deliveryID] = relayDelivery{At: now}
	p.mu.Unlock()
	done := false
	defer func() {
		p.mu.Lock()
		defer p.mu.Unlock()
		if done {
			p.deliveries[deliveryID] = relayDelivery{At: now, Done: true}
		} else {
			delete(p.deliveries, deliveryID)
		}
	}()
	select {
	case p.slots <- struct{}{}:
		defer func() { <-p.slots }()
	default:
		w.Header().Set("Retry-After", "5")
		w.WriteHeader(429)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	status, reason, err := p.Send(ctx, input)
	if err != nil {
		relayReply(w, 502, 0, "ProviderUnavailable")
		return
	}
	if status == 200 {
		done = true
		relayReply(w, 200, status, "")
		return
	}
	// Neither upstream error bodies nor private URLs/tokens are exposed.
	switch reason {
	case "BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "InvalidProviderToken", "ExpiredProviderToken", "TopicDisallowed", "BadTopic", "TooManyRequests":
	default:
		reason = "ProviderRejected"
	}
	relayReply(w, 502, status, reason)
}
func relayReply(w http.ResponseWriter, httpStatus, apnsStatus int, reason string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(httpStatus)
	_ = json.NewEncoder(w).Encode(relayResult{Status: apnsStatus, Reason: reason})
}

func relayCommand(ctx context.Context, args []string) error {
	switch args[0] {
	case "relay-issue":
		if len(args) != 4 || strings.TrimSpace(args[1]) == "" || len(args[1]) > 80 || (args[2] != "sandbox" && args[2] != "production") {
			return errors.New("usage: voice-web relay-issue NAME sandbox|production PRIVATE_OUTPUT")
		}
		grants, err := loadRelayGrants()
		if err != nil {
			return errors.New("cannot read relay grants")
		}
		if len(grants) >= 1000 {
			return errors.New("relay grant limit reached")
		}
		for _, g := range grants {
			if g.Name == args[1] {
				return errors.New("grant name already exists")
			}
		}
		raw := make([]byte, 32)
		if _, err = rand.Read(raw); err != nil {
			return err
		}
		key := "sxr_" + hex.EncodeToString(raw)
		hash := relayDigest(key)
		f, err := os.OpenFile(args[3], os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return errors.New("private output must be a new file")
		}
		grant := relayGrant{ID: hash[:16], Name: args[1], Hash: hash, Environment: args[2]}
		if _, err = f.WriteString(key + "\n"); err == nil {
			err = f.Sync()
		}
		closeErr := f.Close()
		if err == nil {
			err = closeErr
		}
		if err == nil {
			err = privateJSON(relayGrantsPath(), append(grants, grant))
		}
		if err != nil {
			_ = os.Remove(args[3])
			return errors.New("relay enrollment failed")
		}
		fmt.Println("Relay backend enrolled; credential written only to private output.")
		return nil
	case "relay-revoke":
		if len(args) != 2 || len(args[1]) != 16 {
			return errors.New("usage: voice-web relay-revoke GRANT_ID")
		}
		grants, err := loadRelayGrants()
		if err != nil {
			return err
		}
		kept := []relayGrant{}
		found := false
		for _, g := range grants {
			if g.ID == args[1] {
				found = true
			} else {
				kept = append(kept, g)
			}
		}
		if !found {
			return errors.New("relay grant not found")
		}
		return privateJSON(relayGrantsPath(), kept)
	case "relay":
		environment := os.Getenv("VOICE_WEB_RELAY_ENVIRONMENT")
		if len(args) != 1 || (environment != "production" && environment != "sandbox") || os.Getenv("VOICE_WEB_APNS_BUNDLE_ID") != "com.junpo.suixinghao" {
			return errors.New("relay requires explicit environment and the Suixinghao publisher topic")
		}
		provider, err := newAPNsProvider(environment == "sandbox")
		if err != nil {
			return errors.New("relay publisher APNs credentials unavailable")
		}
		if _, err = loadRelayGrants(); err != nil {
			return errors.New("relay grant storage unavailable")
		}
		relay := newPushRelay(environment, func(ctx context.Context, p relayPush) (int, string, error) {
			if p.Kind == "voip" {
				return provider.send(ctx, voipDevice{Token: p.Token, Sandbox: environment == "sandbox"}, p.CallID)
			}
			return provider.sendSMSAlert(ctx, smsPushDevice{Token: p.Token, Sandbox: environment == "sandbox"})
		})
		server := &http.Server{Addr: envOrDefault("VOICE_WEB_RELAY_ADDR", "127.0.0.1:7582"), Handler: relay, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
		go func() {
			<-ctx.Done()
			shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = server.Shutdown(shutdown)
		}()
		err = server.ListenAndServe()
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
	return errors.New("unknown relay command")
}
