// Deterministic audio/session doubles. No microphone, network, CallKit or modem.
import Foundation

typealias AVAudioFrameCount = UInt32
typealias AVAudioNodeTapBlock = (AVAudioPCMBuffer, Int) -> Void
let AVAudioSessionRouteChangeReasonKey = "route-reason"
let AVAudioSessionInterruptionTypeKey = "interruption-type"
extension Notification.Name { static let AVAudioEngineConfigurationChange = Self("engine-config") }
final class AVAudioSession {
    struct Port: Equatable {
        let rawValue: String
        static let builtInSpeaker = Self(rawValue: "speaker"), builtInReceiver = Self(rawValue: "receiver")
        static let builtInMic = Self(rawValue: "mic"), bluetoothHFP = Self(rawValue: "hfp"), bluetoothA2DP = Self(rawValue: "a2dp")
    }
    struct PortDescription { let uid: String; let portType: Port; let portName: String }
    struct Route { var inputs: [PortDescription]; var outputs: [PortDescription] }
    enum RouteChangeReason: UInt { case unknown, newDeviceAvailable, oldDeviceUnavailable, categoryChange, override, routeConfigurationChange }
    enum InterruptionType: UInt { case began, ended }
    enum Category { case playback, playAndRecord }
    enum Mode { case `default` }
    struct CategoryOptions: OptionSet {
        let rawValue: Int
        static let allowBluetoothHFP = Self(rawValue: 1), defaultToSpeaker = Self(rawValue: 2)
    }
    enum PortOverride { case speaker, none }
    struct SetActiveOptions: OptionSet { let rawValue: Int; static let notifyOthersOnDeactivation = Self(rawValue: 1) }
    static let routeChangeNotification = Notification.Name("route"), interruptionNotification = Notification.Name("interrupt")
    static let value = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { value }
    static let mic = PortDescription(uid: "phone", portType: .builtInMic, portName: "Phone")
    static let car = PortDescription(uid: "synthetic-car", portType: .bluetoothHFP, portName: "Test car")
    var availableInputs: [PortDescription]? = [mic, car]
    var currentRoute = Route(inputs: [mic], outputs: [PortDescription(uid: "receiver", portType: .builtInReceiver, portName: "Phone")])
    var hardwareRate = 48000.0
    var preferredInput: PortDescription?
    var deferOverrideReset = false, pendingOverrideReset = false
    var preferredRequests = 0, overrideRequests = 0
    var startFailures = 0
    var activeCalls = 0
    var interruptOnSelection = false
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions = []) throws {}
    func setPreferredIOBufferDuration(_ value: Double) throws {}
    func setActive(_ value: Bool, options: SetActiveOptions = []) throws { activeCalls += 1 }
    func setPreferredInput(_ port: PortDescription?) throws {
        preferredRequests += 1
        preferredInput = port
        route(port?.portType == .bluetoothHFP ? .external : .receiver, reason: .override)
        interruptIfRequested()
    }
    func overrideOutputAudioPort(_ port: PortOverride) throws {
        overrideRequests += 1
        if port == .none && deferOverrideReset { pendingOverrideReset = true; return }
        route(port == .speaker ? .speaker : .receiver, reason: .override)
        interruptIfRequested()
    }
    func finishOverrideReset() {
        guard pendingOverrideReset else { return }
        pendingOverrideReset = false
        route(preferredInput?.portType == .bluetoothHFP ? .external : .receiver, reason: .override)
    }
    private func interruptIfRequested() {
        if interruptOnSelection {
            interruptOnSelection = false
            NotificationCenter.default.post(name: Self.interruptionNotification, object: self,
                userInfo: [AVAudioSessionInterruptionTypeKey: InterruptionType.began.rawValue])
        }
    }
    func route(_ kind: AudioRoutePolicy.Output, reason: RouteChangeReason) {
        switch kind {
        case .speaker: currentRoute = Route(inputs: [Self.mic], outputs: [.init(uid: "speaker", portType: .builtInSpeaker, portName: "Speaker")]); hardwareRate = 48000
        case .receiver: currentRoute = Route(inputs: [Self.mic], outputs: [.init(uid: "receiver", portType: .builtInReceiver, portName: "Phone")]); hardwareRate = 48000
        case .external: currentRoute = Route(inputs: [Self.car], outputs: [Self.car]); hardwareRate = 16000
        case .unavailable: currentRoute = Route(inputs: [], outputs: []); hardwareRate = 0
        }
        NotificationCenter.default.post(name: Self.routeChangeNotification, object: self, userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }
    func reset() {
        preferredInput = nil; deferOverrideReset = false; pendingOverrideReset = false
        availableInputs = [Self.mic, Self.car]; preferredRequests = 0; overrideRequests = 0; activeCalls = 0; startFailures = 0; interruptOnSelection = false
        route(.receiver, reason: .unknown)
    }
}
enum AVAudioApplication { static func requestRecordPermission() async -> Bool { true } }
enum AVAudioCommonFormat { case pcmFormatFloat32, pcmFormatInt16 }
final class AVAudioFormat {
    func isEqual(_ other: AVAudioFormat) -> Bool { sampleRate == other.sampleRate && channelCount == other.channelCount }
    let sampleRate: Double, channelCount: UInt32
    init?(commonFormat: AVAudioCommonFormat, sampleRate: Double, channels: UInt32, interleaved: Bool) { self.sampleRate = sampleRate; channelCount = channels }
}
final class AVAudioPCMBuffer {
    let format: AVAudioFormat
    var frameLength: UInt32 = 0
    private let floats: UnsafeMutablePointer<Float>, ints: UnsafeMutablePointer<Int16>
    private let floatChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, intChannels: UnsafeMutablePointer<UnsafeMutablePointer<Int16>>
    var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? { UnsafePointer(floatChannels) }
    var int16ChannelData: UnsafePointer<UnsafeMutablePointer<Int16>>? { UnsafePointer(intChannels) }
    init?(pcmFormat: AVAudioFormat, frameCapacity: UInt32) {
        format = pcmFormat
        floats = .allocate(capacity: Int(frameCapacity)); floats.initialize(repeating: 0, count: Int(frameCapacity))
        ints = .allocate(capacity: Int(frameCapacity)); ints.initialize(repeating: 0, count: Int(frameCapacity))
        floatChannels = .allocate(capacity: 1); floatChannels.initialize(to: floats)
        intChannels = .allocate(capacity: 1); intChannels.initialize(to: ints)
    }
    deinit { floats.deallocate(); ints.deallocate(); floatChannels.deallocate(); intChannels.deallocate() }
}
final class AVAudioConverter {
    enum PrimeMethod { case none }
    enum InputStatus { case noDataNow, haveData }
    enum OutputStatus { case error, haveData }
    static var sourceRates: [Double] = []
    var primeMethod = PrimeMethod.none
    let inputFormat: AVAudioFormat
    init?(from: AVAudioFormat, to: AVAudioFormat) { inputFormat = from; Self.sourceRates.append(from.sampleRate) }
    func convert(to: AVAudioPCMBuffer, error: inout NSError?, withInputFrom: (UInt32, UnsafeMutablePointer<InputStatus>) -> AVAudioPCMBuffer?) -> OutputStatus { .haveData }
}
class AVAudioNode {
    // Model a stopped I/O unit retaining its OLD output format while hardware changes.
    private let cachedRate = AVAudioSession.value.hardwareRate
    private var tapped = false
    func outputFormat(forBus: Int) -> AVAudioFormat { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: cachedRate, channels: 1, interleaved: false)! }
    func inputFormat(forBus: Int) -> AVAudioFormat { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AVAudioSession.value.hardwareRate, channels: 1, interleaved: false)! }
    func installTap(onBus: Int, bufferSize: UInt32, format: AVAudioFormat?, block: @escaping (AVAudioPCMBuffer, Int) -> Void) {
        precondition(!tapped, "Duplicate capture tap")
        let hardware = inputFormat(forBus: onBus)
        precondition(format == nil || format!.isEqual(hardware), "Stale tap format conflicts with hardware")
        precondition(hardware.sampleRate > 0)
        tapped = true
        let buffer = AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: 1024)!
        buffer.frameLength = 1024
        block(buffer, 0)
    }
    func removeTap(onBus: Int) { precondition(tapped); tapped = false }
}
final class AVAudioPlayerNode: AVAudioNode {
    enum CompletionCallbackType { case dataPlayedBack }
    struct BufferOptions: OptionSet { let rawValue: Int; static let loops = Self(rawValue: 1) }
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, completionCallbackType: CompletionCallbackType, completionHandler: @escaping (Int) -> Void) {}
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at: Int?, options: BufferOptions, completionHandler: (() -> Void)?) {}
    func play() {}; func stop() {}
}
final class AVAudioEngine: NSObject, @unchecked Sendable {
    static var latest: AVAudioEngine?
    let inputNode = AVAudioNode(), outputNode = AVAudioNode(), mainMixerNode = AVAudioNode()
    var isRunning = false, starts = 0
    override init() { super.init(); Self.latest = self }
    func attach(_ node: AVAudioNode) {}
    func connect(_ node: AVAudioNode, to: AVAudioNode, format: AVAudioFormat?) {}
    func disconnectNodeOutput(_ node: AVAudioNode) {}
    func prepare() {}
    func start() throws {
        if AVAudioSession.value.startFailures > 0 { AVAudioSession.value.startFailures -= 1; throw APIError(message: "Synthetic transient route") }
        isRunning = true; starts += 1
    }
    func pause() { isRunning = false }
    func stop() { isRunning = false }
    func configurationChanged() { isRunning = false; NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self) }
}
struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }

