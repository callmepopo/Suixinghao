import Foundation

/// A cleared or duplicated call must never schedule another reminder.
struct IncomingReminderState {
    private(set) var active: String?
    private var seen: [String] = []

    mutating func begin(_ id: String) -> Bool {
        guard active == nil, !seen.contains(id) else { return false }
        seen.append(id)
        if seen.count > 64 { seen.removeFirst() }
        active = id
        return true
    }

    mutating func clear(_ id: String) -> Bool {
        guard active == id else { return false }
        active = nil
        return true
    }
}
