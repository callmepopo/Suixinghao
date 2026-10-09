import SwiftUI
import AVFoundation
import UserNotifications
import Network

@MainActor @Observable
final class AppModel {
    var demo = true
    var busy = false
    var restoringConnection = false
    var loadingContent = false
    var notice: String?
    var connectionMessage = "等待连接"
    var serviceRTT: Int?
    var lastServiceCheck: Date?
    var diagnostics: PhoneDiagnostics?
    var diagnosticMessage: String?
    var connectionHistory: ConnectionHistory?
    var localConnectionEvents: [ConnectionEvent] = []
    var localConnectionSummary: ConnectionSummary?
    var pendingConnectionEvents = 0
    var connectionHistoryMessage = ""
    var loadingConnectionHistory = false
    @ObservationIgnored private let telemetry = ConnectionTelemetry()
    @ObservationIgnored private let historyAPI = API()
    @ObservationIgnored private var historyUploadTask: Task<Void, Never>?
    private var lastHistoryUpload = Date.distantPast
    var dialingStage = ""
    var hangupMessage: String?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
    @ObservationIgnored private var hangupTask: Task<Void, Never>?
    private var recoveryGeneration = UUID()
    private var networkSignature: String?
    private var networkAvailable = true
    private var authenticationRejected = false
    private var loggingOut = false
    private var pendingHangupID: String?
    private var nextDiagnostics = Date.distantPast
    var status: CallStatus?
    var contacts: [SMSContact] = []
    var devices: [Device] = []
    var connected = false
    var endpoint = ""
    var mediaConnected = false
    var callBusy = false
    var muted = false
    var speakerEnabled = false
    var ownedCallID: String?
    var callStartedAt: Date?
    var statusFresh = false
    var smsNotificationState = "未开启"
    var openSMSFromNotification = false
    var externalDialNumber: String?
    #if DEBUG
    var externalCallRoute = "尚未收到系统号码事件"
    #endif
    var callerDisplayName: String?
    var callHistory: [CallRecord] = []

    func acceptExternalCall(_ raw: String) {
        do {
            externalDialNumber = try API.normalizedExternalCallNumber(raw)
            #if DEBUG
            externalCallRoute = "收到有效号码，等待拨号页填入"
            #endif
        } catch {
            #if DEBUG
            externalCallRoute = "收到号码，但格式不受支持"
            #endif
            notice = error.localizedDescription
        }
    }
    #if DEBUG
    var audioDiagnostics = "音频：等待连接"
    #endif
    @ObservationIgnored private let audio = VoiceAudio()
    @ObservationIgnored private let transport = VoiceTransport()
    @ObservationIgnored private var voip: VoIPCalls?
    @ObservationIgnored private var smsPushToken: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private var isForeground = true
    private var epoch = UUID()
    @ObservationIgnored private let connectionOperation = SharedOperation()
    @ObservationIgnored private let statusOperation = SharedOperation()
    @ObservationIgnored private let sessionOperation = SharedOperation()
    @ObservationIgnored private var contentTask: Task<Void, Never>?
    private var answeringSystemCallID: String?
    private var lastCallerLookup: String?
    private var systemCallActive = false
    private var systemCallUUID: UUID?
    var systemCallPreparing = false
    private var canRunCallInBackground: Bool {
        systemCallActive || (mediaConnected && ownedCallID != nil)
    }

    var connectionTitle: String {
        if demo { return "演示模式" }
        if restoringConnection { return "正在恢复连接" }
        if connected && statusFresh { return "已连接 · \(status?.title ?? "待机")" }
        return "连接待恢复"
    }

