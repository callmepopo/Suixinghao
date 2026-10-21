package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func enrollmentFixture(t *testing.T) (*pushRelay, ed25519.PrivateKey) {
	t.Helper()
	t.Setenv("VOICE_WEB_DATA_DIR", t.TempDir())
	t.Setenv("VOICE_WEB_RELAY_GRANTS_FILE", "")
	t.Setenv("VOICE_WEB_RELAY_AUTO_ENROLL", "1")
	t.Setenv("VOICE_WEB_APP_ATTEST_APP_ID", "SYNTHETIC0.com.junpo.suixinghao")
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	p := newPushRelay("production", func(context.Context, relayPush) (int, string, error) {
		t.Fatal("setup must not send APNs")
		return 0, "", nil
	})
	return p, key
}
func enrollmentCall(p *pushRelay, key ed25519.PrivateKey, action, binding, name string, proof *attestProof) (*httptest.ResponseRecorder, []byte) {
	msg, _ := json.Marshal(nasMessage{Action: action, PublicKey: base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey)), Name: name, Environment: p.Environment, Timestamp: p.Now().Unix(), Nonce: randomRelayID(), BindingID: binding})
	body, _ := json.Marshal(nasEnvelope{Message: string(msg), Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(key, msg)), Proof: proof})
	r := httptest.NewRequest("POST", "https://relay.example.org/push-relay/v1/"+action, bytes.NewReader(body))
	w := httptest.NewRecorder()
	p.ServeHTTP(w, r)
	return w, body
}
func beginFixture(t *testing.T, p *pushRelay, key ed25519.PrivateKey) relayBinding {
	t.Helper()
	w, _ := enrollmentCall(p, key, "bind", "", "synthetic recipient", nil)
	if w.Code != 200 {
		t.Fatalf("bind %d", w.Code)
	}
	var b relayBinding
	if json.Unmarshal(w.Body.Bytes(), &b) != nil || b.ID == "" {
		t.Fatal("binding")
	}
	return b
}
func mockOfficialVerifier(t *testing.T) {
	t.Helper()
	old := enrollmentVerifier
	t.Cleanup(func() { enrollmentVerifier = old })
	enrollmentVerifier = func(proof attestProof, challenge, environment, stored string, counter uint32, now time.Time) (verifiedAttest, error) {
		if proof.Object != "synthetic-verified" {
			return verifiedAttest{}, os.ErrPermission
		}
		return verifiedAttest{PublicKey: "synthetic-public", Counter: counter + 1}, nil
	}
}
func TestAutomaticEnrollmentLifecycleAndLedger(t *testing.T) {
	p, key := enrollmentFixture(t)
	mockOfficialVerifier(t)
	b := beginFixture(t, p, key)
	if beginFixture(t, p, key).ID != b.ID {
		t.Fatal("duplicate binding")
	}
	w, _ := enrollmentCall(p, key, "confirm", b.ID, "synthetic recipient", &attestProof{KeyID: "app-key", Object: "invalid"})
	if w.Code != 403 {
		t.Fatal("unverified app authorized")
	}
	proof := &attestProof{KeyID: "app-key", Object: "synthetic-verified"}
	for i := 0; i < 2; i++ {
		w, _ = enrollmentCall(p, key, "confirm", b.ID, "synthetic recipient", proof)
		if w.Code != 200 {
			t.Fatalf("confirm %d", w.Code)
		}
	}
	w, _ = enrollmentCall(p, key, "confirm", b.ID, "synthetic recipient", &attestProof{KeyID: "unverified-retry-key", Object: "invalid"})
	var receipt struct {
		KeyID string `json:"confirmed_app_key"`
	}
	if json.Unmarshal(w.Body.Bytes(), &receipt) != nil || receipt.KeyID != "app-key" {
		t.Fatal("confirmation retry must return original verified key, not caller input")
	}
	w, body := enrollmentCall(p, key, "claim", b.ID, "synthetic recipient", nil)
	if w.Code != 200 {
		t.Fatal("claim")
	}
	var claim struct {
		Credential string `json:"credential"`
	}
	json.Unmarshal(w.Body.Bytes(), &claim)
	r := httptest.NewRequest("POST", "https://relay.example.org/push-relay/v1/claim", bytes.NewReader(body))
	replayed := httptest.NewRecorder()
	p.ServeHTTP(replayed, r)
	if replayed.Code != 409 {
		t.Fatal("signed replay")
	}
	w, _ = enrollmentCall(p, key, "claim", b.ID, "synthetic recipient", nil)
	if !bytes.Contains(w.Body.Bytes(), []byte(claim.Credential)) {
		t.Fatal("changed credential")
	}
	grants, _ := loadRelayGrants()
	if len(grants) != 1 || grants[0].Created.IsZero() {
		t.Fatal("ledger")
	}
	data, _ := os.ReadFile(relayGrantsPath())
	if bytes.Contains(data, []byte(claim.Credential)) {
		t.Fatal("plaintext ledger")
	}
	created := grants[0].Created
	p.Now = func() time.Time { return created.Add(40 * 24 * time.Hour) }
	w, _ = enrollmentCall(p, key, "renew", "", "synthetic recipient", nil)
	if w.Code != 200 {
		t.Fatal("renew")
	}
	grants, _ = loadRelayGrants()
	if len(grants) != 1 || !grants[0].Created.Equal(created) || grants[0].Expires.Sub(p.Now()) != relayLease {
		t.Fatal("renew counted as issuance")
	}
	out := filepath.Join(t.TempDir(), "ledger.json")
	if e := exportRelayLedger([]string{"relay-export", out}); e != nil {
		t.Fatal(e)
	}
	data, _ = os.ReadFile(out)
	for _, secret := range []string{claim.Credential, "synthetic-public", "app-key"} {
		if bytes.Contains(data, []byte(secret)) {
			t.Fatal("crypto material exported")
		}
	}
	w, _ = enrollmentCall(p, key, "unbind", "", "synthetic recipient", nil)
	if w.Code != 200 {
		t.Fatal("unbind")
	}
	for _, action := range []string{"claim", "renew"} {
		w, _ = enrollmentCall(p, key, action, b.ID, "synthetic recipient", nil)
		if w.Code != 403 {
			t.Fatalf("revoked credential bypass %s: %d", action, w.Code)
		}
	}
	rebinding := beginFixture(t, p, key)
	if rebinding.ID == b.ID {
		t.Fatal("owner re-enrollment reused old binding")
	}
	w, _ = enrollmentCall(p, key, "confirm", rebinding.ID, "renamed recipient", proof)
	if w.Code != 200 {
		t.Fatalf("owner re-enrollment confirm %d", w.Code)
	}
	w, _ = enrollmentCall(p, key, "claim", rebinding.ID, "renamed recipient", nil)
	if w.Code != 200 {
		t.Fatalf("owner re-enrollment claim %d", w.Code)
	}
	var replacement struct {
		Credential string `json:"credential"`
	}
	if json.Unmarshal(w.Body.Bytes(), &replacement) != nil || replacement.Credential == "" || replacement.Credential == claim.Credential {
		t.Fatal("owner re-enrollment did not rotate credential")
	}
	if w = relayTestRequest(p, claim.Credential, relayBody("sms", "")); w.Code != 401 {
		t.Fatalf("old credential remained valid after re-enrollment: %d", w.Code)
	}
	grants, _ = loadRelayGrants()
	if len(grants) != 2 || revocationReason(grants[0]) != "instance_owner" || !grants[1].Revoked.IsZero() {
		t.Fatal("owner re-enrollment ledger")
	}
	if e := relayCommand(context.Background(), []string{"relay-revoke", grants[1].ID}); e != nil {
		t.Fatal(e)
	}
	w, _ = enrollmentCall(p, key, "bind", "", "synthetic recipient", nil)
	if w.Code != 403 {
		t.Fatalf("administrator revocation re-enrolled: %d", w.Code)
	}
}
func TestEnrollmentExpiryIsolationAndQuotas(t *testing.T) {
	p, key := enrollmentFixture(t)
	mockOfficialVerifier(t)
	b := beginFixture(t, p, key)
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	w, _ := enrollmentCall(p, other, "confirm", b.ID, "synthetic recipient", &attestProof{Object: "synthetic-verified"})
	if w.Code != 410 {
		t.Fatal("instance isolation")
	}
	now := p.Now()
	p.Now = func() time.Time { return now.Add(11 * time.Minute) }
	w, _ = enrollmentCall(p, key, "confirm", b.ID, "synthetic recipient", &attestProof{Object: "synthetic-verified"})
	if w.Code != 410 {
		t.Fatal("expiry")
	}
	keys := make([]ed25519.PrivateKey, 0, 3)
	bindings := make([]relayBinding, 0, 3)
	for i := 0; i < 3; i++ {
		_, k, _ := ed25519.GenerateKey(rand.Reader)
		b := beginFixture(t, p, k)
		w, _ = enrollmentCall(p, k, "confirm", b.ID, "synthetic recipient", &attestProof{KeyID: "same-app", Object: "synthetic-verified"})
		if w.Code != 200 {
			t.Fatalf("quota %d: %d", i, w.Code)
		}
		keys = append(keys, k)
		bindings = append(bindings, b)
	}
	w, _ = enrollmentCall(p, keys[0], "unbind", bindings[0].ID, "synthetic recipient", nil)
	if w.Code != 200 {
		t.Fatal("quota owner unbind")
	}
	rebinding := beginFixture(t, p, keys[0])
	w, _ = enrollmentCall(p, keys[0], "confirm", rebinding.ID, "synthetic recipient", &attestProof{KeyID: "same-app", Object: "synthetic-verified"})
	if w.Code != 200 {
		t.Fatalf("same instance consumed quota: %d", w.Code)
	}
	_, fourth, _ := ed25519.GenerateKey(rand.Reader)
	fourthBinding := beginFixture(t, p, fourth)
	w, _ = enrollmentCall(p, fourth, "confirm", fourthBinding.ID, "synthetic recipient", &attestProof{KeyID: "same-app", Object: "synthetic-verified"})
	if w.Code != 429 {
		t.Fatalf("fourth unique instance quota: %d", w.Code)
	}
}
func TestConcurrentConfirmationIssuesOneGrant(t *testing.T) {
	p, key := enrollmentFixture(t)
	mockOfficialVerifier(t)
	b := beginFixture(t, p, key)
	var wg sync.WaitGroup
	codes := make(chan int, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w, _ := enrollmentCall(p, key, "confirm", b.ID, "synthetic recipient", &attestProof{KeyID: "app-key", Object: "synthetic-verified"})
			codes <- w.Code
		}()
	}
	wg.Wait()
	close(codes)
	for code := range codes {
		if code != 200 {
			t.Fatalf("concurrent %d", code)
		}
	}
	grants, _ := loadRelayGrants()
	if len(grants) != 1 {
		t.Fatal("duplicate grants")
	}
}
func TestNASAdministrationAndPrivateClaim(t *testing.T) {
	p, _ := enrollmentFixture(t)
	mockOfficialVerifier(t)
	server := httptest.NewTLSServer(p)
	defer server.Close()
	old := relayHTTPClient
	relayHTTPClient = server.Client()
	t.Cleanup(func() { relayHTTPClient = old })
	t.Setenv("VOICE_WEB_PUSH_RELAY_URL_PRODUCTION", server.URL+"/push-relay/v1/push")
	t.Setenv("VOICE_WEB_PUSH_RELAY_KEY_FILE_PRODUCTION", "")
	admin := strings.Repeat("a", 64)
	sessions.Store(admin, time.Now().Add(time.Minute))
	defer sessions.Delete(admin)
	call := func(token, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "https://nas.example.org/voice-test/push-setup?environment=production", strings.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		nasPushSetup(w, r)
		return w
	}
	if w := call("", `{"action":"begin","name":"synthetic"}`); w.Code != 403 {
		t.Fatal("anonymous admin")
	}
	w := call(admin, `{"action":"begin","name":"synthetic"}`)
	if w.Code != 200 {
		t.Fatalf("begin %d", w.Code)
	}
	s, e := loadNASRelay("production")
	if e != nil {
		t.Fatal(e)
	}
	originalBindingID := s.Binding.ID
	if _, e = nasRelayRequest(context.Background(), s, "confirm", &attestProof{KeyID: "app-key", Object: "synthetic-verified"}); e != nil {
		t.Fatal(e)
	}
	if e = claimNASRelay(context.Background(), &s, "claim"); e != nil {
		t.Fatal(e)
	}
	if _, _, e = relayRoute("production"); e != nil {
		t.Fatal("automatic route")
	}
	state, _ := json.Marshal(relaySetupState(s))
	if bytes.Contains(state, []byte(s.Credential)) || bytes.Contains(state, []byte(s.Seed)) {
		t.Fatal("NAS exposed secret")
	}
	fi, _ := os.Stat(autoRelayPath("production"))
	if fi.Mode().Perm() != 0600 {
		t.Fatal("unsafe NAS file")
	}
	originalSeed := s.Seed
	if w = call(admin, `{"action":"unbind"}`); w.Code != 200 {
		t.Fatalf("NAS unbind %d", w.Code)
	}
	if w = call(admin, `{"action":"begin","name":"renamed"}`); w.Code != 200 {
		t.Fatalf("NAS re-enrollment begin %d", w.Code)
	}
	var view relaySetupView
	if json.Unmarshal(w.Body.Bytes(), &view) != nil || view.State != "pending" || view.GrantID != "" {
		t.Fatalf("NAS re-enrollment state: %s", w.Body.String())
	}
	reenrolling, e := loadNASRelay("production")
	if e != nil || reenrolling.Seed != originalSeed || reenrolling.Revoked || reenrolling.Credential != "" || reenrolling.Name != "renamed" || reenrolling.Binding == nil || reenrolling.Binding.ID == originalBindingID {
		t.Fatal("NAS re-enrollment did not preserve identity and clear old authorization")
	}
}

