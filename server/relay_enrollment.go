package main

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const relayLease = 90 * 24 * time.Hour
const bindingLifetime = 10 * time.Minute

type relayAudit struct {
	At     time.Time `json:"at"`
	Action string    `json:"action"`
	Reason string    `json:"reason,omitempty"`
}

func appendAudit(a []relayAudit, e relayAudit) []relayAudit {
	a = append(a, e)
	if len(a) > 128 {
		a = append([]relayAudit{}, a[len(a)-128:]...)
	}
	return a
}
func grantActive(g relayGrant, now time.Time) bool {
	return g.Revoked.IsZero() && (g.Expires.IsZero() || now.Before(g.Expires))
}
func lockRelayStorage() (func(), error) {
	p := relayGrantsPath() + ".lock"
	if e := os.MkdirAll(filepath.Dir(p), 0700); e != nil {
		return nil, e
	}
	f, e := os.OpenFile(p, os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return nil, e
	}
	if e = syscall.Flock(int(f.Fd()), syscall.LOCK_EX); e != nil {
		f.Close()
		return nil, e
	}
	return func() { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}
func randomRelayID() string {
	b := make([]byte, 32)
	if _, e := rand.Read(b); e != nil {
		panic("secure random unavailable")
	}
	return hex.EncodeToString(b)
}

// A private, persistent derivation secret allows authenticated NAS retries to
// retrieve the same credential after a lost response; grant storage has hashes only.
func automaticCredential(g relayGrant) (string, error) {
	p := dataPath("relay-enrollment-secret")
	b, e := os.ReadFile(p)
	if os.IsNotExist(e) {
		b = make([]byte, 32)
		if _, e = rand.Read(b); e != nil {
			return "", e
		}
		f, e := os.OpenFile(p, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if e != nil {
			return "", e
		}
		_, e = f.Write(b)
		if e == nil {
			e = f.Sync()
		}
		f.Close()
		if e != nil {
			return "", e
		}
	}
	if e != nil && !os.IsNotExist(e) {
		return "", e
	}
	if len(b) != 32 {
		return "", errors.New("invalid enrollment secret")
	}
	mac := hmac.New(sha256.New, b)
	mac.Write([]byte("sxh-relay-v1\n" + g.BindingID + "\n" + g.Instance + "\n" + g.Environment))
	return "sxr_" + hex.EncodeToString(mac.Sum(nil)), nil
}

type nasMessage struct {
	Action      string `json:"action"`
	PublicKey   string `json:"public_key"`
	Name        string `json:"name"`
	Environment string `json:"environment"`
	Timestamp   int64  `json:"timestamp"`
	Nonce       string `json:"nonce"`
	BindingID   string `json:"binding_id"`
}
type nasEnvelope struct {
	Message   string       `json:"message"`
	Signature string       `json:"signature"`
	Proof     *attestProof `json:"proof,omitempty"`
}
type relayBinding struct {
	ID          string    `json:"id"`
	Instance    string    `json:"instance_id"`
	PublicKey   string    `json:"public_key"`
	Name        string    `json:"name"`
	Environment string    `json:"environment"`
	Challenge   string    `json:"challenge"`
	Created     time.Time `json:"created_at"`
	Expires     time.Time `json:"expires_at"`
}

func bindingsPath() string { return dataPath("relay-bindings.json") }
func loadBindings(now time.Time) ([]relayBinding, error) {
	b, e := os.ReadFile(bindingsPath())
	if os.IsNotExist(e) {
		return []relayBinding{}, nil
	}
	if e != nil {
		return nil, e
	}
	var list []relayBinding
	if e = json.Unmarshal(b, &list); e != nil {
		return nil, e
	}
	out := []relayBinding{}
	for _, v := range list {
		if now.Before(v.Expires) {
			out = append(out, v)
		}
	}
	return out, nil
}

var enrollmentVerifier = verifyAppAttest

func (p *pushRelay) enrollment(w http.ResponseWriter, r *http.Request) bool {
	path := strings.TrimPrefix(r.URL.Path, "/push-relay/v1/")
	if !strings.HasPrefix(r.URL.Path, "/push-relay/v1/") || !map[string]bool{"bind": true, "confirm": true, "claim": true, "renew": true, "unbind": true}[path] {
		return false
	}
	if os.Getenv("VOICE_WEB_RELAY_AUTO_ENROLL") != "1" || !attestAppIDConfigured() {
		http.Error(w, "automatic enrollment unavailable", 503)
		return true
	}
	if r.Method != "POST" {
		w.WriteHeader(405)
		return true
	}
	if r.URL.RawQuery != "" {
		w.WriteHeader(400)
		return true
	}
	var env nasEnvelope
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32768))
	d.DisallowUnknownFields()
	if d.Decode(&env) != nil || d.Decode(&struct{}{}) != io.EOF || len(env.Message) > 2048 {
		w.WriteHeader(400)
		return true
	}
	var msg nasMessage
	d = json.NewDecoder(strings.NewReader(env.Message))
	d.DisallowUnknownFields()
	if d.Decode(&msg) != nil || d.Decode(&struct{}{}) != io.EOF || msg.Action != path || msg.Environment != p.Environment || len(msg.Name) > 80 || strings.TrimSpace(msg.Name) == "" || strings.ContainsAny(msg.Name, "\r\n\x00") || len(msg.Nonce) != 64 || len(msg.PublicKey) > 64 {
		w.WriteHeader(400)
		return true
	}
	pk, e := base64.StdEncoding.DecodeString(msg.PublicKey)
	sig, e2 := base64.StdEncoding.DecodeString(env.Signature)
	now := p.Now()
	if e != nil || e2 != nil || len(pk) != ed25519.PublicKeySize || !ed25519.Verify(pk, []byte(env.Message), sig) || now.Sub(time.Unix(msg.Timestamp, 0)) > time.Minute || time.Unix(msg.Timestamp, 0).Sub(now) > time.Minute {
		w.WriteHeader(401)
		return true
	}
	// Global bound as well as per-connection source limit; don't trust client XFF.
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if host == "" {
		host = r.RemoteAddr
	}
	p.mu.Lock()
	for k, v := range p.windows {
		if now.Sub(v.Start) > 10*time.Minute {
			delete(p.windows, k)
		}
	}
	limitReached := len(p.windows) > 20000
	window := p.windows["enroll:"+host]
	if now.Sub(window.Start) > time.Minute {
		window = relayWindow{Start: now}
	}
	window.Requests++
	p.windows["enroll:"+host] = window
	p.mu.Unlock()
	if limitReached || window.Requests > 20 {
		w.WriteHeader(429)
		return true
	}
	unlock, e := lockRelayStorage()
	if e != nil {
		w.WriteHeader(503)
		return true
	}
	defer unlock()
	// Persist nonce use across process restarts; retries sign a new envelope.
	noncePath := dataPath("relay-enrollment-nonces.json")
	seen := map[string]int64{}
	raw, readErr := os.ReadFile(noncePath)
	if readErr == nil {
		if json.Unmarshal(raw, &seen) != nil {
			w.WriteHeader(503)
			return true
		}
	} else if !os.IsNotExist(readErr) {
		w.WriteHeader(503)
		return true
	}
	for k, at := range seen {
		if now.Unix()-at > 120 {
			delete(seen, k)
		}
	}
	nonceID := relayDigest(msg.PublicKey + msg.Nonce)
	if _, used := seen[nonceID]; used {
		w.WriteHeader(409)
		return true
	}
	if len(seen) >= 2000 {
		w.WriteHeader(429)
		return true
	}
	seen[nonceID] = now.Unix()
	if privateJSON(noncePath, seen) != nil {
		w.WriteHeader(503)
		return true
	}
	grants, e := loadRelayGrants()
	if e != nil {
		w.WriteHeader(503)
		return true
	}
	instance := relayDigest(msg.PublicKey)
	bindings, e := loadBindings(now)
	if e != nil {
		w.WriteHeader(503)
		return true
	}
	// Instance identity is immutable; revoked instances cannot re-enroll by retry.
	index := -1
	for i, g := range grants {
		if g.Instance == instance && g.Environment == p.Environment {
			index = i
			break
		}
	}
	write := func(v any) { w.Header().Set("Content-Type", "application/json"); json.NewEncoder(w).Encode(v) }
	if path == "bind" {
		if index >= 0 {
			g := grants[index]
			if !g.Revoked.IsZero() {
				w.WriteHeader(403)
				return true
			}
			write(map[string]any{"state": "authorized", "grant_id": g.ID, "expires_at": g.Expires})
			return true
		}
		for _, b := range bindings {
			if b.Instance == instance && b.Environment == p.Environment {
				write(b)
				return true
			}
		}
		if len(bindings) >= 1000 || len(grants) >= 1000 {
			w.WriteHeader(429)
			return true
		}
		b := relayBinding{ID: randomRelayID(), Instance: instance, PublicKey: msg.PublicKey, Name: strings.TrimSpace(msg.Name), Environment: p.Environment, Created: now, Expires: now.Add(bindingLifetime)}
		// Opaque random challenge is stored with the exact instance and proposed name.
		b.Challenge = "sxh-bind-v1:" + b.ID + ":" + instance + ":" + p.Environment + ":" + relayDigest(b.Name) + ":" + randomRelayID()
		if privateJSON(bindingsPath(), append(bindings, b)) != nil {
			w.WriteHeader(503)
			return true
		}
		write(b)
		return true
	}
	if path == "confirm" {
		if index >= 0 {
			g := grants[index]
			if !g.Revoked.IsZero() {
				w.WriteHeader(403)
				return true
			}
			if g.BindingID != msg.BindingID {
				w.WriteHeader(409)
				return true
			}
			write(map[string]any{"state": "authorized", "grant_id": g.ID, "confirmed_app_key": g.AttestID})
			return true
		}
		var binding *relayBinding
		for i := range bindings {
			b := &bindings[i]
			if b.ID == msg.BindingID && b.Instance == instance && b.Environment == p.Environment {
				binding = b
				break
			}
		}
		if binding == nil || env.Proof == nil {
			w.WriteHeader(410)
			return true
		}
		proof := *env.Proof
		stored := ""
		counter := uint32(0)
		associated := 0
		for _, g := range grants {
			if g.AttestID == proof.KeyID {
				stored = g.AttestPublic
				if g.AttestCounter > counter {
					counter = g.AttestCounter
				}
				associated++
			}
		}
		if associated >= 3 {
			w.WriteHeader(429)
			return true
		}
		result, e := enrollmentVerifier(proof, binding.Challenge, p.Environment, stored, counter, now)
		if e != nil {
			w.WriteHeader(403)
			return true
		}
		if len(grants) >= 1000 {
			w.WriteHeader(429)
			return true
		}
		g := relayGrant{ID: randomRelayID()[:16], Name: binding.Name, Environment: p.Environment, Instance: instance, PublicKey: msg.PublicKey, BindingID: binding.ID, Created: now, Expires: now.Add(relayLease), Method: "automatic", Identity: "self_reported_label_app_attest", AttestID: proof.KeyID, AttestPublic: result.PublicKey, AttestCounter: result.Counter, History: []relayAudit{{At: now, Action: "issued"}}}
		credential, e := automaticCredential(g)
		if e != nil {
			w.WriteHeader(503)
			return true
		}
		g.Hash = relayDigest(credential)
		for i := range grants {
			if grants[i].AttestID == proof.KeyID {
				grants[i].AttestCounter = result.Counter
			}
		}
		if privateJSON(relayGrantsPath(), append(grants, g)) != nil {
			w.WriteHeader(503)
			return true
		}
		write(map[string]any{"state": "authorized", "grant_id": g.ID, "confirmed_app_key": g.AttestID})
		return true
	}
	if index < 0 {
		w.WriteHeader(404)
		return true
	}
	g := grants[index]
	if !g.Revoked.IsZero() {
		w.WriteHeader(403)
		return true
	}
	if path == "unbind" {
		g.Revoked = now
		g.History = appendAudit(g.History, relayAudit{At: now, Action: "revoked", Reason: "instance_owner"})
		grants[index] = g
		if privateJSON(relayGrantsPath(), grants) != nil {
			w.WriteHeader(503)
			return true
		}
		write(map[string]string{"state": "revoked"})
		return true
	}
	// Expiration permits renewal within seven days, but never after revocation.
	if now.After(g.Expires.Add(7 * 24 * time.Hour)) {
		w.WriteHeader(410)
		return true
	}
	if path == "renew" && g.Expires.Sub(now) < 60*24*time.Hour {
		g.Expires = now.Add(relayLease)
		g.History = appendAudit(g.History, relayAudit{At: now, Action: "renewed"})
	}
	if path == "claim" {
		found := false
		for _, a := range g.History {
			if a.Action == "claimed" {
				found = true
			}
		}
		if !found {
			g.History = appendAudit(g.History, relayAudit{At: now, Action: "claimed"})
		}
	}
	key, e := automaticCredential(g)
	if e != nil || relayDigest(key) != g.Hash {
		w.WriteHeader(503)
		return true
	}
	grants[index] = g
	if privateJSON(relayGrantsPath(), grants) != nil {
		w.WriteHeader(503)
		return true
	}
	write(map[string]any{"state": "authorized", "grant_id": g.ID, "credential": key, "expires_at": g.Expires})
	return true
}

