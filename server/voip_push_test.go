package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVoIPTokenLifecycle(t *testing.T) {
	h, admin := appTestSetup(t)
	t.Setenv("VOICE_WEB_VOIP_TOKENS_FILE", filepath.Join(t.TempDir(), "tokens.json"))
	id, key := issueTestKey(t, h, admin)
	token := strings.Repeat("ab", 32)
	path := "/voice-test/app/voip-token"
	for _, bad := range []string{admin, "hdk_" + strings.Repeat("0", 64)} {
		if got := appTestRequest(h, "POST", path, bad, `{"token":"`+token+`","environment":"sandbox"}`).Code; got != 401 {
			t.Fatalf("unauthorized registration: %d", got)
		}
	}
	if got := appTestRequest(h, "POST", path, "", `{"token":"`+token+`","environment":"sandbox"}`).Code; got != 403 {
		t.Fatalf("missing bearer: %d", got)
	}
	for _, body := range []string{`{"token":"bad","environment":"sandbox"}`, `{"token":"` + token + `","environment":"other"}`} {
		if got := appTestRequest(h, "POST", path, key, body).Code; got != 400 {
			t.Fatalf("invalid token: %d", got)
		}
	}
	if got := appTestRequest(h, "POST", path, key, `{"token":"`+token+`","environment":"sandbox"}`).Code; got != 204 {
		t.Fatalf("register: %d", got)
	}
	devices, err := loadVoIPDevices()
	if err != nil || len(devices) != 1 || devices[0].Token != token || !devices[0].Sandbox {
		t.Fatal("token not saved")
	}
	info, _ := os.Stat(voipDevicesPath())
	if info.Mode().Perm() != 0600 {
		t.Fatal("token file permissions")
	}
	if got := appTestRequest(h, "DELETE", "/voice-test/app-keys?id="+id, admin, "").Code; got != 204 {
		t.Fatalf("revoke: %d", got)
	}
	devices, err = loadVoIPDevices()
	if err != nil || len(devices) != 0 {
		t.Fatal("revocation did not purge token")
	}
}

type inspectAPNsTransport struct {
	t             *testing.T
	token, callID string
}

func (p inspectAPNsTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.URL.Host != "api.sandbox.push.apple.com" || r.URL.Path != "/3/device/"+p.token ||
		r.Header.Get("apns-push-type") != "voip" || r.Header.Get("apns-topic") != "example.app.voip" ||
		r.Header.Get("apns-expiration") != "0" {
		p.t.Error("APNs request headers or address")
	}
	data, _ := io.ReadAll(r.Body)
	var body map[string]any
	if json.Unmarshal(data, &body) != nil || body["call_id"] != p.callID {
		p.t.Error("APNs payload")
	}
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("")), Header: make(http.Header)}, nil
}

func TestAPNsProviderJWTAndVoIPRequest(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pkcs8, _ := x509.MarshalPKCS8PrivateKey(key)
	path := filepath.Join(t.TempDir(), "key.p8")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8}), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("VOICE_WEB_APNS_KEY_FILE", path)
	t.Setenv("VOICE_WEB_APNS_KEY_ID", "KEY1234567")
	t.Setenv("VOICE_WEB_APNS_TEAM_ID", "TEAM123456")
	t.Setenv("VOICE_WEB_APNS_BUNDLE_ID", "example.app")
	provider, err := newAPNsProvider(true)
	if err != nil {
		t.Fatal(err)
	}
	jwt, err := provider.jwt()
	if err != nil {
		t.Fatal(err)
	}
	if again, err := provider.jwt(); err != nil || again != jwt {
		t.Fatal("provider token should be reused during its safe lifetime")
	}
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		t.Fatal("JWT segments")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		t.Fatal("JOSE signature length")
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("JWT signature invalid")
	}
	token := hex.EncodeToString(make([]byte, 32))
	provider.client = &http.Client{Transport: inspectAPNsTransport{t: t, token: token, callID: "test-call"}}
	status, _, err := provider.send(context.Background(), voipDevice{Token: token, Sandbox: true}, "test-call")
	if err != nil || status != 200 {
		t.Fatalf("send: %d %v", status, err)
	}
}
