package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCallGate(t *testing.T) {
	old := callFlag
	defer func() { callFlag = old }()
	callFlag = filepath.Join(t.TempDir(), "call")
	if activeRun() != "" {
		t.Fatal("idle active")
	}
	os.WriteFile(callFlag, []byte("../invalid"), 0600)
	if activeRun() != "" {
		t.Fatal("unsafe id")
	}
	os.WriteFile(callFlag, []byte("test-20260915-230000"), 0600)
	if activeRun() == "" {
		t.Fatal("valid call inactive")
	}
	os.Chtimes(callFlag, time.Now().Add(-3*time.Minute), time.Now().Add(-3*time.Minute))
	if activeRun() != "" {
		t.Fatal("stale call active")
	}
}

func TestParseUplinkGapPlan(t *testing.T) {
	p := parseUplinkGapPlan(" 90:60, 40:120\n")
	if len(p) != 2 || p[0].at != 40*time.Second || p[0].hold != 120*time.Millisecond || p[1].at != 90*time.Second {
		t.Fatalf("plan %+v", p)
	}
	for _, bad := range []string{"", "40", "40:0", "2:50", "40:5000", "a:b", "40:50,,"} {
		if parseUplinkGapPlan(bad) != nil {
			t.Fatalf("%q must be rejected", bad)
		}
	}
	if underrunMS("underrun!!! (at least 121.345 ms long)") != "121.345" || underrunMS("underrun!!!") != "" {
		t.Fatal("underrun length")
	}
}

func TestJitterDropDiscardsOldest(t *testing.T) {
	j := newUplinkJitter()
	for i := 0; i < 5; i++ {
		b := make([]byte, jitterFrameBytes)
		b[0] = byte(i)
		j.push(b)
	}
	j.drop(3)
	if v := j.view(); v["depth_frames"] != 2 || v["trimmed_frames"] != 3 {
		t.Fatalf("view %v", v)
	}
	j.drop(10)
	if j.view()["depth_frames"] != 0 {
		t.Fatal("drop must stop at empty")
	}
}
