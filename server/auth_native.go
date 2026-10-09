package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

func requestKey(r *http.Request) string {
	key := ""
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, "Bearer ") {
		key = strings.TrimPrefix(h, "Bearer ")
	} else if c, e := r.Cookie("voice_test"); e == nil {
		key = c.Value
	}
	if parent, ok := appSessionParents.Load(key); ok && !appHashActive(parent.(string)) {
		sessions.Delete(key)
		appSessionParents.Delete(key)
		return ""
	}
	v, ok := sessions.Load(key)
	if !ok || !time.Now().Before(v.(time.Time)) {
		return ""
	}
	return key
}

// allowedOrigin 决定哪些来源可以调用服务。
//
// 关键事实：浏览器对**同源**请求不会发送 Origin 头（只有跨源才发），因此不能把
// "没有 Origin" 一律当成非浏览器客户端。判断规则：
//   - 带 Origin：必须是白名单同源（跨源一律拒绝）；
//   - 不带 Origin 的浏览器请求：只能是 /voice-test 页面自己的同源 XHR，
//     真正的凭据是会话 Cookie（SameSite=Strict，跨站不会携带）；其余路径
//     （login/session/logout/recording）仍要求 Bearer，避免放宽对非浏览器客户端的校验；
//   - 非浏览器客户端：始终带 Bearer。
func allowedOrigin(r *http.Request) bool {
	if o := r.Header.Get("Origin"); o != "" {
		return sameOrigin(r)
	}
	if bearer(r) {
		return true
	}
	// 只允许页面自己的只读请求（status/events）：GET + 会话 Cookie + 非 session/login 路径。
	if r.Method != http.MethodGet || r.URL.Path == "/voice-test/session" || r.URL.Path == "/voice-test/login" {
		return false
	}
	return strings.HasPrefix(r.URL.Path, "/voice-test/") && sessionCookie(r) != ""
}

func bearer(r *http.Request) bool {
	h := r.Header.Get("Authorization")
	return strings.HasPrefix(h, "Bearer ") && len(strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))) >= 20
}

func sessionCookie(r *http.Request) string {
	c, e := r.Cookie("voice_test")
	if e != nil {
		return ""
	}
	return c.Value
}
func nativeLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	if r.Header.Get("Origin") != "" && !sameOrigin(r) {
		w.WriteHeader(403)
		return
	}
	b, e := io.ReadAll(http.MaxBytesReader(w, r.Body, 2048))
	if e != nil {
		w.WriteHeader(400)
		return
	}
	var input struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if json.Unmarshal(b, &input) != nil || input.Username == "" || input.Password == "" {
		w.WriteHeader(400)
		return
	}
	_, status := loginUpstream(b)
	if status != 200 {
		w.WriteHeader(status)
		return
	}
	raw := make([]byte, 32)
	if _, e = rand.Read(raw); e != nil {
		w.WriteHeader(500)
		return
	}
	key := hex.EncodeToString(raw)
	expires := time.Now().Add(8 * time.Hour)
	sessions.Store(key, expires)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(map[string]any{"token": key, "expires_at": expires, "token_type": "Bearer"})
}
func logout(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	if !allowedOrigin(r) {
		w.WriteHeader(403)
		return
	}
	key := requestKey(r)
	if key == "" {
		w.WriteHeader(401)
		return
	}
	sessions.Delete(key)
	appSessionParents.Delete(key)
	w.WriteHeader(204)
}
