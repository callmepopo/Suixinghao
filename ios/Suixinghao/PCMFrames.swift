import AVFoundation
import Foundation

/// 8 kHz / S16_LE / mono, bounded to 200 ms. Never retain stale speech.
final class PCMFrames: @unchecked Sendable {
    static let frameBytes = 320
    let diagnostics = VoiceDiagnostics()
    private let lock = NSLock()
    private var pending = Data()
    private var enabled = false
    private var muted = false
    #if DEBUG
    private var capturedBytes = 0
    private var nonzeroSamples = 0
    private var tapBuffers = 0
    private var tapNonzero = 0
    private var conversionFailures = 0
    func captureStats() -> (bytes: Int, nonzero: Int, taps: Int, inputNonzero: Int, failures: Int) {
        lock.lock(); defer { lock.unlock() }
        return (capturedBytes, nonzeroSamples, tapBuffers, tapNonzero, conversionFailures)
    }
    func noteInput(_ buffer: AVAudioPCMBuffer) {
        let nonzero: Int
        if let channel = buffer.floatChannelData?[0] {
            nonzero = (0..<Int(buffer.frameLength)).reduce(0) { $0 + (abs(channel[$1]) > 0.0001 ? 1 : 0) }
        } else { nonzero = 0 }
        lock.lock(); tapBuffers += 1; tapNonzero += nonzero; lock.unlock()
    }
    func noteConversionFailure() {
        lock.lock(); conversionFailures += 1; lock.unlock()
    }
    #endif
    func enable(_ value: Bool) {
        setState(active: value, muted: false)
    }
    func setState(active: Bool, muted: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.muted = active && muted
        enabled = active && !muted
        if !enabled { pending.removeAll(keepingCapacity: true) }
    }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        #if DEBUG
        capturedBytes += data.count
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: data.count - 1, by: 2) {
                if raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self) != 0 { nonzeroSamples += 1 }
            }
        }
        #endif
        pending.append(data)
        diagnostics.add("captured_samples", UInt64(data.count / 2))
        diagnostics.peak("capture_queue_peak_samples", UInt64(min(pending.count, Self.frameBytes * 10) / 2))
        let maximum = Self.frameBytes * 10
        if pending.count > maximum {
            let excess = pending.count - maximum
            let dropped = excess + excess % 2
            pending.removeFirst(dropped)
            diagnostics.add("capture_dropped_samples", UInt64(dropped / 2))
            diagnostics.captureEvent("capture_drop", value: UInt64(dropped / 2))
        }
    }
    func next() -> Data {
        lock.lock(); defer { lock.unlock() }
        guard enabled else {
            diagnostics.add(muted ? "muted_silence_frames" : "waiting_silence_frames")
            return Data(repeating: 0, count: Self.frameBytes)
        }
        guard pending.count >= Self.frameBytes else {
            diagnostics.add("capture_underfill_frames")
            diagnostics.captureEvent("capture_underfill", value: UInt64(pending.count / 2))
            return Data(repeating: 0, count: Self.frameBytes)
        }
        let frame = Data(pending.prefix(Self.frameBytes))
        pending.removeFirst(Self.frameBytes)
        diagnostics.level(frame)
        return frame
    }
    static func floatSamples(_ data: Data) -> [Float]? {
        guard data.count == frameBytes else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<160).map { index in
                let bits = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))
                return Float(Int16(bitPattern: bits)) / 32768
            }
        }
    }
}
