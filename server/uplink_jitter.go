package main

import "sync"

// uplinkJitter paces phone PCM into the module. The caller writes one 20 ms frame
// per next() into a small blocking ALSA buffer, so the device clock sets the pace.
// Late frames are covered by a short fade then silence (the module never
// underruns), and the queue is kept near an adaptive target so latency cannot
// accumulate after network bursts.
type uplinkJitter struct {
	mu        sync.Mutex
	queue     [][]byte
	playing   bool
	target    int // frames buffered before (re)starting playout
	stable    int // frames played since the last underflow
	last      []byte
	concealed bool

	// Counters since begin; read by audioStats.
	concealedFrames, trimmedFrames, overflowFrames, rebuffers, depthPeak uint64
}

const (
	jitterFrameBytes = 320
	jitterMinTarget  = 3   // 60 ms
	jitterMaxTarget  = 8   // 160 ms
	jitterExcess     = 3   // frames above target before trimming quiet frames
	jitterHardMax    = 15  // 300 ms: oldest frames are discarded beyond this
	jitterRelaxAfter = 500 // 10 s without underflow lowers the target by one frame
	jitterQuietPeak  = 328 // about -40 dBFS: safe to drop while catching up
)

func newUplinkJitter() *uplinkJitter { return &uplinkJitter{target: jitterMinTarget} }

func (j *uplinkJitter) push(b []byte) {
	if len(b) != jitterFrameBytes {
		return
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	j.queue = append(j.queue, b)
	for len(j.queue) > jitterHardMax {
		j.queue = j.queue[1:]
		j.overflowFrames++
	}
	if d := uint64(len(j.queue)); d > j.depthPeak {
		j.depthPeak = d
	}
}

// next returns the frame to write now and whether it carries phone audio.
func (j *uplinkJitter) next() ([]byte, bool) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if !j.playing {
		if len(j.queue) < j.target {
			return j.fill(), false
		}
		j.playing = true
	}
	if len(j.queue) == 0 {
		// Underflow: rebuffer to a larger target so the next burst is absorbed.
		j.playing = false
		j.rebuffers++
		j.stable = 0
		j.target = min(j.target+1, jitterMaxTarget)
		return j.fill(), false
	}
	// Catch up after a burst: drop quiet frames first, never more than needed.
	for len(j.queue) > j.target+jitterExcess && (quietFrame(j.queue[0]) || len(j.queue) > jitterMaxTarget+jitterExcess) {
		j.queue = j.queue[1:]
		j.trimmedFrames++
	}
	b := j.queue[0]
	j.queue = j.queue[1:]
	if j.stable++; j.stable >= jitterRelaxAfter && j.target > jitterMinTarget {
		j.target--
		j.stable = 0
	}
	if j.concealed {
		b = ramp(b, true)
		j.concealed = false
	}
	j.last = b
	return b, true
}

// fill fades the previous frame out once, then writes silence.
func (j *uplinkJitter) fill() []byte {
	j.concealedFrames++
	if j.last != nil && !j.concealed {
		j.concealed = true
		return ramp(j.last, false)
	}
	j.concealed = j.last != nil
	return make([]byte, jitterFrameBytes)
}

func (j *uplinkJitter) view() map[string]uint64 {
	j.mu.Lock()
	defer j.mu.Unlock()
	return map[string]uint64{"depth_frames": uint64(len(j.queue)), "depth_peak_frames": j.depthPeak, "target_frames": uint64(j.target),
		"concealed_frames": j.concealedFrames, "trimmed_frames": j.trimmedFrames, "overflow_frames": j.overflowFrames, "rebuffers": j.rebuffers}
}

func quietFrame(b []byte) bool {
	for i := 0; i+1 < len(b); i += 2 {
		v := int(int16(uint16(b[i]) | uint16(b[i+1])<<8))
		if v > jitterQuietPeak || v < -jitterQuietPeak {
			return false
		}
	}
	return true
}

// ramp returns a linearly faded copy (in=true fades in, otherwise out).
func ramp(b []byte, in bool) []byte {
	out := make([]byte, len(b))
	n := len(b) / 2
	for i := 0; i < n; i++ {
		g := float64(i) / float64(n)
		if !in {
			g = 1 - g
		}
		v := int16(float64(int16(uint16(b[2*i])|uint16(b[2*i+1])<<8)) * g)
		out[2*i], out[2*i+1] = byte(uint16(v)), byte(uint16(v)>>8)
	}
	return out
}
