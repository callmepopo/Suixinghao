import Foundation

@main struct AudioChecks {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Native audio check failed: \((error as NSError).domain):\((error as NSError).code) \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        func check(_ value: Bool, _ name: String) throws {
            if !value { throw APIError(message: "音频检查失败：" + name) }
        }
        for cost in [UInt64(0), 3_000_000, 8_000_000] {
            var p = VoicePacer(now: 0); var count = 0
            while p.deadline < 60_000_000_000 {
                let slot = p.deadline
                try check(p.advance(after: slot + cost) == 0, "正常发送耗时不丢节拍")
                count += 1
            }
            try check(count == 3000 && p.deadline == 60_000_000_000, "60秒固定节拍不随发送耗时漂移")
        }
        var p = VoicePacer(now: 0)
        try check(p.advance(after: 85_000_000) == 4 && p.deadline == 100_000_000, "阻塞跳过旧节拍且不集中补发")
        try check(p.advance(after: 103_000_000) == 0 && p.deadline == 120_000_000, "阻塞后恢复固定时间轴")
        var delayed = VoicePacer(now: 0)
        _ = delayed.advance(after: 1_000_000)
        try check(delayed.advance(after: 41_000_000) == 1 && delayed.deadline == 60_000_000, "调度迟到不追发")
        var nearlyLate = VoicePacer(now: 0)
        _ = nearlyLate.advance(after: 1_000_000)
        try check(nearlyLate.advance(after: 39_500_000, sentAt: 39_000_000) == 1 && nearlyLate.deadline == 60_000_000, "接近下一节拍唤醒也不连续追发")
        let frames = PCMFrames(); frames.diagnostics.reset(now: 0)
        _ = frames.next()
        frames.setState(active: true, muted: true); _ = frames.next()
        frames.setState(active: true, muted: false); _ = frames.next()
        frames.append(Data(repeating: 1, count: 6400)); _ = frames.next()
        let stats = frames.diagnostics.snapshot(now: 1_000_000)
        try check(stats["waiting_silence_frames"] as? UInt64 == 1 && stats["muted_silence_frames"] as? UInt64 == 1 && stats["capture_underfill_frames"] as? UInt64 == 1, "等待、静音与采集不足分开计数")
        try check(stats["capture_dropped_samples"] as? UInt64 == 1600 && stats["capture_queue_peak_samples"] as? UInt64 == 1600, "200ms缓冲上限与丢弃量")
        frames.diagnostics.sent(start: 2_000_000, end: 5_000_000)
        frames.diagnostics.sent(start: 22_000_000, end: 24_000_000)
        let sent = frames.diagnostics.snapshot(now: 30_000_000)
        try check(sent["interval_us_max"] as? UInt64 == 20000 && sent["send_us_total"] as? UInt64 == 5000, "发送间隔与耗时统计")
        let old = sent["segment"] as! String
        frames.diagnostics.reset(now: 40_000_000)
        try check(frames.diagnostics.snapshot(now: 40_000_000)["sent_frames"] == nil, "新连接计数清零")
        try check(frames.diagnostics.report(now: 41_000_000, final: true, segment: old) == nil, "旧任务结束不汇总新连接")
        print("通过：固定20ms节拍、阻塞跳过、静音分类、缓冲丢弃与连接计数隔离")
        guard let i = CommandLine.arguments.firstIndex(of: "--loopback"), CommandLine.arguments.count > i + 2,
              let base = URL(string: CommandLine.arguments[i+1]), base.host == "127.0.0.1", base.scheme == "http", let seconds = Double(CommandLine.arguments[i+2]), seconds > 0, seconds <= 120 else { return }
        let transport = VoiceTransport(); let silence = PCMFrames()
        var failure = false; transport.onFailure = { _ in failure = true }
        fputs("Native loopback: connecting\n", stderr)
        try await transport.connect(base: base, token: "local-test")
        transport.startSending(silence); transport.startSending(silence)
        fputs("Native loopback: sending\n", stderr)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try check(!failure && transport.ready, "本机声音连接保持")
        let finalStats = silence.diagnostics.snapshot(now: DispatchTime.now().uptimeNanoseconds)
        if let data = try? JSONSerialization.data(withJSONObject: finalStats, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        transport.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        let ended = silence.diagnostics.snapshot(now: DispatchTime.now().uptimeNanoseconds)["sent_frames"] as? UInt64
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(silence.diagnostics.snapshot(now: DispatchTime.now().uptimeNanoseconds)["sent_frames"] as? UInt64 == ended, "关闭立即停止发送")
        try await transport.connect(base: base, token: "local-test")
        transport.startSending(silence)
        try await Task.sleep(nanoseconds: 200_000_000)
        try check((silence.diagnostics.snapshot(now: DispatchTime.now().uptimeNanoseconds)["sent_frames"] as? UInt64 ?? 999) < 20, "重连不继承旧计数或旧发送任务")
        transport.close()
        print("通过：真实本机WebSocket、重复启动、取消与重连隔离（未启用麦克风）")
    }
}