    init() {
        if ConnectionStore.load() != nil { demo = false; restoringConnection = true }
        transport.onAudio = { [weak self] data in self?.audio.play(data) }
        transport.onFailure = { [weak self] message in
            guard let self else { return }
            self.statusFresh = false
            Task { @MainActor in await self.endCall(reason: message) }
        }
        audio.onInterrupted = { [weak self] in
            Task { @MainActor in
                guard let self, self.mediaConnected || self.ownedCallID != nil else { return }
                await self.endCall(reason: "音频设备发生变化，本次通话已结束，请重新拨打。")
            }
        }
        audio.onSpeakerChanged = { [weak self] value in self?.speakerEnabled = value }
        voip = VoIPCalls(model: self)
        telemetry.canUpload = { [weak self] in self?.canSyncHistory == true }
        telemetry.onUpload = { [weak self] in self?.scheduleHistoryUpload() }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let signature = "\(available)/\(path.usesInterfaceType(.wifi))/\(path.usesInterfaceType(.cellular))/\(path.isExpensive)"
            Task { @MainActor in self?.networkChanged(available: available, signature: signature) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "sxh.network-path"))
    }
    private var startupStarted = false
    private var connectionStage = "start"
    private var connectionFailure = ""
    private let api = API()
    private var base: URL?
    private var smsToken = ""
    private var voiceToken = ""
    private var voiceExpires = Date.distantPast

    var visibleContacts: [SMSContact] { demo ? Self.samples : contacts }
    static let samples = [
        SMSContact(peer: "随行号演示", iccid: nil, imsi: nil, device_id: nil, last_content: "你的远程 SIM，装进口袋。这里是演示消息，不来自真实设备。", last_timestamp: "演示", unread_count: 1),
        SMSContact(peer: "连接指南", iccid: nil, imsi: nil, device_id: nil, last_content: "在设置中填写地址和鉴权 Key，即可读取模块中的短信。", last_timestamp: "演示", unread_count: 0)
    ]
    func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await action() }
        catch {
            if let error = error as? DecodingError {
                switch error {
                case .keyNotFound(let key, _): connectionFailure = "missing-field:" + key.stringValue
                case .typeMismatch(_, let context): connectionFailure = "type:" + (context.codingPath.last?.stringValue ?? "root")
                case .valueNotFound(_, let context): connectionFailure = "null:" + (context.codingPath.last?.stringValue ?? "root")
                default: connectionFailure = "json"
                }
            } else if let api = error as? APIError { connectionFailure = "api:" + String(api.statusCode ?? 0) }
            else { let ns = error as NSError; connectionFailure = ns.domain + ":" + String(ns.code) }
            if let failure = error as? APIError, failure.statusCode == 401 {
                try? ConnectionStore.clear()
                pollTask?.cancel(); pollTask = nil; releaseMedia(); epoch = UUID()
                smsToken = ""; voiceToken = ""; base = nil
                contacts = []; devices = []; status = nil
                callHistory = []
                connected = false; demo = true; endpoint = ""
            }
            notice = error.localizedDescription
        }
    }
    func connect(address: String, key: String) async {
        authenticationRejected = false
        // All startup / PushKit / answer callers await the same critical recovery.
        do {
            try await connectionOperation.run(timeout: 10_000_000_000, onFailure: { error in
                guard !(error is CancellationError) else { return }
                // Retain Keychain settings after a network failure for retry.
                self.connected = false; self.statusFresh = false
                self.connectionFailure = (error as? APIError)?.statusCode.map { "api:" + String($0) } ?? "connection"
                self.authenticationRejected = [401, 403].contains((error as? APIError)?.statusCode ?? 0)
                self.telemetry.failed(authentication: self.authenticationRejected)
                self.connectionMessage = self.authenticationRejected ? "鉴权失效，请重新填写 Key。" : "\(self.connectionStage == "voice-session" ? "建立服务会话" : "获取电话状态")失败，正在自动重试。"
                if self.authenticationRejected { self.notice = self.connectionMessage }
                self.scheduleRecovery()
            }) {
                self.restoringConnection = true
                let url = try API.baseURL(address)
                let token = try API.normalizedKey(key)
                self.telemetry.configure(address: url.absoluteString, key: token, active: self.isForeground || self.canRunCallInBackground)
                self.telemetry.network(available: self.networkAvailable, changed: false)
                self.telemetry.attempt()
                self.contentTask?.cancel()
                self.loadingContent = false
                self.statusOperation.cancel(); self.sessionOperation.cancel()
                self.epoch = UUID()
                let run = self.epoch
                defer { if self.epoch == run { self.restoringConnection = false } }
                self.statusFresh = false
                self.connectionStage = "voice-session"
                let data = try await self.api.request(url, path: "voice-test/app/session", token: token, body: [:], timeout: 5)
                let session = try JSONDecoder().decode(LoginResponse.self, from: data)
                guard !session.token.isEmpty else { throw APIError(message: "电话服务未返回有效会话。") }
                self.connectionStage = "voice-status"
                // Keep the bounded recovery in one cancellation scope. Do not expose
                // connected until a fresh phone status has actually arrived.
                let checkStarted = Date()
                let initialStatus = try await self.api.read(CallStatus.self, base: url, path: "voice-test/status", token: session.token, timeout: 5)
                self.serviceRTT = Int(Date().timeIntervalSince(checkStarted) * 1000)
                self.lastServiceCheck = Date()
                try Task.checkCancellation()
                guard self.epoch == run else { throw CancellationError() }
                self.connectionStage = "keychain-save"
                try ConnectionStore.save(.init(address: url.absoluteString, key: token))
                self.base = url; self.smsToken = token; self.voiceToken = session.token
                self.endpoint = url.absoluteString
                self.callHistory = CallHistoryStore.load(server: self.endpoint)
                self.voiceExpires = Date().addingTimeInterval(max(30, (session.expires_in ?? 900) - 60))
                self.connected = true; self.demo = false
                self.contacts = []; self.devices = []; self.status = nil
                self.applyStatus(initialStatus)
                self.scheduleHistoryUpload()
                self.connectionStage = "complete"
                self.connectionMessage = "电话服务已连接"
                self.refreshDiagnostics()
                self.notice = nil
                self.startPolling()
                // SMS and notification registration must never hold up answering.
                self.contentTask = Task { [weak model = self] in
                    guard let self = model else { return }
                    async let registration: Void = self.registerVoIPToken()
                    do { try await self.reloadContent() }
                    catch { if !Task.isCancelled && self.epoch == run { self.notice = "电话状态已恢复，短信加载失败，请稍后刷新。" } }
                    await registration
                    guard !Task.isCancelled, self.epoch == run else { return }
                    await self.enableSMSNotifications()
                }
            }
        } catch { /* The shared operation reports failure once for all waiters. */ }
    }
    func startup() async {
        guard !startupStarted else { return }
        startupStarted = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-history") {
            let now = Date().timeIntervalSince1970
            let events = [
                ConnectionEvent(id:"preview-online",at:now-180,layer:"phone",kind:"connected",state:"online",reason:""),
                ConnectionEvent(id:"preview-down",at:now-120,layer:"phone",kind:"network_down",state:"offline",reason:"no_network"),
                ConnectionEvent(id:"preview-up",at:now-85,layer:"phone",kind:"network_up",state:"",reason:""),
                ConnectionEvent(id:"preview-success",at:now-82,layer:"phone",kind:"connected",state:"online",reason:""),
                ConnectionEvent(id:"preview-background",at:now-60,layer:"phone",kind:"observer_stop",state:"unknown",reason:"background")
            ]
            localConnectionEvents = events.reversed()
            localConnectionSummary = .phone(events: events, now: now)
            connectionHistoryMessage = "合成数据预览 · 未连接真实服务"
            connectionHistory = ConnectionHistory(generated_at:now,summaries:[
                .init(layer:"module",online_seconds:3600,offline_seconds:60,unknown_seconds:82740,coverage:3660/86400,online_rate:3600/3660,interruptions:1),
                .init(layer:"network",online_seconds:3500,offline_seconds:120,unknown_seconds:82780,coverage:3620/86400,online_rate:3500/3620,interruptions:2)
            ], events:[],outages:[.init(id:"preview-outage",start:now-120,end:now-82,network_restored:now-85,attempts:2,reason:"no_network",incomplete:false)],retention_days:30)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--local-voice-check") {
            await localVoiceCheck()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--integration-check") {
            await integrationCheck()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--provision-connection") {
            let env = ProcessInfo.processInfo.environment
            let busyBefore = busy
            for _ in 0..<50 where busy {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if let address = env["SXH_PROVISION_BASE"], let key = env["SXH_PROVISION_KEY"] {
                await connect(address: address, key: key)
            }
            if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let data = try? JSONSerialization.data(withJSONObject: [
                "environment_received": env["SXH_PROVISION_BASE"] != nil && env["SXH_PROVISION_KEY"] != nil,
                "connected": connected,
                "keychain_saved": ConnectionStore.load() != nil,
                "stage": connectionStage,
                "busy_before": busyBefore,
                "busy_after": busy,
                "nonce": env["SXH_PROVISION_NONCE"] ?? ""
               ]) {
                try? data.write(to: folder.appendingPathComponent("provision-result.json"), options: .atomic)
            }
            return
        }
        #endif
        await restore()
    }
    #if DEBUG
    private func localVoiceCheck() async {
        pathMonitor.cancel()
        var mockState = "active"
        var results: [String: Any] = [:]
        var checks: [String: Bool] = [:]
        func view(_ state: String, _ id: String? = "local-call") -> CallStatus {
            CallStatus(state: state, available: true, recording: nil, call_id: id, caller: nil, media: nil, message: nil)
        }
        func own() {
            mockState = "active"
            connected = true; demo = false; mediaConnected = true; ownedCallID = "local-call"
            statusFresh = true; status = view("active"); isForeground = true
        }
        base = URL(string: "https://example.invalid")!; voiceToken = "local-test"; voiceExpires = .distantFuture
        var actions: [[String: String]] = []
        var failHangup = false
        var releasedBeforeRequest = false
        api.testRequest = { [weak self] path, body in
            // Notification token registration can arrive concurrently at startup.
            // Count only telephone commands when asserting DTMF/hangup behavior.
            if path == "voice-test/phone", let body {
                actions.append(body)
                if body["action"] == "hangup" {
                    releasedBeforeRequest = self?.mediaConnected == false && self?.ownedCallID == nil
                    try await Task.sleep(nanoseconds: 100_000_000)
                    mockState = "idle"
                    if failHangup { throw APIError(message: "通话已结束", statusCode: 409) }
                }
            }
            return Data("{\"state\":\"\(mockState)\",\"available\":true,\"call_id\":\"local-call\"}".utf8)
        }
        own()
        for digit in ["1", "*", "#"] { await dtmf(digit) }
        let validCount = actions.count
        for digit in ["", "12", ";ATH"] { await dtmf(digit) }
        checks["dtmf_valid_and_invalid"] = validCount == 3 && actions.count == 3 && actions.allSatisfy { $0["call_id"] == "local-call" }
        statusFresh = false; await dtmf("2")
        checks["dtmf_blocked_on_stale_status"] = actions.count == 3
        own(); let beforeBackground = actions.count
        await foreground(false)
        checks["background_preserves_established_call"] = mediaConnected && ownedCallID == "local-call" && actions.count == beforeBackground && pollTask != nil
        await foreground(true)
        checks["foreground_return_preserves_call"] = mediaConnected && ownedCallID == "local-call" && pollTask != nil
        own(); ownedCallID = nil; releasedBeforeRequest = false
        await foreground(false)
        checks["background_releases_unowned_media"] = !mediaConnected && pollTask == nil && actions.count == beforeBackground
        own(); await foreground(false); await hangup()
        checks["background_hangup_releases_before_http"] = releasedBeforeRequest && !mediaConnected && ownedCallID == nil && pollTask == nil
        own(); notice = nil; failHangup = true; releasedBeforeRequest = false
        await hangup()
        checks["already_ended_hangup_reconciles_status"] = releasedBeforeRequest && !mediaConnected && ownedCallID == nil && status?.state == "idle" && notice == nil
        own(); releasedBeforeRequest = false
        transport.onFailure?("Local simulated connection failure")
        try? await Task.sleep(nanoseconds: 200_000_000)
        checks["disconnect_releases_and_requests_hangup"] = releasedBeforeRequest && !mediaConnected && ownedCallID == nil
        own(); applyStatus(view("idle", nil))
        checks["remote_hangup_releases_media"] = !mediaConnected && ownedCallID == nil
        own(); applyStatus(view("active", "other-call"))
        checks["ownership_change_releases_media"] = !mediaConnected && ownedCallID == nil
        own(); notice = nil
        var confirms = 0
        api.testRequest = { _, body in
            if body?["action"] == "hangup" { return Data(#"{"state":"active","available":true,"call_id":"local-call"}"#.utf8) }
            confirms += 1
            return Data((confirms < 3 ? #"{"state":"active","available":true,"call_id":"local-call"}"# : #"{"state":"idle","available":true}"#).utf8)
        }
        await hangup()
        checks["hangup_waits_for_delayed_modem_idle"] = confirms >= 3 && pendingHangupID == nil && hangupMessage == nil && notice == nil
        own()
        var hungIDs: [String] = []
        api.testRequest = { _, body in
            if let id = body?["call_id"] { hungIDs.append(id) }
            return Data(#"{"state":"ringing","available":true,"call_id":"next-call"}"#.utf8)
        }
        await hangup()
        checks["old_hangup_never_targets_new_call"] = hungIDs == ["local-call"] && pendingHangupID == nil && status?.call_id == "next-call"
        ownedCallID = nil; mediaConnected = false; systemCallActive = false
        authenticationRejected = false; networkAvailable = true; isForeground = true
        var recoveryReads = 0
        api.testRequest = { path, _ in
            if path == "voice-test/status" {
                recoveryReads += 1
                if recoveryReads < 3 { throw URLError(.timedOut) }
            }
            return Data(#"{"state":"idle","available":true}"#.utf8)
        }
        statusFresh = false; scheduleRecovery(immediate: true)
        await recoveryTask?.value
        checks["automatic_retry_recovers_without_refresh"] = recoveryReads == 3 && statusFresh && connected && recoveryTask == nil
        pollTask?.cancel(); pollTask = nil
        api.testRequest = { _, _ in throw APIError(message: "invalid", statusCode: 401) }
        scheduleRecovery(immediate: true); await recoveryTask?.value
        checks["authentication_failure_stops_retry"] = authenticationRejected && !connected && recoveryTask == nil
        authenticationRejected = false
        connected = false; demo = true; api.testRequest = nil; base = nil; voiceToken = ""
        status = nil; notice = nil; statusFresh = false
        if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: ["checks": checks]) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent("local-voice-progress.json"), options: .atomic)
        }
        // Actual microphone -> AVAudioConverter -> PCMFrames -> native WS -> loopback sink.
        // Neither microphone samples nor server credentials are saved in this test.
        if let raw = ProcessInfo.processInfo.environment["SXH_LOCAL_AUDIO_URL"], let local = URL(string: raw), local.host == "127.0.0.1" {
            do {
                try await audio.start()
                audio.setWaitingTone(true)
                try await Task.sleep(nanoseconds: 300_000_000)
                checks["waiting_tone_does_not_enable_capture"] = audio.isWaitingTone && audio.outgoing.captureStats().bytes == 0 && audio.outgoing.next().allSatisfy { $0 == 0 }
                audio.setActiveCall(true)
                checks["connection_stops_waiting_tone"] = !audio.isWaitingTone
                try await transport.connect(base: local, token: "local-test")
                transport.startSending(audio.outgoing)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let stats = audio.outgoing.captureStats()
                results["captured_bytes"] = stats.bytes; results["nonzero_samples"] = stats.nonzero
                checks["microphone_converted_frames"] = stats.bytes >= 16000
                checks["microphone_nonzero"] = stats.nonzero > 0
                func sinkStats() async throws -> [String: Int] {
                    let (data, _) = try await URLSession.shared.data(from: local.appendingPathComponent("stats"))
                    return try JSONDecoder().decode([String: Int].self, from: data)
                }
                toggleMute()
                let mutedBytes = audio.outgoing.captureStats().bytes
                try await Task.sleep(nanoseconds: 300_000_000)
                checks["mute_clears_capture"] = audio.outgoing.next().allSatisfy { $0 == 0 } && audio.outgoing.captureStats().bytes == mutedBytes
                let beforeMuted = try await sinkStats()
                try await Task.sleep(nanoseconds: 200_000_000)
                let afterMuted = try await sinkStats()
                checks["mute_sends_only_silence"] = (afterMuted["frames"] ?? 0) > (beforeMuted["frames"] ?? 0) && afterMuted["nonzero"] == beforeMuted["nonzero"]
                toggleMute()
                try await Task.sleep(nanoseconds: 300_000_000)
                checks["unmute_resumes_capture"] = audio.outgoing.captureStats().bytes > stats.bytes
                own()
                api.testRequest = { _, _ in Data(#"{"state":"active","available":true,"call_id":"local-call"}"#.utf8) }
                let beforeBackgroundFrames = try await sinkStats()
                await foreground(false)
                try await Task.sleep(nanoseconds: 1_300_000_000)
                let afterBackgroundFrames = try await sinkStats()
                checks["background_audio_keeps_sending"] = mediaConnected && audio.isEngineRunning && transport.ready && (afterBackgroundFrames["frames"] ?? 0) > (beforeBackgroundFrames["frames"] ?? 0) + 20
                await foreground(true)
                // Break the actual native socket while owning a simulated call.
                own(); base = URL(string: "https://example.invalid")!; voiceToken = "local-test"
                var attemptedHangup = false
                api.testRequest = { _, body in
                    if body?["action"] == "hangup" { attemptedHangup = true }
                    throw URLError(.notConnectedToInternet)
                }
                _ = try await URLSession.shared.data(from: local.appendingPathComponent("disconnect"))
                for _ in 0..<20 {
                    if !mediaConnected && attemptedHangup { break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                checks["real_socket_loss_cleans_call"] = !transport.ready && !mediaConnected && ownedCallID == nil && attemptedHangup
                audio.stop(); transport.close()
                checks["stop_clears_capture"] = audio.outgoing.next().allSatisfy { $0 == 0 }
            } catch {
                results["audio_error"] = (error as NSError).domain + ":" + String((error as NSError).code)
            }
        }
        audio.stop(); transport.close(); muted = false
        connected = false; demo = true; api.testRequest = nil; base = nil; voiceToken = ""
        status = nil; notice = nil; statusFresh = false
        results["checks"] = checks
        results["ok"] = checks.count >= 24 && checks.values.allSatisfy { $0 }
        if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent("local-voice-result.json"), options: .atomic)
        }
    }
    private func integrationCheck() async {
        let env = ProcessInfo.processInfo.environment
        var result: [String: Any] = ["ok": false, "stage": "connection"]
        if let address = env["SXH_TEST_BASE"], let key = env["SXH_TEST_KEY"] {
            await connect(address: address, key: key)
            result["stage"] = connectionStage + "/" + connectionFailure
            if connected && notice == nil {
                result["stage"] = "sms-thread"
                do {
                    // Integration checks intentionally cover SMS too; normal launch
                    // returns as soon as the phone is ready.
                    await contentTask?.value
                    if ProcessInfo.processInfo.arguments.contains("--integration-sms") {
                        guard let target = env["SXH_TEST_SMS_NUMBER"], let body = env["SXH_TEST_SMS_BODY"],
                              let reply = env["SXH_TEST_SMS_REPLY"], let device = devices.first else { throw APIError(message: "短信测试参数缺失。") }
                        func matches(_ peer: String) -> Bool { peer.filter(\.isNumber).suffix(11) == target.filter(\.isNumber).suffix(11) }
                        let readOnly = env["SXH_TEST_SMS_AFTER_ID"].flatMap(Int.init)
                        var existing = Set<Int>()
                        for contact in contacts where matches(contact.peer) && readOnly == nil {
                            existing.formUnion(try await messages(contact).map(\.id))
                        }
                        result = ["ok": false, "stage": "sms-submit"]
                        let submitted: Bool
                        if readOnly != nil { submitted = true } else { submitted = await send(number: target, message: body, device: device.id) }
                        if submitted {
                            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            let ready = folder.appendingPathComponent("incoming-ready.json")
                            try Data("ready".utf8).write(to: ready, options: .atomic)
                            defer { try? FileManager.default.removeItem(at: ready) }
                            let deadline = Date().addingTimeInterval(300)
                            var received = false
                            while Date() < deadline && !received {
                                try await Task.sleep(nanoseconds: 3_000_000_000)
                                try await reload()
                                for contact in contacts where matches(contact.peer) {
                                    let thread = try await messages(contact)
                                    if thread.contains(where: { $0.type == 1 && !existing.contains($0.id) && $0.id > (readOnly ?? -1) && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == reply }) { received = true }
                                }
                            }
                            result = ["ok": received, "stage": "sms-reply", "sms_submitted": true, "sms_reply_received": received]
                        }
                    } else if ProcessInfo.processInfo.arguments.contains("--integration-incoming") {
                        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let ready = folder.appendingPathComponent("incoming-ready.json")
                        try Data("ready".utf8).write(to: ready, options: .atomic)
                        defer { try? FileManager.default.removeItem(at: ready) }
                        let deadline = Date().addingTimeInterval(300)
                        var answered = false
                        while Date() < deadline {
                            try await Task.sleep(nanoseconds: 500_000_000)
                            if ownedCallID != nil && status?.state == "active" { answered = true }
                            if answered && ownedCallID == nil && status?.state == "idle" { break }
                        }
                        await endCall()
                        result = ["ok": answered && status?.state == "idle", "stage": "incoming-complete", "hangup_idle": status?.state == "idle"]
                    } else {
                    if let first = contacts.first { _ = try await messages(first) }
                    result["stage"] = "websocket"
                    guard let base, status?.state == "idle" else { throw APIError(message: "设备不在待机状态。") }
                    try await transport.connect(base: base, token: voiceToken)
                    transport.startSending(PCMFrames()) // silence, no microphone or call
                    try await Task.sleep(nanoseconds: 200_000_000)
                    guard transport.ready else { throw APIError(message: "声音通道连接失败。") }
                    transport.close()
                    result = ["ok": true, "stage": "complete"]
                    if ProcessInfo.processInfo.arguments.contains("--integration-call"), let target = env["SXH_TEST_CALL_NUMBER"] {
                        result = ["ok": false, "stage": "call-connect"]
                        await dial(target)
                        if ownedCallID != nil {
                            let microphone = ProcessInfo.processInfo.arguments.contains("--integration-microphone")
                            let deadline = Date().addingTimeInterval(microphone ? 55 : 20)
                            var connectedAt: Date?
                            while Date() < deadline && ownedCallID != nil {
                                try await Task.sleep(nanoseconds: 500_000_000)
                                if microphone {
                                    if status?.state == "active" && connectedAt == nil { connectedAt = Date() }
                                    if let connectedAt, Date().timeIntervalSince(connectedAt) >= 25 { break }
                                } else if audio.playedBuffers >= 150 && audio.peak > 0.01 { break }
                            }
                            var controlChecks: [String: Bool] = [:]
                            if let mode = env["SXH_TEST_CONTROLS"], ["background", "disconnect"].contains(mode), status?.state == "active" {
                                notice = nil
                                await dtmf("#")
                                controlChecks["dtmf_hash_accepted"] = notice == nil
                                toggleMute()
                                try await Task.sleep(nanoseconds: 500_000_000)
                                let paused = audio.outgoing.captureStats().bytes
                                try await Task.sleep(nanoseconds: 700_000_000)
                                controlChecks["mute_stops_capture"] = muted && audio.outgoing.captureStats().bytes == paused && audio.outgoing.next().allSatisfy { $0 == 0 }
                                toggleMute()
                                try await Task.sleep(nanoseconds: 1_000_000_000)
                                controlChecks["unmute_resumes_capture"] = !muted && audio.outgoing.captureStats().bytes > paused
                            }
                            let decoded = audio.receivedFrames
                            let rendered = audio.playedBuffers
                            let audibleSignal = audio.peak > 0.01
                            let capture = audio.outgoing.captureStats()
                            if env["SXH_TEST_CONTROLS"] == "background" {
                                await foreground(false)
                                controlChecks["background_handler_preserves_media"] = mediaConnected && ownedCallID != nil
                                await foreground(true)
                                await endCall()
                            } else if env["SXH_TEST_CONTROLS"] == "disconnect" {
                                transport.close()
                                for _ in 0..<12 {
                                    try await Task.sleep(nanoseconds: 500_000_000)
                                    try await readStatus()
                                    if status?.state == "idle" { break }
                                }
                                controlChecks["socket_close_server_idle"] = status?.state == "idle"
                                await endCall()
                            } else { await endCall() }
                            for _ in 0..<10 {
                                try await Task.sleep(nanoseconds: 500_000_000)
                                try await readStatus()
                                if status?.state == "idle" { break }
                            }
                            result = ["ok": decoded > 50 && rendered > 50 && audibleSignal && status?.state == "idle",
                                      "stage": "call-audio", "frames_received": decoded, "buffers_played": rendered,
                                      "non_silent": audibleSignal, "hangup_idle": status?.state == "idle", "microphone_used": microphone,
                                      "captured_bytes": capture.bytes, "captured_nonzero_samples": capture.nonzero, "control_checks": controlChecks]
                            if env["SXH_TEST_CONTROLS"] != nil { result["ok"] = (result["ok"] as? Bool == true) && controlChecks.count == 4 && controlChecks.values.allSatisfy { $0 } }
                        } else { result["stage"] = "call-start/" + (notice == nil ? "unknown" : "rejected") }
                    }
                    }
                } catch { }
            }
            await logout()
            if ConnectionStore.load() != nil { result = ["ok": false, "stage": "keychain-cleanup"] }
        }
        notice = nil
        if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: result) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent("integration-result.json"), options: .atomic)
        }
    }
    #endif
    func restore() async {
        if connected && !restoringConnection { return }
        if let saved = ConnectionStore.load() {
            demo = false
            await connect(address: saved.address, key: saved.key)
        } else if !connectionOperation.isRunning { restoringConnection = false }
    }
    func voipTokenUpdated() async { await registerVoIPToken() }
    func voipTokenInvalidated() async {
        guard let base, connected else { return }
        try? await api.delete(base, path: "voice-test/app/voip-token", token: smsToken)
    }
    private func registerVoIPToken() async {
        guard let base, connected, let token = voip?.token else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        _ = try? await api.request(base, path: "voice-test/app/voip-token", token: smsToken,
                                   body: ["token": token, "environment": environment])
    }
    func enableSMSNotifications() async {
        let center = UNUserNotificationCenter.current()
        do {
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                status = await center.notificationSettings().authorizationStatus
            }
            if status == .authorized || status == .provisional || status == .ephemeral {
                smsNotificationState = "等待推送登记"
                UIApplication.shared.registerForRemoteNotifications()
                await registerSMSPushToken()
            } else {
                smsNotificationState = "未授权；请在 iPhone 设置中允许通知"
            }
        } catch {
            smsNotificationState = "通知授权失败，请稍后重试"
        }
    }
    func smsPushTokenUpdated(_ token: String) async {
        smsPushToken = token
        await registerSMSPushToken()
    }
    private func registerSMSPushToken() async {
        guard let base, connected, let token = smsPushToken else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        do {
            _ = try await api.request(base, path: "voice-test/app/sms-push-token", token: smsToken,
                                      body: ["token": token, "environment": environment])
            smsNotificationState = "已开启"
        } catch {
            smsNotificationState = "提醒登记失败，请打开 App 重试"
        }
    }
    private func renewVoice() async throws {
        try await sessionOperation.run {
            guard let base = self.base, self.connected else { throw APIError(message: "请先连接服务。") }
            guard !self.mediaConnected else { throw APIError(message: "通话期间不能更换声音会话。") }
            let run = self.epoch
            let previous = self.voiceToken
            let data = try await self.api.request(base, path: "voice-test/app/session", token: self.smsToken, body: [:], timeout: 5)
            let session = try JSONDecoder().decode(LoginResponse.self, from: data)
            try Task.checkCancellation()
            guard self.epoch == run, !self.mediaConnected else { throw CancellationError() }
            guard !session.token.isEmpty else { throw APIError(message: "电话服务未返回有效会话。") }
            self.voiceToken = session.token
            self.voiceExpires = Date().addingTimeInterval(max(30, (session.expires_in ?? 900) - 60))
            if !previous.isEmpty { _ = try? await self.api.request(base, path: "voice-test/logout", token: previous, body: [:]) }
        }
    }
    private func reload() async throws {
        try await readStatus()
        try await reloadContent()
    }
    private func reloadContent() async throws {
        guard let base, connected else { return }
        let run = epoch
        loadingContent = true
        defer { if epoch == run { loadingContent = false } }
        let items = try await api.read([SMSContact].self, base: base, path: "voice-test/app/sms/contacts", token: smsToken, query: [.init(name: "limit", value: "200")])
        let list = try await api.read(DeviceList.self, base: base, path: "voice-test/app/devices", token: smsToken)
        try Task.checkCancellation()
        guard epoch == run else { return }
        contacts = items.sorted { $0.last_timestamp > $1.last_timestamp }
        devices = list.devices.filter(\.running)
    }
    private func readStatus() async throws {
        try await statusOperation.run {
            guard let base = self.base, self.connected else { throw APIError(message: "电话连接尚未恢复。") }
            let run = self.epoch
            if Date() >= self.voiceExpires && !self.mediaConnected { try await self.renewVoice() }
            let checkStarted = Date()
            let value: CallStatus
            do { value = try await self.api.read(CallStatus.self, base: base, path: "voice-test/status", token: self.voiceToken, timeout: 5) }
            catch let error as APIError where error.statusCode == 401 && !self.mediaConnected {
                try await self.renewVoice()
                value = try await self.api.read(CallStatus.self, base: base, path: "voice-test/status", token: self.voiceToken, timeout: 5)
            }
            try Task.checkCancellation()
            guard self.epoch == run else { throw CancellationError() }
            self.serviceRTT = Int(Date().timeIntervalSince(checkStarted) * 1000)
            self.lastServiceCheck = Date()
            self.connectionMessage = "电话服务已连接"
            self.applyStatus(value)
        }
    }
    private func applyStatus(_ value: CallStatus) {
        if isForeground || canRunCallInBackground { telemetry.resume(); telemetry.success() }
        let previous = status
        status = value; statusFresh = true
        if let id = pendingHangupID, ConnectionRecovery.ended(value, originalID: id) {
            pendingHangupID = nil; hangupMessage = nil
            hangupTask?.cancel(); hangupTask = nil
        }
        if ownedCallID != nil {
            dialingStage = value.state == "active" ? "已接通" : (value.state == "dialing" ? "等待接听 · 运营商声音由模块提供" : "")
        }
        audio.setWaitingTone(false)
        audio.setEarlyMedia(value.available && value.media == true && value.state == "dialing" && ownedCallID == value.call_id && ownedCallID != nil)
        if value.available {
            for index in callHistory.indices where callHistory[index].endedAt == nil && callHistory[index].id != value.call_id {
                callHistory[index].endedAt = Date()
                persistCallHistory()
            }
        }
        if let id = value.call_id, value.state == "ringing", let caller = value.caller, !caller.isEmpty {
            addCallRecord(id: id, number: caller, direction: "来电")
        }
        if let id = value.call_id, value.state == "active", ownedCallID == id {
            markCallAnswered(id: id)
            voip?.reportConnected(id)
        }
        if let previousID = previous?.call_id,
           (value.state == "idle" || (value.call_id != nil && value.call_id != previousID)) {
            finishCallRecord(id: previousID)
        }
        if value.state == "ringing", let caller = value.caller, !caller.isEmpty {
            if lastCallerLookup != caller {
                lastCallerLookup = caller
                callerDisplayName = caller
                let callID = value.call_id
                Task {
                    let name = await PhoneContacts.name(matching: caller)
                    if status?.call_id == callID, status?.state == "ringing" {
                        callerDisplayName = name ?? caller
                    }
                }
            }
        } else {
            lastCallerLookup = nil
            callerDisplayName = nil
        }
        audio.setActiveCall(value.available && value.state == "active" && ownedCallID != nil)
        if let ownedCallID, value.available {
            if value.state == "idle" || (value.call_id != nil && value.call_id != ownedCallID) {
                releaseMedia()
            } else {
                audio.setActiveCall(value.state == "active")
                if value.state == "active", callStartedAt == nil { callStartedAt = Date() }
            }
        }
        voip?.synchronize(value)
        #if DEBUG
        let capture = audio.outgoing.captureStats()
        audioDiagnostics = "音频 入\(capture.taps)/\(capture.inputNonzero) 转\(capture.bytes)/\(capture.failures) 收\(audio.receivedFrames) 播\(audio.playedBuffers) \(audio.isEngineRunning ? "运行" : "停止")/\(audio.isActiveCall ? "启用" : "待机")"
        #endif
    }
    func systemCaller(for callID: String) async -> (number: String, name: String?)? {
        await restore()
        guard connected else { return nil }
        do { try await readStatus() } catch { return nil }
        guard status?.call_id == callID, let caller = status?.caller, !caller.isEmpty else { return nil }
        return (caller, await PhoneContacts.name(matching: caller))
    }
    private func startPolling() {
        guard isForeground || canRunCallInBackground, connected else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.connected, self.isForeground || self.canRunCallInBackground else { return }
                if self.callBusy || self.restoringConnection { continue }
                do { try await self.readStatus()
                    if Date() >= self.nextDiagnostics { self.refreshDiagnostics() } }
                catch {
                    if Task.isCancelled { return }
                    self.statusFresh = false
                    self.handleConnectionFailure(error)
                    self.scheduleRecovery()
                    return
                }
            }
        }
    }
    func foreground(_ value: Bool) async {
        isForeground = value
        if value || canRunCallInBackground {
            telemetry.resume(); telemetry.network(available: networkAvailable, changed: false)
        } else {
            telemetry.suspend(); historyUploadTask?.cancel()
        }
        if value {
            scheduleRecovery(immediate: true)
            if !connected { await restore() }
            else { try? await readStatus() }
            startPolling()
            scheduleHistoryUpload()
        } else {
            if !canRunCallInBackground { recoveryTask?.cancel(); recoveryTask = nil; recoveryGeneration = UUID() }
            pollTask?.cancel(); pollTask = nil
            if canRunCallInBackground { startPolling() }
            else if mediaConnected || ownedCallID != nil { await endCall(reason: "通话尚未建立，已释放声音通道。请回到 App 重试。") }
        }
    }
    private func networkChanged(available: Bool, signature: String) {
        let changed = networkSignature != nil && networkSignature != signature
        networkSignature = signature; networkAvailable = available
        guard startupStarted, !demo, !authenticationRejected else { return }
        telemetry.network(available: available, changed: changed)
        if !available {
            statusFresh = false
            connectionMessage = "手机暂无网络，网络恢复后自动连接。"
            recoveryTask?.cancel(); recoveryTask = nil; recoveryGeneration = UUID()
            statusOperation.cancel(); connectionOperation.cancel()
            return
        }
        if changed {
            statusOperation.cancel(); connectionOperation.cancel()
            if !canRunCallInBackground { epoch = UUID(); sessionOperation.cancel() }
            scheduleRecovery(immediate: true)
        } else if !connected || !statusFresh { scheduleRecovery(immediate: true) }
    }
    private func handleConnectionFailure(_ error: Error) {
        guard !(error is CancellationError) else { return }
        telemetry.failed(authentication: [401, 403].contains((error as? APIError)?.statusCode ?? 0))
        if [401, 403].contains((error as? APIError)?.statusCode ?? 0) {
            authenticationRejected = true
            connectionMessage = "鉴权失效，请重新填写 Key。"
            connected = false; notice = connectionMessage
        } else {
            connectionMessage = "手机到服务请求失败，正在自动重试。"
        }
    }
    private func scheduleRecovery(immediate: Bool = false) {
        guard !demo, !loggingOut, !authenticationRejected, networkAvailable, isForeground || canRunCallInBackground,
              connected || ConnectionStore.load() != nil else { return }
        if recoveryTask != nil && !immediate { return }
        recoveryTask?.cancel()
        let run = UUID(); recoveryGeneration = run
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.recoveryGeneration == run { self.recoveryTask = nil } }
            var failures = 0
            if !immediate { try? await Task.sleep(nanoseconds: ConnectionRecovery.delay(afterFailures: 1)) }
            while !Task.isCancelled && self.recoveryGeneration == run && self.networkAvailable && !self.authenticationRejected && (self.isForeground || self.canRunCallInBackground) {
                do {
                    if self.connected { self.telemetry.attempt(); try await self.readStatus() }
                    else { await self.restore() }
                    guard !Task.isCancelled, self.recoveryGeneration == run else { return }
                    if self.connected && self.statusFresh {
                        self.connectionMessage = "电话服务已连接"
                        self.startPolling(); self.refreshDiagnostics(); self.scheduleHistoryUpload(); return
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.handleConnectionFailure(error)
                }
                failures += 1
                if self.mediaConnected && failures >= 3 { await self.endCall(reason: "服务连接中断，本次通话已结束，请重新拨打。") }
                guard !self.authenticationRejected else { return }
                do { try await Task.sleep(nanoseconds: ConnectionRecovery.delay(afterFailures: failures)) } catch { return }
            }
        }
    }
    func refreshDiagnostics() {
        guard let base, connected, diagnosticsTask == nil else { return }
        let run = epoch
        diagnosticsTask = Task {
            defer { diagnosticsTask = nil }
            do {
                let value = try await api.read(PhoneDiagnostics.self, base: base, path: "voice-test/diagnostics", token: voiceToken, timeout: 5)
                guard epoch == run else { return }
                diagnostics = value; diagnosticMessage = nil
            } catch { if epoch == run { diagnosticMessage = "设备诊断暂不可用" } }
            nextDiagnostics = Date().addingTimeInterval(30)
        }
    }
    private var canSyncHistory: Bool {
        !demo && connected && statusFresh && isForeground && networkAvailable &&
        !callBusy && !systemCallActive && ownedCallID == nil && status?.hasCall != true && !loggingOut && !restoringConnection
    }
    private func scheduleHistoryUpload() {
        guard canSyncHistory, historyUploadTask == nil, Date().timeIntervalSince(lastHistoryUpload) >= 60,
              let base, let store = telemetry.store else { return }
        let scope = telemetry.scope, token = smsToken
        lastHistoryUpload = Date()
        historyUploadTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.historyUploadTask = nil }
            let events = await store.pending()
            guard !Task.isCancelled, self.telemetry.scope == scope, self.canSyncHistory, !events.isEmpty else { return }
            do {
                try await self.historyAPI.uploadConnectionEvents(events, base: base, token: token)
                await store.acknowledged(Set(events.map(\.id)))
            } catch { /* Keep the original batch and IDs for a later idempotent retry. */ }
        }
    }
    func refreshConnectionHistory() async {
        guard !loadingConnectionHistory, let store = telemetry.store else { return }
        loadingConnectionHistory = true
        defer { loadingConnectionHistory = false }
        let scope = telemetry.scope
        let local = await store.snapshot()
        guard telemetry.scope == scope else { return }
        localConnectionEvents = Array(local.events.reversed().filter { $0.kind != "observation" }.prefix(200))
        localConnectionSummary = .phone(events: local.events, now: Date().timeIntervalSince1970)
        pendingConnectionEvents = local.pending
        if local.failed { connectionHistoryMessage = "本机历史保存失败；现有文件保留，通话不受影响。"; return }
        guard canSyncHistory, let base else {
            connectionHistoryMessage = "显示本机记录；联网且通话结束后可同步远端历史。"
            return
        }
        scheduleHistoryUpload()
        await historyUploadTask?.value
        guard telemetry.scope == scope, canSyncHistory else { return }
        do {
            let value = try await historyAPI.read(ConnectionHistory.self, base: base,
                path: "voice-test/app/connection-history", token: smsToken, timeout: 5)
            guard telemetry.scope == scope else { return }
            connectionHistory = value
            let updated = await store.snapshot()
            pendingConnectionEvents = updated.pending
            connectionHistoryMessage = updated.pending == 0 ? "历史已同步" : "\(updated.pending) 条本机记录待补传，每分钟最多补传 100 条。"
        } catch {
            if telemetry.scope == scope { connectionHistoryMessage = "远端历史暂不可用，保留本机记录并稍后重试；请确认服务已更新。" }
        }
    }
    private func prepareMedia(callKitManaged: Bool = false) async throws {
        guard let base, connected, !demo, isForeground || systemCallActive else { throw APIError(message: "请先连接服务，并保持 App 在前台。") }
        if mediaConnected { return }
        let systemUUID = systemCallUUID
        // Obtain a fresh session before acquiring audio ownership. Never renew mid-call.
        try await renewVoice()
        let run = epoch
        guard !callKitManaged || systemCallUUID == systemUUID && systemUUID != nil else { throw CancellationError() }
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--integration-call") && !ProcessInfo.processInfo.arguments.contains("--integration-microphone") { try audio.startPlaybackTest() }
            else { try await audio.start(callKitManaged: callKitManaged) }
            #else
            try await audio.start(callKitManaged: callKitManaged)
            #endif
            guard isForeground || systemCallActive, epoch == run,
                  !callKitManaged || systemCallUUID == systemUUID else { throw CancellationError() }
            try await transport.connect(base: base, token: voiceToken)
            guard isForeground || systemCallActive, epoch == run,
                  !callKitManaged || systemCallUUID == systemUUID else { throw CancellationError() }
            mediaConnected = true
            transport.startSending(audio.outgoing)
        } catch {
            if !callKitManaged || systemCallUUID == systemUUID { releaseMedia() }
            throw error
        }
    }
    private func command(_ body: [String: String]) async throws -> CallStatus {
        guard let base, connected else { throw APIError(message: "请先连接服务。") }
        let data = try await api.request(base, path: "voice-test/phone", token: voiceToken, body: body)
        return try JSONDecoder().decode(CallStatus.self, from: data)
    }
    private var directCallTest: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--local-voice-check") || ProcessInfo.processInfo.arguments.contains("--integration-check")
        #else
        return false
        #endif
    }
    func beginSystemCall(_ uuid: UUID) {
        systemCallUUID = uuid
        systemCallActive = true
        systemCallPreparing = true
        telemetry.resume(); telemetry.network(available: networkAvailable, changed: false)
        historyUploadTask?.cancel()
    }
    func systemCallFinished(_ uuid: UUID, remoteID: String?, stopRemote: Bool) {
        guard systemCallUUID == nil || systemCallUUID == uuid else { return }
        let id = remoteID ?? ownedCallID
        let endpoint = base, token = voiceToken
        systemCallUUID = nil; systemCallActive = false; systemCallPreparing = false
        answeringSystemCallID = nil
        // Audio/WS startup may already own resources before mediaConnected becomes true.
        releaseMedia()
        if stopRemote, let id { beginHangupConfirmation(id: id, endpoint: endpoint, token: token) }
    }
    private func beginHangupConfirmation(id: String, endpoint: URL?, token: String) {
        hangupTask?.cancel()
        pendingHangupID = id; hangupMessage = "正在确认挂断"
        hangupTask = Task {
            var run = epoch
            let deadline = Date().addingTimeInterval(5)
            if let endpoint, !token.isEmpty {
                _ = try? await api.request(endpoint, path: "voice-test/phone", token: token, body: ["action": "hangup", "call_id": id], timeout: 2)
            } else {
                await restore()
                run = epoch
                if pendingHangupID == id, status?.call_id == id { _ = try? await command(["action": "hangup", "call_id": id]) }
            }
            while !Task.isCancelled, epoch == run, pendingHangupID == id, Date() < deadline {
                if let endpoint = base, connected {
                    do {
                        let current = try await api.read(CallStatus.self, base: endpoint, path: "voice-test/status", token: voiceToken, timeout: max(0.1, min(1, deadline.timeIntervalSinceNow)))
                        guard epoch == run, pendingHangupID == id, !Task.isCancelled else { return }
                        applyStatus(current)
                    } catch { /* Later normal polling reconciles the same original call. */ }
                }
                if pendingHangupID != id { return }
                do { try await Task.sleep(nanoseconds: UInt64(max(0, min(1, deadline.timeIntervalSinceNow)) * 1_000_000_000)) } catch { return }
            }
            if epoch == run, pendingHangupID == id, !Task.isCancelled {
                hangupMessage = "远端挂断待确认，恢复连接后会自动核对。"
                hangupTask = nil
                scheduleRecovery()
            }
        }
    }
    func dial(_ input: String) async {
        guard !callBusy, !systemCallPreparing, !systemCallActive, !restoringConnection, connected, !demo else { return }
        if directCallTest { _ = await dialRemote(input); return }
        callBusy = true
        var ownsBusy = true
        defer { if ownsBusy { callBusy = false } }
        do {
            let number = try API.normalizedDialNumber(input)
            try await readStatus()
            guard statusFresh, status?.available == true, status?.state == "idle" else { throw APIError(message: "设备不在待机状态，请稍后重试。") }
            guard await AVAudioApplication.requestRecordPermission() else { throw APIError(message: "请在设置中允许麦克风后再拨号。") }
            callBusy = false; ownsBusy = false
            try await voip?.startOutgoing(number)
        } catch { notice = error.localizedDescription }
    }
    func dialSystemCall(_ number: String, uuid: UUID) async -> Bool {
        await dialRemote(number, uuid: uuid)
    }
    private func dialRemote(_ input: String, uuid: UUID? = nil) async -> Bool {
        guard !callBusy, !restoringConnection, connected, !demo,
              uuid == nil || systemCallUUID == uuid else { return false }
        callBusy = true; dialingStage = "准备通话"; defer { callBusy = false }
        do {
            let number = try API.normalizedDialNumber(input)
            try await readStatus()
            guard statusFresh, status?.available == true, status?.state == "idle", uuid == nil || systemCallUUID == uuid else { throw CancellationError() }
            try await prepareMedia(callKitManaged: uuid != nil)
            guard uuid == nil || systemCallUUID == uuid else { throw CancellationError() }
            dialingStage = "正在提交拨号"
            let view = try await command(["action": "dial", "number": number])
            guard uuid == nil || systemCallUUID == uuid else {
                if let id = view.call_id { _ = try? await command(["action": "hangup", "call_id": id]) }
                return false
            }
            guard let id = view.call_id, view.hasCall else { throw APIError(message: "拨号未建立，请刷新后重试。") }
            if let uuid { voip?.bindRemote(id, uuid: uuid) }
            addCallRecord(id: id, number: number, direction: "去电")
            ownedCallID = id; applyStatus(view)
            if !isForeground && !canRunCallInBackground { await endCall(); return false }
            startPolling()
            return ownedCallID == id
        } catch {
            if uuid == nil || systemCallUUID == uuid {
                let failedStage = dialingStage
                releaseMedia()
                notice = error is CancellationError ? "通话连接已取消，请重试。" : "\(failedStage.isEmpty ? "建立通话" : failedStage)失败：\(error.localizedDescription)"
            }
            return false
        }
    }
    func answer() async {
        guard !callBusy, !systemCallPreparing, !restoringConnection, connected, !demo,
              statusFresh, status?.state == "ringing", let id = status?.call_id else { return }
        if directCallTest { await answerRemote(); return }
        callBusy = true
        var ownsBusy = true
        defer { if ownsBusy { callBusy = false } }
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw APIError(message: "请在设置中允许麦克风后再接听。") }
            callBusy = false; ownsBusy = false
            try await voip?.answerIncoming(id: id, number: status?.caller, name: callerDisplayName)
        } catch { notice = error.localizedDescription }
    }
    private func answerRemote(uuid: UUID? = nil) async {
        guard !callBusy, !restoringConnection, connected, !demo, let id = status?.call_id else { return }
        callBusy = true; defer { callBusy = false }
        do {
            try await readStatus()
            guard statusFresh, status?.state == "ringing", status?.call_id == id,
                  uuid == nil || systemCallUUID == uuid && answeringSystemCallID == id else { throw CancellationError() }
            try await prepareMedia(callKitManaged: uuid != nil)
            guard uuid == nil || systemCallUUID == uuid else { throw CancellationError() }
            let view = try await command(["action": "answer", "call_id": id])
            guard uuid == nil || systemCallUUID == uuid else {
                _ = try? await command(["action": "hangup", "call_id": id]); return
            }
            // ATA acknowledgment can precede the modem's active-state notification.
            guard view.call_id == id, view.hasCall else { throw APIError(message: "来电未接通，请刷新后重试。") }
            ownedCallID = id; applyStatus(view)
            if !isForeground && !canRunCallInBackground { await endCall() }
        } catch {
            if uuid == nil || systemCallUUID == uuid { releaseMedia(); notice = error.localizedDescription }
        }
    }
    func answerSystemCall(_ callID: String, uuid: UUID) async -> Bool {
        guard systemCallUUID == uuid else { return false }
        answeringSystemCallID = callID
        await restore()
        guard connected, systemCallUUID == uuid, answeringSystemCallID == callID else { return false }
        do { try await readStatus() } catch { notice = "来电连接恢复失败，请检查网络。"; return false }
        guard systemCallUUID == uuid, statusFresh, status?.state == "ringing", status?.call_id == callID else { return false }
        await answerRemote(uuid: uuid)
        let success = ownedCallID == callID && systemCallUUID == uuid
        if success { startPolling() }
        return success
    }
    func endCall(reason: String? = nil) async {
        let id = ownedCallID
        let endpoint = base, token = voiceToken
        // Stop capture and close media before any potentially slow network request.
        releaseMedia()
        if let id, let endpoint {
            _ = try? await api.request(endpoint, path: "voice-test/phone", token: token, body: ["action": "hangup", "call_id": id], timeout: 2)
        }
        try? await readStatus()
        if let reason { notice = reason }
    }
    func hangup() async {
        if await voip?.requestEnd() == true { return }
        guard !callBusy, !demo, let id = status?.call_id else { return }
        releaseMedia()
        beginHangupConfirmation(id: id, endpoint: base, token: voiceToken)
        await hangupTask?.value
    }
    @discardableResult func dtmf(_ digit: String) async -> Bool {
        guard !callBusy, let id = ownedCallID, status?.state == "active", statusFresh,
              digit.count == 1, "0123456789*#ABCD".contains(digit) else { return false }
        callBusy = true; defer { callBusy = false }
        do { _ = try await command(["action": "dtmf", "call_id": id, "digit": digit]); return true }
        catch { notice = error.localizedDescription; return false }
    }
    func toggleMute() {
        if systemCallActive {
            voip?.requestMute(!muted)
            return
        }
        muted.toggle(); audio.setMuted(muted)
    }
    func setSystemMute(_ value: Bool) -> Bool {
        guard systemCallActive, mediaConnected, ownedCallID != nil else { return false }
        muted = value
        audio.setMuted(value)
        return true
    }
    func toggleSpeaker() async {
        guard !callBusy, mediaConnected, let callID = ownedCallID else { return }
        callBusy = true; defer { callBusy = false }
        let target = !speakerEnabled
        let callKitManaged = audio.callKitManaged
        audio.stop(deactivateSession: false)
        do {
            try await audio.start(useSpeaker: target, callKitManaged: callKitManaged)
            guard mediaConnected, ownedCallID == callID, status?.state == "active" else {
                audio.stop(); return
            }
            audio.setActiveCall(status?.state == "active")
            audio.setMuted(muted)
        } catch {
            await endCall(reason: "声音输出切换失败，已结束通话，请重试。")
        }
    }
    private func releaseMedia() {
        if let ownedCallID { finishCallRecord(id: ownedCallID) }
        dialingStage = ""
        transport.close(); audio.stop()
        mediaConnected = false; ownedCallID = nil; callStartedAt = nil
        muted = false; speakerEnabled = false
        if systemCallActive {
            systemCallActive = false; systemCallPreparing = false; systemCallUUID = nil
            answeringSystemCallID = nil
            voip?.reportEnded()
        }
        if !isForeground { pollTask?.cancel(); pollTask = nil; telemetry.suspend() }
    }
    private func persistCallHistory() {
        try? CallHistoryStore.save(callHistory, server: endpoint)
    }
    private func addCallRecord(id: String, number: String, direction: String) {
        guard !id.isEmpty, !number.isEmpty, !callHistory.contains(where: { $0.id == id }) else { return }
        callHistory.insert(CallRecord(id: id, number: number, direction: direction,
                                      startedAt: Date(), answeredAt: nil, endedAt: nil), at: 0)
        if callHistory.count > 200 { callHistory.removeLast(callHistory.count - 200) }
        persistCallHistory()
    }
    private func markCallAnswered(id: String) {
        guard let index = callHistory.firstIndex(where: { $0.id == id }), callHistory[index].answeredAt == nil else { return }
        callHistory[index].answeredAt = Date()
        persistCallHistory()
    }
    private func finishCallRecord(id: String) {
        guard let index = callHistory.firstIndex(where: { $0.id == id }), callHistory[index].endedAt == nil else { return }
        callHistory[index].endedAt = Date()
        persistCallHistory()
    }
    func clearCallHistory() {
        do { try CallHistoryStore.clear(server: endpoint); callHistory = [] }
        catch { notice = error.localizedDescription }
    }
    func refreshPhone() async {
        guard !demo, !restoringConnection else { return }
        if !connected { await restore(); return }
        do { try await readStatus(); notice = nil }
        catch { statusFresh = false; notice = "电话状态刷新失败，请检查网络后重试。" }
    }
    func refresh() async {
        guard !demo else { return }
        if !connected { await restore(); return }
        await perform { try await reload() }
    }
    func authorizeMicrophone() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        notice = granted ? "麦克风已授权，可在锁屏来电接通后传送声音。" : "麦克风未授权，请在系统设置中允许随行号使用麦克风。"
    }
    #if DEBUG
    func testSpeakerWithoutCall() async {
        guard !mediaConnected, ownedCallID == nil else { return }
        await perform {
            try await audio.start(useSpeaker: true)
            defer { audio.stop() }
            audio.setActiveCall(true)
            try audio.playTestTone()
            try await Task.sleep(nanoseconds: 1_400_000_000)
            let session = AVAudioSession.sharedInstance()
            let route = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
            notice = "扬声器测试结束：引擎\(audio.isEngineRunning ? "运行" : "停止")，播放完成 \(audio.playedBuffers) 段，输出 \(route)，音量 \(Int(session.outputVolume * 100))%。"
        }
    }
    #endif
    func messages(_ contact: SMSContact) async throws -> [SMSMessage] {
        if demo { return [.init(id: 1, content: contact.last_content, timestamp: "演示消息", type: 1)] }
        guard let base, connected else { throw APIError(message: "请先配置服务地址和鉴权 Key。") }
        let query = API.threadQuery(contact)
        return try await api.read([SMSMessage].self, base: base, path: "voice-test/app/sms/thread", token: smsToken, query: query).sorted { $0.timestamp < $1.timestamp }
    }
    func markRead(_ contact: SMSContact, throughID: Int?) async throws {
        guard !demo, let base, connected, let throughID else { return }
        let unread = try await api.markSMSRead(base, token: smsToken, contact: contact, throughID: throughID)
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            let old = contacts[index]
            contacts[index] = SMSContact(peer: old.peer, iccid: old.iccid, imsi: old.imsi,
                                         device_id: old.device_id, last_content: old.last_content,
                                         last_timestamp: old.last_timestamp, unread_count: unread)
        }
    }
    func send(number: String, message: String, device: String, showNotice: Bool = true, allowShortCode: Bool = false) async -> Bool {
        var success = false
        await perform {
            guard !demo, connected, let base else { throw APIError(message: "演示模式不会发送真实短信。") }
            guard !device.isEmpty, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError(message: "请选择设备并填写正文。") }
            let phone = allowShortCode ? try API.normalizedSMSReplyNumber(number) : try API.normalizedNumber(number)
            _ = try await api.request(base, path: "voice-test/app/sms/send", token: smsToken, body: ["device_id": device, "phone": phone, "message": message])
            success = true
            if showNotice { notice = "已提交发送；是否送达以收件方实际收到为准。" }
        }
        return success
    }
    func logout() async {
        guard !busy, !callBusy, !restoringConnection else { return }
        loggingOut = true
        telemetry.suspend(reason: "logout"); historyUploadTask?.cancel()
        defer { loggingOut = false }
        busy = true
        recoveryTask?.cancel(); recoveryTask = nil; recoveryGeneration = UUID()
        hangupTask?.cancel(); hangupTask = nil; pendingHangupID = nil; hangupMessage = nil
        diagnosticsTask?.cancel(); diagnosticsTask = nil; diagnostics = nil
        contentTask?.cancel(); contentTask = nil; loadingContent = false
        connectionOperation.cancel(); statusOperation.cancel(); sessionOperation.cancel()
        pollTask?.cancel(); pollTask = nil
        epoch = UUID()
        await endCall()
        if let base { try? await api.delete(base, path: "voice-test/app/voip-token", token: smsToken) }
        if let base { try? await api.delete(base, path: "voice-test/app/sms-push-token", token: smsToken) }
        do { try ConnectionStore.clear() } catch { notice = error.localizedDescription; busy = false; return }
        telemetry.disconnect()
        connectionHistory = nil; localConnectionSummary = nil; localConnectionEvents = []; pendingConnectionEvents = 0
        if let base, !voiceToken.isEmpty { _ = try? await api.request(base, path: "voice-test/logout", token: voiceToken, body: [:]) }
        smsToken = ""; voiceToken = ""; base = nil; voiceExpires = .distantPast
        contacts = []; devices = []; status = nil; connected = false; demo = true; endpoint = ""; statusFresh = false
        callHistory = []
        busy = false
    }
}
