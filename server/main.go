package main

import (
	"context"
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"github.com/gorilla/websocket"
	"log"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed web/index.html web/audio.js web/menu.js web/app-access.html
var files embed.FS
var appContext = context.Background()
var sessions sync.Map
var lock = make(chan struct{}, 1)

// hostPattern 只允许主机名加可选端口；字符类里不能出现未转义的 `.`，否则会构成
// `.` 到 `-` 的字符区间，把 `/` 等字符一并放行。
var hostPattern = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?$`)

var allowedOrigins = map[string]bool{}

// Optional explicit origins for alternate reverse-proxy entry points.
// The normal deployment needs no list: the browser Origin must match request Host.
func init() {
	for _, o := range strings.Split(os.Getenv("VOICE_WEB_ALLOWED_ORIGINS"), ",") {
		if o = strings.TrimSuffix(strings.TrimSpace(o), "/"); o != "" {
			allowedOrigins[o] = true
		}
	}
}

var upstream = strings.TrimRight(envOrDefault("VOICE_WEB_UPSTREAM", "http://127.0.0.1:7577"), "/")
var client = &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

// sameOrigin matches the browser origin against the reverse-proxy Host,
// including explicit ports. Additional origins require explicit configuration.
func sameOrigin(r *http.Request) bool {
	o := strings.TrimSuffix(r.Header.Get("Origin"), "/")
	if !strings.HasPrefix(o, "https://") && !strings.HasPrefix(o, "http://") {
		return false
	}
	if allowedOrigins[o] {
		return true
	}
	originHost := strings.TrimPrefix(strings.TrimPrefix(o, "https://"), "http://")
	reqHost := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(r.Host)), ".")
	if !hostPattern.MatchString(reqHost) {
		return false
	}
	if originHost == reqHost {
		return true
	}
	return !strings.Contains(originHost, ":") && (reqHost == originHost+":443" || reqHost == originHost+":80")
}
func session(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	if !allowedOrigin(r) {
		w.WriteHeader(403)
		return
	}
	token := r.Header.Get("Authorization")
	if !strings.HasPrefix(token, "Bearer ") || len(token) > 4096 {
		w.WriteHeader(401)
		return
	}
	q, _ := http.NewRequestWithContext(r.Context(), "GET", upstream+"/api/devices", nil)
	q.Header.Set("Authorization", token)
	resp, e := client.Do(q)
	if e != nil {
		w.WriteHeader(503)
		return
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		w.WriteHeader(401)
		return
	}
	b := make([]byte, 32)
	if _, e = rand.Read(b); e != nil {
		w.WriteHeader(500)
		return
	}
	key := hex.EncodeToString(b)
	sessions.Store(key, time.Now().Add(15*time.Minute))

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	// 先按浏览器同源 Cookie 处理；Set-Cookie 只对与请求 Host 同源的页面有效。
	http.SetCookie(w, &http.Cookie{Name: "voice_test", Value: key, Path: "/voice-test", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: 900})
	// 同时回传 token：若页面来源与请求 Host 不同源（例如用 443 打开页面而反代走 :40443），
	// 浏览器会丢弃上面的 Cookie，此时页面改用会话内存里的 Bearer，避免状态接口 403。
	// 仅白名单来源能到达这里，且 token 不写 storage、不进 URL、不写日志。
	json.NewEncoder(w).Encode(map[string]any{"ready": true, "token": key, "expires_in": 900})
}
func permitted(r *http.Request) bool { return requestKey(r) != "" }
func stream(w http.ResponseWriter, r *http.Request) {
	if !allowedOrigin(r) {
		w.WriteHeader(403)
		return
	}
	if !permitted(r) {
		w.WriteHeader(401)
		return
	}
	select {
	case lock <- struct{}{}:
		defer func() { <-lock }()
	default:
		w.WriteHeader(409)
		return
	}
	u := websocket.Upgrader{CheckOrigin: allowedOrigin, Subprotocols: []string{"sxh.audio-diagnostics.v1"}}
	c, e := u.Upgrade(w, r, nil)
	if e != nil {
		log.Printf("音频通道升级失败: %v", e)
		return
	}
	started := time.Now()
	log.Print("音频通道已建立")
	defer func() {
		log.Printf("音频通道结束: 时长=%.1fs 上行帧=%d 下行帧=%d", time.Since(started).Seconds(), framesUp(), framesDown())
	}()
	defer c.Close()
	key := requestKey(r)
	expiry, ok := sessions.Load(key)
	if !ok {
		return
	}
	ctx, cancel := context.WithDeadline(r.Context(), expiry.(time.Time))
	defer cancel()
	stopWatch := context.AfterFunc(appContext, cancel)
	defer stopWatch()
	bindAudio(key)
	defer unbindAudio(key)
	// Optional capability is in the handshake header: no extra pre-pong data frame.
	stats := &audioStats{}
	mic := make(chan []byte, 8)
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer cancel()
		defer c.Close()
		last := ""
		for ctx.Err() == nil {
			run := activeRun()
			if run != "" && run != last {
				last = run
				stats.begin(run)
				for len(mic) > 0 {
					<-mic
					stats.discardStartup()
				}
				c.SetWriteDeadline(time.Now().Add(3 * time.Second))
				if c.WriteJSON(map[string]string{"status": "声音链路已启动；接通前仅接收模块声音"}) != nil {
					return
				}
				// Controller owns the media flag; never resurrect a call after hangup.
				if activeRun() != run {
					continue
				}
				audioStart := time.Now()
				err := runAudio(ctx, c, mic, run, nil, stats)
				stats.summary(true)
				log.Printf("音频循环结束: 时长=%.1fs 上行=%d 下行=%d 错误=%v 上下文已取消=%v",
					time.Since(audioStart).Seconds(), framesUp(), framesDown(), err, ctx.Err() != nil)
				if err != nil && ctx.Err() == nil {
					cancel()
					c.SetWriteDeadline(time.Now().Add(3 * time.Second))
					c.WriteJSON(map[string]string{"error": "模块声音连接失败，通话将结束"})
				}
				if ctx.Err() == nil {
					c.SetWriteDeadline(time.Now().Add(3 * time.Second))
					if c.WriteJSON(map[string]string{"status": "声音已结束，等待下一通电话"}) != nil {
						return
					}
				}
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(200 * time.Millisecond):
			}
		}
	}()
	go func() { <-ctx.Done(); c.Close() }()
	c.SetReadLimit(4096)
	for {
		c.SetReadDeadline(time.Now().Add(15 * time.Second))
		kind, b, e := c.ReadMessage()
		if e != nil {
			log.Printf("音频通道读结束: %v", e)
			break
		}
		if requestKey(r) == "" {
			log.Printf("音频通道读结束: 会话失效")
			break
		}
		if kind == websocket.TextMessage {
			if string(b) != "ping" {
				stats.acceptClient(b, time.Now())
			}
			continue
		}
		if kind != websocket.BinaryMessage || len(b) != 320 {
			break
		}
		// 上行帧计数：统计浏览器实际送到的帧（无论当前是否有通话），
		// 这是判断"浏览器有没有在发"的唯一可靠指标。
		if framesUp() == 1 {
			log.Printf("收到浏览器第一个音频帧（320 字节）")
		}
		noteUp()
		if run := activeRun(); run != "" {
			if !uplinkAllowed(phone.snapshot(), run, activeRun()) {
				b = make([]byte, 320)
			}
			dropped := false
			select {
			case mic <- b:
			default:
				dropped = true
			}
			stats.arrival(run, dropped, len(mic))
		}
	}
	cancel()
	<-done

}
func routes() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/voice-test/app-keys", appKeyAdmin)
	m.HandleFunc("/voice-test/app/session", appSession)
	m.HandleFunc("/voice-test/app/voip-token", appVoIPToken)
	m.HandleFunc("/voice-test/app/sms-push-token", appSMSPushToken)
	m.HandleFunc("/voice-test/app/connection-history", appConnectionHistory)
	m.HandleFunc("/voice-test/app/", appProxy)
	m.HandleFunc("/voice-test/app-access/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/voice-test/app-access/" || r.Method != "GET" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		b, _ := files.ReadFile("web/app-access.html")
		w.Write(b)
	})
	m.HandleFunc("/voice-test/session", session)
	m.HandleFunc("/voice-test/phone", phoneAction)
	m.HandleFunc("/voice-test/events", phoneEvents)
	m.HandleFunc("/voice-test/diagnostics", phoneDiagnostics)
	m.HandleFunc("/voice-test/login", nativeLogin)
	m.HandleFunc("/voice-test/logout", logout)
	m.HandleFunc("/voice-test/status", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			w.WriteHeader(405)
			return
		}
		if !allowedOrigin(r) {
			w.WriteHeader(403)
			return
		}
		if !permitted(r) {
			w.WriteHeader(401)
			return
		}
		writeView(w, phone.snapshot())
	})
	m.HandleFunc("/voice-test/recording", recordingAction)
	m.HandleFunc("/voice-test/stream", stream)
	m.HandleFunc("/voice-test/health", func(w http.ResponseWriter, r *http.Request) {
		health := map[string]any{"ok": true, "version": releaseVersion}
		if sourceCommit != "" {
			health["source_commit"] = sourceCommit
		}
		json.NewEncoder(w).Encode(health)
	})
	m.HandleFunc("/voice-test", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/voice-test" {
			http.NotFound(w, r)
			return
		}
		// Location 故意写成相对地址：经 NPM 反代时不能带上内部端口或丢公网端口。
		w.Header().Set("Location", "voice-test/")
		w.WriteHeader(http.StatusSeeOther)
	})
	m.HandleFunc("/voice-test/", func(w http.ResponseWriter, r *http.Request) {
		name := "index.html"
		if r.URL.Path == "/voice-test/audio.js" {
			name = "audio.js"
		} else if r.URL.Path == "/voice-test/menu.js" {
			name = "menu.js"
		} else if r.URL.Path != "/voice-test/" {
			http.NotFound(w, r)
			return
		}
		b, _ := files.ReadFile("web/" + name)
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if name == "audio.js" || name == "menu.js" {
			w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		} else {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
		}
		w.Write(b)
	})
	return m
}
func listenAddr() string {
	if v := strings.TrimSpace(os.Getenv("VOICE_WEB_ADDR")); v != "" {
		return v
	}
	return "127.0.0.1:7581"
}
func main() {
	var cancel context.CancelFunc
	appContext, cancel = signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if len(os.Args) > 1 && strings.HasPrefix(os.Args[1], "relay") {
		if err := relayCommand(appContext, os.Args[1:]); err != nil {
			log.Print(err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "serve-page" {
		log.Print("page preview on " + listenAddr())
		log.Fatal(http.ListenAndServe(listenAddr(), routes()))
	}
	workerDone := make(chan struct{})
	historyDone := startConnectionHistory(appContext)
	go func() { defer close(workerDone); watchPhone(appContext) }()
	go runIncomingPushes(appContext)
	go watchSMS(appContext)
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-appContext.Done():
				return
			case <-ticker.C:
				sessions.Range(func(k, v any) bool {
					if time.Now().After(v.(time.Time)) {
						sessions.Delete(k)
					}
					return true
				})
			}
		}
	}()
	s := &http.Server{Addr: listenAddr(), Handler: routes(), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
	go func() {
		<-appContext.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		s.Shutdown(ctx)
	}()
	if err := s.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Print(err)
	}
	if appContext.Err() != nil {
		<-workerDone
		<-historyDone
	}
}
