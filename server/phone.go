package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var callLine = regexp.MustCompile(`(?m)\+CLCC:\s*(\d+),([01]),([0-6]),0,\d+(?:,"([^"\r\n]*)")?`)

// Only digits (or a leading international +) may reach ATD. The domestic
// branches cover short service codes, local/area-code landlines, and 400/800.
var dialNumber = regexp.MustCompile(`^(?:\+[1-9][0-9]{6,14}|[0-9]{3,6}|[2-9][0-9]{6,7}|0[0-9]{9,11}|(?:400|800)[0-9]{7})$`)
var domesticNumber = regexp.MustCompile(`^1[0-9]{10}$`)
var dtmfPattern = regexp.MustCompile(`^[0-9*#A-D]$`)

func normalizeNumber(n string) string {
	n = strings.TrimSpace(n)
	if domesticNumber.MatchString(n) {
		n = "+86" + n
	}
	return n
}

type modemCall struct{ state, fingerprint, caller string }

func parseCall(s string) modemCall {
	out := modemCall{state: "idle"}
	for _, m := range callLine.FindAllStringSubmatch(s, -1) {
		state := "busy"
		switch m[3] {
		case "0":
			state = "active"
		case "4", "5":
			state = "ringing"
		case "2", "3":
			state = "dialing"
		}
		c := modemCall{state: state, fingerprint: m[1] + ":" + m[2] + ":" + m[4]}
		if m[2] == "1" {
			c.caller = m[4]
		}
		if state == "active" {
			return c
		}
		if out.state == "idle" || state == "ringing" {
			out = c
		}
	}
	return out
}
func voiceState(s string) string { return parseCall(s).state }
func newID() string {
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b)
}

type phoneView struct {
	State      string `json:"state"`
	CallID     string `json:"call_id"`
	Caller     string `json:"caller,omitempty"`
	Media      bool   `json:"media"`
	Recording  bool   `json:"recording"`
	FramesUp   uint64 `json:"frames_up"`
	FramesDn   uint64 `json:"frames_down"`
	Available  bool   `json:"available"`
	Message    string `json:"message,omitempty"`
	Sequence   uint64 `json:"sequence"`
	ObservedAt string `json:"observed_at,omitempty"`
	ModuleRTT  int64  `json:"module_rtt_ms,omitempty"`
}
type controller struct {
	sync.Mutex
	view                                phoneView
	owner, audioOwner, run, fingerprint string
	peer, direction                     string
	owned, ending                       bool
	failures                            int
	started                             time.Time
	published                           atomic.Pointer[phoneView]
}

var phone = controller{view: phoneView{State: "unavailable"}}
var moduleRoute = func(action string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "/bin/bash", envOrDefault("VOICE_WEB_MODULE_ROUTE", dataPath("module-route.sh")), action).Run()
}
var mediaOff = func() { os.Remove(callFlag); time.Sleep(400 * time.Millisecond) }
var mediaOn = func(run string) error {
	tmp := callFlag + ".tmp"
	if e := os.WriteFile(tmp, []byte(run), 0600); e != nil {
		return e
	}
	return os.Rename(tmp, callFlag)
}

func (p *controller) publish() { v := p.view; p.published.Store(&v) }
func (p *controller) changed() { p.view.Sequence++; p.publish() }

