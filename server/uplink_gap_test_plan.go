package main

import (
	"os"
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
type uplinkGap struct{ at, hold time.Duration }

var uplinkGapFile = dataPath("uplink-gap-test")

func uplinkGapPlan() []uplinkGap {
	b, err := os.ReadFile(uplinkGapFile)
	if err != nil {
		return nil
	}
	return parseUplinkGapPlan(string(b))
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