func TestNASMissingRelayEndpointAndLegacyStateRecovery(t *testing.T) {
	p, _ := enrollmentFixture(t)
	for _, suffix := range []string{"", "_PRODUCTION"} {
		t.Setenv("VOICE_WEB_PUSH_RELAY_URL"+suffix, "")
		t.Setenv("VOICE_WEB_PUSH_RELAY_KEY_FILE"+suffix, "")
	}
	// An explicit key-only route must still fail closed, without borrowing the
	// new official default or silently sending an old key to another endpoint.
	t.Setenv("VOICE_WEB_PUSH_RELAY_KEY_FILE_PRODUCTION", "/private/missing-relay.key")
	admin := strings.Repeat("b", 64)
	sessions.Store(admin, time.Now().Add(time.Minute))
	defer sessions.Delete(admin)
	call := func(method, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "https://nas.example.org/voice-test/push-setup?environment=production", strings.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+admin)
		w := httptest.NewRecorder()
		nasPushSetup(w, r)
		return w
	}

	w := call("GET", "")
	var view relaySetupView
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &view) != nil || view.State != "manual" {
		t.Fatalf("missing relay endpoint state: code=%d body=%s", w.Code, w.Body.String())
	}
	if w = call("POST", `{"action":"begin","name":"synthetic"}`); w.Code != 409 {
		t.Fatalf("unconfigured begin = %d", w.Code)
	}
	if _, err := os.Stat(autoRelayPath("production")); !os.IsNotExist(err) {
		t.Fatal("unconfigured begin persisted an empty instance")
	}

	seed := make([]byte, 32)
	if _, err := rand.Read(seed); err != nil {
		t.Fatal(err)
	}
	legacy := nasRelayState{Seed: base64.StdEncoding.EncodeToString(seed), Name: "synthetic", Environment: "production"}
	if err := saveNASRelay(legacy); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewTLSServer(p)
	defer server.Close()
	old := relayHTTPClient
	relayHTTPClient = server.Client()
	t.Cleanup(func() { relayHTTPClient = old })
	endpoint := server.URL + "/push-relay/v1/push"
	t.Setenv("VOICE_WEB_PUSH_RELAY_KEY_FILE_PRODUCTION", "")
	t.Setenv("VOICE_WEB_PUSH_RELAY_URL_PRODUCTION", endpoint)

	w = call("GET", "")
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &view) != nil || view.State != "not_enabled" {
		t.Fatalf("recovered relay state: code=%d body=%s", w.Code, w.Body.String())
	}
	recovered, err := loadNASRelay("production")
	if err != nil || recovered.Endpoint != endpoint || recovered.Seed != legacy.Seed {
		t.Fatal("legacy state was not repaired without changing its identity")
	}
	w = call("POST", `{"action":"begin","name":"synthetic"}`)
	if w.Code != 200 {
		t.Fatalf("recovered begin = %d", w.Code)
	}
	if json.Unmarshal(w.Body.Bytes(), &view) != nil || view.State != "pending" {
		t.Fatalf("recovered begin response: %s", w.Body.String())
	}
}
