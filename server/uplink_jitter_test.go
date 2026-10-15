package main

import (
	"encoding/binary"
	"math/rand"
	"testing"
)

// frame builds a 20 ms PCM frame carrying its sequence number and a level.
func jitterFrame(seq int, level int16) []byte {
	b := make([]byte, jitterFrameBytes)
	for i := 0; i < len(b); i += 2 {
		binary.LittleEndian.PutUint16(b[i:], uint16(level))
	}
	binary.LittleEndian.PutUint16(b[0:], uint16(seq))
	return b
}

type jitterRun struct {
	maxLatency, latencySum, played, concealed int
}

// simulate delivers frame seq at arrive[seq] (in 20 ms ticks) and pulls one
// frame per tick, as the blocking device write does.
func simulate(t *testing.T, arrive []int, level int16) jitterRun {
	t.Helper()
	j := newUplinkJitter()
	var r jitterRun
	next := 0
	for tick := 0; tick < arrive[len(arrive)-1]+60; tick++ {
		for next < len(arrive) && arrive[next] <= tick {
			j.push(jitterFrame(next, level))
			next++
		}
		_, real := j.next()
		if !real {
			r.concealed++
			continue
		}
		// FIFO with head-only trimming: the frame played is the one just before
		// the new head (faded frames cannot carry the sequence number).
		seq := next - 1
		if len(j.queue) > 0 {
			seq = int(binary.LittleEndian.Uint16(j.queue[0][0:])) - 1
		}
		latency := tick - seq
		r.played++
		r.latencySum += latency
		r.maxLatency = max(r.maxLatency, latency)
	}
	return r
}

func TestJitterSteadyWifiKeepsSmallDelay(t *testing.T) {
	arrive := make([]int, 3000)
	for i := range arrive {
		arrive[i] = i
	}
	r := simulate(t, arrive, 3000)
	if r.played != 3000 || r.maxLatency > jitterMinTarget {
		t.Fatalf("steady stream: played %d max latency %d frames", r.played, r.maxLatency)
	}
}

// Cellular as measured on the road: frames delivered in ~120 ms batches, plus
// stalls of 0.4, 0.9 and 1.7 s whose frames all arrive at once afterwards.
func TestJitterCellularBurstsBoundLatency(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	arrive := make([]int, 30000) // 10 minutes
	for i := range arrive {
		arrive[i] = (i/6)*6 + 6 + rng.Intn(2)
	}
	for _, stall := range []struct{ at, ticks int }{{3000, 20}, {9000, 45}, {15000, 87}} {
		for i := stall.at; i < stall.at+stall.ticks; i++ {
			arrive[i] = stall.at + stall.ticks
		}
	}
	for i := 1; i < len(arrive); i++ {
		arrive[i] = max(arrive[i], arrive[i-1])
	}
	r := simulate(t, arrive, 3000)
	avg := float64(r.latencySum) / float64(r.played)
	// The old path started aplay only after 500 ms buffered (25 frames).
	if avg*20 > 220 || r.maxLatency*20 > 400 {
		t.Fatalf("latency avg %.0f ms max %d ms", avg*20, r.maxLatency*20)
	}
	if lost := len(arrive) - r.played; lost > 200 {
		t.Fatalf("too many frames dropped to catch up: %d", lost)
	}
	t.Logf("avg %.0f ms, max %d ms, played %d/%d, concealed %d", avg*20, r.maxLatency*20, r.played, len(arrive), r.concealed)
}

func TestJitterQuietFramesTrimmedFirst(t *testing.T) {
	j := newUplinkJitter()
	for i := 0; i < 12; i++ {
		j.push(jitterFrame(i, 10))
	}
	j.next()
	if v := j.view(); v["depth_frames"] > uint64(j.target+jitterExcess) || v["trimmed_frames"] == 0 {
		t.Fatalf("quiet backlog not trimmed: %v", v)
	}
}

func TestJitterConcealFadesOutThenSilence(t *testing.T) {
	j := newUplinkJitter()
	for i := 0; i < jitterMinTarget; i++ {
		j.push(jitterFrame(i, 8000))
	}
	for i := 0; i < jitterMinTarget; i++ {
		j.next()
	}
	fade, real := j.next()
	if real || int16(binary.LittleEndian.Uint16(fade[2:])) < 7000 || int16(binary.LittleEndian.Uint16(fade[len(fade)-2:])) > 100 {
		t.Fatal("first concealed frame must fade the last frame out")
	}
	silence, _ := j.next()
	if !quietFrame(silence) || silence[2] != 0 {
		t.Fatal("later concealment must be silence")
	}
	if j.view()["target_frames"] != jitterMinTarget+1 {
		t.Fatal("underflow must raise the target")
	}
}

// Negative control: the previous path wrote frames straight into aplay's default
// 500 ms buffer, which starts (and restarts after an underrun) only when full.
func TestJitterOldAplayDefaultAddsHalfSecond(t *testing.T) {
	arrive := make([]int, 30000)
	for i := range arrive {
		arrive[i] = (i/6)*6 + 6
	}
	const start = 25 // 4000 samples at 8 kHz
	buffered, latencySum, played, next, running := []int{}, 0, 0, 0, false
	for tick := 0; tick < arrive[len(arrive)-1]+60; tick++ {
		for next < len(arrive) && arrive[next] <= tick {
			if len(buffered) < start {
				buffered = append(buffered, next)
			}
			next++
		}
		if !running && len(buffered) >= start {
			running = true
		}
		if running {
			if len(buffered) == 0 {
				running = false
				continue
			}
			latencySum += tick - buffered[0]
			played++
			buffered = buffered[1:]
		}
	}
	old := float64(latencySum) / float64(played) * 20
	if old < 450 {
		t.Fatalf("old model latency %.0f ms; expected about 500 ms", old)
	}
	t.Logf("old aplay default: avg %.0f ms", old)
}
