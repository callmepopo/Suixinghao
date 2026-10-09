package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// 通话录音开关：默认开启，可在网页电话台上切换，状态落盘到 Unraid 宿主文件，
// 服务重启后保持。文件里只保存一个布尔值，不含号码等敏感信息。

var recordingMu sync.Mutex

func recordingFile() string {
	if v := strings.TrimSpace(os.Getenv("VOICE_WEB_RECORDING_FILE")); v != "" {
		return v
	}
	return dataPath("recording.json")
}

type recordingConfig struct {
	Enabled bool `json:"enabled"`
}

// recordingEnabled 读取开关；文件缺失或损坏时按默认开启处理，避免静默停止留档。
func recordingEnabled() bool {
	recordingMu.Lock()
	defer recordingMu.Unlock()
	b, e := os.ReadFile(recordingFile())
	if e != nil {
		return true
	}
	var c recordingConfig
	if json.Unmarshal(b, &c) != nil {
		return true
	}
	return c.Enabled
}

// setRecording 原子写入开关状态，失败时不改变已有文件。
func setRecording(on bool) error {
	recordingMu.Lock()
	defer recordingMu.Unlock()
	b, e := json.Marshal(recordingConfig{Enabled: on})
	if e != nil {
		return e
	}
	path := recordingFile()
	if e = os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return e
	}
	tmp := path + ".tmp"
	if e = os.WriteFile(tmp, append(b, '\n'), 0600); e != nil {
		return e
	}
	return os.Rename(tmp, path)
}

// recordingAction 是网页电话台的通话录音开关接口：GET 读取，POST {"enabled":bool} 修改。
// 使用与服务状态接口相同的来源与会话校验；开关只影响后续通话，不打断正在进行的录音。
func recordingAction(w http.ResponseWriter, r *http.Request) {
	if !allowedOrigin(r) {
		w.WriteHeader(403)
		return
	}
	if requestKey(r) == "" {
		w.WriteHeader(401)
		return
	}
	write := func() {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		json.NewEncoder(w).Encode(map[string]any{"enabled": recordingEnabled()})
	}
	switch r.Method {
	case http.MethodGet:
		write()
	case http.MethodPost:
		var req struct {
			Enabled *bool `json:"enabled"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 512)).Decode(&req) != nil || req.Enabled == nil {
			http.Error(w, "参数错误", 400)
			return
		}
		if e := setRecording(*req.Enabled); e != nil {
			log.Printf("录音开关写入失败: %v", e)
			http.Error(w, "开关保存失败", 500)
			return
		}
		phone.Lock()
		phone.view.Recording = *req.Enabled
		phone.changed()
		phone.Unlock()
		log.Printf("通话录音开关: %v", *req.Enabled)
		write()
	default:
		w.WriteHeader(405)
	}
}
