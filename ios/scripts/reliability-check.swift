import Foundation

@main struct ReliabilityChecks {
    static func main() throws {
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: label, code: 1) }
            print("通过：" + label)
        }
        let delays = (1...8).map { ConnectionRecovery.delay(afterFailures: $0) / 1_000_000_000 }
        try check(delays == [1, 2, 4, 8, 15, 15, 15, 15], "重连退避上限15秒")
        func state(_ state: String, _ id: String?, _ available: Bool = true) throws -> CallStatus {
            let data = try JSONSerialization.data(withJSONObject: ["state": state, "available": available, "call_id": id as Any? ?? NSNull()])
            return try JSONDecoder().decode(CallStatus.self, from: data)
        }
        try check(!ConnectionRecovery.ended(state("active", "old"), originalID: "old"), "旧通话仍活动不能误报挂断成功")
        try check(ConnectionRecovery.ended(state("idle", nil), originalID: "old"), "模块待机确认结束")
        try check(ConnectionRecovery.ended(state("ringing", "new"), originalID: "old"), "新来电不受旧挂断影响")
        try check(!ConnectionRecovery.ended(state("idle", nil, false), originalID: "old"), "设备失联不能确认挂断")
        let commit = String(repeating: "a", count: 40)
        let source = AppSource(commit: commit, url: "https://github.com/example/suixinghao/tree/" + commit)
        try check(source.commit == commit && source.url != nil, "已关联构建显示对应源码")
        for candidate in [nil, "", "uncommitted", "$(SXH_SOURCE_COMMIT)", "fake-version"] as [String?] {
            let unknown = AppSource(commit: candidate, url: source.url?.absoluteString)
            try check(unknown.commit == nil && unknown.url == nil, "缺少提交信息不伪造源码关联")
        }
        let dirty = AppSource(commit: commit + "-dirty", url: source.url?.absoluteString)
        try check(dirty.commit == commit + "-dirty" && dirty.url == nil, "本地改动不冒充已发布提交")
        for candidate in [nil, "", "http://github.com/example/suixinghao/tree/" + commit,
                          "https://user:secret@github.com/example/suixinghao/tree/" + commit,
                          "https://github.com/example/suixinghao/tree/" + String(repeating: "b", count: 40)] as [String?] {
            try check(AppSource(commit: commit, url: candidate).url == nil, "源码链接必须安全且对应构建提交")
        }
        print("通过：构建源码信息与未关联状态")
    }
}
