import Foundation

final class SMSDeleteProtocol: URLProtocol {
    static var responseCode = 200
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.responseCode, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct SMSSettingsChecks {
    static func main() async throws {
        func check(_ value: Bool, _ name: String) throws {
            if !value { throw APIError(message: "检查失败：" + name) }
        }
        let legacy = try JSONDecoder().decode(SavedConnection.self, from: Data(#"{"address":"https://example.invalid","key":"synthetic-key"}"#.utf8))
        try check(legacy.shouldAutoRestore, "旧钥匙串连接保持自动恢复")
        var paused = legacy
        paused.disconnected = true
        let restored = try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(paused))
        try check(!restored.shouldAutoRestore && restored.address == legacy.address && restored.key == legacy.key, "主动断开状态及地址Key保留")
        paused.disconnected = nil
        try check(paused.shouldAutoRestore, "重连解除主动断开")
        let oldHistory = Data(#"""
        [
            {"id":"missed","number":"000","direction":"来电","startedAt":0,"endedAt":10},
            {"id":"ringing","number":"000","direction":"来电","startedAt":20},
            {"id":"answered","number":"000","direction":"来电","startedAt":30,"answeredAt":31,"endedAt":40},
            {"id":"outgoing","number":"000","direction":"去电","startedAt":50,"endedAt":60}
        ]
        """#.utf8)
        var records = try JSONDecoder().decode([CallRecord].self, from: oldHistory)
        try check(records.filter(\.isUnreadMissedIncoming).map(\.id) == ["missed"], "旧通话记录中仅已结束且未接的来电计入角标")
        records[0].missedCallViewed = true
        let reloaded = try JSONDecoder().decode([CallRecord].self, from: JSONEncoder().encode(records))
        try check(reloaded.allSatisfy { !$0.isUnreadMissedIncoming }, "已读状态随通话记录保存")
        try check(reloaded.first?.isMissedIncoming == true, "标记已读后保留未接结果")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SMSDeleteProtocol.self]
        let api = API()
        api.testSession = URLSession(configuration: config)
        let base = URL(string: "https://example.invalid")!
        let contact = SMSContact(peer: "+synthetic-peer", iccid: "synthetic-card", imsi: "ignored", device_id: "ignored", last_content: "", last_timestamp: "", unread_count: 0)
        try await api.deleteSMS(base, token: "synthetic-key", contact: contact, messageID: nil)
        let thread = SMSDeleteProtocol.requests.last!
        let query = URLComponents(url: thread.url!, resolvingAgainstBaseURL: false)!.queryItems!
        try check(thread.httpMethod == "DELETE" && query.count == 2 && query.contains(.init(name: "peer", value: "+synthetic-peer")) && query.contains(.init(name: "iccid", value: "synthetic-card")), "整会话精确SIM选择器和加号编码")
        try await api.deleteSMS(base, token: "synthetic-key", contact: contact, messageID: 42)
        try check(SMSDeleteProtocol.requests.last!.url!.path == "/voice-test/app/sms/messages/42", "单条删除记录ID")
        for code in [401, 404, 500] {
            SMSDeleteProtocol.responseCode = code
            do { try await api.deleteSMS(base, token: "synthetic-key", contact: contact, messageID: 42); fatalError("删除失败误判成功") }
            catch let error as APIError { try check(error.statusCode == code, "保留删除失败状态") }
        }
        let count = SMSDeleteProtocol.requests.count
        do { try await api.deleteSMS(base, token: "synthetic-key", contact: contact, messageID: 0); fatalError("接受无效ID") }
        catch is APIError {}
        try check(SMSDeleteProtocol.requests.count == count, "无效删除不发请求")
        print("SMS deletion, saved connection and call history migration/persistence checks passed")
    }
}
