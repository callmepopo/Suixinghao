package main

import (
	"testing"
	"time"
)

func TestOfficialRelayDefaultsAndExistingRoutes(t *testing.T) {
	t.Setenv("VOICE_WEB_DATA_DIR", t.TempDir())
	for _, suffix := range []string{"", "_SANDBOX", "_PRODUCTION"} {
		t.Setenv("VOICE_WEB_PUSH_RELAY_URL"+suffix, "")
		t.Setenv("VOICE_WEB_PUSH_RELAY_KEY_FILE"+suffix, "")
	}
	if relayEndpoint("production") != officialRelayEndpoint || relayEndpoint("sandbox") != "https://sxhpush.jphr.cc/sandbox/push-relay/v1/push" || relayEndpoint("invalid") != "" {
		t.Fatal("official defaults must isolate environments")
	}
	if relayEnabled() {
		t.Fatal("default discovery must preserve self-signed direct APNs before enrollment")
	}
	if _, _, err := relayRoute("production"); err == nil {
		t.Fatal("public endpoint must not authorize push")
	}
	state := nasRelayState{Environment: "production", Endpoint: officialRelayEndpoint, Credential: "synthetic", GrantID: "synthetic", Expires: time.Now().Add(time.Hour)}
	if err := saveNASRelay(state); err != nil {
		t.Fatal(err)
	}
	endpoint, keyFile, err := relayRoute("production")
	if err != nil || endpoint != officialRelayEndpoint || keyFile != "" || !relayEnabled() {
		t.Fatal("default automatic authorization must route pushes")
	}
	state.Endpoint = "https://old-relay.example.org/push-relay/v1/push"
	if err := saveNASRelay(state); err != nil {
		t.Fatal(err)
	}
	endpoint, _, err = relayRoute("production")
	if err != nil || endpoint != state.Endpoint {
		t.Fatal("existing automatic endpoint and credential must stay together")
	}
	if _, err := automaticRelayCredential("production", officialRelayEndpoint); err == nil {
		t.Fatal("implicit endpoint change must be rejected")
	}
	t.Setenv("VOICE_WEB_PUSH_RELAY_URL", "https://custom.example.org/push-relay/v1/push")
	t.Setenv("VOICE_WEB_PUSH_RELAY_KEY_FILE", "/private/custom.key")
	endpoint, keyFile, err = relayRoute("production")
	if err != nil || endpoint != relayEndpoint("production") || keyFile != "/private/custom.key" {
		t.Fatal("explicit legacy route must take precedence")
	}
	t.Setenv("VOICE_WEB_PUSH_RELAY_KEY_FILE_SANDBOX", "/private/sandbox.key")
	if relayEndpoint("sandbox") != "" {
		t.Fatal("key-only route must not borrow default endpoint")
	}
	if _, _, err := relayRoute("sandbox"); err == nil {
		t.Fatal("incomplete manual route must fail closed")
	}
}
