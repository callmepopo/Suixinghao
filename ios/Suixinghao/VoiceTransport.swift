import Foundation

@MainActor
final class VoiceTransport: NSObject, URLSessionWebSocketDelegate {
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var opening: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var sending = UUID()
    private var diagnosticsSupported = false
    private var diagnosticsVersion = 1
    private var diagnostics: VoiceDiagnostics?
    private(set) var ready = false
    var onAudio: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?

    func connect(base: URL, token: String) async throws {
        close()
        var components = URLComponents(url: base.appendingPathComponent("voice-test/stream"), resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        #if DEBUG
        // Only the explicit offline acceptance runner can use a loopback WS sink.
        if ProcessInfo.processInfo.arguments.contains("--local-voice-check"), base.host == "127.0.0.1", base.scheme == "http" {
            components.scheme = "ws"
        }
        #endif
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("sxh.audio-diagnostics.v3, sxh.audio-diagnostics.v2, sxh.audio-diagnostics.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = 32768
        socket = ws
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            opening = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                self?.failed("声音连接超时，请重试。")
            }
            ws.resume()
        }
        // Read before pinging: iOS hands the pong over only after earlier unread
        // messages, and on a reconnect mid-call the server may already be pushing audio.
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    guard let self, self.socket === ws else { return }
                    switch message {
                    case .data(let data):
                        guard data.count == PCMFrames.frameBytes else { self.failed("声音数据格式不正确。"); return }
                        self.onAudio?(data)
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                            if value["error"] != nil { self.failed("服务端声音通道异常，请检查设备后重试。"); return }
                        }
                    @unknown default: break
                    }
                }
            } catch {
                guard let self, self.socket === ws, !Task.isCancelled else { return }
                self.failed("声音连接已断开，本次通话将结束。")
            }
        }
        // A pong proves the server has entered its read loop and bound ownership.
        try await awaitPong { handler in ws.sendPing(pongReceiveHandler: handler) }
        guard socket === ws else { throw CancellationError() }
        ready = true
        timeout?.cancel(); timeout = nil
    }
    func startSending(_ frames: PCMFrames) {
        guard let ws = socket, ready else { return }
        // One worker per socket. Repeated setup cannot leave two concurrent writers.
        guard sendTask == nil else { return }
        diagnostics = frames.diagnostics
        frames.diagnostics.negotiate(diagnosticsSupported, version: diagnosticsVersion)
        let generation = UUID(); sending = generation
        sendTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await VoiceSendLoop.run(socket: ws, frames: frames)
            } catch {
                guard !Task.isCancelled, let owner = self else { return }
                await MainActor.run {
                    guard owner.socket === ws, owner.sending == generation else { return }
                    owner.failed("声音上传中断，本次通话将结束。")
                }
            }
        }
    }
    private func failed(_ message: String) {
        let hadConnection = ready
        let pending = opening; opening = nil
        close()
        pending?.resume(throwing: APIError(message: message))
        if hadConnection { onFailure?(message) }
    }
    func close() {
        let pending = opening; opening = nil
        pending?.resume(throwing: CancellationError())
        timeout?.cancel(); timeout = nil
        receiveTask?.cancel(); receiveTask = nil
        sendTask?.cancel(); sendTask = nil
        sending = UUID(); diagnostics?.negotiate(false); diagnostics = nil; diagnosticsSupported = false
        ready = false
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            guard self.socket === webSocketTask else { return }
            let versions = ["sxh.audio-diagnostics.v1": 1, "sxh.audio-diagnostics.v2": 2, "sxh.audio-diagnostics.v3": 3]
            self.diagnosticsSupported = versions[`protocol` ?? ""] != nil
            self.diagnosticsVersion = versions[`protocol` ?? ""] ?? 1
            let pending = self.opening; self.opening = nil; pending?.resume()
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            guard self.socket === task else { return }
            self.failed("声音连接失败，可能已被其他客户端占用。")
        }
    }
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            guard self.socket === webSocketTask else { return }
            self.failed("声音连接已关闭，本次通话将结束。")
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Waits for one pong. URLSession may call a ping's handler more than once while
/// the network changes (an error, then again as the task is cancelled); only the
/// first call may resume, a second resume would trap the App mid-call.
func awaitPong(_ sendPing: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let once = ResumeOnce(continuation)
        sendPing { error in once.resume(error) }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func resume(_ error: Error?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
