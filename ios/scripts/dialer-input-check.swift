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
        // Long press 0: "+" only at the start, otherwise a plain "0"; never both.
        var plus = DialerInput()
        precondition(plus.longPressZero() && plus.number == "+")
        precondition(plus.longPressZero() && plus.number == "+0")
        var typed = DialerInput(number: "138")
        precondition(typed.longPressZero() && typed.number == "1380")
        var full = DialerInput(number: String(repeating: "1", count: DialerInput.maxLength))
        precondition(!full.append("2") && !full.longPressZero() && full.number.count == DialerInput.maxLength)
        precondition(full.deleteLast() && full.number.count == DialerInput.maxLength - 1)
        var empty = DialerInput()
        precondition(!empty.deleteLast())
        // Paste cleaning.
        let pastes: [(String, String?)] = [
            ("+86 138-0013-8000", "+8613800138000"), ("(010) 6552.9988", "01065529988"),
            (" 138 0013 8000\n", "13800138000"), ("＋1 202 555 0123", "+12025550123"),
            ("*#06#", "*#06#"), ("95588", "95588"),
            ("Tel: 13800138000", nil), ("138+0013", nil), ("hello", nil), ("", nil), ("- -", nil),
            ("12345678901234567", nil), ("1234567890123456", "1234567890123456"),
        ]
        for (text, expected) in pastes {
            precondition(DialerInput.sanitizedPaste(text) == expected, "paste \(text)")
        }
        // Display grouping.
        for (raw, shown) in [("138", "138"), ("1380", "138 0"), ("1380013", "138 0013"), ("13800138000", "138 0013 8000"),
                             ("010", "010"), ("+8613800138000", "+8613800138000"), ("138001380001", "138001380001")] {
            precondition(DialerInput.display(raw) == shown, "display \(raw)")
        }
        print("Dialer input: external handoff callback orders, cold start, call, pending and inactive transitions passed")
        // Call-screen name lookup: whole number only, never a suffix.
        for (x, y, same) in [("10086", "10086", true), ("10086", "13800010086", false), ("10086", "02110086", false),
                             ("13800138000", "+86 138-0013-8000", true), ("13800138000", "008613800138000", true),
                             ("13800138000", "3800138000", false), ("", "", false), ("02165529988", "2165529988", true)] {
            precondition(DialerInput.sameNumber(x, y) == same, "same \(x) \(y)")
        }
        print("Dialer input: long-press plus, length limit, delete, paste cleaning, number grouping and whole-number name match passed")
    }
}
