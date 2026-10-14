// Deterministic AVAudio doubles for the shipped VoiceAudio. No microphone, CallKit, network or modem.
import Foundation

typealias AVAudioFrameCount = UInt32
typealias AVAudioNodeTapBlock = (AVAudioPCMBuffer, Int) -> Void
let AVAudioSessionRouteChangeReasonKey = "route-reason"
let AVAudioSessionInterruptionTypeKey = "interruption-type"
extension Notification.Name { static let AVAudioEngineConfigurationChange = Self("engine-config") }
struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }

final class AVAudioSession {
    struct Port: Hashable {
        let rawValue: String
        static let builtInSpeaker = Self(rawValue: "speaker"), builtInReceiver = Self(rawValue: "receiver"), builtInMic = Self(rawValue: "mic")
        static let bluetoothHFP = Self(rawValue: "hfp"), carAudio = Self(rawValue: "car"), headsetMic = Self(rawValue: "headset"), usbAudio = Self(rawValue: "usb")
    }
    struct PortDescription { let uid: String; let portType: Port; let portName: String }
    struct Route { var inputs: [PortDescription]; var outputs: [PortDescription] }
    enum RouteChangeReason: UInt { case unknown, newDeviceAvailable, oldDeviceUnavailable, categoryChange, override }
    enum InterruptionType: UInt { case began, ended }
    enum Category { case playback, playAndRecord }
    enum Mode { case `default`, voiceChat }
    struct CategoryOptions: OptionSet { let rawValue: Int; static let allowBluetoothHFP = Self(rawValue: 1), defaultToSpeaker = Self(rawValue: 2) }
    enum PortOverride { case speaker, none }
    struct SetActiveOptions: OptionSet { let rawValue: Int; static let notifyOthersOnDeactivation = Self(rawValue: 1) }
    static let routeChangeNotification = Notification.Name("route"), interruptionNotification = Notification.Name("interrupt")
    static let value = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { value }
    static let mic = PortDescription(uid: "phone-mic", portType: .builtInMic, portName: "iPhone 麦克风")
    static let pods = PortDescription(uid: "synthetic-pods", portType: .bluetoothHFP, portName: "Test AirPods")
    var availableInputs: [PortDescription]? = [mic, pods]
    var currentRoute = Route(inputs: [], outputs: [])
    var hardwareRate = 48000.0
    var preferred: PortDescription?
    var speakerOverride = false
    var categoryChanges = 0, overrides = 0, preferredRequests = 0
    var startFailures = 0
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions = []) throws { categoryChanges += 1 }
    func setPreferredIOBufferDuration(_ value: Double) throws {}
    func setActive(_ value: Bool, options: SetActiveOptions = []) throws {}
    func setPreferredInput(_ port: PortDescription?) throws { preferredRequests += 1; preferred = port; apply(.override) }
    func overrideOutputAudioPort(_ port: PortOverride) throws { overrides += 1; speakerOverride = port == .speaker; apply(.override) }
    /// iOS voiceChat routing: speaker override wins; else the preferred (or newest) HFP device; else receiver.
    func apply(_ reason: RouteChangeReason) {
        let before = currentRoute.outputs.first?.portType
        let connected = availableInputs ?? []
        let hfp = preferred.flatMap { p in connected.first { $0.uid == p.uid && $0.portType == .bluetoothHFP } }
            ?? (preferred == nil ? connected.first { $0.portType == .bluetoothHFP } : nil)
        if speakerOverride {
            currentRoute = Route(inputs: [Self.mic], outputs: [.init(uid: "spk", portType: .builtInSpeaker, portName: "Speaker")])
        } else if let hfp {
            currentRoute = Route(inputs: [hfp], outputs: [hfp])
        } else {
            currentRoute = Route(inputs: [Self.mic], outputs: [.init(uid: "rcv", portType: .builtInReceiver, portName: "Receiver")])
        }
        hardwareRate = currentRoute.inputs.first?.portType == .bluetoothHFP ? 16000 : 48000
        if before != currentRoute.outputs.first?.portType, let engine = AVAudioEngine.latest, engine.isRunning { engine.configurationChanged() }
        NotificationCenter.default.post(name: Self.routeChangeNotification, object: self, userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }
    func disconnectPods() {
        availableInputs = [Self.mic]
        if preferred?.uid == Self.pods.uid { preferred = nil }
        apply(.oldDeviceUnavailable)
    }
}
enum AVAudioApplication { static func requestRecordPermission() async -> Bool { true } }
enum AVAudioCommonFormat { case pcmFormatFloat32, pcmFormatInt16 }
final class AVAudioFormat {
    let sampleRate: Double, channelCount: UInt32
    func isEqual(_ other: AVAudioFormat) -> Bool { sampleRate == other.sampleRate && channelCount == other.channelCount }
    init?(commonFormat: AVAudioCommonFormat, sampleRate: Double, channels: UInt32, interleaved: Bool) { self.sampleRate = sampleRate; channelCount = channels }
    init?(standardFormatWithSampleRate rate: Double, channels: UInt32) { sampleRate = rate; channelCount = channels }
}
final class AVAudioPCMBuffer {
    let format: AVAudioFormat
    var frameLength: UInt32 = 0
    private let floats: UnsafeMutablePointer<Float>, ints: UnsafeMutablePointer<Int16>
    private let fc: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, ic: UnsafeMutablePointer<UnsafeMutablePointer<Int16>>
    var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? { UnsafePointer(fc) }
    var int16ChannelData: UnsafePointer<UnsafeMutablePointer<Int16>>? { UnsafePointer(ic) }
    init?(pcmFormat: AVAudioFormat, frameCapacity: UInt32) {
        format = pcmFormat
        floats = .allocate(capacity: Int(frameCapacity)); floats.initialize(repeating: 0, count: Int(frameCapacity))
        ints = .allocate(capacity: Int(frameCapacity)); ints.initialize(repeating: 0, count: Int(frameCapacity))
        fc = .allocate(capacity: 1); fc.initialize(to: floats); ic = .allocate(capacity: 1); ic.initialize(to: ints)
    }
    deinit { floats.deallocate(); ints.deallocate(); fc.deallocate(); ic.deallocate() }
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
    private(set) var tapped = false
    private var block: AVAudioNodeTapBlock?
    var tapInstalls = 0
    func hardware() -> AVAudioFormat { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AVAudioSession.value.hardwareRate, channels: 1, interleaved: false)! }
    func outputFormat(forBus: Int) -> AVAudioFormat { hardware() }
    func inputFormat(forBus: Int) -> AVAudioFormat { hardware() }
    func installTap(onBus: Int, bufferSize: UInt32, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {
        precondition(!tapped, "Duplicate capture tap")
        precondition(format == nil || format!.isEqual(hardware()), "Forced tap format conflicts with hardware (build41 crash)")
        tapped = true; self.block = block; tapInstalls += 1
    }
    func removeTap(onBus: Int) { precondition(tapped); tapped = false; block = nil }
    func deliver() {
        guard let block else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: hardware(), frameCapacity: 1024)!
        buffer.frameLength = 1024; block(buffer, 0)
    }
}
final class AVAudioPlayerNode: AVAudioNode {
    enum CompletionCallbackType { case dataPlayedBack }
    struct BufferOptions: OptionSet { let rawValue: Int; static let loops = Self(rawValue: 1) }
    var playing = false
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, completionCallbackType: CompletionCallbackType, completionHandler: @escaping (Int) -> Void) {}
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at: Int?, options: BufferOptions, completionHandler: (() -> Void)?) {}
    func play() { playing = true }; func stop() { playing = false }
}
final class AVAudioEngine: NSObject, @unchecked Sendable {
    static var latest: AVAudioEngine?
    static var created = 0
    let inputNode = AVAudioNode(), outputNode = AVAudioNode(), mainMixerNode = AVAudioNode()
    var isRunning = false, starts = 0, outputRate = 0.0
    override init() { super.init(); Self.latest = self; Self.created += 1 }
    func attach(_ node: AVAudioNode) {}
    func connect(_ node: AVAudioNode, to: AVAudioNode, format: AVAudioFormat?) { if to === outputNode { outputRate = format?.sampleRate ?? 0 } }
    func prepare() {}
    func start() throws {
        if AVAudioSession.value.startFailures > 0 { AVAudioSession.value.startFailures -= 1; throw APIError(message: "synthetic start failure") }
        precondition(outputRate == 0 || outputRate == AVAudioSession.value.hardwareRate, "Mixer bound to stale output rate")
        isRunning = true; starts += 1; inputNode.deliver()
    }
    func stop() { isRunning = false }
    func configurationChanged() { isRunning = false; NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self) }
}

