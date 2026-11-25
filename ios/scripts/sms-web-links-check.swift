import Foundation

@main struct SMSWebLinkChecks {
    static func main() {
        let cases: [(text: String, labels: [String], urls: [String])] = [
            ("🧾详情：https://example.com/账单?r=1&v=2#明细。", ["https://example.com/账单?r=1&v=2#明细"],
             ["https://example.com/%E8%B4%A6%E5%8D%95?r=1&v=2#%E6%98%8E%E7%BB%86"]),
            ("（http://example.org/a_(b)），另见 www.example.com/a。",
             ["http://example.org/a_(b)", "www.example.com/a"], ["http://example.org/a_(b)", "https://www.example.com/a"]),
            ("邮件 sample@example.com；放大 ftp://example.org/a；打开 app://example.com/a 或 file:///tmp/demo。", [], []),
            ("验证码 482913。\n这是一条普通短信。", [], []),
            ("", [], [])
        ]
        for test in cases {
            let attributed = SMSWebLinks.attributedText(test.text)
            let runs = attributed.runs.filter { $0.link != nil }
            precondition(String(attributed.characters) == test.text, "短信原文发生变化")
            precondition(runs.map { String(attributed[$0.range].characters) } == test.labels, "网页链接文本不匹配")
            precondition(runs.compactMap { $0.link?.absoluteString } == test.urls, "网页链接目标不匹配")
        }
        print("SMS web links: multiple links, Unicode, punctuation, original text and supported schemes passed")
    }
}