@main struct AudioRouteRuntimeChecks {
    @MainActor static func settle() async { try? await Task.sleep(nanoseconds: 2_100_000_000) }
    @MainActor static func main() async throws {
        let session = AVAudioSession.value
        session.reset()
        let audio = VoiceAudio()
        var failures = 0
        var audioMessage: String?
        audio.onAudioStatusChanged = { message in
            audioMessage = message
            if message?.contains("切换未恢复") == true { failures += 1 }
        }
        var routes: [CallAudioRoute] = []
        audio.onRoutesChanged = { list, _, _ in routes = list }
        audio.beginRouting(UUID())
        audio.audioSessionActivated()
        precondition(session.currentRoute.outputs.first?.portType == .bluetoothHFP)
        try await audio.start(callKitManaged: true)
        var graph = AVAudioEngine.latest!
        precondition(AVAudioConverter.sourceRates.last == 16000)
        precondition(routes.contains { $0.id == "input:synthetic-car" })
        audio.setActiveCall(true); audio.setMuted(true)
        // Choosing the current AirPods/HFP device must not churn the session.
        let selections = session.preferredRequests, overrides = session.overrideRequests
        try audio.selectRoute("input:synthetic-car")
        precondition(session.preferredRequests == selections && session.overrideRequests == overrides)
        // Real iOS can deactivate audio during device switching. This is a pause,
        // not a hangup; CallKit reactivation must resume the existing call.
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: session,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        precondition(audio.isActiveCall && audio.muted && !audio.isEngineRunning && audioMessage != nil)
        graph.configurationChanged(); await settle()
        precondition(!audio.isEngineRunning && failures == 0)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: session,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        precondition(!audio.isEngineRunning) // No premature self-activation.
        audio.audioSessionActivated(); await settle()
        precondition(audio.isEngineRunning && audioMessage == nil && audio.isActiveCall && audio.muted)
        // The interruption can arrive synchronously during the user's selection.
        session.interruptOnSelection = true
        try audio.selectRoute("speaker")
        precondition(audio.isActiveCall && !audio.isEngineRunning && audioMessage != nil)
        audio.audioSessionActivated(); await settle()
        precondition(audio.isEngineRunning && audio.muted && audioMessage == nil)
        precondition(graph !== AVAudioEngine.latest!)
        precondition(graph.inputNode.outputFormat(forBus: 0).sampleRate == 16000 && graph.inputNode.inputFormat(forBus: 0).sampleRate == 48000)
        graph = AVAudioEngine.latest!
        session.route(.speaker, reason: .override); graph.configurationChanged()
        await settle()
        precondition(audio.isEngineRunning && audio.muted && audio.isActiveCall && failures == 0)
        precondition(AVAudioConverter.sourceRates.last == 48000)
        // Speaker uses the built-in mic, but the preferred input still points to
        // HFP. Clearing the override is asynchronous: currentRoute alone cannot
        // tell whether a receiver request has actually replaced that preference.
        precondition(session.preferredInput?.uid == AVAudioSession.car.uid)
        session.deferOverrideReset = true
        try audio.selectRoute("input:phone")
        session.finishOverrideReset(); await settle()
        precondition(session.preferredInput?.uid == AVAudioSession.mic.uid, "Receiver must clear stale HFP preference")
        precondition(session.currentRoute.outputs.first?.portType == .builtInReceiver)
        precondition(audio.isEngineRunning && audio.isActiveCall && audio.muted)
        try audio.selectRoute("input:synthetic-car"); await settle()
        try audio.selectRoute("input:phone"); await settle()
        precondition(session.currentRoute.outputs.first?.portType == .builtInReceiver && audio.isEngineRunning)
        session.deferOverrideReset = false
        try audio.selectRoute("speaker"); await settle()
        graph = AVAudioEngine.latest!
        let convertersBeforeSpeaker = AVAudioConverter.sourceRates.count
        // Internal reconfiguration loses the temporary speaker override.
        session.route(.receiver, reason: .routeConfigurationChange); graph.configurationChanged()
        await settle()
        precondition(session.currentRoute.outputs.first?.portType == .builtInSpeaker)
        // Explicit CallKit receiver selection wins over remembered speaker.
        session.route(.receiver, reason: .override); graph.configurationChanged()
        await settle()
        precondition(session.currentRoute.outputs.first?.portType == .builtInReceiver)
        precondition(AVAudioConverter.sourceRates.count == convertersBeforeSpeaker)
        // HFP reselect and device removal keep the call and its mute state.
        try audio.selectRoute("input:synthetic-car"); graph.configurationChanged()
        await settle()
        precondition(AVAudioConverter.sourceRates.last == 16000 && audio.muted)
        precondition(graph !== AVAudioEngine.latest!)
        graph = AVAudioEngine.latest!
        session.availableInputs = [AVAudioSession.mic]
        session.route(.receiver, reason: .oldDeviceUnavailable); graph.configurationChanged()
        await settle()
        precondition(audio.isEngineRunning && audio.isActiveCall && failures == 0)
        graph = AVAudioEngine.latest!
        do { try audio.selectRoute("input:synthetic-car"); preconditionFailure("Missing device accepted") } catch {}
        precondition(audio.isEngineRunning)
        // One transient engine failure retries and preserves early-media waiting tone.
        audio.setActiveCall(false); audio.setWaitingTone(true)
        session.startFailures = 1
        graph.configurationChanged(); await settle()
        precondition(audio.isEngineRunning && audio.isWaitingTone && !audio.isActiveCall && audio.muted && failures == 0)
        // Exhaustion is bounded, visibly retains the call, and permits explicit retry.
        session.startFailures = 10
        graph.configurationChanged(); await settle()
        precondition(failures == 1 && audioMessage != nil)
        session.startFailures = 0
        try audio.retryAudio(); await settle()
        precondition(audio.isEngineRunning && audioMessage == nil && audio.muted)
        audio.stop()
        session.reset()
        audio.beginRouting(UUID()); session.route(.speaker, reason: .override)
        audio.audioSessionActivated()
        precondition(session.preferredRequests == 0)
        try await audio.start(callKitManaged: true)
        let newGraph = AVAudioEngine.latest!
        // A cancelled recovery from the previous call cannot stop or rebuild this one.
        newGraph.configurationChanged(); audio.stop()
        audio.beginRouting(UUID()); audio.audioSessionActivated()
        try await audio.start(callKitManaged: true)
        let newest = AVAudioEngine.latest!
        let count = newest.starts
        graph.configurationChanged(); newGraph.configurationChanged(); await settle()
        precondition(audio.isEngineRunning && newest.starts == count && failures == 1)
        precondition(session.activeCalls == 0) // Only CallKit owns activation/deactivation.
        audio.stop()
        print("通过：实际VoiceAudio代码模拟旧节点格式滞留/新引擎重建、实际采集格式转换、中断暂停不挂断、CallKit重新激活、恢复失败可重试、HFP接入/采样率变化、系统免提回退修复、手动听筒优先、蓝牙断开续通话、暂态重试/超限、等待音/静音保留、旧引擎/任务隔离；无硬件实证")
    }
}
