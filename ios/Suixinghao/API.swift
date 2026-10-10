import Foundation

struct APIError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}

struct LoginResponse: Decodable { let token: String; let expires_in: Double? }
struct PhoneDiagnostics: Decodable {
    let server_version: String
    let module_available: Bool
    let module_checked_at: String?
    let module_rtt_ms: Int
    let sim_status: String
    let network_status: String
    let signal_rssi: Int?
    let network_checked_at: String?
}
struct CallStatus: Decodable {
    let state: String
    let available: Bool
    let recording: Bool?
    let call_id: String?
    let caller: String?
    let media: Bool?
    let message: String?
    var hasCall: Bool { ["dialing", "ringing", "active", "busy"].contains(state) }
    var title: String {
        guard available else { return "设备暂不可用" }
        return ["idle": "待机", "ringing": "有来电", "dialing": "拨号中", "active": "通话中", "busy": "忙线", "unavailable": "暂不可用"][state] ?? "未知状态"
    }
}
struct SMSContact: Decodable, Identifiable {
    let peer: String
    let iccid: String?
    let imsi: String?
    let device_id: String?
    let last_content: String
    let last_timestamp: String
    let unread_count: Int
    var id: String { "\(iccid ?? imsi ?? device_id ?? "")|\(peer)" }
}
struct SMSMessage: Decodable, Identifiable {
    let id: Int
    let content: String
    let timestamp: String
    let type: Int
}
struct Device: Decodable, Identifiable {
    let id: String
    let name: String?
    let running: Bool
}
struct DeviceList: Decodable { let devices: [Device] }

