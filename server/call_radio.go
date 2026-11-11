package main

import (
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// In-call LTE serving-cell series. The other side periodically loses several
// seconds of our voice while everything up to the module's PCM port is clean,
// so each audio summary carries what the modem reported in between (connection
// state, uplink TX power, CQI, quality), sampled read-only every callRadioPeriod
// by the controller worker. Cell ID and TAC are never kept.
const (
	callRadioPeriod = 2 * time.Second
	callRadioKeep   = 8 // samples per summary window (5 s) with headroom
)

var qengServingPattern = regexp.MustCompile(`\+QENG:\s*"servingcell","([A-Z]+)"(?:,"([A-Z-]+)")?(.*)`)

// callRadioSample holds one +QENG="servingcell" reading. LTE fields follow the
// module's order after <TAC>: RSRP, RSRQ, RSSI, SINR, then CQI and TX power
// (CONNECT only) and srxlev. Values the modem leaves empty or "-" are omitted.
type callRadioSample struct {
	At      string `json:"at"`
	State   string `json:"state"`
	RAT     string `json:"rat,omitempty"`
	Duplex  string `json:"duplex,omitempty"`
	PCI     *int   `json:"pci,omitempty"`
	EARFCN  *int   `json:"earfcn,omitempty"`
	RSRP    *int   `json:"rsrp,omitempty"`
	RSRQ    *int   `json:"rsrq,omitempty"`
	RSSI    *int   `json:"rssi,omitempty"`
	SINR    *int   `json:"sinr,omitempty"`
	CQI     *int   `json:"cqi,omitempty"`
	TXPower *int   `json:"tx_power,omitempty"`
	SRxLev  *int   `json:"srxlev,omitempty"`
}

var callRadio = struct {
	sync.Mutex
	next             time.Time
	recent           []callRadioSample
	samples, failure uint64
	states           map[string]uint64
	disabled         bool
}{}

func resetCallRadio(now time.Time) {
	callRadio.Lock()
	defer callRadio.Unlock()
	callRadio.next = now.Add(3 * time.Second)
	callRadio.recent, callRadio.samples, callRadio.failure = nil, 0, 0
	callRadio.states = map[string]uint64{}
	callRadio.disabled = false
}

func optionalInt(s string) *int {
	s = strings.Trim(strings.TrimSpace(s), `"`)
	if n, err := strconv.Atoi(s); err == nil {
		return &n
	}
	return nil
}

func parseServingCell(s string) *callRadioSample {
	m := qengServingPattern.FindStringSubmatch(s)
	if m == nil {
		return nil
	}
	v := &callRadioSample{State: m[1], RAT: m[2]}
	rest := m[3]
	if i := strings.IndexAny(rest, "\r\n"); i >= 0 {
		rest = rest[:i]
	}
	if v.RAT != "LTE" {
		return v
	}
	f := strings.Split(strings.TrimPrefix(rest, ","), ",")
	// <is_tdd>,<MCC>,<MNC>,<cellID>,<PCID>,<earfcn>,<band>,<UL_bw>,<DL_bw>,<TAC>,<RSRP>,...
	if len(f) < 14 {
		return v
	}
	v.Duplex = strings.Trim(f[0], `"`)
	v.PCI, v.EARFCN = optionalInt(f[4]), optionalInt(f[5])
	tail := f[10:]
	v.RSRP, v.RSRQ, v.RSSI, v.SINR = optionalInt(tail[0]), optionalInt(tail[1]), optionalInt(tail[2]), optionalInt(tail[3])
	switch len(tail) {
	case 5:
		v.SRxLev = optionalInt(tail[4])
	case 6:
		v.CQI, v.TXPower = optionalInt(tail[4]), optionalInt(tail[5])
	default:
		if len(tail) >= 7 {
			v.CQI, v.TXPower, v.SRxLev = optionalInt(tail[4]), optionalInt(tail[5]), optionalInt(tail[6])
		}
	}
	return v
}

// Called by the controller with its lock held while a call has media.
func sampleCallRadio(now time.Time) {
	callRadio.Lock()
	due := !callRadio.disabled && !callRadio.next.IsZero() && !now.Before(callRadio.next)
	if due {
		callRadio.next = now.Add(callRadioPeriod)
	}
	callRadio.Unlock()
	if !due {
		return
	}
	s, err := phoneAT("", `AT+QENG="servingcell"`)
	var v *callRadioSample
	if err == nil {
		v = parseServingCell(s)
	}
	callRadio.Lock()
	defer callRadio.Unlock()
	if v == nil {
		// Stop for this call after repeated failures: no point filling AT logs.
		if callRadio.failure++; callRadio.failure >= 3 && callRadio.samples == 0 {
			callRadio.disabled = true
		}
		return
	}
	v.At = now.UTC().Format("2006-01-02T15:04:05.0Z")
	callRadio.samples++
	callRadio.states[v.State]++
	callRadio.recent = append(callRadio.recent, *v)
	if len(callRadio.recent) > callRadioKeep {
		callRadio.recent = callRadio.recent[len(callRadio.recent)-callRadioKeep:]
	}
}

// callRadioSummary returns the samples since the previous summary and clears them.
func callRadioSummary() map[string]any {
	callRadio.Lock()
	defer callRadio.Unlock()
	states := map[string]uint64{}
	for k, n := range callRadio.states {
		states[k] = n
	}
	v := map[string]any{"samples": callRadio.samples, "failures": callRadio.failure, "states": states, "series": callRadio.recent}
	callRadio.recent = nil
	return v
}
