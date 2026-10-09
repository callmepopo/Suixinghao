package main

import (
	"context"
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// TestManualAudioLoop 在 Unraid 上脱离电话验证音频循环：
// 启动模块音频路由 → 本地 WebSocket 模拟浏览器 → 运行 runAudio → 报告上下行帧数。
// 只在显式指定 -run TestManualAudioLoop 时执行，且需要 Linux/Unraid 环境（arecord/aplay/ADB）。
func TestManualAudioLoop(t *testing.T) {
	if os.Getenv("VOICE_WEB_MANUAL_AUDIO") != "1" {
		t.Skip("手动测试：需在 Unraid 上设置 VOICE_WEB_MANUAL_AUDIO=1 并显式 -run TestManualAudioLoop")
	}
	const seconds = 8
	t.Log("1) 启动模块音频路由…")
	if e := moduleRoute("start"); e != nil {
		t.Fatalf("模块路由启动失败: %v", e)
	}
	defer func() {
		t.Log("6) 释放模块音频路由…")
		if e := moduleRoute("stop"); e != nil {
			t.Logf("释放失败: %v", e)
		}
	}()

	t.Log("2) 创建录音…")
	rec, e := newPair(recordRoot, recordingInfo{Peer: "0000", Direction: "拨打"})
	if e != nil {
		t.Logf("录音创建失败: %v", e)
	} else {
		t.Logf("录音: %s/%s*", rec.dir, rec.base)
	}

	up := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	connCh := make(chan *websocket.Conn, 1)
	srv := &http.Server{Addr: "127.0.0.1:7599", Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, e := up.Upgrade(w, r, nil)
		if e == nil {
			connCh <- c
		}
	})}
	go srv.ListenAndServe()
	time.Sleep(300 * time.Millisecond)

	t.Log("3) 连接本地 WebSocket…")
	c, _, e := websocket.DefaultDialer.Dial("ws://127.0.0.1:7599/", nil)
	if e != nil {
		t.Fatalf("连接失败: %v", e)
	}
	defer c.Close()
	srvConn := <-connCh
	defer srvConn.Close()

	mic := make(chan []byte, 8)
	ctx, cancel := context.WithTimeout(context.Background(), seconds*time.Second)
	defer cancel()

	// runAudio 以 call.active 为闸门：标记不存在会立刻退出，必须先写好。
	run := recordingName(time.Now(), "0000", "拨打")
	if e := mediaOn(run); e != nil {
		t.Fatalf("写 call.active 失败: %v", e)
	}
	defer mediaOff()

	t.Log("4) 运行音频循环 + 注入帧…")
	done := make(chan error, 1)
	go func() {
		stats := &audioStats{}
		stats.begin(run)
		e := runAudio(ctx, srvConn, mic, run, rec, stats)
		t.Logf("runAudio 返回: %v", e)
		done <- e
	}()
	downMsgs := make(chan int, 1)
	go func() {
		n := 0
		for ctx.Err() == nil {
			srvConn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
			if _, _, e := srvConn.ReadMessage(); e != nil {
				break // 出错即退出，避免对已失败连接重复读取
			}
			n++
		}
		downMsgs <- n
	}()

	for i := 0; i < seconds/2; i++ {
		time.Sleep(2 * time.Second)
		t.Logf("   t+%ds 上行=%d 下行=%d", (i+1)*2, framesUp(), framesDown())
	}
	cancel()
	<-done
	msgs := <-downMsgs
	if rec != nil {
		rec.close()
	}
	t.Logf("结果：上行帧=%d 下行帧=%d 下行消息=%d", framesUp(), framesDown(), msgs)
	if framesUp() == 0 {
		t.Error("音频循环没有跑起来（上行帧为 0，arecord/aplay 可能打开失败）")
	} else if framesDown() == 0 {
		t.Log("上行正常但没有回传：模块未把通话音频送到 USB（无真实通话时属预期）")
	}
}
