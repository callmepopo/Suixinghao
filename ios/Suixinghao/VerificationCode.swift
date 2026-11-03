import Foundation

/// Finds a one-time code in a received SMS so the thread can offer a copy button.
/// Runs only on the in-memory message text; nothing is stored or sent.
enum VerificationCode {
    static let keywords = ["验证码", "校验码", "动态码", "动态密码", "确认码", "安全码", "code", "otp", "passcode"]
    /// Maximum characters between the keyword and the digits.
    static let maxDistance = 30

    static func extract(from text: String) -> String? {
        let ns = text as NSString
        let lower = text.lowercased() as NSString
        guard lower.length == ns.length else { return nil }
        var keywordRanges: [NSRange] = []
        for keyword in keywords {
            var search = NSRange(location: 0, length: lower.length)
            while true {
                let found = lower.range(of: keyword, options: [], range: search)
                if found.location == NSNotFound { break }
                keywordRanges.append(found)
                let next = found.location + found.length
                search = NSRange(location: next, length: lower.length - next)
            }
        }
        guard !keywordRanges.isEmpty,
              let digits = try? NSRegularExpression(pattern: "(?<![0-9])[0-9]{4,8}(?![0-9])") else { return nil }
        var best: (distance: Int, after: Bool, code: String)?
        for match in digits.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let number = match.range
            for keyword in keywordRanges {
                let after = number.location >= keyword.location + keyword.length
                let distance = after
                    ? number.location - (keyword.location + keyword.length)
                    : keyword.location - (number.location + number.length)
                guard distance >= 0, distance <= maxDistance else { continue }
                if let current = best, current.distance < distance || (current.distance == distance && (current.after || !after)) { continue }
                best = (distance, after, ns.substring(with: number))
            }
        }
        return best?.code
    }
}
