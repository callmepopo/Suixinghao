import Foundation

@main struct ReminderStateChecks {
    static func main() {

        var state = IncomingReminderState()
        precondition(state.begin("call-a"))
        precondition(!state.begin("call-a"), "duplicate push must not remind again")
        precondition(!state.begin("call-b"), "an occupied call cannot be replaced")
        precondition(!state.clear("stale-call"))
        precondition(state.active == "call-a", "stale cleanup must preserve current reminder")
        precondition(state.clear("call-a"))
        precondition(!state.begin("call-a"), "late push after answer/end must not remind again")
        precondition(state.begin("call-b"))
        precondition(!state.clear("call-a"))
        precondition(state.active == "call-b", "late add completion/cleanup must preserve new call")
        precondition(state.clear("call-b"))
        for index in 0..<1000 {
            let id = "call-\(index)"
            precondition(state.begin(id))
            precondition(state.clear(id))
        }
        precondition(!state.begin("call-999"), "recent closed calls remain deduplicated")
        print("Incoming reminder: duplicate, occupied, answer/end, stale completion and bounded history checks passed")
    }
}
