import Foundation

// Downlink playback against the arrival pattern measured on 2026-10-14 (frames reach
// the phone in ~100 ms batches with occasional 0.3-0.6 s stalls). The old rule counted
// a buffer as queued until its late played-back callback and dropped anything beyond
// 10, losing 3-4% of the far voice. Simulated; real-device sound still needs a call.

func check(_ value: Bool, _ name: String) {
    if !value { fputs("下行检查失败：" + name + "\n", stderr); exit(1) }
}

/// Arrival times (ms) of 20 ms frames: sent every 20 ms, delivered in 100 ms batches,
/// every 7th batch 60 ms late, plus stalls of 560 ms and 300 ms.
func arrivals(seconds: Int, stalls: Bool = true) -> [Int] {
    var out: [Int] = []
    for n in 0..<(seconds * 50) {
        let sent = n * 20
        var at = (sent / 100 + 1) * 100
        if (sent / 100) % 7 == 3 { at += 60 }
        if stalls && sent >= 20_000 && sent < 20_560 { at = 20_600 }
        if stalls && sent >= 40_000 && sent < 40_300 { at = 40_340 }
        out.append(at)
    }
    return out
}

/// Model of builds ≤53: AVAudioPlayerNode buffers, counter released `latency` ms after
/// the buffer finished playing (output latency + main-thread hop), cap 10.
func oldRule(_ times: [Int], latency: Int) -> (dropped: Int, total: Int) {
    var playEnd = 0, dropped = 0
    var releases: [Int] = []
    for t in times {
        releases.removeAll { $0 <= t }
        if releases.count >= 10 { dropped += 1; continue }
        let start = max(t, playEnd)
        playEnd = start + 20
        releases.append(playEnd + latency)
    }
    return (dropped, times.count)
}

func newRule(_ times: [Int], ioMs: Int) -> (lost: Int, underruns: Int, concealedMs: Int, peak: Int) {
    let jitter = DownlinkJitter()
    var frame = [Float](repeating: 0.25, count: 160)
    var lost = 0
    let out = UnsafeMutablePointer<Float>.allocate(capacity: 8 * ioMs); defer { out.deallocate() }
    var next = 0, underruns = 0, concealed = 0, peak = 0
    let end = (times.last ?? 0) + 30
    var ms = 0
    while ms <= end {
        while next < times.count && times[next] <= ms {
            frame[0] = Float(next % 100) / 1000
            jitter.push(frame, now: UInt64(ms) * 1_000_000); next += 1
        }
        if ms % ioMs == 0 { jitter.render(into: out, count: 8 * ioMs, now: UInt64(ms) * 1_000_000) }
        if ms % 1000 == 0 {
            let s = jitter.drain()
            lost += Int(s.counters["down_overflow_frames"]! + s.counters["down_trimmed_frames"]!)
            underruns += Int(s.counters["down_underruns"]!); concealed += Int(s.counters["down_concealed_samples"]!)
            peak = max(peak, Int(s.peaks["down_depth_peak_frames"]!))
        }
        ms += 1
    }
    return (lost, underruns, concealed / 8, peak)
}

