package main

import (
	"bytes"
	"encoding/json"
	"log"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Each instance belongs to one authenticated socket; run never appears in logs.
type audioStats struct {
	sync.Mutex
	run                                                    string
	segment                                                int
	started, lastUp, lastClient                            time.Time
	up, down, written, dropped, queuePeak, intervalMaxUS   uint64
	underruns, overruns, stderrLines                       uint64
	client                                                 map[string]any
	startupDiscarded                                       uint64
	firstUnderrun, lastUnderrun, firstOverrun, lastOverrun time.Time
	socketFrames, recordedFrames                           uint64
	trace                                                  string
	events                                                 []audioEvent
	eventsOmitted                                          uint64
	writeMaxUS                                             uint64
	queueDepth                                             uint64
}

type audioEvent struct {
	Kind      string `json:"kind"`
	ElapsedMS uint64 `json:"elapsed_ms"`
	Frame     uint64 `json:"frame"`
	Value     uint64 `json:"value"`
	At        string `json:"at,omitempty"`
}

func (s *audioStats) receivedFrame() { s.Lock(); s.socketFrames++; s.Unlock() }
func (s *audioStats) eventLocked(kind string, value uint64, now time.Time) {
	if len(s.events) >= 32 {
		s.eventsOmitted++
		return
	}
	s.events = append(s.events, audioEvent{Kind: kind, ElapsedMS: uint64(max(int64(0), now.Sub(s.started).Milliseconds())), Frame: s.socketFrames, Value: value, At: now.UTC().Format(time.RFC3339Nano)})
}

func (s *audioStats) begin(run string) {
	s.Lock()
	defer s.Unlock()
	if s.run == run {
		return
	}
	s.run = run
	s.segment++
	s.started = time.Now()
	s.lastUp = time.Time{}
	s.up = 0
	s.down = 0
	s.written = 0
	s.dropped = 0
	s.queuePeak = 0
	s.intervalMaxUS = 0
	s.underruns = 0
	s.overruns = 0
	s.stderrLines = 0
	s.client = nil
	s.startupDiscarded = 0
	s.firstUnderrun = time.Time{}
	s.lastUnderrun = time.Time{}
	s.firstOverrun = time.Time{}
	s.lastOverrun = time.Time{}
	if s.trace == "" {
		s.trace = randomHistoryID()
	}
	s.recordedFrames = 0
	s.writeMaxUS = 0
	s.queueDepth = 0
	s.events = nil
	s.eventsOmitted = 0
}
func (s *audioStats) arrival(run string, dropped bool, depth int) {
	if run == "" {
		return
	}
	s.arrivalAt(run, dropped, depth, time.Now())
}
func (s *audioStats) arrivalAt(run string, dropped bool, depth int, now time.Time) {
	s.Lock()
	defer s.Unlock()
	if s.run != run {
		return
	}
	s.up++
	if !s.lastUp.IsZero() {
		if n := uint64(now.Sub(s.lastUp).Microseconds()); n > s.intervalMaxUS {
			s.intervalMaxUS = n
		}
		if gap := now.Sub(s.lastUp).Microseconds(); gap >= 60000 {
			s.eventLocked("receive_gap", uint64(gap), now)
		}
	}
	s.lastUp = now
	s.queueDepth = uint64(depth)
	if dropped {
		s.dropped++
		s.eventLocked("receive_drop", uint64(depth), now)
	}
	if uint64(depth) > s.queuePeak {
		s.queuePeak = uint64(depth)
	}
}

// Called after writing to the existing module pipe; it never changes PCM or pacing.
func (s *audioStats) moduleWrite(active bool, duration time.Duration) {
	s.Lock()
	defer s.Unlock()
	if active {
		s.recordedFrames++
	}
	us := uint64(max(int64(0), duration.Microseconds()))
	if us > s.writeMaxUS {
		s.writeMaxUS = us
	}
	if us >= 40000 {
		s.eventLocked("module_write_slow", us, time.Now())
	}
}
func (s *audioStats) discardStartup() { s.Lock(); s.startupDiscarded++; s.Unlock() }
func (s *audioStats) output(up bool) {
	s.Lock()
	defer s.Unlock()
	if up {
		s.written++
	} else {
		s.down++
	}
}
func (s *audioStats) summary(final bool) {
	s.Lock()
	if s.started.IsZero() {
		s.Unlock()
		return
	}
	v := map[string]any{"segment": s.segment, "elapsed_ms": time.Since(s.started).Milliseconds(), "up_received": s.up, "up_written": s.written,
		"down_read": s.down, "up_dropped": s.dropped, "queue_peak_frames": s.queuePeak, "up_interval_max_us": s.intervalMaxUS,
		"underruns": s.underruns, "overruns": s.overruns, "stderr_lines": s.stderrLines, "final": final}
	v["up_startup_discarded"] = s.startupDiscarded
	v["trace"] = s.trace
	v["socket_received_frames"] = s.socketFrames
	v["recorded_up_ms"] = s.recordedFrames * 20
	v["module_write_max_us"] = s.writeMaxUS
	v["receive_queue_ms"] = s.queueDepth * 20
	v["events"] = append([]audioEvent(nil), s.events...)
	v["events_omitted"] = s.eventsOmitted
	s.events = nil
	for name, at := range map[string]time.Time{"underrun_first_at": s.firstUnderrun, "underrun_last_at": s.lastUnderrun, "overrun_first_at": s.firstOverrun, "overrun_last_at": s.lastOverrun} {
		if !at.IsZero() {
			v[name] = at.UTC().Format(time.RFC3339Nano)
		}
	}
	if s.client != nil {
		v["phone"] = s.client
		v["phone_received_at"] = s.lastClient.UTC().Format(time.RFC3339Nano)
	}
	s.Unlock()
	b, err := json.Marshal(v)
	if err == nil {
		log.Printf("音频诊断 %s", b)
	}
}

var audioSegment = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)
var audioCounterNames = map[string]bool{
	"sent_frames": true, "send_us_total": true, "send_us_max": true, "interval_us_total": true, "interval_count": true, "interval_us_max": true,
	"missed_slots": true, "captured_samples": true, "capture_queue_peak_samples": true, "capture_dropped_samples": true,
	"waiting_silence_frames": true, "muted_silence_frames": true, "capture_underfill_frames": true,
	"down_received_frames": true, "down_inactive_frames": true, "down_dropped_frames": true, "down_played_frames": true, "playback_queue_peak_frames": true,
	"events_omitted": true,
}

