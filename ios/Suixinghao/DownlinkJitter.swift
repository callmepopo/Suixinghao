import Foundation
import os

/// Downlink jitter buffer (8 kHz mono). The network delivers 20 ms frames in bursts
/// (~100 ms batches seen in 10-14 logs); the old "≤10 scheduled buffers" rule counted
/// buffers until the late played-back callback and discarded 3-4% of the far voice.
/// Here the receiver pushes frames and the real-time render pulls exactly what the
/// hardware needs: bursts are absorbed, a short gap is faded instead of clicking,
/// and latency is bounded by trimming one old frame at a time only when the backlog
/// stays high. Only numbers leave this type.
final class DownlinkJitter: @unchecked Sendable {
    static let frame = 160
    /// Playback (re)starts after 60 ms is buffered.
    static let prebufferFrames = 3
    /// A backlog above 160 ms for 1 s loses one old frame, keeping delay bounded.
    static let highFrames = 8
    static let highNanos: UInt64 = 1_000_000_000
    /// Hard ceiling (360 ms): a burst beyond it drops the oldest frame immediately.
    static let maxFrames = 18
    static let gapEventNanos: UInt64 = 80_000_000

    struct Event { let kind: String; let at: UInt64; let value: UInt64 }

    private var lock = os_unfair_lock()
    private let capacity = DownlinkJitter.frame * (DownlinkJitter.maxFrames + 2)
    private let ring: UnsafeMutablePointer<Float>
    private var head = 0, count = 0
    private var buffering = true, started = false
    private var last: Float = 0
    private var highSince: UInt64?
    private var lastPush: UInt64?
    // Counters since the last drain.
    private var total = 0
    private var played = 0, underruns = 0, concealed = 0, overflow = 0, trimmed = 0
    private var depthPeak = 0, gapMax: UInt64 = 0
    private var squares: Double = 0, levelSamples = 0, levelPeak = 0, levelQuiet = 0, levelClipped = 0
    private var events: [Event] = []

    init() { ring = .allocate(capacity: capacity); ring.initialize(repeating: 0, count: capacity) }
    deinit { ring.deallocate() }

    /// Frames handed to the hardware since the last reset.
    var totalPlayedFrames: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return total / Self.frame }
    var depthFrames: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return count / Self.frame }

    /// Forget queued audio (route change, call end); next playback prebuffers again.
    func reset() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        head = 0; count = 0; buffering = true; started = false; last = 0; total = 0
        highSince = nil; lastPush = nil
    }

    private func eventLocked(_ kind: String, at: UInt64, value: UInt64) {
        if events.count < 16 { events.append(Event(kind: kind, at: at, value: value)) }
    }
    private func dropOldestLocked() {
        head = (head + Self.frame) % capacity; count -= Self.frame
    }

    func push(_ samples: [Float], now: UInt64) {
        guard samples.count == Self.frame else { return }
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if let lastPush, now > lastPush {
            let gap = now - lastPush
            gapMax = max(gapMax, gap / 1000)
            if gap >= Self.gapEventNanos { eventLocked("down_gap", at: now, value: gap / 1000) }
        }
        lastPush = now
        if count + Self.frame > Self.maxFrames * Self.frame {
            dropOldestLocked(); overflow += 1
            eventLocked("down_trim", at: now, value: UInt64(Self.maxFrames))
        }
        var tail = (head + count) % capacity
        for sample in samples {
            ring[tail] = sample; tail += 1; if tail == capacity { tail = 0 }
            let magnitude = Int(min(32768, abs(sample) * 32768))
            squares += Double(magnitude * magnitude); levelPeak = max(levelPeak, magnitude)
            if magnitude < 104 { levelQuiet += 1 }
            if magnitude >= 32760 { levelClipped += 1 }
        }
        levelSamples += Self.frame
        count += Self.frame
        let depth = count / Self.frame
        depthPeak = max(depthPeak, depth)
        if depth > Self.highFrames {
            if let since = highSince {
                if now - since >= Self.highNanos {
                    dropOldestLocked(); trimmed += 1; highSince = now
                    eventLocked("down_trim", at: now, value: UInt64(depth))
                }
            } else { highSince = now }
        } else { highSince = nil }
        if buffering && depth >= Self.prebufferFrames { buffering = false }
    }

    /// Real-time render: never allocates or blocks beyond the short unfair lock.
    func render(into out: UnsafeMutablePointer<Float>, count wanted: Int, now: UInt64) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        var i = 0
        if !buffering {
            let take = min(wanted, count)
            while i < take {
                out[i] = ring[head]; head += 1; if head == capacity { head = 0 }
                i += 1
            }
            count -= take; played += take; total += take
            if take > 0 { last = out[take - 1]; started = true }
            if take < wanted {
                buffering = true
                underruns += 1
                eventLocked("down_underrun", at: now, value: UInt64(wanted - take))
            }
        }
        // Gap: fade the last sample out over 5 ms instead of a hard click, then silence.
        let missing = wanted - i
        if missing > 0 {
            if started { concealed += missing }
            var level = last
            while i < wanted {
                level *= 0.9; out[i] = level; i += 1
            }
            last = 0
        }
    }

    struct Snapshot {
        var playedFrames: UInt64
        var counters: [String: UInt64]
        var peaks: [String: UInt64]
        var level: [String: UInt64]
        var events: [Event]
    }
    /// Counters since the previous drain; the caller accumulates them.
    func drain() -> Snapshot {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let rms = levelSamples == 0 ? 0 : UInt64(sqrt(squares / Double(levelSamples)))
        let frames = played / Self.frame
        let snapshot = Snapshot(
            playedFrames: UInt64(frames),
            counters: ["down_underruns": UInt64(underruns), "down_concealed_samples": UInt64(concealed),
                       "down_overflow_frames": UInt64(overflow), "down_trimmed_frames": UInt64(trimmed)],
            peaks: ["down_depth_peak_frames": UInt64(depthPeak), "down_arrival_gap_max_us": gapMax],
            level: ["samples": UInt64(levelSamples), "rms": rms, "peak": UInt64(levelPeak),
                    "quiet_samples": UInt64(levelQuiet), "clipped_samples": UInt64(levelClipped)],
            events: events)
        played -= frames * Self.frame; underruns = 0; concealed = 0; overflow = 0; trimmed = 0
        depthPeak = count / Self.frame; gapMax = 0
        squares = 0; levelSamples = 0; levelPeak = 0; levelQuiet = 0; levelClipped = 0
        events.removeAll(keepingCapacity: true)
        return snapshot
    }
}
