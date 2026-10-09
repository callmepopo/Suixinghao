import Foundation

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "SXHReleaseVersion") as? String ?? "开发构建"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未设置"
    }
    static var channel: String {
        switch Bundle.main.object(forInfoDictionaryKey: "SXHBuildChannel") as? String {
        case "testing": return "本地测试"
        case "release": return "正式 Release 构建"
        case "simulator": return "模拟器构建"
        default: return "开发构建"
        }
    }
}

/// Read build provenance from the bundle. No remote update service is contacted.
struct AppSource {
    let commit: String?
    let url: URL?

    static var current: AppSource {
        AppSource(commit: Bundle.main.object(forInfoDictionaryKey: "SXHSourceCommit") as? String,
                  url: Bundle.main.object(forInfoDictionaryKey: "SXHSourceURL") as? String)
    }

    init(commit rawCommit: String?, url rawURL: String?) {
        let value = rawCommit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.range(of: "^(?:[0-9a-f]{40}|[0-9a-f]{64})(?:-dirty)?$", options: .regularExpression) != nil else {
            commit = nil
            url = nil
            return
        }
        commit = value
        guard !value.hasSuffix("-dirty"),
              let source = URL(string: rawURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
              source.scheme == "https", source.host != nil,
              source.user == nil, source.password == nil, source.query == nil, source.fragment == nil,
              source.path.hasSuffix("/" + value) else {
            url = nil
            return
        }
        url = source
    }
}
