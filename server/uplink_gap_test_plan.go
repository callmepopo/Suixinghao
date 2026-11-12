package main

import (
	"errors"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Diagnostic only. The module pushes every 16 ms of USB audio straight into the
// voice DSP, which keeps almost no slack; about 64 s after the USB stream
// starts, and every 80 s after that, the far end loses several seconds of our
// voice. To learn whether a short, deliberate break in the stream makes the DSP
// realign cleanly, a plan file can schedule such breaks for the next calls.
//
// File <data dir>/uplink-gap-test, one line: "40:120,90:120,140:60" means
// 40 s after the stream starts stop feeding it for 120 ms, and so on. Missing
// or invalid file: no breaks. Remove the file to end the test.
//
// Optional second line "same-number-as=20261112-164127" limits the test to
// calls with the same remote number as that earlier run, so the conditions of
// a bad call can be repeated without catching unrelated calls. A first line of
// "-" means no breaks (useful with the test audio below only).
//
// If the plan applies and <data dir>/uplink-test-audio.raw exists (S16LE 8 kHz
// mono), its frames replace the phone microphone while the call is active, so
// a test call needs nobody speaking and every run sends the same signal.
type uplinkGap struct{ at, hold time.Duration }

type uplinkTestPlan struct {
	gaps        []uplinkGap
	matchPrefix string
	valid       bool
}

var (
	uplinkGapFile       = dataPath("uplink-gap-test")
	uplinkTestAudioFile = dataPath("uplink-test-audio.raw")
	runPrefixPattern    = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}$`)
	runPeerPattern      = regexp.MustCompile(`^(?:test-)?[0-9]{8}-[0-9]{6}-([0-9]{3,20})-`)
)

const uplinkTestAudioMax = 40 << 20

func parseUplinkTestPlan(s string) uplinkTestPlan {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) > 2 {
		return uplinkTestPlan{}
	}
	var p uplinkTestPlan
	if first := strings.TrimSpace(lines[0]); first != "-" {
		if p.gaps = parseUplinkGapPlan(first); p.gaps == nil {
			return uplinkTestPlan{}
		}
	}
	if len(lines) == 2 {
		v, ok := strings.CutPrefix(strings.TrimSpace(lines[1]), "same-number-as=")
		if !ok || !runPrefixPattern.MatchString(v) {
			return uplinkTestPlan{}
		}
		p.matchPrefix = v
	}
	p.valid = true
	return p
}

// runPeer returns the remote number embedded in a run or recording file name
// (YYYYMMDD-HHMMSS-<number>-拨打|接听...); "" when unknown.
func runPeer(name string) string {
	if m := runPeerPattern.FindStringSubmatch(name); m != nil {
		return m[1]
	}
	return ""
}

// referencePeer finds the number of the earlier run from its recordings
// (<root>/<YYYYMMDD>/<run>-拨打.wav and siblings).
func referencePeer(root, prefix string) string {
	names, _ := filepath.Glob(filepath.Join(root, "*", prefix+"-*"))
	for _, n := range names {
		if peer := runPeer(filepath.Base(n)); peer != "" {
			return peer
		}
	}
	return ""
}

// planAppliesTo reports whether the plan covers this call; numbers stay in memory only.
func planAppliesTo(p uplinkTestPlan, root, run string) bool {
	if !p.valid {
		return false
	}
	if p.matchPrefix == "" {
		return true
	}
	peer := runPeer(run)
	return peer != "" && peer == referencePeer(root, p.matchPrefix)
}

type uplinkTestAudio struct {
	b   []byte
	pos int
}

func loadUplinkTestAudio(path string) (*uplinkTestAudio, error) {
	f, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if f.Size() > uplinkTestAudioMax {
		return nil, errors.New("test audio too large")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	b = b[:len(b)/320*320]
	if len(b) == 0 {
		return nil, errors.New("test audio empty")
	}
	return &uplinkTestAudio{b: b}, nil
}

// next returns the following 20 ms frame, wrapping at the end.
func (a *uplinkTestAudio) next() []byte {
	if a.pos >= len(a.b) {
		a.pos = 0
	}
	f := a.b[a.pos : a.pos+320]
	a.pos += 320
	return f
}

func (a *uplinkTestAudio) seconds() float64 { return float64(len(a.b)) / 16000 }

// uplinkTest loads the plan for this call: breaks, and test audio (nil if none).
func uplinkTest(run string) ([]uplinkGap, *uplinkTestAudio) {
	b, err := os.ReadFile(uplinkGapFile)
	if err != nil {
		return nil, nil
	}
	p := parseUplinkTestPlan(string(b))
	if !p.valid {
		return nil, nil
	}
	if !planAppliesTo(p, recordRoot, run) {
		log.Print("上行测试: 号码不匹配或找不到参照通话，本通不启用")
		return nil, nil
	}
	audio, err := loadUplinkTestAudio(uplinkTestAudioFile)
	if err != nil && !os.IsNotExist(err) {
		log.Print("上行测试音频无效，本通不替换麦克风")
	}
	return p.gaps, audio
}

func parseUplinkGapPlan(s string) []uplinkGap {
	var plan []uplinkGap
	for _, part := range strings.Split(strings.TrimSpace(s), ",") {
		f := strings.Split(strings.TrimSpace(part), ":")
		if len(f) != 2 {
			return nil
		}
		at, e1 := strconv.Atoi(f[0])
		hold, e2 := strconv.Atoi(f[1])
		if e1 != nil || e2 != nil || at < 5 || at > 3600 || hold < 5 || hold > 1000 {
			return nil
		}
		plan = append(plan, uplinkGap{time.Duration(at) * time.Second, time.Duration(hold) * time.Millisecond})
	}
	if len(plan) > 64 {
		return nil
	}
	sort.Slice(plan, func(i, j int) bool { return plan[i].at < plan[j].at })
	return plan
}

var underrunLength = regexp.MustCompile(`at least ([0-9]+(?:\.[0-9]+)?) ms`)

// underrunMS extracts aplay's "underrun!!! (at least X ms long)" length.
func underrunMS(line string) string {
	if m := underrunLength.FindStringSubmatch(line); m != nil {
		return m[1]
	}
	return ""
}
