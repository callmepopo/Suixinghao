package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"log"
	"strings"
	"testing"
	"time"
)

func TestParseQCSQ(t *testing.T) {
	v := parseQCSQ("\r\n+QCSQ: \"LTE\",-62,-91,150,-9\r\n\r\nOK\r\n")
	if v == nil || v.RAT != "LTE" || *v.RSSI != -62 || *v.RSRP != -91 || *v.SINR != 10 || *v.RSRQ != -9 {
		t.Fatalf("lte %+v", v)
	}
	if v := parseQCSQ("+QCSQ: \"NOSERVICE\"\r\nOK"); v == nil || v.RAT != "NOSERVICE" || v.RSRP != nil {
		t.Fatal("no service")
	}
	if parseQCSQ("ERROR") != nil {
		t.Fatal("error must not parse")
	}
}

func TestCallSignalSamplingFallsBackAndThrottles(t *testing.T) {
	old := phoneAT
	defer func() { phoneAT = old }()
	var commands []string
	phoneAT = func(_, c string) (string, error) {
		commands = append(commands, c)
		if c == "AT+QCSQ" {
			return "", errors.New("ERROR")
		}
		return "+CSQ: 18,99\r\nOK", nil
	}
	now := time.Now()
	resetCallSignal(now)
	sampleCallSignal(now.Add(time.Second)) // startup grace: no query
	sampleCallSignal(now.Add(4 * time.Second))
	sampleCallSignal(now.Add(5 * time.Second)) // throttled
	sampleCallSignal(now.Add(15 * time.Second))
	if strings.Join(commands, ",") != "AT+QCSQ,AT+CSQ,AT+CSQ" {
		t.Fatalf("commands %v", commands)
	}
	s := callSignalSummary()
	if s["samples"] != uint64(2) || s["latest"].(callSignalView).CSQ == nil || *s["latest"].(callSignalView).CSQ != 18 {
		t.Fatalf("summary %+v", s)
	}
	callSignal.Lock()
	callSignal.noQCSQ = false
	callSignal.Unlock()
}

func TestAudioDiagnosticsV3ContextLevelsAndGaps(t *testing.T) {
	base := map[string]any{"type": "audio_stats", "version": 3, "segment": "12345678-1234-1234-1234-123456789abc", "elapsed_ms": 5000,
		"down_underruns": 2, "down_concealed_samples": 480, "down_depth_peak_frames": 7, "input_rate": 16000,
		"context":    map[string]string{"route_in": "BluetoothHFP", "route_out": "BluetoothHFP", "session_mode": "AVAudioSessionModeVoiceChat", "net": "wifi"},
		"down_level": map[string]uint64{"samples": 10, "rms": 100, "peak": 900, "quiet_samples": 1, "clipped_samples": 0},
		"events":     []map[string]any{{"kind": "down_gap", "elapsed_ms": 100, "frame": 3, "value": 180000}, {"kind": "route_change", "elapsed_ms": 200, "frame": 4, "value": 1}},
	}
	encode := func(v map[string]any) []byte { b, _ := json.Marshal(v); return b }
	s := &audioStats{}
	s.begin("one")
	var out bytes.Buffer
	old := log.Writer()
	log.SetOutput(&out)
	defer log.SetOutput(old)
	if !s.acceptClient(encode(base), time.Now()) || !strings.Contains(out.String(), "BluetoothHFP") {
		t.Fatalf("v3 rejected: %s", out.String())
	}
	for name, bad := range map[string]any{
		"context": map[string]string{"route_in": "Test AirPods 的耳机"},
		"events":  []map[string]any{{"kind": "phone_number", "elapsed_ms": 1, "frame": 1, "value": 1}},
	} {
		clone := map[string]any{}
		for k, v := range base {
			clone[k] = v
		}
		clone[name] = bad
		if (&audioStats{}).acceptClient(encode(clone), time.Now()) {
			t.Fatalf("accepted invalid %s", name)
		}
	}
	unknownKey := map[string]any{}
	for k, v := range base {
		unknownKey[k] = v
	}
	unknownKey["context"] = map[string]string{"device_name": "x"}
	if (&audioStats{}).acceptClient(encode(unknownKey), time.Now()) {
		t.Fatal("unknown context key")
	}
	// v2 clients keep the old strict schema.
	v2 := map[string]any{}
	for k, v := range base {
		v2[k] = v
	}
	v2["version"] = 2
	if (&audioStats{}).acceptClient(encode(v2), time.Now()) {
		t.Fatal("v2 must not carry v3 fields")
	}
	now := time.Now()
	s.arrivalAt("one", false, 0, now)
	s.arrivalAt("one", false, 0, now.Add(200*time.Millisecond))
	s.arrivalAt("one", false, 0, now.Add(600*time.Millisecond))
	s.level(true, []byte{0xff, 0x7f, 0x00, 0x00})
	s.level(false, []byte{0x10, 0x00})
	out.Reset()
	s.summary(false)
	text := out.String()
	for _, want := range []string{`"ge150ms":2`, `"ge300ms":1`, `"up_level":{"clipped_samples":1,"peak":32767`, `"down_level":{"clipped_samples":0,"peak":16`, `"signal":{`} {
		if !strings.Contains(text, want) {
			t.Fatalf("missing %s in %s", want, text)
		}
	}
	out.Reset()
	s.summary(false)
	if !strings.Contains(out.String(), `"up_level":{"clipped_samples":0,"peak":0,"quiet_samples":0,"rms":0,"samples":0}`) {
		t.Fatal("levels are per window")
	}
}
