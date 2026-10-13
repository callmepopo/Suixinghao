package main

// App Attest verification follows Apple's server validation procedure. The
// embedded public CA is fetched from apple.com, never from client input.
import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"os"
	"time"
)

//go:embed apple-app-attest-root.pem
var appAttestRoot []byte

// A deliberately bounded CBOR reader for App Attest. No indefinite values,
// duplicate map keys, trailing data or allocation based on untrusted lengths.
type attestCBOR struct {
	data      []byte
	at, nodes int
}

func decodeAttestCBOR(data []byte) (any, error) {
	if len(data) > 32768 {
		return nil, errors.New("CBOR too large")
	}
	c := attestCBOR{data: data}
	v, e := c.read(0)
	if e == nil && c.at != len(data) {
		e = errors.New("trailing CBOR")
	}
	return v, e
}
func (c *attestCBOR) read(depth int) (any, error) {
	c.nodes++
	if depth > 12 || c.nodes > 512 || c.at >= len(c.data) {
		return nil, errors.New("invalid CBOR")
	}
	h := c.data[c.at]
	c.at++
	major := h >> 5
	ai := h & 31
	n := uint64(ai)
	if ai >= 24 {
		size := 0
		switch ai {
		case 24:
			size = 1
		case 25:
			size = 2
		case 26:
			size = 4
		case 27:
			size = 8
		default:
			return nil, errors.New("indefinite CBOR")
		}
		if c.at+size > len(c.data) {
			return nil, errors.New("truncated CBOR")
		}
		n = 0
		for _, b := range c.data[c.at : c.at+size] {
			n = n<<8 | uint64(b)
		}
		c.at += size
	}
	switch major {
	case 0:
		return n, nil
	case 1:
		if n > 1<<31 {
			return nil, errors.New("CBOR integer")
		}
		return -1 - int64(n), nil
	case 2, 3:
		if n > uint64(len(c.data)-c.at) {
			return nil, errors.New("CBOR length")
		}
		v := c.data[c.at : c.at+int(n)]
		c.at += int(n)
		if major == 3 {
			return string(v), nil
		}
		return v, nil
	case 4:
		if n > 128 {
			return nil, errors.New("CBOR array")
		}
		a := []any{}
		for i := uint64(0); i < n; i++ {
			v, e := c.read(depth + 1)
			if e != nil {
				return nil, e
			}
			a = append(a, v)
		}
		return a, nil
	case 5:
		if n > 64 {
			return nil, errors.New("CBOR map")
		}
		m := map[any]any{}
		for i := uint64(0); i < n; i++ {
			k, e := c.read(depth + 1)
			if e != nil {
				return nil, e
			}
			switch k.(type) {
			case string, uint64, int64:
			default:
				return nil, errors.New("CBOR key")
			}
			if _, ok := m[k]; ok {
				return nil, errors.New("duplicate CBOR key")
			}
			v, e := c.read(depth + 1)
			if e != nil {
				return nil, e
			}
			m[k] = v
		}
		return m, nil
	}
	return nil, errors.New("unsupported CBOR")
}

type attestProof struct {
	KeyID     string `json:"key_id"`
	Object    string `json:"object"`
	Assertion bool   `json:"assertion"`
}
type verifiedAttest struct {
	PublicKey string
	Counter   uint32
}

