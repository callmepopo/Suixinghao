import Foundation
import os

/// Downlink jitter buffer (8 kHz mono). The network delivers 20 ms frames in bursts
/// (~100 ms batches seen in 10-14 logs); the old "≤10 scheduled buffers" rule counted
/// buffers until the late played-back callback and discarded 3-4% of the far voice.
/// Here the receiver pushes frames and the real-time render pulls exactly what the
/// hardware needs: bursts are absorbed, a short gap is faded instead of clicking,
/// and latency is bounded by trimming one old frame at a time only when the backlog
/// stays high. Only numbers leave this type.
///
/// Comfort noise: the module outputs near-digital silence (-80 dBFS) in 31-39% of a
/// call whenever the far end pauses (10-14 recordings), unlike a system call which
/// keeps a faint background. Those 0.3-1.2 s of dead air sound like the line dropped,
/// so near-silent frames and playback gaps are filled with soft noise that follows
/// the far end's own background level (-66…-54 dBFS).
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
    /// Frames below -70 dBFS count as dead air; -70…-45 dBFS is the far-end background.
    static let silenceRMS: Float = 0.000316, backgroundRMS: Float = 0.0056
    static let comfortMin: Float = 0.0005, comfortMax: Float = 0.002, comfortDefault: Float = 0.001

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
    private var noiseFloor = DownlinkJitter.comfortDefault
    private var seed: UInt32 = 0x9E37_79B9
    private var smooth: Float = 0

    init() { ring = .allocate(capacity: capacity); ring.initialize(repeating: 0, count: capacity) }
    deinit { ring.deallocate() }

    /// Frames handed to the hardware since the last reset.
    var totalPlayedFrames: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return total / Self.frame }
    var depthFrames: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return count / Self.frame }

    /// Forget queued audio (route change, call end); next playback prebuffers again.
    func reset() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        head = 0; count = 0; buffering = true; started = false; last = 0; total = 0
        noiseFloor = Self.comfortDefault; smooth = 0
        highSince = nil; lastPush = nil
    }

    private func eventLocked(_ kind: String, at: UInt64, value: UInt64) {
        if events.count < 16 { events.append(Event(kind: kind, at: at, value: value)) }
    }
    /// Soft low-passed noise with the given RMS; allocation-free for the render thread.
    private func noiseLocked(_ rms: Float) -> Float {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        let white = Float(Int32(bitPattern: seed)) / Float(Int32.max)
        smooth = 0.6 * smooth + 0.4 * white
        return smooth * rms / 0.289
    }
    private var comfortLevel: Float { min(Self.comfortMax, max(Self.comfortMin, noiseFloor)) }
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
        let rms = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(Self.frame)).squareRoot()
        let dead = rms < Self.silenceRMS
        if !dead && rms < Self.backgroundRMS { noiseFloor = 0.9 * noiseFloor + 0.1 * rms }
        var tail = (head + count) % capacity
        for sample in samples {
            ring[tail] = dead ? noiseLocked(comfortLevel) : sample
            tail += 1; if tail == capacity { tail = 0 }
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
        // Gap: fade the last sample out over 5 ms instead of a hard click, then comfort
        // noise once the call has audio (before the first frame stays silent).
        let missing = wanted - i
        if missing > 0 {
            if started { concealed += missing }
            var level = last
            let noise = started ? comfortLevel : 0
            while i < wanted {
                level *= 0.9; out[i] = level + (noise > 0 ? noiseLocked(noise) : 0); i += 1
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