// Optional text metadata is whitelisted. Invalid metadata never tears down audio.
func (s *audioStats) acceptClient(b []byte, now time.Time) bool {
	if len(b) > 8192 {
		return false
	}
	var raw map[string]json.RawMessage
	if json.Unmarshal(b, &raw) != nil {
		return false
	}
	var kind, segment string
	var version, elapsed uint64
	if json.Unmarshal(raw["type"], &kind) != nil || kind != "audio_stats" || json.Unmarshal(raw["version"], &version) != nil ||
		json.Unmarshal(raw["segment"], &segment) != nil || !audioSegment.MatchString(segment) || json.Unmarshal(raw["elapsed_ms"], &elapsed) != nil || elapsed > 86400000 {
		return false
	}
	if version != 1 && version != 2 || version == 1 && len(b) > 2048 {
		return false
	}
	value := map[string]any{"type": kind, "version": version, "segment": segment, "elapsed_ms": elapsed}
	for name, encoded := range raw {
		if name == "type" || name == "version" || name == "segment" || name == "elapsed_ms" {
			continue
		}
		if version == 2 && name == "events" {
			var events []audioEvent
			dec := json.NewDecoder(bytes.NewReader(encoded))
			dec.DisallowUnknownFields()
			if dec.Decode(&events) != nil || len(events) > 16 {
				return false
			}
			for _, e := range events {
				if !map[string]bool{"send_gap": true, "send_slow": true, "capture_drop": true, "capture_underfill": true}[e.Kind] || e.At != "" || e.ElapsedMS > elapsed || e.Frame > 1000000000000 || e.Value > 1000000000000 {
					return false
				}
			}
			value[name] = events
			continue
		}
		if version == 2 && name == "level" {
			var level map[string]uint64
			if json.Unmarshal(encoded, &level) != nil || len(level) != 5 {
				return false
			}
			for _, k := range []string{"samples", "rms", "peak", "quiet_samples", "clipped_samples"} {
				if _, ok := level[k]; !ok {
					return false
				}
			}
			if level["samples"] > 1000000000000 || level["rms"] > 32768 || level["peak"] > 32768 || level["quiet_samples"] > level["samples"] || level["clipped_samples"] > level["samples"] {
				return false
			}
			value[name] = level
			continue
		}
		if !audioCounterNames[name] {
			return false
		}
		var number uint64
		if json.Unmarshal(encoded, &number) != nil || number > 1000000000000 {
			return false
		}
		value[name] = number
	}
	s.Lock()
	defer s.Unlock()
	if !s.lastClient.IsZero() && now.Sub(s.lastClient) < 4*time.Second {
		return false
	}
	s.lastClient = now
	s.client = value
	if version == 2 && !s.started.IsZero() {
		anchor := map[string]any{"trace": s.trace, "segment": s.segment, "server_at": now.UTC().Format(time.RFC3339Nano), "server_elapsed_ms": max(int64(0), now.Sub(s.started).Milliseconds()), "socket_received_frames": s.socketFrames, "up_written": s.written, "recorded_up_ms": s.recordedFrames * 20, "phone": value}
		data, _ := json.Marshal(anchor)
		log.Printf("音频关联 %s", data)
	}
	return true
}

