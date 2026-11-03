import Foundation

/// An in-memory draft. Clear the previous visit before a new external handoff,
/// never when activating: the system may deliver the number before that callback.
struct DialerInput {
    enum Phase { case active, inactive, background }
    static let maxLength = 16
    var number = ""

    @discardableResult
    mutating func transition(to phase: Phase, callInProgress: Bool, pendingExternalNumber: Bool) -> Bool {
        guard phase == .background, !callInProgress, !pendingExternalNumber else { return false }
        number = ""
        return true
    }

    /// Appends one keypad key; returns false when the draft is full.
    @discardableResult
    mutating func append(_ key: String) -> Bool {
        guard number.count < Self.maxLength else { return false }
        number += key
        return true
    }

    /// Native long press on 0: "+" only at the start of an empty number, otherwise a plain "0".
    @discardableResult
    mutating func longPressZero() -> Bool {
        number.isEmpty ? append("+") : append("0")
    }

    @discardableResult
    mutating func deleteLast() -> Bool {
        guard !number.isEmpty else { return false }
        number.removeLast()
        return true
    }

    /// Cleans pasted text into a dialable draft: drops spaces, dashes, dots and brackets;
    /// keeps digits, * and #, and "+" only as the first character. Returns nil for text
    /// that is not a number (letters or other symbols), has no digit, or is too long.
    static func sanitizedPaste(_ text: String) -> String? {
        let separators = Set(" -.()（）\u{00A0}\u{2009}\u{202F}\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\t\r\n")
        var result = ""
        for character in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if separators.contains(character) { continue }
            if character == "+" || character == "＋" {
                guard result.isEmpty else { return nil }
                result.append("+")
            } else if let ascii = character.asciiValue, (48...57).contains(ascii) || ascii == 42 || ascii == 35 {
                result.append(character)
            } else {
                return nil
            }
        }
        guard result.contains(where: \.isNumber), result.count <= maxLength else { return nil }
        return result
    }

    /// Normalizes a number for exact comparison: drops +86/0086 and restores a dropped area-code 0.
    static func comparableDigits(_ raw: String) -> String {
        var digits = raw.filter(\.isNumber)
        if digits.hasPrefix("0086") { digits = String(digits.dropFirst(4)) }
        else if digits.hasPrefix("86") && digits.count >= 12 { digits = String(digits.dropFirst(2)) }
        if digits.count >= 9 && digits.count <= 12 && !digits.hasPrefix("0") && !digits.hasPrefix("1") && !digits.hasPrefix("400") && !digits.hasPrefix("800") {
            digits = "0" + digits
        }
        return digits
    }

    /// Whole-number match only; a number that merely ends with the dialed digits is a different number.
    static func sameNumber(_ a: String, _ b: String) -> Bool {
        let left = comparableDigits(a)
        return !left.isEmpty && left == comparableDigits(b)
    }

    /// Mainland mobile numbers read as 3-4-4 while typing; everything else is shown as typed.
    static func display(_ number: String) -> String {
        guard number.count > 3, number.first == "1", number.allSatisfy({ $0.isASCII && $0.isNumber }), number.count <= 11 else { return number }
        let digits = Array(number)
        var groups = [String(digits[0..<3])]
        groups.append(String(digits[3..<min(7, digits.count)]))
        if digits.count > 7 { groups.append(String(digits[7...])) }
        return groups.joined(separator: " ")
    }
}
