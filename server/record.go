package main

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// 自动通话录音：每通电话在接通启动音频时创建，挂断后收尾。
// 命名规则由用户指定：日期-对手-拨打/接听，例如 20260916-143012-8613800000000-拨打.wav。
// 每通电话产出三个文件：拨打（本机上行）、接听（对方下行）各一份单声道，
// 以及双声道的 -合并.wav（左=拨打/本机，右=接听/对方），便于直接播放核对双方。
var (
	recordRoot    = dataPath("recordings")
	recordMaxByte = int64(1 << 30) // 录音目录总量上限，超出后按修改时间删除最旧文件
	peerPattern   = regexp.MustCompile(`^\+?[0-9]{3,20}$`)
	namePattern   = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}-[^\-\r\n]{1,40}-(拨打|接听)(-[0-9]+)?$`)
	// safeRun 校验 call.active 中的 run 名：既接受历史测试名（test-YYYYMMDD-HHMMSS），
	// 也接受现行录音命名（YYYYMMDD-HHMMSS-对手-拨打/接听，对手可能是"未知号码"）。
	// 只允许日期时间、数字、字母、下划线、中文与短横线，杜绝路径穿越。
	safeRun = regexp.MustCompile(`^(test-)?[0-9]{8}-[0-9]{6}(-[^-/\\\s.]{1,40}-(拨打|接听)(-[0-9]+)?)?$`)
)

const recordSampleRate = 8000

// recordingInfo 是启动录音所需的通话信息，全部在内存中传递，不写日志。
type recordingInfo struct {
	Run       string
	Peer      string
	Direction string
}

// recordingName 生成用户指定的命名：日期-对手-拨打/接听（不含扩展名）。
// 号码只保留数字与可选前导 +；模块未提供号码时用“未知号码”占位。
func recordingName(t time.Time, peer, direction string) string {
	peer = strings.TrimSpace(peer)
	if !peerPattern.MatchString(peer) {
		peer = "未知号码"
	}
	if direction != "拨打" && direction != "接听" {
		direction = "接听"
	}
	return t.Format("20060102-150405") + "-" + strings.TrimPrefix(peer, "+") + "-" + direction
}

// uniqueName 在目录内挑选未占用的名字，同一秒内的多通电话自动追加 -2、-3。
func uniqueName(dir, base string, taken map[string]bool) string {
	for i := 1; ; i++ {
		name := base
		if i > 1 {
			name = base + "-" + strconv.Itoa(i)
		}
		if taken[name] {
			continue
		}
		if _, e := os.Stat(filepath.Join(dir, name+".wav")); e == nil {
			continue
		}
		taken[name] = true
		return name
	}
}

type recorder struct {
	file      *os.File
	size      uint32
	limit     uint32
	truncated bool
}

// newPair 为一通电话创建两路录音。任一路失败只返回错误，不影响通话与音频。
func newPair(root string, info recordingInfo) (*pair, error) {
	dir := filepath.Join(root, time.Now().Format("20060102"))
	if e := os.MkdirAll(dir, 0700); e != nil {
		return nil, e
	}
	base := info.Run
	if !namePattern.MatchString(base) || len(base) > 80 {
		// 未按约定命名或名字过长（个别文件系统上限）时，退回标准命名。
		base = recordingName(time.Now(), info.Peer, info.Direction)
	}
	base = uniqueName(dir, base, map[string]bool{})
	p := &pair{dir: dir, base: base}
	var e error
	if p.up, e = openRecorder(filepath.Join(dir, base+"-拨打.wav")); e != nil {
		return nil, e
	}
	if p.down, e = openRecorder(filepath.Join(dir, base+"-接听.wav")); e != nil {
		p.up.close()
		return nil, e
	}
	return p, nil
}

func openRecorder(path string) (*recorder, error) {
	f, e := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
	if e != nil {
		return nil, e
	}
	f.Write(make([]byte, 44))
	// 单通最多保留 1 小时，异常挂断时不会无限增长。
	return &recorder{file: f, limit: uint32(recordSampleRate*2) * 3600}, nil
}

func (r *recorder) write(b []byte) {
	if r == nil || r.file == nil || r.truncated {
		return
	}
	if r.size >= r.limit {
		r.truncated = true
		return
	}
	n, e := r.file.Write(b)
	r.size += uint32(n)
	if e != nil {
		r.close()
	}
}

// close 回填 WAV 头并关闭文件；挂断、音频异常、服务停止都会调用。
func (r *recorder) close() {
	if r == nil || r.file == nil {
		return
	}
	writeWAVHeader(r.file, r.size, 1)
	r.file.Close()
	r.file = nil
}

// pair 是一通电话的两路录音，负责收尾合并与目录容量控制。
type pair struct {
	up   *recorder // 拨打：本机上行
	down *recorder // 接听：对方下行
	dir  string
	base string
}

func (p *pair) writeUp(b []byte) {
	if p != nil {
		p.up.write(b)
	}
}

func (p *pair) writeDown(b []byte) {
	if p != nil {
		p.down.write(b)
	}
}

func (p *pair) close() {
	if p == nil {
		return
	}
	p.up.close()
	p.down.close()
	if p.dir != "" && p.base != "" {
		mixWAV(filepath.Join(p.dir, p.base+"-合并.wav"),
			filepath.Join(p.dir, p.base+"-拨打.wav"),
			filepath.Join(p.dir, p.base+"-接听.wav"))
	}
	pruneRecordings(recordRoot, recordMaxByte)
}

// mixWAV 把上下行写成一个双声道文件：左声道本机（拨打），右声道对方（接听）。
// 较短的一侧按静音补齐；任一侧缺失也不报错，分轨原始文件保持可用。
func mixWAV(dst, up, down string) {
	// 读出的 PCM 不含 WAV 头，避免把 44 字节头当成音频混进结果。
	u, _ := readPCM(up)
	v, _ := readPCM(down)
	n := len(u)
	if len(v) > n {
		n = len(v)
	}
	n -= n % 2
	f, e := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_RDWR, 0600)
	if e != nil {
		return
	}
	f.Write(make([]byte, 44))
	buf := make([]byte, 0, 4096)
	var written uint32
	for i := 0; i+1 < n; i += 2 {
		a, b := int16(0), int16(0)
		if i+1 < len(u) {
			a = int16(binary.LittleEndian.Uint16(u[i:]))
		}
		if i+1 < len(v) {
			b = int16(binary.LittleEndian.Uint16(v[i:]))
		}
		var s [4]byte
		binary.LittleEndian.PutUint16(s[0:], uint16(a))
		binary.LittleEndian.PutUint16(s[2:], uint16(b))
		buf = append(buf, s[:]...)
		if len(buf) >= 4096 {
			f.Write(buf)
			written += uint32(len(buf))
			buf = buf[:0]
		}
	}
	if len(buf) > 0 {
		f.Write(buf)
		written += uint32(len(buf))
	}
	writeWAVHeader(f, written, 2)
	f.Close()
}

func readPCM(path string) ([]byte, error) {
	b, e := os.ReadFile(path)
	if e != nil {
		return nil, e
	}
	if len(b) <= 44 {
		return nil, nil
	}
	return b[44:], nil
}

func writeWAVHeader(f *os.File, data uint32, channels uint16) {
	h := make([]byte, 44)
	copy(h, "RIFF")
	binary.LittleEndian.PutUint32(h[4:], 36+data)
	copy(h[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(h[16:], 16)
	binary.LittleEndian.PutUint16(h[20:], 1)
	binary.LittleEndian.PutUint16(h[22:], channels)
	binary.LittleEndian.PutUint32(h[24:], recordSampleRate)
	binary.LittleEndian.PutUint32(h[28:], recordSampleRate*2*uint32(channels))
	binary.LittleEndian.PutUint16(h[32:], 2*uint16(channels))
	binary.LittleEndian.PutUint16(h[34:], 16)
	copy(h[36:], "data")
	binary.LittleEndian.PutUint32(h[40:], data)
	f.WriteAt(h, 0)
}

// pruneRecordings 控制录音目录总量：超过上限时按修改时间从最旧开始删除。
func pruneRecordings(root string, max int64) {
	var (
		files []string
		sizes []int64
		total int64
	)
	filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil || info.IsDir() {
			return nil
		}
		files = append(files, path)
		sizes = append(sizes, info.Size())
		total += info.Size()
		return nil
	})
	if max <= 0 || total <= max {
		return
	}
	idx := make([]int, len(files))
	for i := range idx {
		idx[i] = i
	}
	sort.Slice(idx, func(a, b int) bool {
		ai, bi := fileInfoTime(files[idx[a]]), fileInfoTime(files[idx[b]])
		if ai.Equal(bi) {
			return files[idx[a]] < files[idx[b]]
		}
		return ai.Before(bi)
	})
	for _, i := range idx {
		if total <= max {
			return
		}
		if os.Remove(files[i]) == nil {
			total -= sizes[i]
		}
	}
}

func fileInfoTime(path string) time.Time {
	if fi, e := os.Stat(path); e == nil {
		return fi.ModTime()
	}
	return time.Now()
}
