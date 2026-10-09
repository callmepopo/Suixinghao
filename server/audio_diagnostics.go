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
}
func (s *audioStats) arrival(run string, dropped bool, depth int) {
	if run == "" {
		return
	}
	now := time.Now()
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
	}
	s.lastUp = now
	if dropped {
		s.dropped++
	}
	if uint64(depth) > s.queuePeak {
		s.queuePeak = uint64(depth)
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
}

// Optional text metadata is whitelisted. Invalid metadata never tears down audio.
func (s *audioStats) acceptClient(b []byte, now time.Time) bool {
	if len(b) > 2048 {
		return false
	}
	var raw map[string]json.RawMessage
	if json.Unmarshal(b, &raw) != nil {
		return false
	}
	var kind, segment string
	var version, elapsed uint64
	if json.Unmarshal(raw["type"], &kind) != nil || kind != "audio_stats" || json.Unmarshal(raw["version"], &version) != nil || version != 1 ||
		json.Unmarshal(raw["segment"], &segment) != nil || !audioSegment.MatchString(segment) || json.Unmarshal(raw["elapsed_ms"], &elapsed) != nil || elapsed > 86400000 {
		return false
	}
	value := map[string]any{"type": kind, "version": version, "segment": segment, "elapsed_ms": elapsed}
	for name, encoded := range raw {
		if name == "type" || name == "version" || name == "segment" || name == "elapsed_ms" {
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
		kind = "underrun"
	}
	if strings.Contains(line, "overrun") {
		w.stats.overruns++
		now := time.Now()
		if w.stats.firstOverrun.IsZero() {
			w.stats.firstOverrun = now
		}
		w.stats.lastOverrun = now
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