@main struct DownlinkChecks {
    static func main() {
        let batches = arrivals(seconds: 60, stalls: false), stalled = arrivals(seconds: 60)
        for latency in [60, 120] {
            let old = oldRule(batches, latency: latency)
            print("旧规则（回调迟到\(latency)ms，常规成批到达）：丢弃 \(old.dropped)/\(old.total) 帧")
            check(old.dropped * 100 >= old.total * 2, "旧规则应复现约3%丢帧（负例，延迟\(latency)ms）")
        }
        let oldStalled = oldRule(stalled, latency: 60)
        for io in [10, 20] {
            let new = newRule(batches, ioMs: io)
            print("新缓冲（硬件每\(io)ms取一次，常规成批到达）：丢弃 \(new.lost) 帧，断流 \(new.underruns) 次/补静音 \(new.concealedMs)ms，最深 \(new.peak) 帧")
            check(new.lost == 0, "成批到达不丢对方声音")
            check(new.underruns <= 1 && new.concealedMs <= 80, "常规成批到达最多首次迟到时断流一次，之后缓冲自动加深")
            let hard = newRule(stalled, ioMs: io)
            print("新缓冲（含0.56s与0.3s停顿）：丢弃 \(hard.lost) 帧（旧规则 \(oldStalled.dropped) 帧），断流 \(hard.underruns) 次/补静音 \(hard.concealedMs)ms，最深 \(hard.peak) 帧")
            check(hard.lost <= 20 && hard.lost * 4 < oldStalled.dropped, "长停顿后只舍弃超出360ms的旧积压，远少于旧规则")
            check(hard.underruns <= 6 && hard.peak <= DownlinkJitter.maxFrames, "只在真实停顿时断流且积压有上限")
        }

        // Unit behaviour.
        let j = DownlinkJitter()
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 4000); defer { out.deallocate() }
        let one = [Float](repeating: 0.5, count: 160)
        j.push(one, now: 0); j.push(one, now: 20_000_000)
        j.render(into: out, count: 160, now: 30_000_000)
        check(out[0] == 0 && j.depthFrames == 2, "未攒够60ms前不开始播放")
        j.push(one, now: 40_000_000)
        j.render(into: out, count: 160, now: 50_000_000)
        check(out[0] == 0.5 && j.depthFrames == 2, "攒够后连续播放")
        j.render(into: out, count: 480, now: 60_000_000)
        check(out[319] == 0.5 && abs(out[320]) < 0.5 && abs(out[400]) < 0.01, "断流时淡出而不是硬切")
        var s = j.drain()
        check(s.counters["down_underruns"] == 1 && s.counters["down_concealed_samples"] == 160 && s.playedFrames == 3, "断流与补静音计数")
        for n in 0..<30 { j.push(one, now: UInt64(100 + n) * 1_000_000) }
        s = j.drain()
        check(j.depthFrames == DownlinkJitter.maxFrames && s.counters["down_overflow_frames"] == UInt64(30 - DownlinkJitter.maxFrames), "极端积压只丢最旧帧并封顶")
        // A backlog above 160 ms for 2 s loses exactly one old frame per 2 s.
        let k = DownlinkJitter()
        for n in 0..<10 { k.push(one, now: UInt64(n) * 1_000_000) }
        var t: UInt64 = 10_000_000
        for _ in 0..<250 {
            k.push(one, now: t); k.render(into: out, count: 160, now: t); t += 20_000_000
        }
        s = k.drain()
        let trims = s.counters["down_trimmed_frames"] ?? 0
        check(trims >= 2 && trims <= 5 && k.depthFrames <= DownlinkJitter.highFrames, "持续高积压每秒最多收回一帧，回到160ms以内")
        check(s.events.contains { $0.kind == "down_trim" } && s.level["samples"] == 260 * 160 && s.level["peak"] == 16384, "事件与音量只含数值")
        k.reset()
        check(k.depthFrames == 0 && k.totalPlayedFrames == 0, "切换设备或结束通话清空旧声音")
        k.render(into: out, count: 160, now: t)
        check(k.drain().counters["down_underruns"] == 0, "未开始播放的静音不算断流")

        // Diagnostics: new fields only reach servers that negotiated v3.
        let diagnostics = VoiceDiagnostics()
        let feed = DownlinkJitter()
        diagnostics.attachDownlink(feed); diagnostics.reset(now: 0)
        for n in 0..<3 { feed.push(one, now: UInt64(n) * 1_000_000) }
        feed.push(one, now: 200_000_000)
        feed.render(into: out, count: 960, now: 210_000_000)
        diagnostics.setContext("route_out", "BluetoothHFP"); diagnostics.setValue("input_rate", 16000)
        diagnostics.change("route_change", counter: "route_changes", value: 3)
        diagnostics.negotiate(true, version: 2)
        let v2 = diagnostics.snapshot(now: 300_000_000)
        check(v2["version"] as? Int == 2 && v2["context"] == nil && v2["down_underruns"] == nil && v2["input_rate"] == nil, "v2服务不收到新字段")
        check((v2["events"] as! [[String: Any]]).allSatisfy { !["down_gap", "route_change"].contains($0["kind"] as! String) }, "v2服务不收到新事件")
        check(v2["down_played_frames"] as? UInt64 == 4, "旧字段继续统计实际播放帧")
        diagnostics.negotiate(true, version: 3)
        let v3 = diagnostics.snapshot(now: 300_000_000)
        let kinds = (v3["events"] as! [[String: Any]]).map { $0["kind"] as! String }
        check(v3["version"] as? Int == 3 && (v3["context"] as? [String: String])?["route_out"] == "BluetoothHFP" && v3["input_rate"] as? UInt64 == 16000, "v3带路由与采样率")
        check(v3["down_underruns"] as? UInt64 == 1 && v3["route_changes"] as? UInt64 == 1 && kinds.contains("down_gap") && kinds.contains("route_change"), "v3带下行断流、到达间隔与切换时间线")
        check((v3["down_level"] as? [String: UInt64])?["samples"] == 640, "v3带对方声音音量")
        for _ in 0..<40 { diagnostics.captureEvent("capture_drop", value: 1); diagnostics.change("net_change", counter: "net_changes", value: 1) }
        check((diagnostics.snapshot(now: 400_000_000)["events"] as! [[String: Any]]).count == 16, "事件总数不超过服务端上限16")
        print("通过：下行抖动缓冲（模拟实测到达节奏，旧规则失败/新缓冲不丢帧）、淡出补静音、积压上限与缓慢收回、v3诊断字段与旧服务兼容（模拟，未证明真机声音）")
    }
}