// Status requests must not queue behind slow audio route work or AT timeouts.
func (p *controller) snapshot() phoneView {
	var v phoneView
	if p.TryLock() {
		v = p.view
		p.Unlock()
	} else if saved := p.published.Load(); saved != nil {
		v = *saved
	} else {
		v.State = "unavailable"
	}
	if t, err := time.Parse(time.RFC3339Nano, v.ObservedAt); err == nil && time.Since(t) > 6*time.Second {
		v.Available = false
		v.Message = "设备状态暂未更新"
	}
	return v
}
func (p *controller) stopMedia() {
	mediaOff()
	if p.run != "" {
		if moduleRoute("stop") != nil {
			p.view.Message = "模块音频释放失败，请检查设备"
		}
	}
	p.run = ""
	p.view.Media = false
}
func (p *controller) finish() {
	p.stopMedia()
	p.owned = false
	p.ending = false
	p.owner = ""
	p.started = time.Time{}
}
func (p *controller) terminate(message string) {
	p.stopMedia()
	p.view.Message = message
	if _, e := phoneAT("", "ATH"); e != nil {
		p.ending = true
		p.view.Message = "挂断待重试：" + message
	} else {
		p.ending = false
		p.owned = false
		p.owner = ""
	}
	p.changed()
}
func (p *controller) observe(c modemCall) {
	old := p.view
	p.view.Available = true
	if c.state == "idle" {
		if p.owned || p.run != "" {
			p.finish()
		}
		p.view.State = "idle"
		p.view.CallID = ""
		p.view.Caller = ""
		p.fingerprint = ""
	} else {
		if p.view.CallID == "" || (!p.owned && p.fingerprint != c.fingerprint) {
			p.view.CallID = newID()
		}
		p.fingerprint = c.fingerprint
		p.view.State = c.state
		p.view.Caller = c.caller
	}
	if old.State != p.view.State || old.CallID != p.view.CallID || old.Available != p.view.Available || old.Caller != p.view.Caller {
		p.changed()
	}
}
func (p *controller) tick() {
	defer p.publish()
	started := time.Now()
	s, e := phoneAT("", "AT+CLCC")
	p.view.ModuleRTT = time.Since(started).Milliseconds()
	if e != nil {
		p.failures++
		p.view.Available = false
		p.view.Message = e.Error()
		p.changed()
		if p.owned && p.failures >= 3 {
			p.terminate("设备控制失联")
		}
		return
	}
	p.failures = 0
	p.view.ObservedAt = time.Now().UTC().Format(time.RFC3339Nano)
	p.observe(parseCall(s))
	p.view.Recording = recordingEnabled()
	p.view.FramesUp = framesUp()
	p.view.FramesDn = framesDown()
	if p.ending {
		p.terminate("结束通话")
		return
	}
	if !p.owned {
		return
	}
	if p.audioOwner != p.owner {
		p.terminate("声音连接已断开")
		return
	}
	if time.Since(p.started) > time.Hour || (p.view.State == "dialing" && time.Since(p.started) > 60*time.Second) {
		p.terminate("通话超时")
		return
	}
	if p.view.State == "active" {
		if p.run == "" {
			resetFrames()
			if moduleRoute("start") != nil {
				moduleRoute("stop")
				p.terminate("模块音频路由启动失败")
				return
			}
			p.run = recordingName(time.Now(), p.peer, p.direction)
			p.view.Media = true
			log.Printf("通话音频启动: 方向=%s 号码=%s", p.direction, maskNumber(p.peer))
			p.changed()
		}
		if mediaOn(p.run) != nil {
			p.terminate("声音启动失败")
		}
	}
}
func watchPhone(ctx context.Context) {
	mediaOff()
	defer func() {
		phone.Lock()
		defer phone.Unlock()
		if phone.owned {
			phone.terminate("服务停止")
		}
		phone.stopMedia()
	}()
	for ctx.Err() == nil {
		phone.Lock()
		previous := phone.view.CallID
		phone.tick()
		sampleNetworkIdle()
		incoming := phone.view.Available && phone.view.State == "ringing" && phone.view.CallID != "" && phone.view.CallID != previous
		callID := phone.view.CallID
		phone.Unlock()
		if incoming {
			queueIncomingPush(callID)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}

// 音频帧计数：区分"手机没上行"与"手机没下行"，只在内存统计。
var audioFrames struct {
	up, down atomic.Uint64
}

func noteUp()            { audioFrames.up.Add(1) }
func noteDown()          { audioFrames.down.Add(1) }
func framesUp() uint64   { return audioFrames.up.Load() }
func framesDown() uint64 { return audioFrames.down.Load() }
func resetFrames() {
	audioFrames.up.Store(0)
	audioFrames.down.Store(0)
}

// currentCallInfo 返回当前通话的录音命名信息；没有通话时返回空结构，调用方据此跳过录音。
func currentCallInfo() recordingInfo {
	phone.Lock()
	defer phone.Unlock()
	return recordingInfo{Run: phone.run, Peer: phone.peer, Direction: phone.direction}
}
func bindAudio(key string) { phone.Lock(); phone.audioOwner = key; phone.Unlock() }
func unbindAudio(key string) {
	phone.Lock()
	defer phone.Unlock()
	if phone.audioOwner == key {
		phone.audioOwner = ""
	}
	if phone.owned && phone.owner == key {
		phone.terminate("声音连接已断开")
	}
}
func phoneAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	key := requestKey(r)
	if key == "" {
		w.WriteHeader(401)
		return
	}
	if !allowedOrigin(r) {
		w.WriteHeader(403)
		return
	}
	var req struct {
		Action string `json:"action"`
		Number string `json:"number"`
		CallID string `json:"call_id"`
		Digit  string `json:"digit"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&req) != nil {
		w.WriteHeader(400)
		return
	}
	phone.Lock()
	defer phone.Unlock()
	fail := func(s string) { http.Error(w, s, 409) }
	if req.Action == "state" {
		writeView(w, phone.view)
		return
	}
	if req.Action != "dial" && req.Action != "answer" && req.Action != "hangup" && req.Action != "dtmf" {
		http.Error(w, "未知操作", 400)
		return
	}
	if phone.owned && phone.owner != key {
		fail("通话由另一个客户端控制")
		return
	}
	if req.Action != "hangup" && phone.audioOwner != key {
		fail("请先连接声音接口")
		return
	}
	n := normalizeNumber(req.Number)
	if req.Action == "dial" && !dialNumber.MatchString(n) {
		http.Error(w, "号码无效", 400)
		return
	}
	s, e := phoneAT("", "AT+CLCC")
	if e != nil {
		fail(e.Error())
		return
	}
	phone.observe(parseCall(s))
	switch req.Action {
	case "dial":
		if phone.view.State != "idle" || phone.owned || phone.ending {
			fail("设备已有通话")
			return
		}
		if moduleRoute("stop") != nil {
			fail("无法释放旧音频路由")
			return
		}
		phone.owned = true
		phone.owner = key
		phone.started = time.Now()
		phone.direction = "拨打"
		phone.peer = n
		phone.view.CallID = newID()
		phone.view.Message = ""
		if _, e = phoneAT("", "ATD"+n+";"); e != nil {
			phone.terminate("拨号失败")
			fail("拨号失败")
			return
		}
		phone.view.State = "dialing"
		phone.changed()
	case "answer":
		if req.CallID == "" || req.CallID != phone.view.CallID || phone.view.State != "ringing" || phone.owned {
			fail("来电已变化，请刷新状态")
			return
		}
		if moduleRoute("stop") != nil {
			fail("无法准备音频")
			return
		}
		phone.owned = true
		phone.owner = key
		phone.started = time.Now()
		phone.direction = "接听"
		phone.peer = phone.view.Caller
		phone.view.Message = ""
		if _, e = phoneAT("", "ATA"); e != nil {
			phone.terminate("接听失败")
			fail("接听失败")
			return
		}
		phone.changed()
	case "hangup":
		if req.CallID == "" || req.CallID != phone.view.CallID || phone.view.State == "idle" {
			fail("通话已变化，请刷新状态")
			return
		}
		// Explicit authenticated hangup can recover an orphan call after a process crash.
		phone.owned = true
		phone.owner = key
		phone.terminate("通话已结束")
	case "dtmf":
		if !phone.owned || phone.owner != key {
			fail("通话未被当前客户端控制")
			return
		}
		if phone.view.State != "active" {
			fail("仅在通话接通时可发送按键")
			return
		}
		if req.CallID == "" || req.CallID != phone.view.CallID {
			fail("通话已变化，请刷新状态")
			return
		}
		digit := strings.ToUpper(strings.TrimSpace(req.Digit))
		if !dtmfPattern.MatchString(digit) {
			http.Error(w, "按键无效", 400)
			return
		}
		if _, e = phoneAT("", "AT+VTS="+digit); e != nil {
			fail("发送按键失败")
			return
		}
		phone.view.Message = "已发送按键 " + digit
		phone.changed()
	}
	writeView(w, phone.view)
}
func writeView(w http.ResponseWriter, v phoneView) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(v)
}
func phoneEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		w.WriteHeader(405)
		return
	}
	if !allowedOrigin(r) {
		w.WriteHeader(403)
		return
	}
	if requestKey(r) == "" {
		w.WriteHeader(401)
		return
	}
	f, ok := w.(http.Flusher)
	if !ok {
		w.WriteHeader(500)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Accel-Buffering", "no")
	var seq uint64
	first := true
	for {
		if requestKey(r) == "" {
			return
		}
		phone.Lock()
		v := phone.view
		phone.Unlock()
		http.NewResponseController(w).SetWriteDeadline(time.Now().Add(5 * time.Second))
		if first || v.Sequence != seq {
			b, _ := json.Marshal(v)
			if _, e := fmt.Fprintf(w, "id: %d\nevent: call\ndata: %s\n\n", v.Sequence, b); e != nil {
				return
			}
			seq = v.Sequence
			first = false
		} else {
			if _, e := fmt.Fprint(w, ": heartbeat\n\n"); e != nil {
				return
			}
		}
		f.Flush()
		select {
		case <-r.Context().Done():
			return
		case <-appContext.Done():
			return
		case <-time.After(time.Second):
		}
	}
}

// maskNumber 只保留号码末 4 位，服务日志不写完整号码。
func maskNumber(n string) string {
	n = strings.TrimSpace(n)
	if len(n) <= 4 {
		if n == "" {
			return "未知"
		}
		return "***"
	}
	return "***" + n[len(n)-4:]
}
