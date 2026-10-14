#!/usr/bin/env python3
"""Run the shipped AppModel.reconnectMedia against fakes (no network, microphone or modem)."""
import os
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "Suixinghao/AppModel.swift").read_text()
start = source.index("    /// Slightly shorter than the server's 15 s reconnect grace.")
end = source.index("    private func releaseMedia()", start)
method = source[start:end].replace("private func reconnectMedia", "func reconnectMedia").replace("static let mediaReconnectWindow: TimeInterval = 14", "static let mediaReconnectWindow: TimeInterval = 3")
out = root / ".build/checks"
out.mkdir(parents=True, exist_ok=True)
harness = r'''
import Foundation
struct Offline: Error {}
@MainActor final class Transport {
    var failures = 0, connects = 0, sending = 0, closed = 0
    func connect(base: URL, token: String) async throws { connects += 1; if failures > 0 { failures -= 1; throw Offline() } }
    func startSending(_ frames: Frames) { sending += 1 }
    func close() { closed += 1 }
}
final class Frames {}
@MainActor final class Audio { let outgoing = Frames() }
@MainActor final class Scenario {
    var mediaConnected = true
    var ownedCallID: String? = "synthetic-call"
    var base: URL? = URL(string: "https://example.invalid")
    var voiceToken = "synthetic"
    var audioRouteMessage: String?
    var ended: String?
    var mediaReconnect: Task<Void, Never>?
    let transport = Transport()
    let audio = Audio()
    func endCall(reason: String?) async { ended = reason; mediaReconnect?.cancel(); mediaReconnect = nil; mediaConnected = false; ownedCallID = nil }
''' + method + r'''
}
@main struct Check {
    @MainActor static func main() async {
        // Brief network switch: two failed attempts, then the same call resumes.
        let brief = Scenario(); brief.transport.failures = 2
        brief.reconnectMedia(after: "lost")
        precondition(brief.audioRouteMessage != nil)
        brief.reconnectMedia(after: "lost") // a second failure report must not start a parallel loop
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        precondition(brief.ended == nil && brief.transport.sending == 1 && brief.transport.connects == 3)
        precondition(brief.audioRouteMessage == nil && brief.mediaReconnect == nil)
        // Network stays down past the window: end the call with the original reason.
        let down = Scenario(); down.transport.failures = 99
        down.reconnectMedia(after: "lost")
        try? await Task.sleep(nanoseconds: 4_500_000_000)
        precondition(down.ended == "lost" && down.transport.sending == 0)
        // Call ended elsewhere while reconnecting: stop quietly, never resurrect it.
        let gone = Scenario(); gone.transport.failures = 99
        gone.reconnectMedia(after: "lost")
        try? await Task.sleep(nanoseconds: 300_000_000)
        gone.ownedCallID = nil; gone.mediaConnected = false
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        precondition(gone.ended == nil && gone.transport.sending == 0 && gone.mediaReconnect == nil)
        print("Media reconnect: brief outage resumes same call, single loop, window expiry ends call, ended call not resurrected (offline).")
    }
}
'''
test = out / "media-reconnect-check.swift"
test.write_text(harness)
env = os.environ.copy()
env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()
binary = out / "media-reconnect-check"
subprocess.run(["xcrun", "swiftc", "-sdk", sdk, "-parse-as-library", "-module-cache-path", str(out / "module-cache"), str(test), "-o", str(binary)], env=env, check=True)
subprocess.run([str(binary)], check=True, timeout=60)
