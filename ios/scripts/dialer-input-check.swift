import Foundation

@main struct DialerInputChecks {
    static func main() {
        // Both system callback orders must retain this visit's external number.
        for deliveredBeforeActivation in [true, false] {
            var input = DialerInput(number: "old-draft")
            precondition(input.transition(to: .background, callInProgress: false, pendingExternalNumber: false))
            precondition(input.number.isEmpty)
            if deliveredBeforeActivation { input.number = "synthetic-incoming" }
            input.transition(to: .active, callInProgress: false, pendingExternalNumber: false)
            if !deliveredBeforeActivation { input.number = "synthetic-incoming" }
            precondition(input.number == "synthetic-incoming")
        }
        var cold = DialerInput(number: "synthetic-cold-start")
        cold.transition(to: .active, callInProgress: false, pendingExternalNumber: false)
        precondition(cold.number == "synthetic-cold-start")
        var existingCall = DialerInput(number: "synthetic-active-call")
        existingCall.transition(to: .background, callInProgress: true, pendingExternalNumber: false)
        precondition(existingCall.number == "synthetic-active-call")
        var pending = DialerInput(number: "synthetic-pending")
        pending.transition(to: .background, callInProgress: false, pendingExternalNumber: true)
        precondition(pending.number == "synthetic-pending")
        var permissionSheet = DialerInput(number: "synthetic-draft")
        permissionSheet.transition(to: .inactive, callInProgress: false, pendingExternalNumber: false)
        permissionSheet.transition(to: .active, callInProgress: false, pendingExternalNumber: false)
        precondition(permissionSheet.number == "synthetic-draft")
        print("Dialer input: external handoff callback orders, cold start, call, pending and inactive transitions passed")
    }
}
