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
        print("pong-check ok")
    }
}
