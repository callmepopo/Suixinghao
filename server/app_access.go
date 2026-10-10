package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Only hashes are persisted. App keys cannot administer keys, execute AT, or
// reach arbitrary HiDeck endpoints. Every issued voice session remains bound
// to its key so revocation also stops existing sessions.
type appGrant struct {
	ID      string    `json:"id"`
	Name    string    `json:"name"`
	Hash    string    `json:"hash"`
	Created time.Time `json:"created_at"`
}

var appKeysMu sync.Mutex
var appSessionMu sync.Mutex
var appSessionParents sync.Map // service session -> key hash

func appKeysPath() string {
	if p := os.Getenv("VOICE_WEB_APP_KEYS_FILE"); p != "" {
		return p
	}
	return dataPath("app-keys.json")
}
func loadAppGrants() ([]appGrant, error) {
	b, err := os.ReadFile(appKeysPath())
	if os.IsNotExist(err) {
		return []appGrant{}, nil
	}
	if err != nil {
		return nil, err
	}
	var grants []appGrant
	if err = json.Unmarshal(b, &grants); err != nil {
		return nil, err
	}
	return grants, nil
}
func saveAppGrants(grants []appGrant) error {
	path := appKeysPath()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	b, err := json.Marshal(grants)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".app-keys-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
func appHashActive(hash string) bool {
	appKeysMu.Lock()
	defer appKeysMu.Unlock()
	grants, err := loadAppGrants()
	if err != nil {
		return false
	}
	for _, grant := range grants {
		if subtle.ConstantTimeCompare([]byte(grant.Hash), []byte(hash)) == 1 {
			return true
		}
	}
	return false
}
func appRequestHash(r *http.Request) string {
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Bearer hdk_") {
		return ""
	}
	key := strings.TrimPrefix(header, "Bearer ")
	if len(key) != 68 {
		return ""
	}
	if _, err := hex.DecodeString(key[4:]); err != nil {
		return ""
	}
	hash := sha256.Sum256([]byte(key))
	h := hex.EncodeToString(hash[:])
	if appHashActive(h) {
		return h
	}
	return ""
}
func appKeyAdmin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !allowedOrigin(r) {
		w.WriteHeader(403)
		return
	}
	key := requestKey(r)
	_, isApp := appSessionParents.Load(key)
	if key == "" || isApp {
		w.WriteHeader(401)
		return
	}
	appKeysMu.Lock()
	defer appKeysMu.Unlock()
	grants, err := loadAppGrants()
	if err != nil {
		http.Error(w, "Key 存储不可用", 503)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	switch r.Method {
	case "GET":
		type summary struct {
			ID      string    `json:"id"`
			Name    string    `json:"name"`
			Created time.Time `json:"created_at"`
		}
		result := []summary{}
		for _, g := range grants {
			result = append(result, summary{g.ID, g.Name, g.Created})
		}
		json.NewEncoder(w).Encode(result)
	case "POST":
		var in struct {
			Name string `json:"name"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&in) != nil || len(strings.TrimSpace(in.Name)) == 0 || len(in.Name) > 80 {
			http.Error(w, "名称无效", 400)
			return
		}
		if len(grants) >= 20 {
			http.Error(w, "最多 20 个 Key，请先撤销旧 Key", 409)
			return
		}
		raw := make([]byte, 32)
		if _, err = rand.Read(raw); err != nil {
			w.WriteHeader(500)
			return
		}
		secret := "hdk_" + hex.EncodeToString(raw)
		digest := sha256.Sum256([]byte(secret))
		grant := appGrant{ID: hex.EncodeToString(digest[:8]), Name: strings.TrimSpace(in.Name), Hash: hex.EncodeToString(digest[:]), Created: time.Now().UTC()}
		if saveAppGrants(append(grants, grant)) != nil {
			http.Error(w, "Key 保存失败", 503)
			return
		}
		w.WriteHeader(201)
		json.NewEncoder(w).Encode(map[string]string{"id": grant.ID, "key": secret})
	case "DELETE":
		id := r.URL.Query().Get("id")
		found := false
		revokedHash := ""
		remaining := []appGrant{}
		for _, g := range grants {
			if g.ID == id {
				found = true
				revokedHash = g.Hash
			} else {
				remaining = append(remaining, g)
			}
		}
		if !found {
			w.WriteHeader(404)
			return
		}
		if saveAppGrants(remaining) != nil {
			http.Error(w, "Key 保存失败", 503)
			return
		}
		purgeVoIPForHash(revokedHash)
		purgeSMSPushForHash(revokedHash)
		if histories.purgeOwner(id) != nil {
			log.Print("撤销 Key 后清理连接历史失败；访问权限已撤销")
		}
		w.WriteHeader(204)
	default:
		w.WriteHeader(405)
	}
}
func appSession(w http.ResponseWriter, r *http.Request) {
	appSessionMu.Lock()
	defer appSessionMu.Unlock()
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	if !allowedOrigin(r) {
		w.WriteHeader(403)
		return
	}
	hash := appRequestHash(r)
	if hash == "" {
		w.WriteHeader(401)
		return
	}
	// Drop expired parent bindings before creating a new bounded voice session.
	appSessionParents.Range(func(k, v any) bool {
		expiry, ok := sessions.Load(k)
		if !ok || !time.Now().Before(expiry.(time.Time)) {
			sessions.Delete(k)
			appSessionParents.Delete(k)
		}
		return true
	})
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		w.WriteHeader(500)
		return
	}
	token := hex.EncodeToString(raw)
	appSessionParents.Store(token, hash)
	sessions.Store(token, time.Now().Add(2*time.Hour))
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"token": token, "expires_in": 7200})
}

// Fixed allow-list: never forward arbitrary paths or caller-supplied auth.
func appProxy(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !allowedOrigin(r) {
		w.WriteHeader(403)
		return
	}
	if appRequestHash(r) == "" {
		w.WriteHeader(401)
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/voice-test/app")
	method := map[string]string{"/devices": "GET", "/sms/contacts": "GET", "/sms/thread": "GET", "/sms/send": "POST"}[path]
	if path == "/sms/thread" && (r.Method == "PATCH" || r.Method == "DELETE") {
		method = r.Method
	}
	if strings.HasPrefix(path, "/sms/messages/") {
		id := strings.TrimPrefix(path, "/sms/messages/")
		if number, err := strconv.ParseUint(id, 10, 64); err != nil || number == 0 || strings.Trim(id, "0123456789") != "" {
			w.WriteHeader(400)
			return
		}
		method = "DELETE"
	}
	if method == "" {
		w.WriteHeader(404)
		return
	}
	if r.Method != method {
		w.WriteHeader(405)
		return
	}
	if method == "DELETE" && path == "/sms/thread" {
		selectors := 0
		for _, name := range []string{"iccid", "imsi", "device_id"} {
			if strings.TrimSpace(r.URL.Query().Get(name)) != "" {
				selectors++
			}
		}
		if selectors != 1 || strings.TrimSpace(r.URL.Query().Get("peer")) == "" {
			w.WriteHeader(400)
			return
		}
	}
	var body []byte
	if method == "POST" || method == "PATCH" {
		var err error
		limit := int64(32768)
		if method == "PATCH" {
			limit = 128
		}
		body, err = io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
		if err != nil {
			w.WriteHeader(413)
			return
		}
		var value map[string]json.RawMessage
		if json.Unmarshal(body, &value) != nil {
			w.WriteHeader(400)
			return
		}
		if method == "PATCH" {
			var throughID uint64
			if len(value) != 1 || json.Unmarshal(value["through_id"], &throughID) != nil || throughID == 0 ||
				strings.TrimSpace(r.URL.Query().Get("iccid")) == "" || strings.TrimSpace(r.URL.Query().Get("peer")) == "" {
				w.WriteHeader(400)
				return
			}
		} else {
			for k := range value {
				if k != "device_id" && k != "phone" && k != "message" {
					http.Error(w, "不支持的字段", 400)
					return
				}
			}
		}
	}
	token, err := backendToken()
	if err != nil {
		http.Error(w, "服务凭据不可用", 503)
		return
	}
	target := upstream + "/api" + path
	q, err := http.NewRequestWithContext(r.Context(), method, target, bytes.NewReader(body))
	if err != nil {
		w.WriteHeader(500)
		return
	}
	params := q.URL.Query()
	for _, name := range []string{"device_id", "peer", "iccid", "imsi", "limit", "before_ts", "before_id"} {
		if value := r.URL.Query().Get(name); value != "" {
			params.Set(name, value)
		}
	}
	q.URL.RawQuery = params.Encode()
	q.Header.Set("Authorization", token)
	q.Header.Set("Content-Type", "application/json")
	response, err := client.Do(q)
	if err != nil {
		http.Error(w, "HiDeck 暂不可用", 502)
		return
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		code := response.StatusCode
		if code < 400 || code > 599 {
			code = 502
		}
		http.Error(w, "HiDeck 请求未完成", code)
		return
	}
	payload, err := io.ReadAll(io.LimitReader(response.Body, 4*1024*1024+1))
	if err != nil || len(payload) > 4*1024*1024 {
		http.Error(w, "响应过大或不完整", 502)
		return
	}
	if !json.Valid(payload) {
		http.Error(w, "HiDeck 响应无效", 502)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(response.StatusCode)
	w.Write(payload)
}
