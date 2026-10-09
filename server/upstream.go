package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"gopkg.in/yaml.v3"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

var configPath = envOrDefault("VOICE_WEB_CONFIG_FILE", "/mnt/user/appdata/hideck/config/config.yaml")

func loginUpstream(body []byte) (string, int) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	q, _ := http.NewRequestWithContext(ctx, "POST", upstream+"/api/auth/login", bytes.NewReader(body))
	q.Header.Set("Content-Type", "application/json")
	r, e := client.Do(q)
	if e != nil {
		return "", 503
	}
	defer r.Body.Close()
	var v struct {
		Token string `json:"token"`
	}
	if r.StatusCode != 200 {
		return "", r.StatusCode
	}
	if json.NewDecoder(io.LimitReader(r.Body, 16384)).Decode(&v) != nil || v.Token == "" {
		return "", 503
	}
	return "Bearer " + v.Token, 200
}

// Local service credential: use HiDeck's existing HMAC session format with its
// root-readable signing material. Never reverse bcrypt or expose the key.
func backendToken() (string, error) {
	b, e := os.ReadFile(configPath)
	if e != nil {
		return "", errors.New("无法读取 HiDeck 配置")
	}
	var cfg struct {
		Web struct {
			Password string `yaml:"password"`
		} `yaml:"web"`
	}
	if yaml.Unmarshal(b, &cfg) != nil || cfg.Web.Password == "" {
		return "", errors.New("HiDeck 服务凭据配置不完整")
	}
	exp := strconv.FormatInt(time.Now().Add(5*time.Minute).Unix(), 10)
	mac := hmac.New(sha256.New, []byte(cfg.Web.Password))
	mac.Write([]byte(exp))
	token := base64.StdEncoding.EncodeToString([]byte(exp + "." + hex.EncodeToString(mac.Sum(nil))))
	return "Bearer " + token, nil
}

var phoneAT = func(_ string, command string) (string, error) {
	token, e := backendToken()
	if e != nil {
		return "", e
	}
	b, _ := json.Marshal(map[string]any{"cmd": command, "timeout_ms": 3000})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	q, _ := http.NewRequestWithContext(ctx, "POST", upstream+"/api/devices/"+url.PathEscape(envOrDefault("VOICE_WEB_DEVICE_ID", "eth1"))+"/actions/at", bytes.NewReader(b))
	q.Header.Set("Authorization", token)
	q.Header.Set("Content-Type", "application/json")
	r, e := client.Do(q)
	if e != nil {
		return "", errors.New("设备控制暂不可用")
	}
	defer r.Body.Close()
	var v struct {
		Response string `json:"response"`
		Status   string `json:"status"`
	}
	if r.StatusCode != 200 || json.NewDecoder(io.LimitReader(r.Body, 32768)).Decode(&v) != nil || v.Status != "ok" || strings.Contains(v.Response, "ERROR") {
		return "", errors.New("设备拒绝指令或暂不可用")
	}
	return v.Response, nil
}
