import AVFoundation
import Foundation

/// Convert the format actually delivered by the audio unit, never a pre-switch
/// input-node output format cached before Bluetooth hardware settled.
final class PCMInputConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private let destination: AVAudioFormat
    init() throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: false) else {
            throw APIError(message: "无法建立通话采音格式。")
        }
        destination = format
    }
    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else { return nil }
        if converter?.inputFormat.isEqual(buffer.format) != true {
            converter = AVAudioConverter(from: buffer.format, to: destination)
            converter?.primeMethod = .none
        }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: destination,
                  frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 8000 / buffer.format.sampleRate) + 64)) else { return nil }
        var provided = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if provided { state.pointee = .noDataNow; return nil }
            provided = true; state.pointee = .haveData; return buffer
        }
        guard failure == nil, status != .error, let channel = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: channel, count: Int(output.frameLength) * 2)
    }
}