@main struct VoiceAudioRouteChecks {
    static func settle() async { try? await Task.sleep(nanoseconds: 500_000_000) }
    @MainActor static func main() async throws {
        let session = AVAudioSession.value
        session.apply(.unknown)
        let audio = VoiceAudio()
        var message: String? = nil, selected = "", name = "", routes: [CallAudioRoute] = []
        var speaker = false
        audio.onAudioStatusChanged = { message = $0 }
        audio.onRoutesChanged = { routes = $0; selected = $1; name = $2 }
        audio.onSpeakerChanged = { speaker = $0 }
        // CallKit path with AirPods connected: call starts on AirPods.
        try await audio.start(callKitManaged: true)
        let graph = AVAudioEngine.latest!
        audio.setActiveCall(true); audio.setMuted(true)
        let pods = "device:" + AVAudioSession.pods.uid
        precondition(selected == pods && name == "Test AirPods" && routes.map(\.id) == ["receiver", "speaker", pods])
        precondition(session.categoryChanges == 0, "CallKit owns the category")
        func check(_ id: String, _ port: AVAudioSession.Port, _ rate: Double, _ label: String) async throws {
            let taps = audio.outgoing.captureStats().taps
            try audio.selectRoute(id); await settle()
            precondition(session.currentRoute.outputs.first?.portType == port, label + ": wrong output")
            precondition(selected == id && message == nil, label + ": checkmark must follow real output")
            precondition(audio.isEngineRunning && audio.isActiveCall && audio.muted, label + ": call/mute lost")
            precondition(graph === AVAudioEngine.latest! && AVAudioEngine.created == 1, label + ": engine must not be replaced")
            precondition(AVAudioConverter.sourceRates.last == rate && audio.outgoing.captureStats().taps > taps, label + ": capture not rebound")
        }
        try await check("speaker", .builtInSpeaker, 48000, "AirPods→扬声器"); precondition(speaker)
        try await check("receiver", .builtInReceiver, 48000, "扬声器→听筒"); precondition(!speaker)
        try await check(pods, .bluetoothHFP, 16000, "听筒→AirPods")
        try await check("receiver", .builtInReceiver, 48000, "AirPods→听筒")
        try await check("speaker", .builtInSpeaker, 48000, "听筒→扬声器")
        try await check(pods, .bluetoothHFP, 16000, "扬声器→AirPods")
        precondition(session.categoryChanges == 0, "Never change CallKit category/mode mid-call")
        // Removing AirPods mid-call: falls back to receiver, call kept, capture rebound.
        session.disconnectPods(); await settle()
        precondition(selected == "receiver" && audio.isEngineRunning && audio.isActiveCall && message == nil)
        precondition(routes.map(\.id) == ["receiver", "speaker"])
        do { try audio.selectRoute(pods); preconditionFailure("disconnected device accepted") } catch {}
        precondition(audio.isActiveCall && audio.isEngineRunning)
        // Interruption ended resumes the same graph.
        graph.stop()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        await settle(); precondition(audio.isEngineRunning)
        // Transient start failures recover; persistent failure only reports, never ends the call.
        session.availableInputs = [AVAudioSession.mic, AVAudioSession.pods]
        session.startFailures = 2
        try audio.selectRoute(pods); try? await Task.sleep(nanoseconds: 2_000_000_000)
        precondition(audio.isEngineRunning && message == nil && selected == pods)
        session.startFailures = 99
        try audio.selectRoute("speaker"); try? await Task.sleep(nanoseconds: 3_500_000_000)
        precondition(!audio.isEngineRunning && audio.isActiveCall && message?.contains("通话仍保留") == true)
        session.startFailures = 0
        audio.retryAudio(); await settle()
        precondition(audio.isEngineRunning && message == nil && selected == "speaker")
        // Old-graph notifications cannot touch the next call.
        audio.stop()
        precondition(!graph.inputNode.tapped)
        session.speakerOverride = false; session.preferred = nil; session.apply(.unknown)
        try await audio.start(callKitManaged: true)
        let next = AVAudioEngine.latest!, starts = next.starts
        graph.configurationChanged(); await settle()
        precondition(next.starts == starts && audio.isEngineRunning)
        audio.stop()
        // No Bluetooth: original receiver↔speaker still works.
        session.availableInputs = [AVAudioSession.mic]; session.apply(.unknown)
        try await audio.start(callKitManaged: true)
        try audio.selectRoute("speaker"); await settle()
        precondition(selected == "speaker" && audio.isEngineRunning)
        try audio.selectRoute("receiver"); await settle()
        precondition(selected == "receiver" && audio.isEngineRunning && routes.count == 2)
        audio.stop()
        print("通过：AirPods↔扬声器↔听筒六向切换、显示按实际输出、保持同一引擎与静音、采音按新格式重装、拔出AirPods不挂断、中断恢复、启动失败重试与只提示不挂断、新旧通话隔离、无蓝牙听筒↔扬声器（模拟，未证明真机声音）")
    }
}
