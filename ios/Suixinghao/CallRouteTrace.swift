import Foundation

#if DEBUG && os(iOS)
/// Development-only, bounded local metadata. No names, IDs, addresses or audio.
@MainActor
final class CallRouteTrace {
    private var events: [[String: Any]] = []
    private let started = DispatchTime.now().uptimeNanoseconds
    func record(_ event: String, input: String, output: String, preferred: String,
                options: UInt, mode: String, reason: UInt, running: Bool, suspended: Bool) {
        events.append(["event": event, "elapsed_ms": (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
                       "input_type": input, "output_type": output, "preferred_input_type": preferred,
                       "category_options": options, "mode": mode, "reason": reason,
                       "engine_running": running, "session_suspended": suspended])
        if events.count > 96 { events.removeFirst(events.count - 96) }
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: ["version": 2, "events": events], options: [.sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("call-route-debug.json"), options: .atomic)
    }
}
#endif
