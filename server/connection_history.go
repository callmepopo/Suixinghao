package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Only enum values and timestamps are accepted. No addresses, raw errors,
// identifiers from the modem, phone numbers or credentials enter this file.
type connectionEvent struct {
	ID     string  `json:"id"`
	At     float64 `json:"at"`
	Layer  string  `json:"layer"`
	Kind   string  `json:"kind"`
	State  string  `json:"state"`
	Reason string  `json:"reason"`
	RSSI   *int    `json:"rssi,omitempty"`
	Owner  string  `json:"owner,omitempty"`
}

type connectionSummary struct {
	Layer         string   `json:"layer"`
	Online        float64  `json:"online_seconds"`
	Offline       float64  `json:"offline_seconds"`
	Unknown       float64  `json:"unknown_seconds"`
	Coverage      float64  `json:"coverage"`
	Rate          *float64 `json:"online_rate"`
	Interruptions int      `json:"interruptions"`
}

type connectionOutage struct {
	ID              string   `json:"id"`
	Start           float64  `json:"start"`
	End             *float64 `json:"end,omitempty"`
	NetworkRestored *float64 `json:"network_restored,omitempty"`
	Attempts        int      `json:"attempts"`
	Reason          string   `json:"reason"`
	Incomplete      bool     `json:"incomplete"`
}

type connectionHistoryView struct {
	GeneratedAt   float64             `json:"generated_at"`
	Summaries     []connectionSummary `json:"summaries"`
	Events        []connectionEvent   `json:"events"`
	Outages       []connectionOutage  `json:"outages"`
	RetentionDays int                 `json:"retention_days"`
}

const observationLease = 90.0 // A stopped process never counts as continuously online.
const historyRetention = 30 * 24 * time.Hour

type historyStore struct {
	mu            sync.Mutex
	path          string
	events        []connectionEvent
	loaded        bool
	dirty         bool
	loadErr       error
	seen          map[string]bool
	lastPruned    float64
	pending       []connectionEvent
	lastCompacted float64
}

var histories = &historyStore{}
var remoteHistoryEvents = make(chan connectionEvent, 256)

