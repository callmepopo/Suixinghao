package main

import (
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// In-call radio quality of the module: read-only queries, sampled by the existing
// controller worker (same serial path, lock held) at most once per callSignalPeriod.
// It explains "the other side hears stutter" moments that never show in our audio.
const callSignalPeriod = 10 * time.Second

var qcsqPattern = regexp.MustCompile(`\+QCSQ:\s*"([A-Z0-9-]+)"((?:,\s*-?\d+)*)`)

type callSignalView struct {
	RAT  string `json:"rat,omitempty"`
	RSSI *int   `json:"rssi,omitempty"`
	RSRP *int   `json:"rsrp,omitempty"`
	SINR *int   `json:"sinr,omitempty"`
	RSRQ *int   `json:"rsrq,omitempty"`
	CSQ  *int   `json:"csq,omitempty"`
	At   string `json:"at"`
}

var callSignal = struct {
	sync.Mutex
	view      *callSignalView
	next      time.Time
	noQCSQ    bool
	samples   uint64
	failures  uint64
	worstRSRP *int
	worstSINR *int
}{}

func resetCallSignal(now time.Time) {
	callSignal.Lock()
	defer callSignal.Unlock()
	callSignal.view, callSignal.worstRSRP, callSignal.worstSINR = nil, nil, nil
	callSignal.samples, callSignal.failures = 0, 0
	callSignal.next = now.Add(3 * time.Second)
}

func intPtr(n int) *int { return &n }

func parseQCSQ(s string) *callSignalView {
	m := qcsqPattern.FindStringSubmatch(s)
	if len(m) < 2 || m[1] == "NOSERVICE" {
		if len(m) >= 2 {
			return &callSignalView{RAT: "NOSERVICE"}
		}
		return nil
	}
	var values []int
	for _, part := range strings.Split(strings.TrimPrefix(m[2], ","), ",") {
		if n, err := strconv.Atoi(strings.TrimSpace(part)); err == nil {
			values = append(values, n)
		}
	}
	v := &callSignalView{RAT: m[1]}
	if len(values) > 0 {
		v.RSSI = intPtr(values[0])
	}
	if m[1] == "LTE" && len(values) >= 4 {
		// +QCSQ: "LTE",<rssi>,<rsrp>,<sinr>,<rsrq>; SINR is reported in 1/5 dB steps minus 20.
		v.RSRP, v.SINR, v.RSRQ = intPtr(values[1]), intPtr(values[2]/5-20), intPtr(values[3])
	}
	return v
}

// Called by the controller with its lock held while a call has media.
func sampleCallSignal(now time.Time) {
	callSignal.Lock()
	due := !callSignal.next.IsZero() && !now.Before(callSignal.next)
	noQCSQ := callSignal.noQCSQ
	if due {
		callSignal.next = now.Add(callSignalPeriod)
	}
	callSignal.Unlock()
	if !due {
		return
	}
	var view *callSignalView
	if !noQCSQ {
		if s, err := phoneAT("", "AT+QCSQ"); err == nil {
			view = parseQCSQ(s)
		}
		if view == nil {
			callSignal.Lock()
			callSignal.noQCSQ = true
			callSignal.Unlock()
		}
	}
	if view == nil {
		if s, err := phoneAT("", "AT+CSQ"); err == nil {
			if m := signalPattern.FindStringSubmatch(s); len(m) > 1 {
				if n, _ := strconv.Atoi(m[1]); n >= 0 && n <= 31 || n == 99 {
					view = &callSignalView{CSQ: intPtr(n)}
				}
			}
		}
	}
	callSignal.Lock()
	defer callSignal.Unlock()
	if view == nil {
		callSignal.failures++
		return
	}
	view.At = now.UTC().Format(time.RFC3339)
	callSignal.view = view
	callSignal.samples++
	if view.RSRP != nil && (callSignal.worstRSRP == nil || *view.RSRP < *callSignal.worstRSRP) {
		callSignal.worstRSRP = intPtr(*view.RSRP)
	}
	if view.SINR != nil && (callSignal.worstSINR == nil || *view.SINR < *callSignal.worstSINR) {
		callSignal.worstSINR = intPtr(*view.SINR)
	}
}

func callSignalSummary() map[string]any {
	callSignal.Lock()
	defer callSignal.Unlock()
	v := map[string]any{"samples": callSignal.samples, "failures": callSignal.failures}
	if callSignal.view != nil {
		v["latest"] = *callSignal.view
	}
	if callSignal.worstRSRP != nil {
		v["worst_rsrp"] = *callSignal.worstRSRP
	}
	if callSignal.worstSINR != nil {
		v["worst_sinr"] = *callSignal.worstSINR
	}
	return v
}
