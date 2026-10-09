import Foundation

@main struct HistoryChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func event(_ at: Double, _ state: String, _ kind: String = "observation") -> ConnectionEvent {
        ConnectionEvent(id: UUID().uuidString.lowercased(), at: at, layer: "phone", kind: kind, state: state, reason: "")
    }
    @MainActor static func main() async throws {
        let now = Date().timeIntervalSince1970
        let history = [event(now-300,"online"), event(now-240,"offline","network_down"),
                       event(now-205,"online","connected"), event(now-200,"unknown","observer_stop")]
        let summary = ConnectionSummary.phone(events: history, now: now)
        require(summary.online_seconds == 65 && summary.offline_seconds == 35 && summary.unknown_seconds == 86300, "observed time calculation")
        require(summary.online_rate == 0.65 && summary.interruptions == 1, "availability denominator")
        let gap = ConnectionSummary.phone(events: [event(now-300,"offline"),event(now-100,"online")], now: now)
        require(gap.offline_seconds == 90 && gap.online_seconds == 90 && gap.unknown_seconds == 86220, "suspension must expire observations")
        require(ConnectionSummary.phone(events: [],now: now).online_rate == nil, "empty history must not imply availability")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConnectionEventStore(scope: "synthetic", directory: dir)
        for e in history { await store.append(e) }
        await store.flush()
        let reopened = ConnectionEventStore(scope: "synthetic", directory: dir)
        let initial = await reopened.snapshot()
        require(initial.events.count == 4 && initial.pending == 4 && !initial.failed, "offline persistence and restart")
        await reopened.acknowledged([history[0].id]); await reopened.flush()
        let afterAckBase = try Data(contentsOf: dir.appendingPathComponent("synthetic.json"))
        let initialBase = try JSONDecoder().decode([ConnectionEventStore.Item].self, from: afterAckBase)
        require(!initialBase[0].uploaded, "acknowledgement should append journal, not rewrite history")
        let third = ConnectionEventStore(scope: "synthetic", directory: dir)
        let pending = await third.pending()
        require(pending.count == 3 && !pending.contains(where: { $0.id == history[0].id }), "acknowledged IDs survive restart")
        let journalURL = dir.appendingPathComponent("synthetic.json.journal")
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{interrupted".utf8)); try handle.close()
        let afterInterruption = ConnectionEventStore(scope:"synthetic",directory:dir)
        let recovered = await afterInterruption.snapshot()
        require(recovered.events.count == 4 && recovered.pending == 3 && !recovered.failed, "interrupted journal append must preserve acknowledged records")
        let other = ConnectionEventStore(scope: "other", directory: dir)
        let otherState = await other.snapshot()
        require(otherState.events.isEmpty, "server/Key scope isolation")
        try Data("corrupt".utf8).write(to: dir.appendingPathComponent("broken.json"))
        let broken = ConnectionEventStore(scope: "broken", directory: dir)
        await broken.append(event(now,"online")); await broken.flush()
        let brokenState = await broken.snapshot()
        require(brokenState.failed, "corrupt history must surface failure")
        let original = try String(contentsOf: dir.appendingPathComponent("broken.json"),encoding: .utf8)
        require(original == "corrupt", "corrupt history must not be overwritten")
        let recorder = ConnectionTelemetry(directory: dir)
        recorder.configure(address:"https://synthetic.example",key:"synthetic-key",active:true)
        recorder.success(); recorder.network(available: false, changed: true)
        recorder.network(available: false, changed: false)
        recorder.network(available: true, changed: true); recorder.attempt(); recorder.success()
        recorder.suspend(); recorder.network(available: false, changed: true); recorder.resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        let recorded = await recorder.store!.snapshot()
        require(recorded.events.filter { $0.kind == "network_down" }.count == 1, "duplicate network callbacks or background detection")
        require(recorded.events.filter { $0.kind == "network_up" }.count == 1, "network recovery timestamp")
        require(recorded.events.last?.state == "unknown", "foreground return requires fresh service success")
        recorder.disconnect()
        print("Connection history: coverage/gaps, persistence/acknowledgement, scope isolation, corruption and lifecycle checks passed")
    }
}
