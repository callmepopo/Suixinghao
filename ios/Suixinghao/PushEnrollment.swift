import CryptoKit
import DeviceCheck
import Foundation
import Security

struct PushSetup: Decodable {
    let state: String
    let name: String?
    let environment: String
    let grant_id: String?
    let expires_at: String?
    let binding_id: String?
    let challenge: String?
    let confirmed_app_key: String?
    var title: String {
        ["not_enabled": "尚未开通，请先在 NAS 管理页申请", "pending": "等待本机确认绑定", "binding_expired": "绑定已过期，请在 NAS 重新申请", "authorized": "中继已授权", "expired": "授权已过期，请在 NAS 恢复续期", "revoked": "授权已撤销", "manual": "使用既有手工中继授权"][state] ?? "状态待核对"
    }
}
struct PushProof: Codable { let key_id: String; let object: String; let assertion: Bool }

// Opaque App Attest key IDs only. No service address, backend credential or
// device serial is sent to the publisher. Never fall back to an unverified proof.
@MainActor enum PushEnrollment {
    private struct KeyState: Codable {
        let id: String
        var registered: Bool
        var pendingChallenge: String?
        var pendingObject: String?
    }
    private static func query(_ environment: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Suixinghao.AppAttest",
         kSecAttrAccount as String: environment]
    }
    private static func load(_ environment: String) -> KeyState? {
        var q = query(environment); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(KeyState.self, from: data)
    }
    private static func save(_ value: KeyState, _ environment: String) throws {
        let a: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(query(environment) as CFDictionary, a as CFDictionary)
        if result == errSecItemNotFound { result = SecItemAdd(query(environment).merging(a) { _, new in new } as CFDictionary, nil) }
        guard result == errSecSuccess else { throw APIError(message: "无法安全保存推送绑定证明，请稍后重试。") }
    }
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
    static func proof(challenge: String) async throws -> PushProof {
        let service = DCAppAttestService.shared
        guard service.isSupported else { throw APIError(message: "此设备暂不支持官方应用验证，请使用既有手工接入方式。") }
        guard !challenge.isEmpty, challenge.utf8.count < 1024 else { throw APIError(message: "绑定请求无效，请在 NAS 重新申请。") }
        var key = load(environment)
        if key == nil || (key?.registered == false && key?.pendingObject != nil && key?.pendingChallenge != challenge) {
            let id: String = try await withCheckedThrowingContinuation { continuation in
                service.generateKey { id, error in
                    if let id { continuation.resume(returning: id) }
                    else { continuation.resume(throwing: error ?? APIError(message: "无法生成应用验证，请稍后重试。")) }
                }
            }
            key = KeyState(id: id, registered: false)
            try save(key!, environment)
        }
        var state = key!
        if !state.registered, state.pendingChallenge == challenge, let object = state.pendingObject {
            return PushProof(key_id: state.id, object: object, assertion: false)
        }
        let hash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let object: Data = try await withCheckedThrowingContinuation { continuation in
            let done: (Data?, Error?) -> Void = { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? APIError(message: "应用验证暂不可用，请稍后重试。")) }
            }
            if state.registered { service.generateAssertion(state.id, clientDataHash: hash, completionHandler: done) }
            else { service.attestKey(state.id, clientDataHash: hash, completionHandler: done) }
        }
        if !state.registered {
            state.pendingChallenge = challenge; state.pendingObject = object.base64EncodedString()
            try save(state, environment)
        }
        return PushProof(key_id: state.id, object: object.base64EncodedString(), assertion: state.registered)
    }
    static func confirmed() throws {
        guard var state = load(environment) else { return }
        state.registered = true; state.pendingChallenge = nil; state.pendingObject = nil
        try save(state, environment)
    }
    static func recoverConfirmation(keyID: String?) throws {
        guard let keyID, let state = load(environment), state.id == keyID else { return }
        try confirmed()
    }
}

extension API {
    func confirmPush(base: URL, token: String, binding: String, proof: PushProof, environment: String) async throws -> PushSetup {
        struct Body: Encodable { let action = "confirm"; let binding_id: String; let proof: PushProof }
        let data = try JSONEncoder().encode(Body(binding_id: binding, proof: proof))
        let response = try await requestJSON(base, path: "voice-test/app/push-setup", token: token,
            body: data, query: [URLQueryItem(name: "environment", value: environment)])
        return try JSONDecoder().decode(PushSetup.self, from: response)
    }
}
