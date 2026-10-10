import AVFoundation
import Foundation

@MainActor
final class VoiceAudio {
    let outgoing = PCMFrames()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var waitingPlayer: AVAudioPlayerNode?
    private var waitingTone = false
    #if DEBUG
    var isWaitingTone: Bool { waitingTone }
    #endif
    private var playbackFormat: AVAudioFormat?
    private var scheduled = 0
    private var generation = UUID()
    private var routeRecovery = UUID()
    private var observers: [NSObjectProtocol] = []
    var onInterrupted: (() -> Void)?
    var onSpeakerChanged: ((Bool) -> Void)?
    private(set) var muted = false
    private var earlyMedia = false
    private var active = false
    var isActiveCall: Bool { active }
    var isEngineRunning: Bool { engine?.isRunning == true }
    private var tapInstalled = false
    private(set) var callKitManaged = false
    private(set) var receivedFrames = 0
    private(set) var playedBuffers = 0
    private(set) var peak: Float = 0

    #if DEBUG
    /// Acceptance uses real downlink playback and silence uplink, never the mic.
    func startPlaybackTest() throws {
        guard engine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        let graph = AVAudioEngine()
        let output = AVAudioPlayerNode()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false) else { throw APIError(message: "无法建立测试音频格式。") }
        graph.attach(output); graph.connect(output, to: graph.mainMixerNode, format: format)
        attachWaitingPlayer(to: graph, format: format)
        graph.prepare()
        do { try graph.start() } catch { try? session.setActive(false, options: .notifyOthersOnDeactivation); throw error }
        output.play()
        engine = graph; player = output; playbackFormat = format
        earlyMedia = false; active = false; muted = false; outgoing.enable(false)
        generation = UUID(); receivedFrames = 0; playedBuffers = 0; peak = 0
    }
    #endif
    func start(useSpeaker: Bool? = nil, callKitManaged: Bool = false) async throws {
        guard engine == nil else { return }
        let attempt = generation
        let granted = await AVAudioApplication.requestRecordPermission()
        guard generation == attempt else { throw CancellationError() }
        guard granted else { throw APIError(message: "请在系统设置中允许随行号使用麦克风后再拨号。") }
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if useSpeaker == true { options.insert(.defaultToSpeaker) }
        if !callKitManaged {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        }
        // CallKit may already have applied the user's system speaker selection.
        // Only explicit in-app choices override it; initial managed startup preserves it.
        if let useSpeaker {
            try session.overrideOutputAudioPort(useSpeaker ? .speaker : .none)
        } else if !callKitManaged {
            try session.overrideOutputAudioPort(.none)
        }
        let graph = AVAudioEngine()
        do {
            let output = AVAudioPlayerNode()
            let inputFormat = graph.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let uplinkFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: false),
                  let downlinkFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inputFormat, to: uplinkFormat) else {
                throw APIError(message: "当前音频设备无法建立通话通道。")
            }
            converter.primeMethod = .none
            graph.attach(output)
            graph.connect(output, to: graph.mainMixerNode, format: downlinkFormat)
            attachWaitingPlayer(to: graph, format: downlinkFormat)
            let frames = outgoing
            graph.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                #if DEBUG
                frames.noteInput(buffer)
                #endif
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 8000 / inputFormat.sampleRate) + 64)
                guard let converted = AVAudioPCMBuffer(pcmFormat: uplinkFormat, frameCapacity: capacity) else { return }
                var provided = false
                var failure: NSError?
                let status = converter.convert(to: converted, error: &failure) { _, state in
                    if provided { state.pointee = .noDataNow; return nil }
                    provided = true; state.pointee = .haveData; return buffer
                }
                if failure == nil, status != .error, let channel = converted.int16ChannelData?[0] {
                    frames.append(Data(bytes: channel, count: Int(converted.frameLength) * 2))
                } else {
                    #if DEBUG
                    frames.noteConversionFailure()
                    #endif
                }
            }
            tapInstalled = true
            engine = graph; player = output; playbackFormat = downlinkFormat
            self.callKitManaged = callKitManaged
            earlyMedia = false; active = false; muted = false; outgoing.enable(false)
            generation = UUID(); receivedFrames = 0; playedBuffers = 0; peak = 0
            observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.onInterrupted?() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor in
                    self?.reportSpeakerRoute()
                    if raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                        self?.onInterrupted?()
                    }
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: graph, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.resumeAfterConfigurationChange(graph) }
            })
            graph.prepare()
            try graph.start()
            output.play()
            try await Task.sleep(nanoseconds: 120_000_000)
            guard engine === graph else { throw CancellationError() }
            if !graph.isRunning { try graph.start(); output.play() }
            reportSpeakerRoute()
        } catch {
            // A hangup may have stopped this graph while startup was suspended.
            guard engine === graph || engine == nil else { throw error }
            observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
            if tapInstalled { graph.inputNode.removeTap(onBus: 0); tapInstalled = false }
            graph.stop()
            waitingPlayer?.stop(); waitingPlayer = nil; waitingTone = false
            engine = nil; player = nil; playbackFormat = nil
            self.callKitManaged = false
            if !callKitManaged { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
            throw error
        }
    }
    private func reportSpeakerRoute() {
        let speaker = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        onSpeakerChanged?(speaker)
    }
    func setSpeaker(_ enabled: Bool) throws {
        guard engine != nil else { throw APIError(message: "声音通道尚未就绪。") }
        // Preserve CallKit activation and the existing input tap/converter.
        // The configuration-change observer resumes the same graph if iOS pauses it.
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        reportSpeakerRoute()
    }
    private func resumeAfterConfigurationChange(_ graph: AVAudioEngine) async {
        // iOS can consume queued buffers while rebuilding the output route without playing them.
        // Drop that queue after the route settles, then resume new incoming frames.
        let attempt = UUID()
        routeRecovery = attempt
        try? await Task.sleep(nanoseconds: 160_000_000)
        guard engine === graph, routeRecovery == attempt else { return }
        do {
            generation = UUID()
            scheduled = 0
            player?.stop()
            if !graph.isRunning { try graph.start() }
            player?.play()
            reportSpeakerRoute()
        }
        catch { onInterrupted?() }
    }
    private func attachWaitingPlayer(to graph: AVAudioEngine, format: AVAudioFormat) {
        let node = AVAudioPlayerNode()
        graph.attach(node); graph.connect(node, to: graph.mainMixerNode, format: format)
        waitingPlayer = node
    }
    func setWaitingTone(_ value: Bool) {
        guard waitingTone != value else { return }
        waitingTone = value
        waitingPlayer?.stop()
        guard value, !active, let waitingPlayer, let format = playbackFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = 16000
        // A soft 0.4s local waiting beep followed by silence; never uplink audio.
        for i in 0..<16000 {
            let envelope = i < 3200 ? min(1, Double(i) / 80) * min(1, Double(3200 - i) / 80) : 0
            samples[i] = Float(sin(Double(i) * 2 * Double.pi * 440 / 8000) * 0.08 * envelope)
        }
        waitingPlayer.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        waitingPlayer.play()
    }
    func setEarlyMedia(_ value: Bool) { earlyMedia = value }
    func setActiveCall(_ value: Bool) {
        if value { setWaitingTone(false) }
        active = value; outgoing.setState(active: value, muted: muted)
    }
    func setMuted(_ value: Bool) {
        muted = value; outgoing.setState(active: active, muted: value)
    }
    func play(_ data: Data) {
        guard let samples = PCMFrames.floatSamples(data) else { return }
        receivedFrames += 1
        outgoing.diagnostics.add("down_received_frames")
        peak = max(peak, samples.map { abs($0) }.max() ?? 0)
        guard active || earlyMedia else { outgoing.diagnostics.add("down_inactive_frames"); return }
        if scheduled >= 10 { outgoing.diagnostics.add("down_dropped_frames"); return }
        guard scheduled < 10,
              let format = playbackFormat, let player,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
              let target = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = 160
        for i in 0..<160 { target[i] = samples[i] }
        scheduled += 1
        outgoing.diagnostics.peak("playback_queue_peak_frames", UInt64(scheduled))
        let run = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.scheduled = max(0, self.scheduled - 1)
                self.playedBuffers += 1
                self.outgoing.diagnostics.add("down_played_frames")
            }
        }
    }
    #if DEBUG
    func playTestTone() throws {
        guard let format = playbackFormat, let player,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000),
              let samples = buffer.floatChannelData?[0] else {
            throw APIError(message: "测试音频通道尚未就绪。")
        }
        buffer.frameLength = 8000
        for index in 0..<8000 {
            samples[index] = Float(sin(Double(index) * 2 * Double.pi * 440 / 8000) * 0.2)
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.playedBuffers += 1 }
        }
    }
    #endif
    func stop(deactivateSession: Bool = true) {
        setWaitingTone(false); waitingPlayer?.stop(); waitingPlayer = nil
        let managedByCallKit = callKitManaged
        callKitManaged = false
        outgoing.enable(false); earlyMedia = false; active = false; muted = false
        routeRecovery = UUID()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        generation = UUID(); scheduled = 0
        let wasRunning = engine != nil
        if let engine { if tapInstalled { engine.inputNode.removeTap(onBus: 0) }; engine.stop() }
        tapInstalled = false
        player?.stop(); player = nil; engine = nil; playbackFormat = nil
        if wasRunning && deactivateSession && !managedByCallKit { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
