#!/usr/bin/env python3
"""Exercise the shipped AppModel switch entry point without a microphone or modem."""
import os
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "Suixinghao/AppModel.swift").read_text()
start = source.index("    func toggleSpeaker() async {")
end = source.index("    private func releaseMedia()", start)
method = source[start:end]
out = root / ".build/checks"
out.mkdir(parents=True, exist_ok=True)
harness = r'''
import Foundation
struct Status { var state: String }
struct RouteFailure: Error {}
@MainActor final class Audio {
    var running = true
    var captureEnabled = false
    var muted = false
    var routeChanges = 0
    var requestedSpeaker: Bool?
    var failRoute = false
    func setSpeaker(_ value: Bool) throws {
        if failRoute { throw RouteFailure() }
        requestedSpeaker = value; routeChanges += 1
    }
}
@MainActor final class Scenario {
    var callBusy = false
    var mediaConnected = true
    var ownedCallID: String? = "synthetic-call"
    var speakerEnabled = false
    var muted = false
    var notice = ""
    var status: Status? = Status(state: "dialing")
    let audio = Audio()
    // The fixture deliberately exposes no engine teardown/start or end-call API.
    // A route operation must not depend on those destructive operations.
''' + method + r'''
}
@main struct Check {
    @MainActor static func main() async {
        let pending = Scenario()
        await pending.toggleSpeaker()
        precondition(pending.audio.running && pending.mediaConnected)
        precondition(!pending.audio.captureEnabled && pending.audio.requestedSpeaker == true)
        pending.status = Status(state: "active"); pending.audio.captureEnabled = true
        precondition(pending.audio.running && pending.audio.captureEnabled)

        let active = Scenario()
        active.status = Status(state: "active"); active.audio.captureEnabled = true
        active.muted = true; active.audio.muted = true
        await active.toggleSpeaker()
        precondition(active.audio.running && active.audio.captureEnabled && active.audio.muted)
        active.speakerEnabled = true
        await active.toggleSpeaker()
        precondition(active.audio.requestedSpeaker == false && active.audio.routeChanges == 2)

        let failed = Scenario(); failed.audio.failRoute = true
        await failed.toggleSpeaker()
        precondition(failed.audio.running && failed.mediaConnected && !failed.callBusy)
        precondition(!failed.notice.isEmpty)

        for blocked in 0..<3 {
            let unavailable = Scenario()
            if blocked == 0 { unavailable.callBusy = true }
            if blocked == 1 { unavailable.mediaConnected = false }
            if blocked == 2 { unavailable.ownedCallID = nil }
            await unavailable.toggleSpeaker()
            precondition(unavailable.audio.routeChanges == 0)
        }
        print("Speaker switching: dialing→active, active, mute, both routes, route failure and ownership guards passed (offline).")
    }
}
'''
test = out / "speaker-switch-check.swift"
test.write_text(harness)
env = os.environ.copy()
env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()
binary = out / "speaker-switch-check"
subprocess.run(["xcrun", "swiftc", "-sdk", sdk, "-parse-as-library",
                "-module-cache-path", str(out / "module-cache"), str(test), "-o", str(binary)], env=env, check=True)
subprocess.run([str(binary)], check=True)
