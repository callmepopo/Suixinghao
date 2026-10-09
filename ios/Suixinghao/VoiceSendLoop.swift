import Foundation
import OSLog

/// Absolute monotonic deadlines: send cost never gets added to the 20 ms period.
struct VoicePacer {
    static let period: UInt64 = 20_000_000
    private(set) var deadline: UInt64
    init(now: UInt64) { deadline = now }
    mutating func advance(after now: UInt64, sentAt: UInt64? = nil) -> UInt64 {
        deadline += Self.period
        // Normal scheduler jitter may shorten one interval; never send back-to-back.
        let cutoff = max(now, sentAt.map { $0 + 10_000_000 - 1 } ?? now)
        guard cutoff >= deadline else { return 0 }
        let missed = (cutoff - deadline) / Self.period + 1
        deadline += missed * Self.period
        return missed
    }
}

/// Only numeric metadata is retained. Shared with the audio tap and playback callback.
final class VoiceDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var supported = false
    private var id = UUID().uuidString
    private var started: UInt64 = 0
    private var reported: UInt64 = 0
    private var previousSend: UInt64?
    private var counts: [String: UInt64] = [:]
    private static let logger = Logger(subsystem: "com.junpo.suixinghao", category: "audio")
    func negotiate(_ enabled: Bool) { lock.lock(); supported = enabled; lock.unlock() }
    @discardableResult func reset(now: UInt64) -> String {
        lock.lock(); defer { lock.unlock() }
        id = UUID().uuidString; started = now; reported = now
        previousSend = nil; counts.removeAll(keepingCapacity: true)
        return id
    }
    func add(_ name: String, _ amount: UInt64 = 1) {
        lock.lock(); counts[name, default: 0] += amount; lock.unlock()
    }
    func peak(_ name: String, _ value: UInt64) {
        lock.lock(); counts[name] = max(counts[name, default: 0], value); lock.unlock()
    }
    func sent(start: UInt64, end: UInt64, segment: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let segment, segment != id { return }
        counts["sent_frames", default: 0] += 1
        let duration = (end - start) / 1000
        counts["send_us_total", default: 0] += duration
        counts["send_us_max"] = max(counts["send_us_max", default: 0], duration)
        if let previousSend {
            let interval = (start - previousSend) / 1000
            counts["interval_us_total", default: 0] += interval
            counts["interval_count", default: 0] += 1
            counts["interval_us_max"] = max(counts["interval_us_max", default: 0], interval)
        }
        previousSend = start
    }
    func snapshot(now: UInt64) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked(now: now)
    }
    private func snapshotLocked(now: UInt64) -> [String: Any] {
        var value: [String: Any] = counts.mapValues { $0 as Any }
        value["type"] = "audio_stats"; value["version"] = 1
        value["segment"] = id; value["elapsed_ms"] = (max(now, started) - started) / 1_000_000
        return value
    }
    func report(now: UInt64, final: Bool = false, segment: String? = nil) -> String? {
        lock.lock()
        if let segment, segment != id { lock.unlock(); return nil }
        let due = final || max(now, reported) - reported >= 5_000_000_000
        let upload = supported
        let value = due ? snapshotLocked(now: now) : nil
        if due { reported = now }
        lock.unlock()
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        Self.logger.info("\(text, privacy: .public)")
        return upload ? text : nil
    }
}

enum VoiceSendLoop {
    static func run(socket: URLSessionWebSocketTask, frames: PCMFrames) async throws {
        try Task.checkCancellation()
        let now = DispatchTime.now().uptimeNanoseconds
        let segment = frames.diagnostics.reset(now: now)
        var pacer = VoicePacer(now: now)
        defer { _ = frames.diagnostics.report(now: DispatchTime.now().uptimeNanoseconds, final: true, segment: segment) }
        while !Task.isCancelled {
            try Task.checkCancellation()
            let start = DispatchTime.now().uptimeNanoseconds
            try await socket.send(.data(frames.next()))
            frames.diagnostics.sent(start: start, end: DispatchTime.now().uptimeNanoseconds, segment: segment)
            try Task.checkCancellation()
            if let report = frames.diagnostics.report(now: DispatchTime.now().uptimeNanoseconds) {
                try Task.checkCancellation()
                try await socket.send(.string(report))
            }
            try Task.checkCancellation()
            let end = DispatchTime.now().uptimeNanoseconds
            frames.diagnostics.add("missed_slots", pacer.advance(after: end, sentAt: start))
            let current = DispatchTime.now().uptimeNanoseconds
            if pacer.deadline > current { try await Task.sleep(nanoseconds: pacer.deadline - current) }
        }
    }
}
