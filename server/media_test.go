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
