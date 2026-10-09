package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type handlerTransport struct{ handler http.Handler }

func (transport handlerTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	response := httptest.NewRecorder()
	transport.handler.ServeHTTP(response, request)
	return response.Result(), nil
}

func TestConfiguredDeviceUsesExistingUpstreamATQueue(t *testing.T) {
	oldUpstream, oldConfig, oldClient := upstream, configPath, client
	t.Cleanup(func() { upstream, configPath, client = oldUpstream, oldConfig, oldClient })
	t.Setenv("VOICE_WEB_DEVICE_ID", "custom-modem")
	configPath = filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(configPath, []byte("web:\n  password: synthetic-signing-material\n"), 0600); err != nil {
		t.Fatal(err)
	}
	observed := false
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/devices/custom-modem/actions/at" || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
			t.Errorf("configured device did not use the authenticated upstream AT queue")
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		var body struct {
			Cmd string `json:"cmd"`
		}
		if json.NewDecoder(r.Body).Decode(&body) != nil || body.Cmd != "AT+CLCC" {
			t.Error("AT command changed")
		}
		observed = true
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok","response":"OK"}`))
	})
	upstream = "http://upstream.example.org"
	client = &http.Client{Transport: handlerTransport{handler}}
	if response, err := phoneAT("", "AT+CLCC"); err != nil || response != "OK" || !observed {
		t.Fatalf("configured module request failed: response=%q err=%v observed=%v", response, err, observed)
	}
}

func TestDataDirectoryKeepsStateTogetherAndRespectsLegacyOverrides(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("VOICE_WEB_DATA_DIR", directory)
	for _, name := range []string{"VOICE_WEB_APP_KEYS_FILE", "VOICE_WEB_RECORDING_FILE", "VOICE_WEB_VOIP_TOKENS_FILE", "VOICE_WEB_SMS_PUSH_TOKENS_FILE", "VOICE_WEB_SMS_CURSOR_FILE", "VOICE_WEB_CONNECTION_HISTORY_FILE"} {
		t.Setenv(name, "")
	}
	paths := map[string]string{
		"app-keys.json": appKeysPath(), "recording.json": recordingFile(),
		"voip-tokens.json": voipDevicesPath(), "sms-push-tokens.json": smsPushTokensPath(),
		"sms-push-cursor.json": smsCursorPath(), "connection-history.json": historyPath(),
	}
	for name, path := range paths {
		if path != filepath.Join(directory, name) {
			t.Errorf("%s escaped the configured data directory", name)
		}
	}
	if err := setRecording(false); err != nil || recordingEnabled() {
		t.Fatalf("recording setting was not stored in configured data directory: %v", err)
	}
	legacyKeys := filepath.Join(t.TempDir(), "device-keys.json")
	t.Setenv("VOICE_WEB_APP_KEYS_FILE", legacyKeys)
	if appKeysPath() != legacyKeys || historyPath() != filepath.Join(filepath.Dir(legacyKeys), "connection-history.json") {
		t.Fatal("legacy key location and dependent history location changed")
	}
	explicitHistory := filepath.Join(directory, "explicit-history.json")
	t.Setenv("VOICE_WEB_CONNECTION_HISTORY_FILE", explicitHistory)
	if historyPath() != explicitHistory {
		t.Fatal("explicit history file override ignored")
	}
}

func TestEmbeddedWebRoutesAndOptionalSourceCommit(t *testing.T) {
	handler := routes()
	for _, path := range []string{"/voice-test/", "/voice-test/audio.js", "/voice-test/menu.js", "/voice-test/app-access/"} {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, origin+path, nil))
		if response.Code != http.StatusOK || response.Body.Len() == 0 {
			t.Errorf("embedded asset unavailable: %s (%d)", path, response.Code)
		}
	}
	oldCommit := sourceCommit
	defer func() { sourceCommit = oldCommit }()
	sourceCommit = "synthetic-commit"
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, origin+"/voice-test/health", nil))
	var health map[string]any
	if json.Unmarshal(response.Body.Bytes(), &health) != nil || health["source_commit"] != sourceCommit || health["ok"] != true {
		t.Fatal("health did not identify the embedded build source")
	}
}
