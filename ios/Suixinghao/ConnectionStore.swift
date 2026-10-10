import Foundation
import Security
import CryptoKit

struct SavedConnection: Codable {
    let address: String
    let key: String
    var disconnected: Bool? = nil
    var shouldAutoRestore: Bool { disconnected != true }
}
enum ConnectionStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Suixinghao.AppConnection",
         kSecAttrAccount as String: "current-server"]
    }
    static func save(_ connection: SavedConnection) throws {
        let data = try JSONEncoder().encode(connection)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw APIError(message: "无法安全保存连接信息，请重新连接。", statusCode: Int(status)) }
    }
    static func load() -> SavedConnection? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SavedConnection.self, from: data)
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError(message: "无法删除已保存的连接。") }
    }
}

struct CallRecord: Codable, Identifiable {
    let id: String
    let number: String
    let direction: String
    let startedAt: Date
    var answeredAt: Date?
    var endedAt: Date?
    var result: String {
        if endedAt == nil { return answeredAt == nil ? (direction == "来电" ? "呼入中" : "拨号中") : "通话中" }
        if answeredAt != nil { return "已接通" }
        return direction == "来电" ? "未接来电" : "未接通"
    }
    var duration: TimeInterval { answeredAt.map { max(0, (endedAt ?? Date()).timeIntervalSince($0)) } ?? 0 }
}

enum CallHistoryStore {
    private static func query(server: String) -> [String: Any] {
        let hash = SHA256.hash(data: Data(server.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Suixinghao.CallHistory",
                kSecAttrAccount as String: hash]
    }
    static func load(server: String) -> [CallRecord] {
        guard !server.isEmpty else { return [] }
        var request = query(server: server)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([CallRecord].self, from: data)) ?? []
    }
    static func save(_ records: [CallRecord], server: String) throws {
        guard !server.isEmpty else { return }
        let data = try JSONEncoder().encode(Array(records.prefix(200)))
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let query = query(server: server)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw APIError(message: "通话记录暂未保存到本机。") }
    }
    static func clear(server: String) throws {
        guard !server.isEmpty else { return }
        let status = SecItemDelete(query(server: server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError(message: "无法清空通话记录。") }
    }
}
