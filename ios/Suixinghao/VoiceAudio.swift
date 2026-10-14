import AVFoundation
import Foundation
import os

/// One in-call sound device. Bluetooth ids hold the port UID only in memory.
struct CallAudioRoute: Identifiable, Equatable {
    static let receiver = "receiver", speaker = "speaker"
    let id: String
    let name: String
    let symbol: String
}

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
    /// Set while Bluetooth calling is temporarily disabled to reach the receiver.
    private var phoneOnly: (mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)?
    /// Bluetooth devices stay selectable while phoneOnly hides them from availableInputs.
    private var knownDevices: [CallAudioRoute] = []
    private var routeTask: Task<Void, Never>?
    /// Port types only (no names, ids, numbers); read with `log collect` when debugging routes.
    private let routeLog = Logger(subsystem: "com.junpo.suixinghao", category: "audio-route")
    private var observers: [NSObjectProtocol] = []
    /// Device changes never end the call; failures only surface a message.
    var onAudioStatusChanged: ((String?) -> Void)?
    var onSpeakerChanged: ((Bool) -> Void)?
    var onRoutesChanged: (([CallAudioRoute], String, String) -> Void)?
    private var capture: PCMInputConverter?
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
            guard let downlinkFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false) else {
                throw APIError(message: "当前音频设备无法建立通话通道。")
            }
            graph.attach(output)
            graph.connect(output, to: graph.mainMixerNode, format: downlinkFormat)
            attachWaitingPlayer(to: graph, format: downlinkFormat)
            capture = try PCMInputConverter()
            try installCapture(on: graph)
            engine = graph; player = output; playbackFormat = downlinkFormat
            self.callKitManaged = callKitManaged
            earlyMedia = false; active = false; muted = false; outgoing.enable(false)
            generation = UUID(); receivedFrames = 0; playedBuffers = 0; peak = 0
            observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                // Pause on began; CallKit/system decides the call. Resume the same graph on ended.
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                Task { @MainActor in await self?.resumeAfterConfigurationChange(graph) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                // Removing AirPods falls back to the phone; the config-change path restores audio.
                // Bluetooth HFP can finish connecting seconds later: if audio is still stopped,
                // restart recovery right away for the settled route.
                Task { @MainActor in
                    guard let self else { return }
                    self.reportSpeakerRoute()
                    if self.engine === graph, !graph.isRunning { await self.resumeAfterConfigurationChange(graph) }
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
            capture = nil
            graph.stop()
            waitingPlayer?.stop(); waitingPlayer = nil; waitingTone = false
            engine = nil; player = nil; playbackFormat = nil
            self.callKitManaged = false
            if !callKitManaged { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
            throw error
        }
    }
    private func installCapture(on graph: AVAudioEngine) throws {
        guard let capture else { throw APIError(message: "声音通道尚未就绪。") }
        let hardware = graph.inputNode.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw APIError(message: "当前音频设备无法建立通话通道。")
        }
        let frames = outgoing
        // Use the live hardware format explicitly. On the same engine a nil format
        // inherits the previous device's rate (15Pro log: HW 48 kHz vs tap 24 kHz after
        // leaving AirPods → start fails -10868). The converter adapts per buffer.
        let block: AVAudioNodeTapBlock = { buffer, _ in
            #if DEBUG
            frames.noteInput(buffer)
            #endif
            if let data = capture.convert(buffer) { frames.append(data) } else {
                #if DEBUG
                frames.noteConversionFailure()
                #endif
            }
        }
        #if os(iOS)
        if #available(iOS 27.0, *) {
            try graph.inputNode.__installTap(onBus: 0, bufferSize: 1024, format: hardware, error: (), block: block)
        } else {
            graph.inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardware, block: block)
        }
        #else
        graph.inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardware, block: block)
        #endif
        tapInstalled = true
    }
    private func reportSpeakerRoute() {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        onSpeakerChanged?(output?.portType == .builtInSpeaker)
        var routes = [CallAudioRoute(id: CallAudioRoute.receiver, name: "iPhone 听筒", symbol: "iphone"),
                      CallAudioRoute(id: CallAudioRoute.speaker, name: "扬声器", symbol: "speaker.wave.3.fill")]
        let live = (session.availableInputs ?? []).filter { Self.externalInputs.contains($0.portType) }
            .map { CallAudioRoute(id: "device:" + $0.uid, name: $0.portName, symbol: "headphones") }
        // While phoneOnly hides Bluetooth, keep the devices seen earlier in this call selectable.
        if phoneOnly == nil { knownDevices = live } else {
            for device in live where !knownDevices.contains(device) { knownDevices.append(device) }
        }
        routes += knownDevices
        let input = session.currentRoute.inputs.first?.portType.rawValue ?? "none"
        routeLog.notice("route in=\(input, privacy: .public) out=\((output?.portType.rawValue ?? "none"), privacy: .public) phoneOnly=\(self.phoneOnly != nil, privacy: .public) engine=\(self.engine?.isRunning == true, privacy: .public)")
        // The checkmark follows the real output, never the selected microphone.
        let current: String
        switch output?.portType {
        case .builtInSpeaker?: current = CallAudioRoute.speaker
        case .builtInReceiver?: current = CallAudioRoute.receiver
        case nil: current = ""
        case let port?:
            let name = output?.portName ?? ""
            current = routes.first { $0.id == "device:" + (output?.uid ?? "") }?.id
                ?? routes.first { $0.id.hasPrefix("device:") && $0.name == name }?.id
                ?? "output:" + port.rawValue
        }
        let name = routes.first { $0.id == current }?.name ?? output?.portName ?? "无可用声音设备"
        onRoutesChanged?(routes, current, name)
    }
    private static let externalInputs: Set<AVAudioSession.Port> = [.bluetoothHFP, .carAudio, .headsetMic, .usbAudio]
    func setSpeaker(_ enabled: Bool) throws {
        try selectRoute(enabled ? CallAudioRoute.speaker : CallAudioRoute.receiver)
    }
    private static func outputIsExternal(_ session: AVAudioSession) -> Bool {
        guard let port = session.currentRoute.outputs.first?.portType else { return false }
        return port != .builtInReceiver && port != .builtInSpeaker
    }
    /// Speaker is an output override; receiver and Bluetooth use the preferred input.
    /// iOS 27 keeps output on AirPods when only the mic is preferred (15Pro log), so the
    /// receiver falls back to temporarily disabling Bluetooth calling for this call;
    /// choosing a Bluetooth device restores the original category. The engine is kept.
    func selectRoute(_ id: String) throws {
        guard engine != nil else { throw APIError(message: "声音通道尚未就绪。") }
        let session = AVAudioSession.sharedInstance()
        routeTask?.cancel(); routeTask = nil
        routeLog.notice("select \(id.hasPrefix("device:") ? "device" : id, privacy: .public)")
        if id == CallAudioRoute.speaker {
            try session.overrideOutputAudioPort(.speaker)
        } else if id == CallAudioRoute.receiver {
            guard let mic = (session.availableInputs ?? []).first(where: { $0.portType == .builtInMic }) else {
                throw APIError(message: "听筒暂不可用，请选择其他声音设备。")
            }
            try session.overrideOutputAudioPort(.none)
            try session.setPreferredInput(mic)
            routeTask = Task { [weak self] in await self?.forceReceiverIfNeeded() }
        } else {
            guard knownDevices.contains(where: { $0.id == id }) || (session.availableInputs ?? []).contains(where: { "device:" + $0.uid == id }) else {
                throw APIError(message: "该声音设备已断开，请重新选择。")
            }
            try session.overrideOutputAudioPort(.none)
            if let saved = phoneOnly {
                try session.setCategory(.playAndRecord, mode: saved.mode, options: saved.options)
                phoneOnly = nil
            }
            if let port = (session.availableInputs ?? []).first(where: { "device:" + $0.uid == id }) {
                try session.setPreferredInput(port)
            } else {
                // Bluetooth reappears shortly after re-enabling it; select once it is listed.
                routeTask = Task { [weak self] in await self?.selectDeviceWhenAvailable(id) }
            }
        }
        onAudioStatusChanged?(nil)
        reportSpeakerRoute()
    }
    private func forceReceiverIfNeeded() async {
        try? await Task.sleep(nanoseconds: 700_000_000)
        let session = AVAudioSession.sharedInstance()
        guard !Task.isCancelled, engine != nil, Self.outputIsExternal(session) else { return }
        routeLog.notice("receiver fallback: disable Bluetooth calling")
        do {
            if phoneOnly == nil { phoneOnly = (session.mode, session.categoryOptions) }
            // voiceChat implicitly enables HFP, so the phone-only session uses default mode.
            try session.setCategory(.playAndRecord, mode: .default, options: [])
            try session.overrideOutputAudioPort(.none)
            if let mic = (session.availableInputs ?? []).first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(mic)
            }
        } catch {
            onAudioStatusChanged?("系统未允许切到听筒，通话保留。可选择扬声器或蓝牙设备。")
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled, engine != nil else { return }
        reportSpeakerRoute()
        if Self.outputIsExternal(session) { onAudioStatusChanged?("系统未允许切到听筒，通话保留。可选择扬声器或蓝牙设备。") }
    }
    private func selectDeviceWhenAvailable(_ id: String) async {
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, engine != nil else { return }
            let session = AVAudioSession.sharedInstance()
            if let port = (session.availableInputs ?? []).first(where: { "device:" + $0.uid == id }) {
                try? session.setPreferredInput(port)
                reportSpeakerRoute()
                return
            }
        }
        onAudioStatusChanged?("蓝牙设备未能重新连接，通话保留。请重新选择声音设备。")
    }
    /// Manual retry after a failed recovery; uses the same graph.
    func retryAudio() {
        guard let engine else { return }
        Task { await resumeAfterConfigurationChange(engine) }
    }
    private func resumeAfterConfigurationChange(_ graph: AVAudioEngine) async {
        // iOS stops the engine when the device changes. Re-install capture for the
        // new microphone format on the same graph (a new engine re-selects Bluetooth),
        // drop stale queued playback, and restart. Failures never end the call.
        let attempt = UUID()
        routeRecovery = attempt
        // AirPods/car HFP links often need several seconds; keep retrying quietly (~12 s)
        // before reporting, since the switch usually completes on its own.
        for delay in [160_000_000, 300_000_000, 500_000_000, 700_000_000, 1_000_000_000, 1_000_000_000, 1_500_000_000, 2_000_000_000, 2_500_000_000, 2_500_000_000] as [UInt64] {
            try? await Task.sleep(nanoseconds: delay)
            guard engine === graph, routeRecovery == attempt else { return }
            do {
                generation = UUID()
                scheduled = 0
                player?.stop()
                graph.stop()
                if tapInstalled { graph.inputNode.removeTap(onBus: 0); tapInstalled = false }
                try installCapture(on: graph)
                // Re-bind the mixer to the new hardware output rate (HFP 16/24 kHz vs 48 kHz).
                let hardware = graph.outputNode.outputFormat(forBus: 0)
                if hardware.sampleRate > 0, hardware.channelCount > 0,
                   let mixed = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: min(hardware.channelCount, 2)) {
                    graph.connect(graph.mainMixerNode, to: graph.outputNode, format: mixed)
                }
                graph.prepare()
                try graph.start()
                player?.play()
                if waitingTone { waitingTone = false; setWaitingTone(true) }
                onAudioStatusChanged?(nil)
                reportSpeakerRoute()
                return
            } catch {
                reportSpeakerRoute()
            }
        }
        guard engine === graph, routeRecovery == attempt else { return }
        onAudioStatusChanged?("声音设备恢复失败，通话仍保留。请重新选择声音设备或点击重试。")
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
        routeTask?.cancel(); routeTask = nil; phoneOnly = nil; knownDevices = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        generation = UUID(); scheduled = 0
        let wasRunning = engine != nil
        if let engine { if tapInstalled { engine.inputNode.removeTap(onBus: 0) }; engine.stop() }
        tapInstalled = false; capture = nil
        player?.stop(); player = nil; engine = nil; playbackFormat = nil
        if wasRunning && deactivateSession && !managedByCallKit { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