func historyPath() string {
	if p := os.Getenv("VOICE_WEB_CONNECTION_HISTORY_FILE"); p != "" {
		return p
	}
	return filepath.Join(filepath.Dir(appKeysPath()), "connection-history.json")
}
func historyNow() float64 { return float64(time.Now().UnixMilli()) / 1000 }
func (s *historyStore) loadLocked() error {
	if s.loaded {
		return s.loadErr
	}
	s.loaded = true
	s.seen = map[string]bool{}
	if s.path == "" {
		s.path = historyPath()
	}
	b, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		err = nil
	} else if err == nil {
		err = json.Unmarshal(b, &s.events)
	}
	if err != nil {
		s.loadErr = err
		return err
	}
	if info, e := os.Stat(s.path); e == nil {
		s.lastCompacted = float64(info.ModTime().Unix())
	}
	s.seen = make(map[string]bool, len(s.events))
	for _, e := range s.events {
		s.seen[e.Owner+"/"+e.ID] = true
	}
	journal, e := os.ReadFile(s.path + ".journal")
	if os.IsNotExist(e) {
		return nil
	}
	if e != nil {
		s.loadErr = e
		return e
	}
	// An interrupted append has no durable acknowledgement. Recover complete
	// lines only; preserve any corrupt complete record as an explicit error.
	complete := bytes.LastIndexByte(journal, '\n') + 1
	for _, line := range bytes.Split(journal[:complete], []byte{'\n'}) {
		if len(line) == 0 {
			continue
		}
		var event connectionEvent
		if err = json.Unmarshal(line, &event); err != nil {
			s.loadErr = err
			return err
		}
		key := event.Owner + "/" + event.ID
		if !s.seen[key] {
			s.seen[key] = true
			s.events = append(s.events, event)
		}
	}
	if complete < len(journal) {
		err = os.Truncate(s.path+".journal", int64(complete))
	}
	s.loadErr = err
	return err
}
func (s *historyStore) pruneLocked(now float64) {
	cutoff := now - historyRetention.Seconds()
	sort.SliceStable(s.events, func(i, j int) bool { return s.events[i].At < s.events[j].At })
	kept := s.events[:0]
	for _, e := range s.events {
		if e.At >= cutoff {
			kept = append(kept, e)
		}
	}
	// Retain newest observations fairly per owner, with an overall hard bound.
	counts := map[string]int{}
	bounded := make([]connectionEvent, 0, len(kept))
	for i := len(kept) - 1; i >= 0 && len(bounded) < 200000; i-- {
		e := kept[i]
		bucket := e.Owner + "/" + e.Layer
		if counts[bucket] >= 45000 {
			continue
		}
		counts[bucket]++
		bounded = append(bounded, e)
	}
	for i, j := 0, len(bounded)-1; i < j; i, j = i+1, j-1 {
		bounded[i], bounded[j] = bounded[j], bounded[i]
	}
	s.events = bounded
	s.seen = make(map[string]bool, len(bounded))
	for _, e := range bounded {
		s.seen[e.Owner+"/"+e.ID] = true
	}
	s.lastPruned = now
}
func (s *historyStore) compactLocked() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0700); err != nil {
		return err
	}
	b, err := json.Marshal(s.events)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(s.path), ".connection-history-*")
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
	if err = os.Rename(f.Name(), s.path); err != nil {
		return err
	}
	journal, err := os.OpenFile(s.path+".journal", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	err = journal.Sync()
	closeErr := journal.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	s.pending = nil
	s.lastCompacted = historyNow()
	s.dirty = false
	return nil
}
func (s *historyStore) saveLocked() error {
	if !s.dirty {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0700); err != nil {
		return err
	}
	info, err := os.Stat(s.path + ".journal")
	if s.lastCompacted == 0 || historyNow()-s.lastCompacted >= 86400 || (err == nil && info.Size() > 32*1024*1024) {
		s.pruneLocked(historyNow())
		return s.compactLocked()
	}
	var b bytes.Buffer
	encoder := json.NewEncoder(&b)
	for _, e := range s.pending {
		if err := encoder.Encode(e); err != nil {
			return err
		}
	}
	f, err := os.OpenFile(s.path+".journal", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	info, err = f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	size := info.Size()
	if _, err = f.Write(b.Bytes()); err == nil {
		err = f.Sync()
	}
	if err != nil {
		_ = f.Truncate(size)
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	s.pending = nil
	s.dirty = false
	return nil
}
func (s *historyStore) ingest(events []connectionEvent, durable bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.loadLocked(); err != nil {
		return err
	}
	for _, e := range events {
		key := e.Owner + "/" + e.ID
		if !s.seen[key] {
			s.events = append(s.events, e)
			s.pending = append(s.pending, e)
			s.seen[key] = true
			s.dirty = true
		}
	}
	now := historyNow()
	if now-s.lastPruned >= 3600 || len(s.events) > 200000 {
		s.pruneLocked(now)
	}
	if durable {
		return s.saveLocked()
	}
	return nil
}
func (s *historyStore) snapshot(owner string) ([]connectionEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.loadLocked(); err != nil {
		return nil, err
	}
	result := []connectionEvent{}
	cutoff := historyNow() - historyRetention.Seconds()
	for _, e := range s.events {
		if e.At >= cutoff && (e.Owner == "" || e.Owner == owner) {
			e.Owner = ""
			result = append(result, e)
		}
	}
	return result, nil
}
func (s *historyStore) purgeOwner(owner string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.loadLocked(); err != nil {
		return err
	}
	kept := make([]connectionEvent, 0, len(s.events))
	for _, e := range s.events {
		if e.Owner != owner {
			kept = append(kept, e)
		}
	}
	if len(kept) == len(s.events) {
		return nil
	}
	s.events = kept
	s.pruneLocked(historyNow())
	s.dirty = true
	return s.compactLocked()
}

func summarizeConnections(events []connectionEvent, layer string, start, end float64) connectionSummary {
	v := connectionSummary{Layer: layer}
	state, until, cursor := "unknown", start, start
	add := func(stop float64) {
		knownEnd := min(stop, until)
		if knownEnd > cursor {
			switch state {
			case "online":
				v.Online += knownEnd - cursor
			case "offline":
				v.Offline += knownEnd - cursor
			}
		}
		cursor = stop
	}
	for _, e := range events {
		if e.Layer != layer || e.At > end || e.State == "" {
			continue
		}
		if e.At < start {
			state = e.State
			until = e.At + observationLease
			continue
		}
		add(e.At)
		if e.State == "offline" && (state != "offline" || e.At > until) {
			v.Interruptions++
		}
		state = e.State
		until = e.At + observationLease
	}
	add(end)
	v.Unknown = max(0, end-start-v.Online-v.Offline)
	known := v.Online + v.Offline
	if end > start {
		v.Coverage = known / (end - start)
	}
	if known > 0 {
		rate := v.Online / known
		v.Rate = &rate
	}
	return v
}

func connectionOutages(events []connectionEvent) []connectionOutage {
	result := []connectionOutage{}
	var current *connectionOutage
	lastObservation := 0.0
	finishUnknown := func() {
		if current != nil {
			current.Incomplete = true
			result = append(result, *current)
			current = nil
		}
	}
	for _, e := range events {
		if e.Layer != "phone" {
			continue
		}
		if lastObservation > 0 && e.At-lastObservation > observationLease {
			finishUnknown()
		}
		if e.State != "" {
			lastObservation = e.At
		}
		if e.State == "unknown" {
			finishUnknown()
			continue
		}
		if e.State == "offline" && current == nil {
			current = &connectionOutage{ID: e.ID, Start: e.At, Reason: e.Reason}
		}
		if current == nil {
			continue
		}
		if e.Kind == "retry" {
			current.Attempts++
		}
		if e.Kind == "network_up" && current.NetworkRestored == nil {
			t := e.At
			current.NetworkRestored = &t
		}
		if e.Kind == "network_down" {
			current.NetworkRestored = nil
		}
		if e.State == "online" {
			t := e.At
			current.End = &t
			result = append(result, *current)
			current = nil
		}
	}
	if current != nil {
		current.Incomplete = historyNow()-lastObservation > observationLease
		result = append(result, *current)
	}
	return result
}

func validPhoneEvent(e connectionEvent, now float64) bool {
	if e.Owner != "" || e.RSSI != nil || e.Layer != "phone" || e.At < now-historyRetention.Seconds() || e.At > now+300 {
		return false
	}
	if len(e.ID) != 36 {
		return false
	}
	for i, c := range e.ID {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
			continue
		}
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	kinds := map[string]bool{"observation": true, "network_down": true, "network_up": true, "network_change": true, "retry": true, "connected": true, "request_failed": true, "observer_start": true, "observer_stop": true, "auth_failed": true}
	reasons := map[string]bool{"": true, "no_network": true, "network_change": true, "request_failed": true, "background": true, "startup": true, "foreground": true, "logout": true, "auth_failed": true, "gap": true}
	return kinds[e.Kind] && reasons[e.Reason] && (e.State == "" || e.State == "online" || e.State == "offline" || e.State == "unknown")
}

func appConnectionHistory(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != "GET" && r.Method != "POST" {
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
	// Use the non-secret grant ID; never persist/expose the key or its hash in telemetry.
	appKeysMu.Lock()
	grants, err := loadAppGrants()
	appKeysMu.Unlock()
	owner := ""
	for _, g := range grants {
		if g.Hash == hash {
			owner = g.ID
		}
	}
	if err != nil || owner == "" {
		w.WriteHeader(401)
		return
	}
	if r.Method == "POST" {
		var batch struct {
			Events []connectionEvent `json:"events"`
		}
		d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 65536))
		d.DisallowUnknownFields()
		if d.Decode(&batch) != nil || len(batch.Events) == 0 || len(batch.Events) > 100 {
			w.WriteHeader(400)
			return
		}
		if d.Decode(&struct{}{}) != io.EOF {
			w.WriteHeader(400)
			return
		}
		for i, e := range batch.Events {
			if !validPhoneEvent(e, historyNow()) {
				w.WriteHeader(400)
				return
			}
			batch.Events[i].Owner = owner
		}
		if histories.ingest(batch.Events, true) != nil {
			http.Error(w, "历史保存暂不可用", 503)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]int{"accepted": len(batch.Events)})
		return
	}
	events, err := histories.snapshot(owner)
	if err != nil {
		http.Error(w, "历史读取暂不可用", 503)
		return
	}
	sort.SliceStable(events, func(i, j int) bool { return events[i].At < events[j].At })
	now := historyNow()
	view := connectionHistoryView{GeneratedAt: now, RetentionDays: 30, Summaries: []connectionSummary{}}
	for _, layer := range []string{"phone", "module", "network"} {
		view.Summaries = append(view.Summaries, summarizeConnections(events, layer, now-86400, now))
	}
	view.Outages = connectionOutages(events)
	if len(view.Outages) > 100 {
		view.Outages = view.Outages[len(view.Outages)-100:]
	}
	view.Events = []connectionEvent{}
	for i := len(events) - 1; i >= 0 && len(view.Events) < 200; i-- {
		if events[i].Kind != "observation" {
			view.Events = append(view.Events, events[i])
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(view)
}

func runConnectionHistory(ctx context.Context) {
	// Cached snapshots only. No extra AT commands or serial interface access.
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	last := map[string]connectionEvent{}
	lastNetworkCheck := ""
	queue := func(layer, state, kind, reason string, rssi *int) {
		now := historyNow()
		old, ok := last[layer]
		if ok && old.State == state && now-old.At < 60 {
			return
		}
		if ok && old.State == state {
			kind = "observation"
		}
		e := connectionEvent{ID: randomHistoryID(), At: now, Layer: layer, State: state, Kind: kind, Reason: reason, RSSI: rssi}
		select {
		case remoteHistoryEvents <- e:
			last[layer] = e
		default: /* Expiring leases expose a collection gap. */
		}
	}
	for {
		select {
		case <-ctx.Done():
			for _, layer := range []string{"module", "network"} {
				queue(layer, "unknown", "observer_stop", "shutdown", nil)
			}
			return
		case <-ticker.C:
			v := phone.snapshot()
			state := "offline"
			if v.Available {
				state = "online"
			}
			queue("module", state, "module_state", "", nil)
			diagnosticCache.Lock()
			d := diagnosticCache.view
			diagnosticCache.Unlock()
			if d.NetworkCheckedAt != "" && d.NetworkCheckedAt != lastNetworkCheck {
				lastNetworkCheck = d.NetworkCheckedAt
				network := "unknown"
				switch d.NetworkStatus {
				case "已注册", "漫游已注册":
					network = "online"
				case "未注册", "正在搜索", "注册被拒绝":
					network = "offline"
				}
				queue("network", network, "network_state", "", d.SignalRSSI)
			}
		}
	}
}
func randomHistoryID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("random source unavailable")
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func writeConnectionHistory(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	flush := func() {
		histories.mu.Lock()
		defer histories.mu.Unlock()
		if histories.dirty {
			_ = histories.saveLocked()
		}
	}
	for {
		select {
		case e := <-remoteHistoryEvents:
			_ = histories.ingest([]connectionEvent{e}, false)
		case <-ticker.C:
			flush()
		case <-ctx.Done():
			for {
				select {
				case e := <-remoteHistoryEvents:
					_ = histories.ingest([]connectionEvent{e}, false)
				default:
					flush()
					return
				}
			}
		}
	}
}

func startConnectionHistory(ctx context.Context) <-chan struct{} {
	done := make(chan struct{})
	writerCtx, cancel := context.WithCancel(context.Background())
	writerDone := make(chan struct{})
	go func() { defer close(writerDone); writeConnectionHistory(writerCtx) }()
	go func() { defer close(done); runConnectionHistory(ctx); cancel(); <-writerDone }()
	return done
}
