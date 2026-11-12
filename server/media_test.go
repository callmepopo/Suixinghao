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

func TestParseUplinkTestPlan(t *testing.T) {
	if p := parseUplinkTestPlan("40:120,90:120\n"); !p.valid || len(p.gaps) != 2 || p.matchPrefix != "" {
		t.Fatalf("one-line plan %+v", p)
	}
	if p := parseUplinkTestPlan("-"); !p.valid || p.gaps != nil {
		t.Fatalf("no-gap plan %+v", p)
	}
	if p := parseUplinkTestPlan("-\r\nsame-number-as=20260101-000000\n"); !p.valid || p.gaps != nil || p.matchPrefix != "20260101-000000" {
		t.Fatalf("no-gap matched plan %+v", p)
	}
	if p := parseUplinkTestPlan("40:120\nsame-number-as=20260101-000000"); !p.valid || len(p.gaps) != 1 || p.matchPrefix == "" {
		t.Fatalf("matched plan %+v", p)
	}
	for _, bad := range []string{"", "x", "40:0", "-\nsame-number-as=2026-0101", "-\nsame-number-as=20260101-00000a",
		"-\nsame-number-as=../20260101-000000", "-\nsame=20260101-000000", "-\nsame-number-as=20260101-000000\nextra"} {
		if parseUplinkTestPlan(bad).valid {
			t.Fatalf("%q must be rejected", bad)
		}
	}
}

func TestUplinkTestNumberMatch(t *testing.T) {
	if runPeer("20260101-000000-10000000001-拨打") != "10000000001" || runPeer("20260101-000000-10000000001-2-接听.wav") != "10000000001" {
		t.Fatal("peer from run name")
	}
	if runPeer("20260101-000000-未知号码-接听") != "" || runPeer("test-20260101-000000") != "" {
		t.Fatal("unknown peer must not match")
	}
	root := t.TempDir()
	dir := filepath.Join(root, "20260101")
	os.MkdirAll(dir, 0700)
	os.WriteFile(filepath.Join(dir, "20260101-000000-10000000001-拨打-合并.wav"), nil, 0600)
	plan := uplinkTestPlan{valid: true, matchPrefix: "20260101-000000"}
	if !planAppliesTo(plan, root, "20260102-120000-10000000001-拨打") {
		t.Fatal("same number must match")
	}
	if planAppliesTo(plan, root, "20260102-120000-10000000002-拨打") || planAppliesTo(plan, root, "20260102-120000-未知号码-接听") {
		t.Fatal("different or unknown number must not match")
	}
	plan.matchPrefix = "20260101-000001"
	if planAppliesTo(plan, root, "20260102-120000-10000000001-拨打") {
		t.Fatal("missing reference must not match")
	}
	if !planAppliesTo(uplinkTestPlan{valid: true}, root, "20260102-120000-未知号码-接听") || planAppliesTo(uplinkTestPlan{}, root, "") {
		t.Fatal("unmatched plan applies to every call; invalid plan to none")
	}
}

func TestLoadUplinkTestAudio(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "a.raw")
	if _, err := loadUplinkTestAudio(path); err == nil {
		t.Fatal("missing file")
	}
	os.WriteFile(path, make([]byte, 319), 0600)
	if _, err := loadUplinkTestAudio(path); err == nil {
		t.Fatal("shorter than one frame must be rejected")
	}
	b := make([]byte, 2*320+100)
	b[0], b[320] = 1, 2
	os.WriteFile(path, b, 0600)
	a, err := loadUplinkTestAudio(path)
	if err != nil || len(a.b) != 640 || a.seconds() != 0.04 {
		t.Fatalf("audio %v %v", a, err)
	}
	for i, want := range []byte{1, 2, 1, 2} {
		if f := a.next(); len(f) != 320 || f[0] != want {
			t.Fatalf("frame %d", i)
		}
	}
	f, _ := os.Create(path)
	f.Truncate(uplinkTestAudioMax + 320)
	f.Close()
	if _, err := loadUplinkTestAudio(path); err == nil {
		t.Fatal("oversized file must be rejected")
	}
}