func verifyAppAttest(proof attestProof, challenge, environment, storedKey string, previous uint32, now time.Time) (verifiedAttest, error) {
	fail := func() (verifiedAttest, error) {
		return verifiedAttest{}, errors.New("official app verification failed")
	}
	appID := os.Getenv("VOICE_WEB_APP_ATTEST_APP_ID")
	if appID == "" {
		return fail()
	}
	keyID, e := base64.StdEncoding.DecodeString(proof.KeyID)
	if e != nil || len(keyID) != 32 {
		return fail()
	}
	object, e := base64.StdEncoding.DecodeString(proof.Object)
	if e != nil {
		return fail()
	}
	decoded, e := decodeAttestCBOR(object)
	if e != nil {
		return fail()
	}
	m, ok := decoded.(map[any]any)
	if !ok {
		return fail()
	}
	rp := sha256.Sum256([]byte(appID))
	clientHash := sha256.Sum256([]byte(challenge))
	if proof.Assertion {
		auth, ok := m["authenticatorData"].([]byte)
		if !ok || len(auth) < 37 || !bytes.Equal(auth[:32], rp[:]) {
			return fail()
		}
		counter := binary.BigEndian.Uint32(auth[33:37])
		if counter <= previous {
			return fail()
		}
		der, e := base64.StdEncoding.DecodeString(storedKey)
		if e != nil {
			return fail()
		}
		pk, e := x509.ParsePKIXPublicKey(der)
		if e != nil {
			return fail()
		}
		pub, ok := pk.(*ecdsa.PublicKey)
		if !ok || pub.Curve != elliptic.P256() {
			return fail()
		}
		pubHash := sha256.Sum256(elliptic.Marshal(pub.Curve, pub.X, pub.Y))
		if !bytes.Equal(pubHash[:], keyID) {
			return fail()
		}
		sig, ok := m["signature"].([]byte)
		if !ok {
			return fail()
		}
		nonce := sha256.Sum256(append(append([]byte{}, auth...), clientHash[:]...))
		if !ecdsa.VerifyASN1(pub, nonce[:], sig) {
			return fail()
		}
		return verifiedAttest{PublicKey: storedKey, Counter: counter}, nil
	}
	if storedKey != "" || m["fmt"] != "apple-appattest" {
		return fail()
	}
	auth, ok := m["authData"].([]byte)
	if !ok || len(auth) < 87 || auth[32]&0x40 == 0 || !bytes.Equal(auth[:32], rp[:]) || binary.BigEndian.Uint32(auth[33:37]) != 0 {
		return fail()
	}
	want := []byte("appattest\x00\x00\x00\x00\x00\x00\x00")
	if environment == "sandbox" {
		if !bytes.Equal(auth[37:53], []byte("appattestdevelop")) && !bytes.Equal(auth[37:53], []byte("appattestsandbox")) {
			return fail()
		}
	} else if !bytes.Equal(auth[37:53], want) {
		return fail()
	}
	if binary.BigEndian.Uint16(auth[53:55]) != 32 || !bytes.Equal(auth[55:87], keyID) {
		return fail()
	}
	stmt, ok := m["attStmt"].(map[any]any)
	if !ok {
		return fail()
	}
	chain, ok := stmt["x5c"].([]any)
	if !ok || len(chain) < 2 || len(chain) > 4 {
		return fail()
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(appAttestRoot) {
		return fail()
	}
	intermediates := x509.NewCertPool()
	var leaf *x509.Certificate
	for i, v := range chain {
		b, ok := v.([]byte)
		if !ok {
			return fail()
		}
		cert, e := x509.ParseCertificate(b)
		if e != nil {
			return fail()
		}
		if i == 0 {
			leaf = cert
		} else {
			intermediates.AddCert(cert)
		}
	}
	if _, e = leaf.Verify(x509.VerifyOptions{Roots: roots, Intermediates: intermediates, CurrentTime: now, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}}); e != nil {
		return fail()
	}
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return fail()
	}
	pubHash := sha256.Sum256(elliptic.Marshal(pub.Curve, pub.X, pub.Y))
	if !bytes.Equal(pubHash[:], keyID) {
		return fail()
	}
	nonce := sha256.Sum256(append(append([]byte{}, auth...), clientHash[:]...))
	matched := false
	for _, ext := range leaf.Extensions {
		if ext.Id.String() == "1.2.840.113635.100.8.2" {
			var outer struct {
				Nonce []byte `asn1:"tag:1,explicit"`
			}
			rest, e := asn1.Unmarshal(ext.Value, &outer)
			matched = e == nil && len(rest) == 0 && bytes.Equal(outer.Nonce, nonce[:])
		}
	}
	if !matched {
		return fail()
	}
	// Validate COSE key independently, and optional signed iOS 26 properties.
	c := attestCBOR{data: auth[87:]}
	cose, e := c.read(0)
	if e != nil {
		return fail()
	}
	cm, ok := cose.(map[any]any)
	if !ok {
		return fail()
	}
	x, xok := cm[int64(-2)].([]byte)
	y, yok := cm[int64(-3)].([]byte)
	if !xok || !yok || !bytes.Equal(x, pub.X.FillBytes(make([]byte, 32))) || !bytes.Equal(y, pub.Y.FillBytes(make([]byte, 32))) || cm[uint64(1)] != uint64(2) || cm[int64(-1)] != uint64(1) || cm[uint64(3)] != int64(-7) {
		return fail()
	}
	if auth[32]&0x80 != 0 {
		extensions, e := c.read(0)
		if e != nil {
			return fail()
		}
		em, ok := extensions.(map[any]any)
		if !ok {
			return fail()
		}
		if category, ok := em["apple_validation_category_01"]; ok {
			allowed := category == uint64(2) || category == uint64(4)
			if environment == "sandbox" {
				allowed = category == uint64(3)
			}
			if !allowed {
				return fail()
			}
		}
		if version, ok := em["apple_bundle_version_01"]; ok {
			v, ok := version.(string)
			if !ok || v == "" || len(v) > 64 {
				return fail()
			}
		}
	}
	if c.at != len(c.data) {
		return fail()
	}
	der, e := x509.MarshalPKIXPublicKey(pub)
	if e != nil {
		return fail()
	}
	return verifiedAttest{PublicKey: base64.StdEncoding.EncodeToString(der)}, nil
}
func attestAppIDConfigured() bool { return len(os.Getenv("VOICE_WEB_APP_ATTEST_APP_ID")) > 11 }