// Local-only administrator export. No public endpoint or secret in stdout.
func exportRelayLedger(args []string) error {
	if len(args) != 2 {
		return errors.New("usage: voice-web relay-export NEW_PRIVATE_OUTPUT")
	}
	unlock, e := lockRelayStorage()
	if e != nil {
		return e
	}
	defer unlock()
	grants, e := loadRelayGrants()
	if e != nil {
		return e
	}
	type entry struct {
		ID          string       `json:"id"`
		Name        string       `json:"name"`
		Instance    string       `json:"instance_id,omitempty"`
		Environment string       `json:"environment"`
		Created     time.Time    `json:"created_at"`
		Expires     time.Time    `json:"expires_at"`
		Revoked     time.Time    `json:"revoked_at"`
		Method      string       `json:"method"`
		Identity    string       `json:"identity_source"`
		Status      string       `json:"status"`
		History     []relayAudit `json:"history"`
	}
	entries := []entry{}
	counts := map[string]int{"issued": len(grants), "active": 0, "expired": 0, "revoked": 0}
	instances := map[string]bool{}
	labels := map[string]bool{}
	for _, g := range grants {
		status := "active"
		if !g.Revoked.IsZero() {
			status = "revoked"
		} else if !grantActive(g, time.Now()) {
			status = "expired"
		}
		counts[status]++
		method := g.Method
		if method == "" {
			method = "legacy_manual"
		}
		identity := g.Identity
		if identity == "" {
			identity = "unverified_legacy_label"
		}
		entries = append(entries, entry{g.ID, g.Name, g.Instance, g.Environment, g.Created, g.Expires, g.Revoked, method, identity, status, g.History})
		if g.Instance != "" {
			instances[g.Instance] = true
		}
		labels[g.Name] = true
	}
	counts["instances"] = len(instances)
	counts["labels"] = len(labels)
	payload, e := json.Marshal(map[string]any{"schema_version": 1, "generated_at": time.Now().UTC(), "counts": counts, "grants": entries})
	if e != nil {
		return e
	}
	f, e := os.OpenFile(args[1], os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return errors.New("export requires a new private output")
	}
	_, e = f.Write(payload)
	if e == nil {
		e = f.Sync()
	}
	f.Close()
	return e
}
