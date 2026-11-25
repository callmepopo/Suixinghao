import Foundation

enum SMSWebLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributedText(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector else { return attributed }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  url.host?.isEmpty == false,
                  let range = Range(match.range, in: attributed) else { continue }
            attributed[range].link = url
        }
        return attributed
    }
}
