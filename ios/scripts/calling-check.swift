import Foundation

@main struct CallingChecks {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw APIError(message: "检查失败：" + label) }
            count += 1
        }
        for number in ["13800000000", "+12025550123", "01012345678", "10086", "4001234567"] {
            let url = try API.cellularCallURL(number)
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            try check(components.scheme == "telephony" && components.host == nil && components.path == number,
                      "系统转交保留原号码且不使用默认 tel 路由")
        }
        for invalid in ["tel:10086", "10086;ATH", "10086\nAT", "*123#", "１２３４５"] {
            do {
                _ = try API.cellularCallURL(invalid)
                throw APIError(message: "接受了非法系统号码")
            } catch let e as APIError {
                try check(e.message != "接受了非法系统号码", "拒绝非法系统号码")
            }
        }
        var session = CallSession()
        let incoming = session.incoming(id: "synthetic-incoming")!
        try check(session.incoming(id: "synthetic-incoming") == incoming, "前台与推送重复来电使用同一 UUID")
        try check(session.incoming(id: "other") == nil && session.outgoing(number: "10086") == nil, "单路通话拒绝第二路")
        try check(session.waitForAudio(incoming), "接听等待系统音频激活")
        try check(!session.waitForAudio(incoming), "重复接听不重复启动")
        try check(session.takeAudioWork()?.uuid == incoming && session.takeAudioWork() == nil, "音频回调只消费一次")
        session.clear(incoming)
        try check(!session.bind("late-id", to: incoming) && !session.waitForAudio(incoming), "挂断后的迟到结果无效")
        let outgoing = session.outgoing(number: "10086")!
        try check(session.clear(incoming) == nil && session.contains(outgoing), "旧通话清理不影响新通话")
        try check(session.waitForAudio(outgoing), "外呼等待系统音频")
        session.clear(outgoing)
        try check(session.takeAudioWork() == nil, "连接中取消后不启动声音或拨号")
        let next = session.outgoing(number: "10086")!
        try check(session.bind("synthetic-outgoing", to: next), "外呼建立后绑定远端通话")
        try check(session.connected("other") == nil, "其他客户端接通不更新本机通话")
        try check(session.connected("synthetic-outgoing") == next && session.connected("synthetic-outgoing") == nil,
                  "外呼接通只上报一次")
        session.clear(next)
        try check(session.call == nil, "结束后释放系统通话槽位")
        print("系统拨号与通话生命周期检查 \(count) 项通过（不代表真机 CallKit/蜂窝拨号验收）")
    }
}
