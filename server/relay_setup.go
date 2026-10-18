package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

type nasRelayState struct {
	ConfirmedAppKey string        `json:"confirmed_app_key,omitempty"`
	Seed            string        `json:"seed"`
	Name            string        `json:"name"`
	Environment     string        `json:"environment"`
	Endpoint        string        `json:"endpoint"`
	Binding         *relayBinding `json:"binding,omitempty"`
	Credential      string        `json:"credential,omitempty"`
	GrantID         string        `json:"grant_id,omitempty"`
	Expires         time.Time     `json:"expires_at"`
	LastRenewed     time.Time     `json:"last_renewed_at"`
	Revoked         bool          `json:"revoked"`
}
type relaySetupView struct {
	ConfirmedAppKey string    `json:"confirmed_app_key,omitempty"`
	State           string    `json:"state"`
	Name            string    `json:"name,omitempty"`
	Environment     string    `json:"environment"`
	GrantID         string    `json:"grant_id,omitempty"`
	Expires         time.Time `json:"expires_at,omitempty"`
	BindingID       string    `json:"binding_id,omitempty"`
	Challenge       string    `json:"challenge,omitempty"`
}

var nasRelayMu sync.Mutex

func autoRelayPath(environment string) string { return dataPath("relay-auto-" + environment + ".json") }
func loadNASRelay(environment string) (nasRelayState, error) {
	var s nasRelayState
	b, e := os.ReadFile(autoRelayPath(environment))
	if e != nil {
		return s, e
	}
	e = json.Unmarshal(b, &s)
	return s, e
}
func saveNASRelay(s nasRelayState) error { return privateJSON(autoRelayPath(s.Environment), s) }
func relayEndpoint(environment string) string {
	suffix := "_" + strings.ToUpper(environment)
	endpoint := os.Getenv("VOICE_WEB_PUSH_RELAY_URL" + suffix)
	if endpoint == "" && os.Getenv("VOICE_WEB_PUSH_RELAY_KEY_FILE"+suffix) == "" {
		endpoint = os.Getenv("VOICE_WEB_PUSH_RELAY_URL")
	}
	return endpoint
}
func manualRelayConfigured(environment string) bool {
	suffix := "_" + strings.ToUpper(environment)
	if os.Getenv("VOICE_WEB_PUSH_RELAY_URL"+suffix) != "" || os.Getenv("VOICE_WEB_PUSH_RELAY_KEY_FILE"+suffix) != "" {
		return os.Getenv("VOICE_WEB_PUSH_RELAY_KEY_FILE"+suffix) != ""
	}
	return os.Getenv("VOICE_WEB_PUSH_RELAY_KEY_FILE") != ""
}
func relaySetupState(s nasRelayState) relaySetupView {
	v := relaySetupView{State: "not_enabled", Name: s.Name, Environment: s.Environment, GrantID: s.GrantID, Expires: s.Expires, ConfirmedAppKey: s.ConfirmedAppKey}
	if s.Revoked {
		v.State = "revoked"
	} else if s.Credential != "" {
		v.State = "authorized"
		if time.Now().After(s.Expires) {
			v.State = "expired"
		}
	} else if strings.TrimSpace(s.Endpoint) == "" {
		v.State = "relay_not_configured"
	} else if s.Binding != nil {
		v.State = "pending"
		v.BindingID = s.Binding.ID
		v.Challenge = s.Binding.Challenge
		v.Expires = s.Binding.Expires
		if time.Now().After(s.Binding.Expires) {
			v.State = "binding_expired"
		}
	}
	return v
}
func nasRelayRequest(ctx context.Context, s nasRelayState, action string, proof *attestProof) ([]byte, error) {
	u, e := url.Parse(s.Endpoint)
	if e != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || !strings.HasSuffix(u.Path, "/push-relay/v1/push") {
		return nil, errors.New("invalid publisher endpoint")
	}
	u.Path = strings.TrimSuffix(u.Path, "push") + action
	seed, e := base64.StdEncoding.DecodeString(s.Seed)
	if e != nil || len(seed) != 32 {
		return nil, errors.New("instance identity unavailable")
	}
	key := ed25519.NewKeyFromSeed(seed)
	bindingID := ""
	if s.Binding != nil {
		bindingID = s.Binding.ID
	}
	message, _ := json.Marshal(nasMessage{Action: action, PublicKey: base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey)), Name: s.Name, Environment: s.Environment, Timestamp: time.Now().Unix(), Nonce: randomRelayID(), BindingID: bindingID})
	payload, _ := json.Marshal(nasEnvelope{Message: string(message), Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(key, message)), Proof: proof})
	req, e := http.NewRequestWithContext(ctx, "POST", u.String(), bytes.NewReader(payload))
	if e != nil {
		return nil, e
	}
	req.Header.Set("Content-Type", "application/json")
	response, e := relayHTTPClient.Do(req)
	if e != nil {
		return nil, errors.New("publisher unavailable")
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return nil, &relaySetupError{Status: response.StatusCode}
	}
	b, e := io.ReadAll(io.LimitReader(response.Body, 16385))
	if e != nil || len(b) > 16384 {
		return nil, errors.New("invalid publisher response")
	}
	return b, nil
}