// No cookies, cache, disk storage or logging of credentials/message bodies.
final class API: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    #if DEBUG
    // Local acceptance injection. Release builds have no mock request path.
    var testSession: URLSession?
    var testRequest: (@MainActor (String, [String: String]?) async throws -> Data)?
    #endif
    private lazy var session: URLSession = {
        #if DEBUG
        if let testSession { return testSession }
        #endif
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    // Reject redirects so authorization never travels to a different host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    static func baseURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, ["", "/"].contains(url.path) else {
            throw APIError(message: "请输入 HTTPS 服务器地址，仅含域名和可选端口。")
        }
        return url
    }
    func request(_ base: URL, path: String, token: String = "", body: [String: String]? = nil, query: [URLQueryItem] = [], timeout: TimeInterval = 20) async throws -> Data {
        #if DEBUG
        if let testRequest { return try await testRequest(path, body) }
        #endif
        var request = URLRequest(url: Self.requestURL(base, path: path, query: query))
        request.timeoutInterval = timeout
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "服务器响应无效。") }
        guard (200..<300).contains(http.statusCode) else {
            let description = [401: "鉴权 Key 无效或已过期，请更新 Key。", 403: "服务器拒绝访问。", 409: "设备忙碌或当前状态不允许此操作。"]
            throw APIError(message: description[http.statusCode] ?? "请求未完成（HTTP \(http.statusCode)）。", statusCode: http.statusCode)
        }
        return data
    }
    func delete(_ base: URL, path: String, token: String) async throws {
        var request = URLRequest(url: Self.requestURL(base, path: path, query: []))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 204 else { throw APIError(message: "推送令牌清除失败。") }
    }
    func deleteSMS(_ base: URL, token: String, contact: SMSContact, messageID: Int?) async throws {
        if let messageID, messageID <= 0 { throw APIError(message: "无效的短信记录。") }
        let path = messageID.map { "voice-test/app/sms/messages/\($0)" } ?? "voice-test/app/sms/thread"
        let query = messageID == nil ? Self.threadQuery(contact).filter { $0.name != "limit" } : []
        guard messageID != nil || query.count == 2 else { throw APIError(message: "此会话缺少卡片信息，无法删除。") }
        var request = URLRequest(url: Self.requestURL(base, path: path, query: query))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "未收到删除结果，请刷新核对。") }
        guard http.statusCode == 200 else {
            throw APIError(message: "删除短信失败（HTTP \(http.statusCode)），请稍后重试。", statusCode: http.statusCode)
        }
    }
    func uploadConnectionEvents(_ events: [ConnectionEvent], base: URL, token: String) async throws {
        struct Batch: Encodable { let events: [ConnectionEvent] }
        struct Receipt: Decodable { let accepted: Int }
        var request = URLRequest(url: Self.requestURL(base, path: "voice-test/app/connection-history", query: []))
        request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Batch(events: events))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              (try? JSONDecoder().decode(Receipt.self, from: data).accepted) == events.count else {
            throw APIError(message: "连接历史尚未同步，稍后自动重试。")
        }
    }
    func markSMSRead(_ base: URL, token: String, contact: SMSContact, throughID: Int) async throws -> Int {
        guard let iccid = contact.iccid, !iccid.isEmpty, throughID > 0 else {
            throw APIError(message: "此短信会话缺少已读标记所需的卡片信息。")
        }
        var request = URLRequest(url: Self.requestURL(base, path: "voice-test/app/sms/thread", query: [
            .init(name: "iccid", value: iccid), .init(name: "peer", value: contact.peer)
        ]))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["through_id": throughID])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError(message: "短信已打开，但已读状态未同步，请稍后重试。")
        }
        struct ReadResult: Decodable { let unread_count: Int }
        return try JSONDecoder().decode(ReadResult.self, from: data).unread_count
    }
    func read<T: Decodable>(_ type: T.Type, base: URL, path: String, token: String, query: [URLQueryItem] = [], timeout: TimeInterval = 20) async throws -> T {
        try JSONDecoder().decode(type, from: await request(base, path: path, token: token, query: query, timeout: timeout))
    }
    static func requestURL(_ base: URL, path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }
    static func threadQuery(_ contact: SMSContact) -> [URLQueryItem] {
        var query: [URLQueryItem] = [.init(name: "peer", value: contact.peer), .init(name: "limit", value: "100")]
        // HiDeck selectors are mutually exclusive. ICCID identifies historical SIMs.
        if let iccid = contact.iccid, !iccid.isEmpty { query.append(.init(name: "iccid", value: iccid)) }
        else if let imsi = contact.imsi, !imsi.isEmpty { query.append(.init(name: "imsi", value: imsi)) }
        else if let device = contact.device_id, !device.isEmpty { query.append(.init(name: "device_id", value: device)) }
        return query
    }
    static func normalizedKey(_ input: String) throws -> String {
        var key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("Bearer ") { key = String(key.dropFirst(7)) }
        guard key.range(of: "^hdk_[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw APIError(message: "请输入服务端签发的 App Key（以 hdk_ 开头），不要填写网页密码。")
        }
        return key
    }
    static func normalizedNumber(_ input: String) throws -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.range(of: "^1[0-9]{10}$", options: .regularExpression) != nil { return "+86" + raw }
        if raw.range(of: "^\\+[1-9][0-9]{6,14}$", options: .regularExpression) != nil { return raw }
        throw APIError(message: "请输入 11 位国内手机号，或以 + 开头的完整国际号码。")
    }
    static func normalizedSMSReplyNumber(_ input: String) throws -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.range(of: "^[0-9]{3,6}$", options: .regularExpression) != nil { return raw }
        return try normalizedNumber(raw)
    }
    static func normalizedDialNumber(_ input: String) throws -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.range(of: "^1[0-9]{10}$", options: .regularExpression) != nil { return "+86" + raw }
        if raw.range(of: "^(?:\\+[1-9][0-9]{6,14}|[0-9]{3,6}|[2-9][0-9]{6,7}|0[0-9]{9,11}|(?:400|800)[0-9]{7})$", options: .regularExpression) != nil { return raw }
        throw APIError(message: "请输入手机号、3～6 位短号、座机、400/800 号码或完整国际号码。")
    }

    static func cellularCallURL(_ input: String) throws -> URL {
        // Keep local numbers unchanged. Only remote module dialing adds +86.
        let number = try normalizedExternalCallNumber(input)
        var components = URLComponents()
        components.scheme = "telephony"
        components.path = number
        guard let url = components.url else { throw APIError(message: "无法交给系统拨号。") }
        return url
    }

    static func numberFromSystemCallURL(_ url: URL) throws -> String {
        guard url.scheme?.lowercased() == "tel", url.host == nil,
              let encoded = url.absoluteString.split(separator: ":", maxSplits: 1).last,
              !encoded.isEmpty, !encoded.hasPrefix("//"),
              let decoded = String(encoded).removingPercentEncoding else {
            throw APIError(message: "无法识别其他 App 传来的电话号码。")
        }
        return try normalizedExternalCallNumber(decoded)
    }

    static func normalizedExternalCallNumber(_ input: String) throws -> String {
        guard !input.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 0x20 }) else {
            throw APIError(message: "无法识别其他 App 传来的电话号码。")
        }
        let compact = input.filter { !" -().".contains($0) }
        _ = try normalizedDialNumber(compact)
        return compact
    }
}
