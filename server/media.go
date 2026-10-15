package main

import (
	"context"
	"errors"
	"github.com/gorilla/websocket"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

var callFlag = dataPath("call.active")

func activeRun() string {
	f, e := os.Stat(callFlag)
	if e != nil || time.Since(f.ModTime()) > 120*time.Second {
		return ""
	}
	b, e := os.ReadFile(callFlag)
	s := strings.TrimSpace(string(b))
	if e != nil || !safeRun.MatchString(s) {
		return ""
	}
	return s
}
func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// Recheck on delivery: queued frames must not survive the active -> idle boundary.
func uplinkAllowed(view phoneView, run, current string) bool {
	return run != "" && run == current && view.Available && view.Media && view.State == "active"
}

func runAudio(parent context.Context, c *websocket.Conn, mic <-chan []byte, run string, rec *pair, stats *audioStats) error {
	var recordingMu sync.Mutex
	recordingAttempted := rec != nil
	ownsRecording := false
	writeRecording := func(upstream bool, b []byte) {
		recordingMu.Lock()
		defer recordingMu.Unlock()
		// Never record pre-answer media. Capture starts on the first active frame.
		if !uplinkAllowed(phone.snapshot(), run, activeRun()) {
			return
		}
		if !recordingAttempted {
			recordingAttempted = true
			if recordingEnabled() {
				info := currentCallInfo()
				if info.Run != run {
					return
				}
				var err error
				rec, err = newPair(recordRoot, info)
				ownsRecording = rec != nil
				if err != nil {
					log.Print("录音未启动：文件创建失败")
				}
			}
		}
		if upstream {
			rec.writeUp(b)
		} else {
			rec.writeDown(b)
		}
	}
	defer func() {
		if ownsRecording {
			rec.close()
		}
	}()
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	// ALSA defaults were a 500 ms playback buffer that only starts when full and
	// 125 ms capture periods. Use 20 ms periods: playback keeps 80 ms in the
	// device (starting at 40 ms) and the uplink jitter buffer absorbs the network;
	// capture keeps 500 ms of headroom, which adds no delay.
	device := envOrDefault("VOICE_WEB_AUDIO_DEVICE", "hw:CARD=Baiwang,DEV=0")
	cap := exec.CommandContext(ctx, "arecord", "-q", "-D", device, "-t", "raw", "-f", "S16_LE", "-r", "8000", "-c", "1", "--period-time=20000", "--buffer-time=500000")
	play := exec.CommandContext(ctx, "aplay", "-q", "-D", device, "-t", "raw", "-f", "S16_LE", "-r", "8000", "-c", "1", "--period-time=20000", "--buffer-time=80000", "--start-delay=40000")
	cap.WaitDelay = 2 * time.Second
	play.WaitDelay = 2 * time.Second
	out, e := cap.StdoutPipe()
	if e != nil {
		return e
	}
	in, e := play.StdinPipe()
	if e != nil {
		return e
	}
	capErr := &audioStderr{stats: stats, device: "capture"}
	playErr := &audioStderr{stats: stats, device: "playback"}
	cap.Stderr = capErr
	play.Stderr = playErr
	defer capErr.finish()
	defer playErr.finish()
	if e = cap.Start(); e != nil {
		return e
	}
	defer cap.Wait()
	if e = play.Start(); e != nil {
		cancel()
		return e
	}
	defer play.Wait()
	defer cancel()
	down := make(chan struct{})
	up := make(chan struct{})
	go func() {
		defer close(down)
		defer cancel()

		var total int
		b := make([]byte, 320)
		for {
			if _, e := io.ReadFull(out, b); e != nil {
				log.Printf("下行结束: arecord 读到 %d 字节后退出: %v", total, e)
				return
			}
			total += len(b)
			writeRecording(false, b)
			stats.level(false, b)
			noteDown()
			stats.output(false)

			c.SetWriteDeadline(time.Now().Add(3 * time.Second))
			if c.WriteMessage(websocket.BinaryMessage, b) != nil {
				return
			}
		}
	}()
	jitter := newUplinkJitter()
	stats.attachJitter(jitter)
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case b := <-mic:
				jitter.push(b)
			}
		}
	}()
	go func() {
		defer close(up)
		defer cancel()

		var total int
		started, frames := time.Now(), time.Duration(0)
		for ctx.Err() == nil {
			// The blocking write into the small device buffer paces this loop; the
			// guard only stops a sink that never blocks from spinning ahead.
			if ahead := frames*20*time.Millisecond - time.Since(started); ahead > 120*time.Millisecond {
				time.Sleep(ahead - 100*time.Millisecond)
			}
			frames++
			b, fromPhone := jitter.next()
			active := uplinkAllowed(phone.snapshot(), run, activeRun())
			if !active {
				b = make([]byte, 320)
			}
			writeRecording(true, b)
			writeStarted := time.Now()
			if _, e := in.Write(b); e != nil {
				log.Printf("上行结束: aplay 写入 %d 字节后退出: %v", total, e)
				return
			}
			stats.moduleWrite(active, time.Since(writeStarted))
			if active && fromPhone {
				stats.level(true, b)
			}
			total += len(b)
			if fromPhone {
				stats.output(true)
			}
		}
	}()
	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	summary := time.NewTicker(5 * time.Second)
	defer summary.Stop()
	var err error
loop:
	for {
		select {
		case <-ctx.Done():
			if parent.Err() == nil {
				log.Printf("音频循环因音频进程结束而退出（cap=%v play=%v）", cap.ProcessState, play.ProcessState)
				err = errors.New("audio process ended")
			}
			break loop
		case <-tick.C:
			if activeRun() != run {
				log.Printf("音频循环因标记变化退出（标记=%q 期望=%q）", activeRun(), run)
				break loop
			}
		case <-summary.C:
			stats.summary(false)
		}
	}
	cancel()
	in.Close()
	<-down
	<-up
	return err
}
