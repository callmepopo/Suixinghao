package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"testing"
	"time"
)

func cborFixture(v any) []byte {
	prefix := func(major byte, n int) []byte {
		if n < 24 {
			return []byte{major<<5 | byte(n)}
		}
		if n < 256 {
			return []byte{major<<5 | 24, byte(n)}
		}
		return []byte{major<<5 | 25, byte(n >> 8), byte(n)}
	}
	switch x := v.(type) {
	case string:
		return append(prefix(3, len(x)), []byte(x)...)
	case []byte:
		return append(prefix(2, len(x)), x...)
	case uint64:
		return prefix(0, int(x))
	case int64:
		return prefix(1, int(-1-x))
	case []any:
		b := prefix(4, len(x))
		for _, v := range x {
			b = append(b, cborFixture(v)...)
		}
		return b
	case map[any]any:
		b := prefix(5, len(x))
		for k, v := range x {
			b = append(b, cborFixture(k)...)
			b = append(b, cborFixture(v)...)
		}
		return b
	}
	panic("CBOR type")
}
func TestAppAttestCryptographicVerification(t *testing.T) {
	t.Setenv("VOICE_WEB_APP_ATTEST_APP_ID", "SYNTHETIC0.com.junpo.suixinghao")
	now := time.Now()
	challenge := "synthetic-challenge"
	rootKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	rt := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Synthetic CA"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	rd, _ := x509.CreateCertificate(rand.Reader, rt, rt, &rootKey.PublicKey, rootKey)
	root, _ := x509.ParseCertificate(rd)
	old := appAttestRoot
	appAttestRoot = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: rd})
	t.Cleanup(func() { appAttestRoot = old })
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	id := sha256.Sum256(elliptic.Marshal(key.Curve, key.X, key.Y))
	rp := sha256.Sum256([]byte("SYNTHETIC0.com.junpo.suixinghao"))
	auth := append([]byte{}, rp[:]...)
	auth = append(auth, 0x40, 0, 0, 0, 0)
	auth = append(auth, []byte("appattest\x00\x00\x00\x00\x00\x00\x00")...)
	auth = append(auth, 0, 32)
	auth = append(auth, id[:]...)
	auth = append(auth, cborFixture(map[any]any{uint64(1): uint64(2), uint64(3): int64(-7), int64(-1): uint64(1), int64(-2): key.X.FillBytes(make([]byte, 32)), int64(-3): key.Y.FillBytes(make([]byte, 32))})...)
	h := sha256.Sum256([]byte(challenge))
	nonce := sha256.Sum256(append(append([]byte{}, auth...), h[:]...))
	ext, _ := asn1.Marshal(struct {
		Nonce []byte `asn1:"tag:1,explicit"`
	}{nonce[:]})
	lt := &x509.Certificate{SerialNumber: big.NewInt(2), NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtraExtensions: []pkix.Extension{{Id: asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 2}, Value: ext}}}
	leaf, _ := x509.CreateCertificate(rand.Reader, lt, root, &key.PublicKey, rootKey)
	object := cborFixture(map[any]any{"fmt": "apple-appattest", "authData": auth, "attStmt": map[any]any{"x5c": []any{leaf, rd}, "receipt": []byte("synthetic")}})
	proof := attestProof{KeyID: base64.StdEncoding.EncodeToString(id[:]), Object: base64.StdEncoding.EncodeToString(object)}
	result, e := verifyAppAttest(proof, challenge, "production", "", 0, now)
	if e != nil {
		t.Fatal(e)
	}
	for _, tc := range []struct{ challenge, environment, stored string }{{"changed", "production", ""}, {challenge, "sandbox", ""}, {challenge, "production", result.PublicKey}} {
		if _, e := verifyAppAttest(proof, tc.challenge, tc.environment, tc.stored, 0, now); e == nil {
			t.Fatal("tampered attestation")
		}
	}
	aa := append(append([]byte{}, rp[:]...), 0, 0, 0, 0, 1)
	signed := sha256.Sum256(append(append([]byte{}, aa...), h[:]...))
	sig, _ := ecdsa.SignASN1(rand.Reader, key, signed[:])
	assertion := attestProof{KeyID: proof.KeyID, Assertion: true, Object: base64.StdEncoding.EncodeToString(cborFixture(map[any]any{"authenticatorData": aa, "signature": sig}))}
	v, e := verifyAppAttest(assertion, challenge, "production", result.PublicKey, 0, now)
	if e != nil || v.Counter != 1 {
		t.Fatal("assertion")
	}
	if _, e := verifyAppAttest(assertion, challenge, "production", result.PublicKey, 1, now); e == nil {
		t.Fatal("counter replay")
	}
	if _, e := verifyAppAttest(assertion, "wrong", "production", result.PublicKey, 0, now); e == nil {
		t.Fatal("challenge replay")
	}
	if _, e := decodeAttestCBOR(append(object, 0)); e == nil {
		t.Fatal("trailing CBOR")
	}
	if _, e := decodeAttestCBOR(bytes.Repeat([]byte{0x9f}, 300)); e == nil {
		t.Fatal("indefinite CBOR")
	}
}
