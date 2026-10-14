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
    private var recoveryTask: Task<Void, Never>?
    private var routeSelectionTask: Task<Void, Never>?
    private var routeSelectionToken = UUID()
    private var routeSelectionPending = false
    private var requestedRouteID: String?
    private var recoveryMessage: String?
    private var selectionMessage: String?
    #if DEBUG && os(iOS)
    private let routeTrace = CallRouteTrace()
    #endif
    private var routeScope: UUID?
    private var routePolicy = AudioRoutePolicy()
    private var configuredRoute = ""
    private var rebuilding = false
    private var recoveryFailures = 0
    private var initialBluetoothName: String?
    private var sessionActivated = false
    private var audioSuspended = false
    private var recoveryFailed = false
    var onRoutesChanged: (([CallAudioRoute], String, String) -> Void)?
    var onAudioStatusChanged: ((String?) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?
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
        if routeScope == nil { beginRouting(UUID()) }
        let scope = routeScope
        let granted = await AVAudioApplication.requestRecordPermission()
        guard routeScope == scope else { throw CancellationError() }
        guard granted else { throw APIError(message: "请在系统设置中允许随行号使用麦克风后再拨号。") }
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if useSpeaker == true { options.insert(.defaultToSpeaker) }
        if !callKitManaged {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            audioSessionActivated()
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
            try installCapture(on: graph)
            engine = graph; player = output; playbackFormat = downlinkFormat
            self.callKitManaged = callKitManaged
            earlyMedia = false; active = false; muted = false; outgoing.enable(false)
            generation = UUID(); receivedFrames = 0; playedBuffers = 0; peak = 0
            observeEngine(graph)
            graph.prepare()
            if !audioSuspended { try graph.start() }
            configuredRoute = routeSignature(graph)
            if !audioSuspended { output.play() }
            try await Task.sleep(nanoseconds: 120_000_000)
            guard let current = engine, routeScope == scope else { throw CancellationError() }
            if !audioSuspended && !current.isRunning { try rebuildRoute(current) }
            if let current = engine { scheduleRouteRecovery(current) }
            reportSpeakerRoute()
        } catch {
            // A hangup may have stopped this graph while startup was suspended.
            guard routeScope == scope, engine === graph || engine == nil else { throw error }
            recoveryTask?.cancel(); recoveryTask = nil
            cancelRouteSelection()
            routeScope = nil
            outgoing.resetCapture()
            observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
            if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }; engineObserver = nil
            if tapInstalled { graph.inputNode.removeTap(onBus: 0); tapInstalled = false }
            graph.stop()
            waitingPlayer?.stop(); waitingPlayer = nil; waitingTone = false
            engine = nil; player = nil; playbackFormat = nil
            self.callKitManaged = false
            if !callKitManaged { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
            throw error
        }
    }
    /// Called before CallKit configures/activates audio, so lock-screen choices made
    /// while authentication/media setup is in flight are not missed.
    func beginRouting(_ scope: UUID) {
        guard routeScope != scope else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        recoveryTask?.cancel(); recoveryTask = nil
        cancelRouteSelection()
        routeScope = scope; routePolicy = AudioRoutePolicy(); configuredRoute = ""; sessionActivated = false
        recoveryFailures = 0
        audioSuspended = false; recoveryFailed = false
        setRecoveryMessage(nil)
        initialBluetoothName = AVAudioSession.sharedInstance().currentRoute.outputs.first {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP
        }?.portName
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            // Capture at notification time, not after a later route has replaced it.
            let output = Self.outputKind(AVAudioSession.sharedInstance())
            MainActor.assumeIsolated {
                guard let self, self.routeScope == scope else { return }
                if reason == .override && !self.routeSelectionPending { self.routePolicy.selected(output) }
                else if self.sessionActivated && (reason == .newDeviceAvailable || reason == .oldDeviceUnavailable) {
                    self.cancelRouteSelection()
                    self.routePolicy.deviceChanged(to: output)
                }
                self.traceRoute("notification", reason: reason?.rawValue ?? 0)
                self.reportSpeakerRoute()
                if let graph = self.engine { self.scheduleRouteRecovery(graph) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            MainActor.assumeIsolated {
                guard let self, self.routeScope == scope else { return }
                if raw == AVAudioSession.InterruptionType.began.rawValue {
                    self.audioSessionDeactivated()
                } else if raw == AVAudioSession.InterruptionType.ended.rawValue {
                    // CallKit alone may reactivate its session. Do not grab audio
                    // from another phone call/Siri because an interruption ended.
                    if !self.callKitManaged {
                        self.setRecoveryMessage("声音暂时中断，请点击重试声音。")
                    }
                }
            }
        })
    }

    nonisolated private static func outputKind(_ session: AVAudioSession) -> AudioRoutePolicy.Output {
        let ports = session.currentRoute.outputs
        if ports.contains(where: { $0.portType == .builtInSpeaker }) { return .speaker }
        if ports.contains(where: { $0.portType == .builtInReceiver }) { return .receiver }
        return ports.isEmpty ? .unavailable : .external
    }

    /// CallKit owns activation. Prefer an available HFP device once, only if the
    /// system has left us on the receiver and the user has not chosen a route.
    func audioSessionActivated() {
        guard routeScope != nil else { return }
        let session = AVAudioSession.sharedInstance()
        let current = Self.outputKind(session)
        if current == .speaker { routePolicy.selected(.speaker) }
        let candidates = (session.availableInputs ?? []).filter { $0.portType == .bluetoothHFP }
        let bluetooth = candidates.first { $0.portName == initialBluetoothName } ?? (candidates.count == 1 ? candidates.first : nil)
        if routePolicy.shouldSelectInitialBluetooth(current: current, available: bluetooth != nil), let bluetooth {
            do { try session.setPreferredInput(bluetooth) }
            catch { /* Keep the usable system route; the in-call menu permits retry. */ }
        }
        traceRoute("session_activated")
        sessionActivated = true
        audioSuspended = false; recoveryFailed = false; recoveryFailures = 0
        syncCaptureState()
        if let graph = engine { scheduleRouteRecovery(graph) }
        reportSpeakerRoute()
    }

    func audioSessionDeactivated() {
        guard routeScope != nil else { return }
        traceRoute("session_deactivated")
        sessionActivated = false; audioSuspended = true
        recoveryTask?.cancel(); recoveryTask = nil
        outgoing.resetCapture(); syncCaptureState()
        generation = UUID(); scheduled = 0
        player?.stop(); waitingPlayer?.stop(); engine?.pause()
        setRecoveryMessage("声音暂时被系统中断，通话保留；等待系统恢复声音。")
    }

    func retryAudio() throws {
        guard let graph = engine else { throw APIError(message: "声音通道尚未就绪。") }
        if audioSuspended {
            guard !callKitManaged else { throw APIError(message: "系统尚未恢复本次通话的声音，请结束其他音频占用后重试。") }
            try AVAudioSession.sharedInstance().setActive(true)
            audioSuspended = false; sessionActivated = true
        }
        if let requestedRouteID, !routeMatches(requestedRouteID) {
            try selectRoute(requestedRouteID)
            return
        }
        recoveryFailures = 0; recoveryFailed = false
        configuredRoute = "" // Explicit retry is allowed even if the route is unchanged.
        syncCaptureState()
        scheduleRouteRecovery(graph)
    }

    private func syncCaptureState() {
        outgoing.setState(active: active && !audioSuspended && !recoveryFailed, muted: muted)
    }

    private func setRecoveryMessage(_ message: String?) {
        recoveryMessage = message
        onAudioStatusChanged?(selectionMessage ?? recoveryMessage)
    }

    private func cancelRouteSelection() {
        routeSelectionTask?.cancel(); routeSelectionTask = nil
        routeSelectionToken = UUID(); routeSelectionPending = false
        requestedRouteID = nil; selectionMessage = nil
        onAudioStatusChanged?(recoveryMessage)
    }

    private func traceRoute(_ event: String, reason: UInt = 0) {
        #if DEBUG && os(iOS)
        let session = AVAudioSession.sharedInstance()
        routeTrace.record(event, input: session.currentRoute.inputs.first?.portType.rawValue ?? "none",
                          output: session.currentRoute.outputs.first?.portType.rawValue ?? "none",
                          preferred: session.preferredInput?.portType.rawValue ?? "none",
                          options: session.categoryOptions.rawValue, reason: reason,
                          running: isEngineRunning, suspended: audioSuspended)
        #endif
    }

    private func reportSpeakerRoute() {
        if selectionMessage != nil, let requestedRouteID, routeMatches(requestedRouteID) {
            selectionMessage = nil
            onAudioStatusChanged?(recoveryMessage)
        }
        let session = AVAudioSession.sharedInstance()
        let speaker = Self.outputKind(session) == .speaker
        onSpeakerChanged?(speaker)
        let inputs = session.availableInputs ?? []
        var routes = [CallAudioRoute(id: "speaker", name: "扬声器", symbol: "speaker.wave.2.fill")]
        for input in inputs {
            let phone = input.portType == .builtInMic
            routes.append(CallAudioRoute(id: "input:" + input.uid, name: phone ? "iPhone 听筒" : input.portName,
                                         symbol: phone ? "iphone" : "headphones"))
        }
        // Input and output can differ during a transition. A built-in microphone
        // is not evidence that downlink audio has reached the receiver.
        let output = session.currentRoute.outputs.first
        let selected: String
        let name: String
        if speaker {
            selected = "speaker"; name = "扬声器"
        } else if output?.portType == .builtInReceiver {
            selected = inputs.first(where: { $0.portType == .builtInMic }).map { "input:" + $0.uid } ?? ""
            name = "iPhone 听筒"
        } else if let output {
            let matching = inputs.first { $0.uid == output.uid } ?? inputs.first {
                $0.portType == output.portType && $0.portName == output.portName
            }
            selected = matching.map { "input:" + $0.uid } ?? ""
            name = output.portName
        } else {
            selected = ""; name = "等待声音设备"
        }
        onRoutesChanged?(routes, selected, name)
    }

    private func routeMatches(_ id: String) -> Bool {
        let session = AVAudioSession.sharedInstance()
        if id == "speaker" { return Self.outputKind(session) == .speaker }
        guard let input = session.availableInputs?.first(where: { "input:" + $0.uid == id }) else { return false }
        if input.portType == .builtInMic { return Self.outputKind(session) == .receiver }
        return session.currentRoute.outputs.contains {
            $0.uid == input.uid || ($0.portType == input.portType && $0.portName == input.portName)
        }
    }

    private func applyRoute(_ id: String) throws {
        let session = AVAudioSession.sharedInstance()
        if id == "speaker" {
            if Self.outputKind(session) != .speaker { try session.overrideOutputAudioPort(.speaker) }
            routePolicy.selected(.speaker)
            return
        }
        guard let input = session.availableInputs?.first(where: { "input:" + $0.uid == id }) else {
            throw APIError(message: "该声音设备已断开，请重新选择。")
        }
        if input.portType == .builtInMic {
            // Receiver routing must clear the OUTPUT override after selecting the
            // built-in mic, including when starting on Bluetooth. .none itself
            // only removes an override; it is not a receiver selection command.
            if session.categoryOptions.contains(.defaultToSpeaker) {
                var options = session.categoryOptions; options.remove(.defaultToSpeaker)
                try session.setCategory(.playAndRecord, mode: session.mode, options: options)
            }
            if !routeMatches(id) || session.preferredInput?.uid != input.uid {
                try session.setPreferredInput(input)
                try session.overrideOutputAudioPort(.none)
            }
            routePolicy.selected(.receiver)
        } else {
            if Self.outputKind(session) == .speaker { try session.overrideOutputAudioPort(.none) }
            if !routeMatches(id) || session.preferredInput?.uid != input.uid {
                try session.setPreferredInput(input)
            }
            routePolicy.selected(.external)
        }
    }

    func selectRoute(_ id: String) throws {
        guard engine != nil else { throw APIError(message: "声音通道尚未就绪。") }
        guard !audioSuspended else { throw APIError(message: "系统正在占用通话声音，请稍后再切换。") }
        cancelRouteSelection()
        requestedRouteID = id; routeSelectionPending = true
        let token = routeSelectionToken, scope = routeScope
        if recoveryFailed { configuredRoute = "" }
        recoveryFailures = 0; recoveryFailed = false
        traceRoute("select_begin")
        do { try applyRoute(id) }
        catch { cancelRouteSelection(); traceRoute("select_error"); throw error }
        reportSpeakerRoute()
        traceRoute("select_applied")
        if let graph = engine { scheduleRouteRecovery(graph) }
        // APIs accepting an input preference do not guarantee that output moved.
        // Confirm settled output, retry once, and expose failure without inventing
        // a receiver checkmark or letting engine recovery erase this failure.
        routeSelectionTask = Task { [weak self] in
            for (index, delay) in [300_000_000, 500_000_000, 900_000_000].enumerated() {
                do { try await Task.sleep(nanoseconds: UInt64(delay)) } catch { return }
                guard let self, self.routeScope == scope, self.routeSelectionToken == token,
                      !Task.isCancelled else { return }
                self.reportSpeakerRoute()
                self.traceRoute("select_check")
                if self.routeMatches(id) {
                    self.routeSelectionPending = false; self.routeSelectionTask = nil
                    self.selectionMessage = nil
                    self.onAudioStatusChanged?(self.recoveryMessage)
                    self.traceRoute("select_confirmed")
                    return
                }
                if index == 0 && !self.audioSuspended {
                    do { try self.applyRoute(id) }
                    catch { self.traceRoute("select_retry_error") }
                    if let graph = self.engine { self.scheduleRouteRecovery(graph) }
                }
            }
            guard let self, self.routeScope == scope, self.routeSelectionToken == token else { return }
            self.routeSelectionPending = false; self.routeSelectionTask = nil
            self.selectionMessage = "声音设备未切换成功；当前声音仍在页面显示的设备。请重试声音或通过系统通话界面选择。"
            self.onAudioStatusChanged?(self.selectionMessage)
            self.traceRoute("select_unconfirmed")
            self.reportSpeakerRoute()
        }
    }

    func setSpeaker(_ enabled: Bool) throws {
        if enabled { try selectRoute("speaker") }
        else if let input = AVAudioSession.sharedInstance().availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try selectRoute("input:" + input.uid)
        } else { throw APIError(message: "听筒暂不可用，请选择其他声音设备。") }
    }

    private func installCapture(on graph: AVAudioEngine) throws {
        let inputFormat = graph.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw APIError(message: "当前音频设备无法建立通话通道。")
        }
        let converter = try PCMInputConverter()
        let frames = outgoing
        let capture = frames.resetCapture()
        // nil inherits the current bus format; never force a cached format onto
        // a hardware input (which raises an uncaught Obj-C AVFAudio exception).
        let captureBlock: AVAudioNodeTapBlock = { buffer, _ in
            #if DEBUG
            frames.noteInput(buffer)
            #endif
            if let data = converter.convert(buffer) {
                frames.append(data, generation: capture)
            } else {
                #if DEBUG
                frames.noteConversionFailure()
                #endif
            }
        }
        #if os(iOS)
        if #available(iOS 27.0, *) {
            // iOS 27 exposes the error-returning tap API. Keep a transient
            // hardware failure inside the bounded recovery path, not an abort.
            try graph.inputNode.__installTap(onBus: 0, bufferSize: 1024, format: nil, error: (), block: captureBlock)
        } else {
            graph.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: captureBlock)
        }
        #else
        graph.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: captureBlock)
        #endif
        tapInstalled = true
    }

    private func routeSignature(_ graph: AVAudioEngine) -> String {
        let session = AVAudioSession.sharedInstance()
        return hardwareSignature(graph) + "/" + session.currentRoute.outputs.map { $0.uid + $0.portType.rawValue }.joined(separator: "/")
    }

    private func hardwareSignature(_ graph: AVAudioEngine) -> String {
        let session = AVAudioSession.sharedInstance()
        let input = graph.inputNode.inputFormat(forBus: 0)
        let output = graph.outputNode.inputFormat(forBus: 0)
        return "\(input.sampleRate)/\(input.channelCount)/\(output.sampleRate)/\(output.channelCount)/" +
            session.currentRoute.inputs.map { $0.uid + $0.portType.rawValue }.joined(separator: "/")
    }

    private func scheduleRouteRecovery(_ graph: AVAudioEngine) {
        guard engine === graph, !rebuilding, !audioSuspended, recoveryFailures < 3 else { return }
        let lostSpeaker = routePolicy.selection == .speaker && Self.outputKind(AVAudioSession.sharedInstance()) == .receiver
        guard !graph.isRunning || configuredRoute != routeSignature(graph) || lostSpeaker else { return }
        recoveryTask?.cancel()
        let scope = routeScope
        recoveryTask = Task { [weak self, weak graph] in
            for delay in [250_000_000, 500_000_000, 1_000_000_000] as [UInt64] {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self, let graph, self.routeScope == scope, self.engine === graph,
                      !self.audioSuspended, !Task.isCancelled else { return }
                do {
                    // Repair a lost temporary override once; an explicit system choice
                    // or device removal updates policy before this debounced operation.
                    let session = AVAudioSession.sharedInstance()
                    if self.routePolicy.shouldRepairSpeaker(current: Self.outputKind(session)) {
                        try session.overrideOutputAudioPort(.speaker)
                        continue // Let the hardware settle before rebuilding capture.
                    }
                    try self.rebuildRoute(graph)
                    return
                } catch {
                    // Count across notification rescheduling too, so events caused by
                    // a failed rebuild cannot renew the retry budget indefinitely.
                    self.recoveryFailures += 1
                    if self.recoveryFailures >= 3 { break }
                }
            }
            guard let self, let graph, self.engine === graph, self.routeScope == scope, !Task.isCancelled else { return }
            // Local audio recovery failure is not a remote call termination.
            // Keep CallKit/WS ownership, silence capture, and expose an explicit retry.
            self.recoveryFailed = true
            self.outgoing.resetCapture(); self.syncCaptureState()
            self.setRecoveryMessage("声音切换未恢复，通话仍保留。请换回原设备或点击重试声音；仍无声音时请手动挂断。")
        }
    }

    private func rebuildRoute(_ graph: AVAudioEngine) throws {
        traceRoute("engine_recovery_begin")
        rebuilding = true
        defer { rebuilding = false }
        let resumeTone = waitingTone
        generation = UUID(); scheduled = 0
        player?.stop(); waitingPlayer?.stop()
        if !tapInstalled || !graph.isRunning || configuredRoute != routeSignature(graph) {
            outgoing.resetCapture()
            graph.stop()
            if tapInstalled { graph.inputNode.removeTap(onBus: 0); tapInstalled = false }
            // Rebind output-only changes too. A running I/O unit can still
            // retain the old playback route; never reinstall a tap on that unit.
            let replacement = AVAudioEngine()
            let replacementPlayer = AVAudioPlayerNode()
            guard let format = playbackFormat else { throw APIError(message: "声音格式暂不可用。") }
            replacement.attach(replacementPlayer)
            replacement.connect(replacementPlayer, to: replacement.mainMixerNode, format: format)
            let replacementWaiting = AVAudioPlayerNode()
            replacement.attach(replacementWaiting)
            replacement.connect(replacementWaiting, to: replacement.mainMixerNode, format: format)
            do {
                try installCapture(on: replacement)
                replacement.prepare()
                try replacement.start()
            } catch {
                if tapInstalled { replacement.inputNode.removeTap(onBus: 0); tapInstalled = false }
                replacement.stop()
                throw error
            }
            engine = replacement; player = replacementPlayer; waitingPlayer = replacementWaiting
            observeEngine(replacement)
            finishRouteRecovery(replacement, resumeTone: resumeTone)
            return
        }
        if !graph.isRunning { try graph.start() }
        finishRouteRecovery(graph, resumeTone: resumeTone)
    }

    private func observeEngine(_ graph: AVAudioEngine) {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        let scope = routeScope
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: graph, queue: .main) { [weak self, weak graph] _ in
            MainActor.assumeIsolated {
                guard let self, let graph, self.engine === graph, self.routeScope == scope else { return }
                self.scheduleRouteRecovery(graph)
            }
        }
    }

    private func finishRouteRecovery(_ graph: AVAudioEngine, resumeTone: Bool) {
        recoveryFailures = 0
        recoveryFailed = false
        syncCaptureState()
        configuredRoute = routeSignature(graph)
        player?.play()
        if resumeTone { waitingTone = false; setWaitingTone(true) }
        reportSpeakerRoute()
        setRecoveryMessage(nil)
        traceRoute("engine_recovery_finished")
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
        active = value; syncCaptureState()
    }
    func setMuted(_ value: Bool) {
        muted = value; syncCaptureState()
    }
    func play(_ data: Data) {
        guard let samples = PCMFrames.floatSamples(data) else { return }
        receivedFrames += 1
        outgoing.diagnostics.add("down_received_frames")
        peak = max(peak, samples.map { abs($0) }.max() ?? 0)
        guard !audioSuspended, !recoveryFailed, active || earlyMedia else { outgoing.diagnostics.add("down_inactive_frames"); return }
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
        recoveryTask?.cancel(); recoveryTask = nil
        cancelRouteSelection()
        routeScope = nil; routePolicy = AudioRoutePolicy(); configuredRoute = ""; sessionActivated = false
        audioSuspended = false; recoveryFailed = false; setRecoveryMessage(nil)
        outgoing.resetCapture()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }; engineObserver = nil
        generation = UUID(); scheduled = 0
        let wasRunning = engine != nil
        if let engine { if tapInstalled { engine.inputNode.removeTap(onBus: 0) }; engine.stop() }
        tapInstalled = false
        player?.stop(); player = nil; engine = nil; playbackFormat = nil
        if wasRunning && deactivateSession && !managedByCallKit { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
