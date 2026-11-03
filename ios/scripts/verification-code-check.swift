import Foundation

@main struct VerificationCodeChecks {
    static func main() {
        // Synthetic texts only; no real messages.
        let cases: [(String, String?)] = [
            ("【示例】您的验证码为 482913，5分钟内有效。", "482913"),
            ("482913是您的登录校验码，请勿泄露。", "482913"),
            ("动态码：7305，有效期10分钟。", "7305"),
            ("Your code is 55821930. Do not share it.", "55821930"),
            ("OTP 0042 for login", "0042"),
            ("验证码 123456，订单号 2026110312，客服 95588。", "123456"),
            ("您2026年11月的账单已出，请登录查看。", nil),
            ("请拨打 13800000000 联系我们，验证码稍后发送。", nil),
            ("验证码为 123，请重试。", nil),
            ("会议号 884421，明天上午见。", nil),
            ("", nil),
        ]
        for (text, expected) in cases {
            let got = VerificationCode.extract(from: text)
            precondition(got == expected, "\(text) -> \(got ?? "nil"), expected \(expected ?? "nil")")
        }
        print("Verification code: keyword proximity, 4-8 digit bounds, phone numbers and non-code texts passed")
    }
}
