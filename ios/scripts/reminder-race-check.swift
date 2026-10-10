import Foundation

@MainActor
final class FakeDelivery: ReminderNotificationDelivering {
    var waiting: [String: CheckedContinuation<Void, Error>] = [:]
    var adds: [String] = []
    var removals: [String] = []
    func add(_ id: String) async throws {
        adds.append(id)
        try await withCheckedThrowingContinuation { waiting[id] = $0 }
    }
    func remove(_ id: String) { removals.append(id) }
    func finish(_ id: String) { waiting.removeValue(forKey: id)!.resume() }
    func waitFor(_ id: String) async {
        while waiting[id] == nil { await Task.yield() }
    }
}

@main struct ReminderRaceChecks {
    @MainActor static func main() async {
        let fake = FakeDelivery()
        let reminder = IncomingCallReminder(delivery: fake)
        let a = IncomingCallReminder.category + ".a"
        let b = IncomingCallReminder.category + ".b"
        let first = Task { await reminder.show("a") }
        await fake.waitFor(a)
        await reminder.show("a")
        precondition(fake.adds == [a], "duplicate during add must not schedule again")
        reminder.clear("a")
        let second = Task { await reminder.show("b") }
        await fake.waitFor(b)
        fake.finish(a)
        await first.value
        precondition(fake.removals == [a, a], "late add must remove ended call without removing new call")
        fake.finish(b)
        await second.value
        precondition(fake.removals == [a, a], "live new call remains visible")
        reminder.clear("b")
        await reminder.show("a")
        await reminder.show("b")
        precondition(fake.adds == [a, b], "ended duplicates must not create new reminders")
        precondition(fake.removals.last == b)
        print("Incoming reminder asynchronous add/end, new-call isolation and duplicate checks passed")
    }
}
