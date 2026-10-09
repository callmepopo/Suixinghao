import AVFoundation
import CallKit
import Foundation
import PushKit

@MainActor
final class VoIPCalls: NSObject, @preconcurrency PKPushRegistryDelegate, @preconcurrency CXProviderDelegate {
    private weak var model: AppModel?
    private let registry: PKPushRegistry
    private let provider: CXProvider
    private let controller = CXCallController()
    private var session = CallSession()
    private var setupTimeout: Task<Void, Never>?
    private(set) var token: String?

    init(model: AppModel) {
        self.model = model
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.includesCallsInRecents = false // History remains in the app's local Keychain.
        provider = CXProvider(configuration: configuration)
        registry = PKPushRegistry(queue: .main)
        super.init()
        provider.setDelegate(self, queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        token = credentials.token.map { String(format: "%02x", $0) }.joined()
        Task { await model?.voipTokenUpdated() }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        token = nil
        Task { await model?.voipTokenInvalidated() }
    }

    private func update(number: String? = nil, name: String? = nil) -> CXCallUpdate {
        let update = CXCallUpdate()
        if let number { update.remoteHandle = CXHandle(type: .phoneNumber, value: number) }
        update.localizedCallerName = name ?? number ?? "随行号来电"
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = true
        return update
    }

    nonisolated private static func duplicateReport(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == CXErrorDomainIncomingCall && error.code == CXErrorCodeIncomingCallError.callUUIDAlreadyExists.rawValue
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP, let id = payload.dictionaryPayload["call_id"] as? String, !id.isEmpty else {
            completion(); return
        }
        // Every valid VoIP push must be reported, including duplicates or an occupied slot.
        let existing = session.call?.remoteID == id
        guard let uuid = session.incoming(id: id) else {
            let rejected = UUID()
            provider.reportNewIncomingCall(with: rejected, update: update()) { [weak self] error in
                Task { @MainActor in
                    if error == nil { self?.provider.reportCall(with: rejected, endedAt: Date(), reason: .failed) }
                    completion()
                }
            }
            return
        }
        provider.reportNewIncomingCall(with: uuid, update: update()) { [weak self] error in
            Task { @MainActor in
                completion()
                guard let self, self.session.contains(uuid) else { return }
                if let error, !Self.duplicateReport(error) {
                    if !existing { self.reportEnded(reason: .failed) }
                    return
                }
                if let caller = await self.model?.systemCaller(for: id), self.session.contains(uuid) {
                    self.provider.reportCall(with: uuid, updated: self.update(number: caller.number, name: caller.name))
                } else if self.session.contains(uuid) {
                    self.reportEnded(reason: .remoteEnded)
                }
            }
        }
    }

    private func request(_ action: CXCallAction) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controller.request(CXTransaction(action: action)) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func startOutgoing(_ number: String) async throws {
        guard let uuid = session.outgoing(number: number) else { throw APIError(message: "已有通话正在处理。") }
        model?.beginSystemCall(uuid)
        armTimeout(uuid)
        do { try await request(CXStartCallAction(call: uuid, handle: CXHandle(type: .phoneNumber, value: number))) }
        catch {
            if session.contains(uuid) { reportEnded(reason: .failed) }
            throw APIError(message: "系统未能启动随行号通话，请稍后重试。")
        }
    }

    func answerIncoming(id: String, number: String?, name: String?) async throws {
        let alreadyReported = session.call?.remoteID == id
        guard let uuid = session.incoming(id: id) else { throw APIError(message: "已有通话正在处理。") }
        model?.beginSystemCall(uuid)
        armTimeout(uuid)
        do {
            if !alreadyReported {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    provider.reportNewIncomingCall(with: uuid, update: update(number: number, name: name)) { error in
                        if let error, !Self.duplicateReport(error) { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }
            guard session.contains(uuid) else { throw CancellationError() }
            if session.call?.mediaStarted == true || session.call?.waitingForAudio == true { return }
            try await request(CXAnswerCallAction(call: uuid))
        } catch {
            if session.contains(uuid) { reportEnded(reason: .failed) }
            throw APIError(message: "系统未能接听，来电可能已结束，请刷新后重试。")
        }
    }

    private func configureAudio() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try audio.setPreferredIOBufferDuration(0.02)
    }

    private func armTimeout(_ uuid: UUID) {
        setupTimeout?.cancel()
        setupTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.session.contains(uuid) else { return }
            self.model?.notice = "通话连接超时，已结束本次尝试，请重试。"
            self.finish(uuid, reason: .failed, stopRemote: true)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard session.contains(action.callUUID), session.call?.isOutgoing == true,
              session.waitForAudio(action.callUUID) else { action.fail(); return }
        do {
            try configureAudio()
            provider.reportCall(with: action.callUUID, updated: update(number: session.call?.number))
            action.fulfill()
        } catch { action.fail(); finish(action.callUUID, reason: .failed, stopRemote: true) }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard session.contains(action.callUUID), session.call?.isOutgoing == false,
              session.waitForAudio(action.callUUID) else { action.fail(); return }
        model?.beginSystemCall(action.callUUID)
        armTimeout(action.callUUID)
        do { try configureAudio(); action.fulfill() }
        catch { action.fail(); finish(action.callUUID, reason: .failed, stopRemote: true) }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard let call = session.takeAudioWork() else { return }
        Task {
            let success: Bool
            if let number = call.number {
                provider.reportOutgoingCall(with: call.uuid, startedConnectingAt: Date())
                success = await model?.dialSystemCall(number, uuid: call.uuid) == true
            } else if let id = call.remoteID {
                success = await model?.answerSystemCall(id, uuid: call.uuid) == true
            } else { success = false }
            guard session.contains(call.uuid) else { return }
            setupTimeout?.cancel(); setupTimeout = nil
            if success { model?.systemCallPreparing = false }
            else { finish(call.uuid, reason: .failed, stopRemote: true) }
        }
    }

    func bindRemote(_ id: String, uuid: UUID) { _ = session.bind(id, to: uuid) }
    func reportConnected(_ id: String) {
        if let uuid = session.connected(id) { provider.reportOutgoingCall(with: uuid, connectedAt: Date()) }
    }

    func providerDidReset(_ provider: CXProvider) {
        guard let call = session.call else { return }
        finish(call.uuid, reason: .failed, stopRemote: true, report: false)
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        guard let action = action as? CXCallAction, session.contains(action.callUUID) else { return }
        finish(action.callUUID, reason: .failed, stopRemote: true)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard session.contains(action.callUUID) else { action.fail(); return }
        finish(action.callUUID, reason: .remoteEnded, stopRemote: true, report: false)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard session.contains(action.callUUID), model?.setSystemMute(action.isMuted) == true else { action.fail(); return }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        guard session.contains(action.callUUID) else { action.fail(); return }
        Task {
            guard !action.digits.isEmpty else { action.fail(); return }
            for digit in action.digits {
                guard session.contains(action.callUUID), await model?.dtmf(String(digit)) == true else { action.fail(); return }
            }
            if session.contains(action.callUUID) { action.fulfill() } else { action.fail() }
        }
    }

    func requestEnd() async -> Bool {
        guard let call = session.call else { return false }
        do { try await request(CXEndCallAction(call: call.uuid)) }
        catch {
            // A rejected system transaction still releases the local/remote call.
            if session.contains(call.uuid) { finish(call.uuid, reason: .failed, stopRemote: true) }
        }
        return true
    }

    func requestMute(_ value: Bool) {
        guard let uuid = session.call?.uuid else { return }
        Task {
            do { try await request(CXSetMutedCallAction(call: uuid, muted: value)) }
            catch { if session.contains(uuid) { model?.notice = "系统静音切换失败，请重试。" } }
        }
    }

    private func finish(_ uuid: UUID, reason: CXCallEndedReason, stopRemote: Bool, report: Bool = true) {
        guard let call = session.clear(uuid) else { return }
        setupTimeout?.cancel(); setupTimeout = nil
        if report { provider.reportCall(with: uuid, endedAt: Date(), reason: reason) }
        model?.systemCallFinished(uuid, remoteID: call.remoteID, stopRemote: stopRemote)
    }

    func reportEnded(reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = session.call?.uuid else { return }
        finish(uuid, reason: reason, stopRemote: false)
    }

    func synchronize(_ status: CallStatus) {
        guard let call = session.call, let id = call.remoteID, status.available else { return }
        if status.state == "idle" || (status.call_id != nil && status.call_id != id) { reportEnded() }
    }
}
