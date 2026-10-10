import Foundation

/// An in-memory draft. Clear the previous visit before a new external handoff,
/// never when activating: the system may deliver the number before that callback.
struct DialerInput {
    enum Phase { case active, inactive, background }
    var number = ""

    @discardableResult
    mutating func transition(to phase: Phase, callInProgress: Bool, pendingExternalNumber: Bool) -> Bool {
        guard phase == .background, !callInProgress, !pendingExternalNumber else { return false }
        number = ""
        return true
    }
}
