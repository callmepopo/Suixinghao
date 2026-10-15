import Foundation

// 10-15 SE3 build60 crash: during a network switch URLSession called the pong
// handler of the reconnect ping twice; the second resume trapped the App.
struct PongFailure: Error {}

func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: \(message)"); exit(1) } }

@main
struct PongCheck {
    static func main() async {
        // Error first, then a late success callback.
        do { try await awaitPong { handler in handler(PongFailure()); handler(nil) }; check(false, "error must be reported") }
        catch { check(error is PongFailure, "first callback wins (error)") }
        // Success first, then an error as the task is cancelled.
        do { try await awaitPong { handler in handler(nil); handler(PongFailure()) } }
        catch { check(false, "first callback wins (success)") }
        // Two callbacks racing on URLSession delegate queues.
        for _ in 0..<200 {
            _ = try? await awaitPong { handler in
                DispatchQueue.global().async { handler(nil) }
                DispatchQueue.global().async { handler(PongFailure()) }
            }
        }
        await reconnectIntoActiveCall()
        print("pong-check ok")
    }

    // 10-15 12:49 15Pro: reconnecting mid-call, the server pushed audio at once;
    // iOS held the pong behind unread audio and the App, reading only after its
    // pong, timed out after 10 s. The real VoiceTransport must connect promptly.
    @MainActor static func reconnectIntoActiveCall() async {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-I", CommandLine.arguments[1]]
        let output = Pipe(); server.standardOutput = output
        do { try server.run() } catch { check(false, "start push-first server") }
        defer { server.terminate() }
        guard let line = String(data: output.fileHandleForReading.availableData, encoding: .utf8),
              let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) else { check(false, "server port"); return }
        let transport = VoiceTransport()
        var frames = 0
        transport.onAudio = { _ in frames += 1 }
        let started = Date()
        do { try await transport.connect(base: URL(string: "http://127.0.0.1:\(port)")!, token: "local-test") }
        catch { check(false, "connect into an active call failed after \(Int(Date().timeIntervalSince(started)))s: \(error)") }
        check(Date().timeIntervalSince(started) < 2, "connect must not wait for the 10 s timeout")
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(frames > 5, "audio pushed before the pong must still be received")
        transport.close()
    }
}
