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
    enum Mode { case `default`, voiceChat }
    struct CategoryOptions: OptionSet {
        let rawValue: Int
        static let allowBluetoothHFP = Self(rawValue: 1), defaultToSpeaker = Self(rawValue: 2), allowBluetoothA2DP = Self(rawValue: 4)
    }
    enum PortOverride { case speaker, none }
    struct SetActiveOptions: OptionSet { let rawValue: Int; static let notifyOthersOnDeactivation = Self(rawValue: 1) }
    static let routeChangeNotification = Notification.Name("route"), interruptionNotification = Notification.Name("interrupt")
    static let value = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { value }
    static let mic = PortDescription(uid: "phone", portType: .builtInMic, portName: "Phone")
    static let car = PortDescription(uid: "synthetic-car", portType: .bluetoothHFP, portName: "Test car")
    var connectedInputs: [PortDescription]? = [mic, car]
    var availableInputs: [PortDescription]? {
        get { connectedInputs?.filter { $0.portType != .bluetoothHFP || categoryOptions.contains(.allowBluetoothHFP) } }
        set { connectedInputs = newValue }
    }
    var currentRoute = Route(inputs: [mic], outputs: [PortDescription(uid: "receiver", portType: .builtInReceiver, portName: "Phone")])
    var hardwareRate = 48000.0
    var categoryOptions: CategoryOptions = [.allowBluetoothHFP]
    var mode = Mode.voiceChat
    var micPreferenceLeavesOutput = false, rejectReceiverOutput = false
    var categoryRequests = 0
    var engineReplacementSelectsHFP = false, receiverPreferenceIgnoredOnHFP = false
    var speakerRejected = false
    var preferredInput: PortDescription?
    var deferOverrideReset = false, pendingOverrideReset = false
    var preferredRequests = 0, overrideRequests = 0
    var startFailures = 0
    var activeCalls = 0
    var interruptOnSelection = false
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions = []) throws {
        self.mode = mode
        categoryOptions = mode == .voiceChat ? options.union(.allowBluetoothHFP) : options
        categoryRequests += 1
        if !categoryOptions.contains(.allowBluetoothHFP) { route(.receiver, reason: .categoryChange) }
    }
    func setPreferredIOBufferDuration(_ value: Double) throws {}
    func setActive(_ value: Bool, options: SetActiveOptions = []) throws { activeCalls += 1 }
    func setPreferredInput(_ port: PortDescription?) throws {
        preferredRequests += 1
        if port?.portType == .builtInMic && receiverPreferenceIgnoredOnHFP && categoryOptions.contains(.allowBluetoothHFP) {
            preferredInput = nil
            route(.external, reason: .override)
            return
        }
        preferredInput = port
        if port?.portType == .builtInMic && micPreferenceLeavesOutput {
            currentRoute.inputs = [Self.mic]
            hardwareRate = 48000
            NotificationCenter.default.post(name: Self.routeChangeNotification, object: self, userInfo: [AVAudioSessionRouteChangeReasonKey: RouteChangeReason.override.rawValue])
        } else {
            route(port?.portType == .bluetoothHFP ? .external : (categoryOptions.contains(.defaultToSpeaker) ? .speaker : .receiver), reason: .override)
        }
        interruptIfRequested()
    }
    func overrideOutputAudioPort(_ port: PortOverride) throws {
        overrideRequests += 1
        if port == .speaker && speakerRejected { return }
        if port == .none && deferOverrideReset { pendingOverrideReset = true; return }
        if port == .none && rejectReceiverOutput { return }
        let bluetoothDefault = preferredInput?.portType == .bluetoothHFP || (preferredInput == nil && receiverPreferenceIgnoredOnHFP && categoryOptions.contains(.allowBluetoothHFP))
        route(port == .speaker ? .speaker : (categoryOptions.contains(.defaultToSpeaker) ? .speaker : (bluetoothDefault ? .external : .receiver)), reason: .override)
        interruptIfRequested()
    }
    func finishOverrideReset() {
        guard pendingOverrideReset else { return }
        pendingOverrideReset = false
        if rejectReceiverOutput { return }
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
        let priorOutput = currentRoute.outputs.first?.portType
        switch kind {
        case .speaker: currentRoute = Route(inputs: [Self.mic], outputs: [.init(uid: "speaker", portType: .builtInSpeaker, portName: "Speaker")]); hardwareRate = 48000
        case .receiver: currentRoute = Route(inputs: [Self.mic], outputs: [.init(uid: "receiver", portType: .builtInReceiver, portName: "Phone")]); hardwareRate = 48000
        case .external: currentRoute = Route(inputs: [Self.car], outputs: [Self.car]); hardwareRate = 16000
        case .unavailable: currentRoute = Route(inputs: [], outputs: []); hardwareRate = 0
        }
        if priorOutput != currentRoute.outputs.first?.portType && AVAudioEngine.latest?.isRunning == true {
            AVAudioEngine.latest?.configurationChanged()
        }
        NotificationCenter.default.post(name: Self.routeChangeNotification, object: self, userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }
    func reset() {
        categoryOptions = [.allowBluetoothHFP]; mode = .voiceChat; categoryRequests = 0
        engineReplacementSelectsHFP = false; receiverPreferenceIgnoredOnHFP = false; speakerRejected = false
        micPreferenceLeavesOutput = false; rejectReceiverOutput = false
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
    private var cachedRate = AVAudioSession.value.hardwareRate
    private var tapped = false
    private var tapBlock: AVAudioNodeTapBlock?
    func outputFormat(forBus: Int) -> AVAudioFormat { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: cachedRate, channels: 1, interleaved: false)! }
    func inputFormat(forBus: Int) -> AVAudioFormat { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AVAudioSession.value.hardwareRate, channels: 1, interleaved: false)! }
    func installTap(onBus: Int, bufferSize: UInt32, format: AVAudioFormat?, block: @escaping (AVAudioPCMBuffer, Int) -> Void) {
        precondition(!tapped, "Duplicate capture tap")
        let hardware = inputFormat(forBus: onBus)
        precondition(format == nil || format!.isEqual(hardware), "Stale tap format conflicts with hardware")
        precondition(hardware.sampleRate > 0)
        tapped = true; tapBlock = block
        let buffer = AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: 1024)!
        buffer.frameLength = 1024
        block(buffer, 0)
    }
    func deliverHardwareBuffer() {
        cachedRate = AVAudioSession.value.hardwareRate
        guard let tapBlock else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat(forBus: 0), frameCapacity: 1024)!
        buffer.frameLength = 1024
        tapBlock(buffer, 0)
    }
    func removeTap(onBus: Int) { precondition(tapped); tapped = false; tapBlock = nil }
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
    override init() {
        super.init()
        // Captured 15Pro sequence: constructing the replacement engine changes
        // the just-selected Speaker back to HFP and clears preferred input.
        if Self.latest != nil && AVAudioSession.value.engineReplacementSelectsHFP && AVAudioSession.value.categoryOptions.contains(.allowBluetoothHFP) {
            AVAudioSession.value.preferredInput = nil
            AVAudioSession.value.route(.external, reason: .newDeviceAvailable)
        }
        Self.latest = self
    }
    func attach(_ node: AVAudioNode) {}
    func connect(_ node: AVAudioNode, to: AVAudioNode, format: AVAudioFormat?) {}
    func disconnectNodeOutput(_ node: AVAudioNode) {}
    func prepare() {}
    func start() throws {
        if AVAudioSession.value.startFailures > 0 { AVAudioSession.value.startFailures -= 1; throw APIError(message: "Synthetic transient route") }
        isRunning = true; starts += 1
        inputNode.deliverHardwareBuffer()
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
        session.engineReplacementSelectsHFP = true
        session.receiverPreferenceIgnoredOnHFP = true
        let audio = VoiceAudio()
        var message: String?
        var selected = "", name = "", routes: [CallAudioRoute] = []
        audio.onAudioStatusChanged = { message = $0 }
        audio.onRoutesChanged = { routes = $0; selected = $1; name = $2 }
        audio.beginRouting(UUID()); audio.audioSessionActivated()
        try await audio.start(callKitManaged: true)
        let graph = AVAudioEngine.latest!
        audio.setActiveCall(true); audio.setMuted(true)
        precondition(session.currentRoute.outputs.first?.portType == .bluetoothHFP)
        let preferred = session.preferredRequests, overrides = session.overrideRequests
        try audio.selectRoute("input:synthetic-car"); await settle()
        precondition(session.preferredRequests == preferred && session.overrideRequests == overrides)
        precondition(selected == "input:synthetic-car" && message == nil)
        // Actual trace replay: speaker is selected while the engine stops. It
        // must not be confirmed at that point, replaced, or returned to HFP.
        try audio.selectRoute("speaker")
        precondition(selected.isEmpty && name == "正在切换声音")
        try? await Task.sleep(nanoseconds: 330_000_000)
        precondition(selected.isEmpty, "No success before two post-recovery samples")
        await settle()
        precondition(session.currentRoute.outputs.first?.portType == .builtInSpeaker, "Actual trace regression: engine recovery must retain Speaker")
        precondition(graph === AVAudioEngine.latest!, "Keep the existing I/O unit")
        precondition(audio.isEngineRunning && audio.isActiveCall && audio.muted && message == nil && selected == "speaker")
        precondition(AVAudioConverter.sourceRates.last == 48000)
        // voiceChat implicitly enables HFP. A receiver-only category must use
        // default mode and still offer the remembered, currently connected HFP.
        try audio.selectRoute("input:phone"); await settle()
        precondition(session.mode == .default && !session.categoryOptions.contains(.allowBluetoothHFP))
        precondition(selected == "input:phone" && audio.isEngineRunning && audio.muted)
        precondition(routes.contains { $0.id == "input:synthetic-car" })
        precondition(graph === AVAudioEngine.latest!)
        try audio.selectRoute("input:synthetic-car"); await settle()
        precondition(session.mode == .voiceChat && session.categoryOptions.contains(.allowBluetoothHFP))
        precondition(selected == "input:synthetic-car" && audio.isEngineRunning)
        precondition(AVAudioConverter.sourceRates.last == 16000)
        try audio.selectRoute("input:phone"); await settle()
        precondition(selected == "input:phone" && graph === AVAudioEngine.latest!)
        // CallKit reactivation preserves the receiver choice and its tap lease.
        audio.audioSessionDeactivated()
        precondition(!audio.isEngineRunning && audio.muted && audio.isActiveCall)
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        audio.audioSessionActivated(); await settle()
        precondition(selected == "input:phone" && audio.isEngineRunning && audio.muted && message == nil)
        // Resume/switching uses actual buffer format on the ORIGINAL tap.
        let beforeResume = audio.outgoing.captureStats().taps
        graph.inputNode.deliverHardwareBuffer()
        precondition(audio.outgoing.captureStats().taps > beforeResume)
        // A disconnected remembered device is rejected after restoring eligibility.
        session.connectedInputs = [AVAudioSession.mic]
        do { try audio.selectRoute("input:synthetic-car"); preconditionFailure("Disconnected HFP accepted") } catch {}
        precondition(audio.isActiveCall && audio.muted)
        session.connectedInputs = [AVAudioSession.mic, AVAudioSession.car]
        try audio.selectRoute("input:synthetic-car"); await settle()
        // Failure verification observes only; it cannot create retry storms.
        session.speakerRejected = true
        let failedOverrides = session.overrideRequests
        try audio.selectRoute("speaker"); await settle()
        precondition(session.overrideRequests == failedOverrides + 1)
        precondition(selected == "input:synthetic-car" && message?.contains("未切换成功") == true)
        graph.configurationChanged(); await settle()
        precondition(message?.contains("未切换成功") == true && audio.isActiveCall)
        session.speakerRejected = false
        try audio.retryAudio(); await settle()
        precondition(selected == "speaker" && message == nil && audio.isEngineRunning)
        // A reported target without a running engine is not a successful switch;
        // publishing the route must not immediately erase the failure message.
        session.startFailures = 10
        try audio.selectRoute("input:phone"); await settle()
        precondition(session.currentRoute.outputs.first?.portType == .builtInReceiver)
        precondition(!audio.isEngineRunning && selected.isEmpty && message?.contains("未切换成功") == true)
        session.startFailures = 0
        try audio.retryAudio(); await settle()
        precondition(selected == "input:phone" && message == nil && audio.isEngineRunning)
        // New choices cancel old confirmations. Preserve mute and waiting tone.
        try audio.selectRoute("input:phone")
        try audio.selectRoute("input:synthetic-car"); await settle()
        precondition(selected == "input:synthetic-car" && message == nil && audio.muted)
        audio.setActiveCall(false); audio.setWaitingTone(true)
        session.startFailures = 1
        graph.configurationChanged(); await settle()
        precondition(audio.isWaitingTone && audio.isEngineRunning && audio.muted)
        session.startFailures = 10
        graph.configurationChanged(); await settle()
        precondition(message?.contains("切换未恢复") == true)
        session.startFailures = 0
        try audio.retryAudio(); await settle()
        precondition(message == nil && audio.isEngineRunning && audio.isWaitingTone)
        // Original no-Bluetooth receiver/speaker behavior remains mandatory.
        audio.stop(); session.reset(); session.connectedInputs = [AVAudioSession.mic]
        audio.beginRouting(UUID()); audio.audioSessionActivated()
        try await audio.start(callKitManaged: true)
        audio.setActiveCall(true)
        let phoneGraph = AVAudioEngine.latest!
        try audio.selectRoute("speaker"); await settle()
        precondition(selected == "speaker" && audio.isActiveCall && audio.isEngineRunning)
        try audio.selectRoute("input:phone"); await settle()
        precondition(selected == "input:phone" && message == nil && phoneGraph === AVAudioEngine.latest!)
        // A pending confirmation and old notification cannot cross calls.
        try audio.selectRoute("speaker"); audio.stop()
        session.reset(); audio.beginRouting(UUID()); audio.audioSessionActivated()
        try await audio.start(callKitManaged: true)
        let nextGraph = AVAudioEngine.latest!, starts = AVAudioEngine.latest!.starts
        graph.configurationChanged(); phoneGraph.configurationChanged(); await settle()
        precondition(nextGraph.starts == starts && audio.isEngineRunning && message == nil)
        precondition(session.activeCalls == 0) // CallKit owns activation/deactivation.
        audio.stop()
        print("通过：15Pro现场序列重放/暂停时不确认/保持同一I/O引擎、voiceChat隐式HFP/听筒会话/蓝牙恢复及断开校验、原tap动态格式转换、CallKit重新激活/静音/等待音、选择核验不重复写入/失败可重试/新选择优先、无蓝牙听筒↔扬声器、新旧通话隔离；物理声音未由模拟证明")
    }
}