type relaySetupError struct{ Status int }

func (e *relaySetupError) Error() string { return "publisher refused setup" }
func claimNASRelay(ctx context.Context, s *nasRelayState, action string) error {
	b, e := nasRelayRequest(ctx, *s, action, nil)
	if e != nil {
		return e
	}
	var result struct {
		Credential string    `json:"credential"`
		GrantID    string    `json:"grant_id"`
		Expires    time.Time `json:"expires_at"`
	}
	if json.Unmarshal(b, &result) != nil || relayCredential("Bearer "+result.Credential) == "" || len(result.GrantID) != 16 || result.Expires.Before(time.Now()) {
		return errors.New("invalid publisher credential")
	}
	s.Credential = result.Credential
	s.GrantID = result.GrantID
	s.Expires = result.Expires
	s.LastRenewed = time.Now().UTC()
	s.Binding = nil
	return saveNASRelay(*s)
}
func nasPushSetup(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !allowedOrigin(r) {
		w.WriteHeader(403)
		return
	}
	isApp := r.URL.Path == "/voice-test/app/push-setup"
	if isApp {
		if appRequestHash(r) == "" {
			w.WriteHeader(401)
			return
		}
	} else {
		key := requestKey(r)
		_, app := appSessionParents.Load(key)
		if key == "" || app {
			w.WriteHeader(401)
			return
		}
	}
	if r.Method != "GET" && r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	environment := r.URL.Query().Get("environment")
	if environment != "sandbox" && environment != "production" {
		w.WriteHeader(400)
		return
	}
	nasRelayMu.Lock()
	defer nasRelayMu.Unlock()
	s, e := loadNASRelay(environment)
	loaded := e == nil
	if e != nil && !os.IsNotExist(e) {
		w.WriteHeader(503)
		return
	}
	if os.IsNotExist(e) {
		s = nasRelayState{Environment: environment, Endpoint: relayEndpoint(environment)}
	}
	// Early releases persisted an empty endpoint when an administrator clicked
	// begin before configuring the relay. Preserve that instance identity and
	// repair only the missing field after configuration is added and restarted.
	if loaded && strings.TrimSpace(s.Endpoint) == "" {
		if endpoint := strings.TrimSpace(relayEndpoint(environment)); endpoint != "" {
			s.Endpoint = endpoint
			if saveNASRelay(s) != nil {
				w.WriteHeader(503)
				return
			}
		}
	}
	write := func() {
		w.Header().Set("Content-Type", "application/json")
		view := relaySetupState(s)
		if manualRelayConfigured(environment) {
			view = relaySetupView{State: "manual", Environment: environment}
		}
		json.NewEncoder(w).Encode(view)
	}
	if r.Method == "GET" {
		write()
		return
	}
	var in struct {
		Action    string       `json:"action"`
		Name      string       `json:"name"`
		BindingID string       `json:"binding_id"`
		Proof     *attestProof `json:"proof"`
	}
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32768))
	d.DisallowUnknownFields()
	if d.Decode(&in) != nil || d.Decode(&struct{}{}) != io.EOF {
		w.WriteHeader(400)
		return
	}
	if isApp && in.Action != "confirm" {
		w.WriteHeader(403)
		return
	}
	fail := func(err error) {
		code := 503
		if e, ok := err.(*relaySetupError); ok {
			code = e.Status
		}
		if code < 400 || code > 599 {
			code = 503
		}
		w.WriteHeader(code)
	}
	switch in.Action {
	case "begin":
		if manualRelayConfigured(environment) {
			w.WriteHeader(409)
			return
		}
		if strings.TrimSpace(s.Endpoint) == "" {
			w.WriteHeader(409)
			return
		}
		name := strings.TrimSpace(in.Name)
		if len(name) == 0 || len(name) > 80 || strings.ContainsAny(name, "\r\n\x00") {
			w.WriteHeader(400)
			return
		}
		if s.Seed == "" {
			seed := make([]byte, 32)
			if _, e = rand.Read(seed); e != nil {
				w.WriteHeader(503)
				return
			}
			s.Seed = base64.StdEncoding.EncodeToString(seed)
			s.Name = name
			s.Endpoint = relayEndpoint(environment)
			if saveNASRelay(s) != nil {
				w.WriteHeader(503)
				return
			}
		}
		if s.Revoked {
			w.WriteHeader(403)
			return
		}
		// Current nickname is stable for this instance; retries don't change recipient.
		b, e := nasRelayRequest(r.Context(), s, "bind", nil)
		if e != nil {
			fail(e)
			return
		}
		var result struct {
			State string `json:"state"`
		}
		if json.Unmarshal(b, &result) != nil {
			w.WriteHeader(503)
			return
		}
		if result.State == "authorized" {
			if e = claimNASRelay(r.Context(), &s, "renew"); e != nil {
				fail(e)
				return
			}
		} else {
			var binding relayBinding
			seed, _ := base64.StdEncoding.DecodeString(s.Seed)
			expectedPublic := ""
			if len(seed) == 32 {
				expectedPublic = base64.StdEncoding.EncodeToString(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey))
			}
			if json.Unmarshal(b, &binding) != nil || len(binding.ID) != 64 || binding.Environment != environment || binding.PublicKey != expectedPublic || binding.Challenge == "" || binding.Expires.Before(time.Now()) {
				w.WriteHeader(503)
				return
			}
			s.Binding = &binding
			if saveNASRelay(s) != nil {
				w.WriteHeader(503)
				return
			}
		}
	case "confirm":
		if s.Binding == nil || in.BindingID != s.Binding.ID || in.Proof == nil || time.Now().After(s.Binding.Expires) {
			w.WriteHeader(410)
			return
		}
		response, err := nasRelayRequest(r.Context(), s, "confirm", in.Proof)
		if err != nil {
			fail(err)
			return
		}
		var confirmation struct {
			KeyID string `json:"confirmed_app_key"`
		}
		if json.Unmarshal(response, &confirmation) != nil || confirmation.KeyID == "" {
			w.WriteHeader(503)
			return
		}
		s.ConfirmedAppKey = confirmation.KeyID
		if saveNASRelay(s) != nil {
			w.WriteHeader(503)
			return
		}
		if e = claimNASRelay(r.Context(), &s, "claim"); e != nil {
			fail(e)
			return
		}
	case "unbind":
		if _, e = nasRelayRequest(r.Context(), s, "unbind", nil); e != nil {
			fail(e)
			return
		}
		s.Credential = ""
		s.Binding = nil
		s.Revoked = true
		if saveNASRelay(s) != nil {
			w.WriteHeader(503)
			return
		}
	default:
		w.WriteHeader(400)
		return
	}
	write()
}
func automaticRelayCredential(environment, endpoint string) (string, error) {
	// Atomic state writes permit a lock-free read on the critical incoming push
	// path. A slow setup or renewal must not hold up an existing authorization.
	s, e := loadNASRelay(environment)
	if e != nil || s.Endpoint != endpoint || s.Revoked || s.Credential == "" || time.Now().After(s.Expires) {
		return "", errors.New("automatic relay authorization unavailable")
	}
	return s.Credential, nil
}
func runRelayRenewals(ctx context.Context) {
	renew := func() {
		for _, environment := range []string{"sandbox", "production"} {
			nasRelayMu.Lock()
			s, e := loadNASRelay(environment)
			if e == nil && !s.Revoked && s.Credential != "" && time.Since(s.LastRenewed) > 24*time.Hour {
				requestCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
				e = claimNASRelay(requestCtx, &s, "renew")
				cancel()
				if re, ok := e.(*relaySetupError); ok && re.Status == 403 {
					s.Revoked = true
					s.Credential = ""
					_ = saveNASRelay(s)
				}
			}
			nasRelayMu.Unlock()
		}
	}
	renew()
	ticker := time.NewTicker(30 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			renew()
		}
	}
}