// Continuous stderr drain with bounded memory and rate-limited, sanitized events.
type audioStderr struct {
	mu         sync.Mutex
	stats      *audioStats
	device     string
	pending    []byte
	last       time.Time
	unreported uint64
}

func (w *audioStderr) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	n := len(p)
	for len(p) > 0 {
		i := bytes.IndexByte(p, '\n')
		end := len(p)
		if i >= 0 {
			end = i
		}
		room := 1024 - len(w.pending)
		if room > end {
			room = end
		}
		w.pending = append(w.pending, p[:room]...)
		if i < 0 {
			break
		}
		w.line(string(w.pending))
		w.pending = w.pending[:0]
		p = p[i+1:]
	}
	return n, nil
}
func (w *audioStderr) line(line string) {
	line = strings.ToLower(line)
	w.stats.Lock()
	w.stats.stderrLines++
	kind := "audio_process_error"
	if strings.Contains(line, "underrun") {
		w.stats.underruns++
		now := time.Now()
		if w.stats.firstUnderrun.IsZero() {
			w.stats.firstUnderrun = now
		}
		w.stats.lastUnderrun = now
		w.stats.eventLocked("module_underrun", 1, now)
		kind = "underrun"
	}
	if strings.Contains(line, "overrun") {
		w.stats.overruns++
		now := time.Now()
		if w.stats.firstOverrun.IsZero() {
			w.stats.firstOverrun = now
		}
		w.stats.lastOverrun = now
		w.stats.eventLocked("module_overrun", 1, now)
		kind = "overrun"
	}
	segment := w.stats.segment
	w.stats.Unlock()
	w.unreported++
	if w.last.IsZero() || time.Since(w.last) >= 5*time.Second {
		log.Printf("音频进程事件 segment=%d device=%s kind=%s events_since_log=%d", segment, w.device, kind, w.unreported)
		w.last = time.Now()
		w.unreported = 0
	}
}
func (w *audioStderr) finish() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.pending) > 0 {
		w.line(string(w.pending))
		w.pending = nil
	}
}
