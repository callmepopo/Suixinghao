package main

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strconv"
	"sync"
	"time"
)

// Set from the single Version.xcconfig during a release build.
var releaseVersion = "development"

// Set by build.sh to identify the source used for a release binary.
var sourceCommit string

type diagnosticView struct {
	ServerVersion    string `json:"server_version"`
	ModuleAvailable  bool   `json:"module_available"`
	ModuleCheckedAt  string `json:"module_checked_at,omitempty"`
	ModuleRTT        int64  `json:"module_rtt_ms"`
	SIMStatus        string `json:"sim_status"`
	NetworkStatus    string `json:"network_status"`
	SignalRSSI       *int   `json:"signal_rssi,omitempty"`
	NetworkCheckedAt string `json:"network_checked_at,omitempty"`
}

var diagnosticCache = struct {
	sync.Mutex
	view  diagnosticView
	next  time.Time
	phase int
}{view: diagnosticView{SIMStatus: "待检测", NetworkStatus: "待检测"}}

var registrationPattern = regexp.MustCompile(`(?m)\+CEREG:\s*\d+,\s*(\d+)`)
var signalPattern = regexp.MustCompile(`\+CSQ:\s*(\d+),`)
var pinPattern = regexp.MustCompile(`\+CPIN:\s*(READY|SIM PIN|SIM PUK)`)

// Called only by the existing controller worker, while its lock is held and idle.
// One read-only command per tick; never open another serial interface.
func sampleNetworkIdle() {
	if phone.view.State != "idle" || phone.owned || phone.ending || !phone.view.Available {
		return
	}
	if time.Now().Before(diagnosticCache.next) {
		return
	}
	commands := []string{"AT+CPIN?", "AT+CEREG?", "AT+CSQ"}
	phase := diagnosticCache.phase
	response, err := phoneAT("", commands[phase])
	diagnosticCache.Lock()
	defer diagnosticCache.Unlock()
	if phase == 0 {
		diagnosticCache.view.SIMStatus = "待检测"
		diagnosticCache.view.NetworkStatus = "待检测"
		diagnosticCache.view.SignalRSSI = nil
	}
	if err == nil {
		switch phase {
		case 0:
			if m := pinPattern.FindStringSubmatch(response); len(m) > 1 {
				diagnosticCache.view.SIMStatus = map[string]string{"READY": "就绪", "SIM PIN": "需要 PIN", "SIM PUK": "需要 PUK"}[m[1]]
			}
		case 1:
			if m := registrationPattern.FindStringSubmatch(response); len(m) > 1 {
				diagnosticCache.view.NetworkStatus = map[string]string{"0": "未注册", "1": "已注册", "2": "正在搜索", "3": "注册被拒绝", "4": "状态未知", "5": "漫游已注册"}[m[1]]
				if diagnosticCache.view.NetworkStatus == "" {
					diagnosticCache.view.NetworkStatus = "状态未知"
				}
			}
		case 2:
			if m := signalPattern.FindStringSubmatch(response); len(m) > 1 {
				n, _ := strconv.Atoi(m[1])
				if n >= 0 && n <= 31 {
					diagnosticCache.view.SignalRSSI = &n
				}
			}
		}
	}
	diagnosticCache.phase = (phase + 1) % 3
	if phase == 2 {
		diagnosticCache.next = time.Now().Add(30 * time.Second)
		diagnosticCache.view.NetworkCheckedAt = time.Now().UTC().Format(time.RFC3339)
	}
}

func phoneDiagnostics(w http.ResponseWriter, r *http.Request) {
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
	diagnosticCache.Lock()
	v := diagnosticCache.view
	diagnosticCache.Unlock()
	current := phone.snapshot()
	v.ServerVersion = releaseVersion
	v.ModuleAvailable = current.Available
	v.ModuleCheckedAt = current.ObservedAt
	v.ModuleRTT = current.ModuleRTT
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(v)
}
