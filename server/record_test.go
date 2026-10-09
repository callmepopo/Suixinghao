package main

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRecordingName(t *testing.T) {
	at := time.Date(2026, 9, 16, 14, 30, 12, 0, time.Local)
	for _, tt := range []struct {
		name, peer, direction, want string
	}{
		{"domestic format", "8613800000000", "拨打", "20260916-143012-8613800000000-拨打"},
		{"international plus stripped", "+8613800000000", "接听", "20260916-143012-8613800000000-接听"},
		{"missing caller", "", "接听", "20260916-143012-未知号码-接听"},
		{"injected caller", "86138;ATH", "接听", "20260916-143012-未知号码-接听"},
		{"unknown direction defaults to inbound", "8613800000000", "", "20260916-143012-8613800000000-接听"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got := recordingName(at, tt.peer, tt.direction)
			if got != tt.want {
				t.Fatalf("recordingName=%q want %q", got, tt.want)
			}
			if !namePattern.MatchString(got) {
				t.Fatalf("generated name %q does not match the recording pattern", got)
			}
		})
	}
}

func TestAutoRecordingWritesBothDirectionsAndMix(t *testing.T) {
	oldRoot, oldMax := recordRoot, recordMaxByte
	defer func() { recordRoot, recordMaxByte = oldRoot, oldMax }()
	recordRoot = t.TempDir()
	recordMaxByte = 1 << 20

	up := make([]int16, 800)
	down := make([]int16, 400)
	for i := range up {
		up[i] = 1000
	}
	for i := range down {
		down[i] = -2000
	}
	info := recordingInfo{Run: recordingName(time.Now(), "8613800000000", "拨打"), Peer: "8613800000000", Direction: "拨打"}
	p, err := newPair(recordRoot, info)
	if err != nil {
		t.Fatalf("newPair: %v", err)
	}
	p.writeUp(int16Bytes(up))
	p.writeDown(int16Bytes(down))
	p.close()

	dir := filepath.Join(recordRoot, time.Now().Format("20060102"))
	for _, f := range []string{info.Run + "-拨打.wav", info.Run + "-接听.wav", info.Run + "-合并.wav"} {
		fi, e := os.Stat(filepath.Join(dir, f))
		if e != nil {
			t.Fatalf("missing %s: %v", f, e)
		}
		if fi.Mode().Perm() != 0600 {
			t.Fatalf("%s permissions %v", f, fi.Mode().Perm())
		}
		if !strings.Contains(f, info.Run) {
			t.Fatalf("%s does not follow the agreed naming", f)
		}
	}
	// 单声道分轨：800 与 400 个样本，各 2 字节。
	if got := wavDataLen(t, filepath.Join(dir, info.Run+"-拨打.wav")); got != 1600 {
		t.Fatalf("dial track data %d want 1600", got)
	}
	if got := wavDataLen(t, filepath.Join(dir, info.Run+"-接听.wav")); got != 800 {
		t.Fatalf("answer track data %d want 800", got)
	}
	// 合并文件：左=拨打、右=接听，按较长一侧补齐静音。
	mix, e := os.ReadFile(filepath.Join(dir, info.Run+"-合并.wav"))
	if e != nil {
		t.Fatalf("read mix: %v", e)
	}
	if channels := binary.LittleEndian.Uint16(mix[22:]); channels != 2 {
		t.Fatalf("mix channels %d want 2", channels)
	}
	if data := binary.LittleEndian.Uint32(mix[40:]); data != 3200 {
		t.Fatalf("mix data %d want 3200", data)
	}
	if l := int16(binary.LittleEndian.Uint16(mix[44:])); l != 1000 {
		t.Fatalf("mix left sample %d want 1000", l)
	}
	if r := int16(binary.LittleEndian.Uint16(mix[46:])); r != -2000 {
		t.Fatalf("mix right sample %d want -2000", r)
	}
	// 第 400 个样本之后对方已结束，右声道应为静音。
	if r := int16(binary.LittleEndian.Uint16(mix[44+400*4+2:])); r != 0 {
		t.Fatalf("mix right sample after peer end %d want 0", r)
	}
}

func TestRecordingPruneOldestFirst(t *testing.T) {
	oldRoot, oldMax := recordRoot, recordMaxByte
	defer func() { recordRoot, recordMaxByte = oldRoot, oldMax }()
	recordRoot = t.TempDir()
	recordMaxByte = 1000
	old := filepath.Join(recordRoot, "old.wav")
	newer := filepath.Join(recordRoot, "new.wav")
	os.WriteFile(old, make([]byte, 800), 0600)
	os.WriteFile(newer, make([]byte, 800), 0600)
	os.Chtimes(old, time.Now().Add(-2*time.Hour), time.Now().Add(-2*time.Hour))
	pruneRecordings(recordRoot, recordMaxByte)
	if _, e := os.Stat(old); !os.IsNotExist(e) {
		t.Fatal("oldest recording should be pruned first")
	}
	if _, e := os.Stat(newer); e != nil {
		t.Fatal("newest recording must survive pruning")
	}
}

func int16Bytes(v []int16) []byte {
	b := make([]byte, len(v)*2)
	for i, s := range v {
		binary.LittleEndian.PutUint16(b[i*2:], uint16(s))
	}
	return b
}

func wavDataLen(t *testing.T, path string) uint32 {
	t.Helper()
	b, e := os.ReadFile(path)
	if e != nil {
		t.Fatalf("read %s: %v", path, e)
	}
	if len(b) < 44 || string(b[0:4]) != "RIFF" || string(b[8:12]) != "WAVE" {
		t.Fatalf("%s is not a WAV file", path)
	}
	return binary.LittleEndian.Uint32(b[40:44])
}

// call.active 里的 run 名必须接受现行录音命名，否则音频循环会刚启动就退出（曾导致通话全程无声）。
func TestSafeRunAcceptsCurrentNaming(t *testing.T) {
	ok := []string{
		"test-20260915-231425",
		"20260916-164641-8613800373816-拨打",
		"20260916-164641-8613800373816-接听",
		"20260916-164641-未知号码-接听",
		"20260916-164641-8613800373816-拨打-2",
	}
	for _, name := range ok {
		if !safeRun.MatchString(name) {
			t.Errorf("safeRun 拒绝了合法 run 名 %q", name)
		}
	}
	bad := []string{"", "../../etc/passwd", "20260916", "20260916-164641-../../x-拨打", "x;rm -rf /"}
	for _, name := range bad {
		if safeRun.MatchString(name) {
			t.Errorf("safeRun 接受了非法 run 名 %q", name)
		}
	}
}
