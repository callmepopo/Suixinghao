import Foundation
import CryptoKit

struct ConnectionEvent: Codable, Identifiable, Sendable {
    let id: String
    let at: Double
    let layer: String
    let kind: String
    let state: String
    let reason: String
    var rssi: Int? = nil
    var date: Date { Date(timeIntervalSince1970: at) }
    var title: String {
        switch kind {
        case "network_down": "手机检测到无网络"
        case "network_up": "手机检测到网络恢复"
        case "network_change": "手机网络切换"
        case "retry": "尝试恢复服务连接"
        case "connected": "App 连接服务成功"
        case "request_failed": "手机到服务请求失败"
        case "auth_failed": "鉴权失效，停止重试"
        case "observer_start": "开始检测"
        case "observer_stop": reason == "logout" ? "主动更换服务，结束检测" : "后台未检测"
        case "module_state": "远端模块：\(stateTitle)"
        case "network_state": "模块蜂窝网络：\(stateTitle)"
        default: stateTitle
        }
    }
    var stateTitle: String { ["online":"在线", "offline":"离线", "unknown":"未检测"][state] ?? "状态变化" }
}

struct ConnectionSummary: Codable, Identifiable, Sendable {
    let layer: String
    let online_seconds: Double
    let offline_seconds: Double
    let unknown_seconds: Double
    let coverage: Double
    let online_rate: Double?
    let interruptions: Int
    var id: String { layer }
    var title: String { ["phone":"手机 → 服务", "module":"服务 → 模块", "network":"模块蜂窝网络"][layer] ?? layer }
    var rateText: String { online_rate.map { String(format: "%.1f%%", $0 * 100) } ?? "暂无有效检测" }
    var coverageText: String { String(format: "%.1f%%", coverage * 100) }

    static func phone(events: [ConnectionEvent], now: Double) -> Self {
        let start = now - 86400
        var state = "unknown", until = start, cursor = start
        var online = 0.0, offline = 0.0, interruptions = 0
        func add(_ stop: Double) {
            let knownEnd = min(stop, until)
            if knownEnd > cursor {
                if state == "online" { online += knownEnd - cursor }
                if state == "offline" { offline += knownEnd - cursor }
            }
            cursor = stop
        }
        for e in events.sorted(by: { $0.at < $1.at }) where e.layer == "phone" && e.at <= now && !e.state.isEmpty {
            if e.at < start { state = e.state; until = e.at + 90; continue }
            add(e.at)
            if e.state == "offline" && (state != "offline" || e.at > until) { interruptions += 1 }
            state = e.state; until = e.at + 90
        }
        add(now)
        let known = online + offline
        return Self(layer: "phone", online_seconds: online, offline_seconds: offline,
                    unknown_seconds: max(0, 86400-known), coverage: known/86400,
                    online_rate: known > 0 ? online/known : nil, interruptions: interruptions)
    }
}

struct ConnectionOutage: Codable, Identifiable, Sendable {
    let id: String
    let start: Double
    let end: Double?
    let network_restored: Double?
    let attempts: Int
    let reason: String
    let incomplete: Bool
    var date: Date { Date(timeIntervalSince1970: start) }
    var durationText: String {
        if incomplete { return "检测中断，完整时长未知" }
        return end.map { ConnectionHistory.duration(max(0, $0-start)) } ?? "尚未检测到恢复"
    }
    var reconnectText: String {
        guard !incomplete, let end, let network_restored else { return "暂无完整记录" }
        return ConnectionHistory.duration(max(0, end-network_restored))
    }
}

struct ConnectionHistory: Codable, Sendable {
    let generated_at: Double
    var summaries: [ConnectionSummary]
    let events: [ConnectionEvent]
    let outages: [ConnectionOutage]
    let retention_days: Int
    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f 秒", seconds) }
        if seconds < 3600 { return String(format: "%.1f 分钟", seconds/60) }
        return String(format: "%.1f 小时", seconds/3600)
    }
}

// Disk I/O stays on this actor. Events contain enums/timestamps only, with a
// per-service/per-Key opaque scope; the URL and Key never enter the file.
actor ConnectionEventStore {
    struct Item: Codable { let event: ConnectionEvent; var uploaded: Bool }
    struct JournalRecord: Codable { var event: ConnectionEvent?; var acknowledged: [String]? }
    private let file: URL
    private var items: [Item] = []
    private var loaded = false
    private var writable = true
    private var writeTask: Task<Void, Never>?
    private var dirty = false
    private var journal: [JournalRecord] = []
    private var lastCompacted = Date.distantPast
    private(set) var storageFailed = false
    init(scope: String, directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ConnectionHistory", isDirectory: true)
        file = root.appendingPathComponent(scope + ".json")
    }
    private func load() {
        guard !loaded else { return }
        loaded = true
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: file))
                lastCompacted = (try file.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate ?? .distantPast
            }
            let journalFile = file.appendingPathExtension("journal")
            if FileManager.default.fileExists(atPath: journalFile.path) {
                let data = try Data(contentsOf: journalFile)
                let complete = data.lastIndex(of: 10).map { $0 + 1 } ?? 0
                var indices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.event.id, $0.offset) })
                for line in data.prefix(complete).split(separator: 10) {
                    let record = try JSONDecoder().decode(JournalRecord.self, from: Data(line))
                    if let e = record.event, indices[e.id] == nil {
                        indices[e.id] = items.count; items.append(Item(event: e, uploaded: false))
                    }
                    for id in record.acknowledged ?? [] { if let i = indices[id] { items[i].uploaded = true } }
                }
                if complete < data.count {
                    let handle = try FileHandle(forWritingTo: journalFile)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: UInt64(complete))
                }
            }
        } catch { writable = false; storageFailed = true }
    }
    private func prune(now: Double) {
        items.removeAll { $0.event.at < now-30*86400 }
        if items.count > 45000 { items.removeFirst(items.count-45000) }
    }
    func append(_ event: ConnectionEvent) {
        load(); items.append(Item(event: event, uploaded: false)); prune(now: event.at); dirty = true
        journal.append(JournalRecord(event: event))
        scheduleWrite()
    }
    private func scheduleWrite() {
        guard writeTask == nil else { return }
        writeTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            persist(); writeTask = nil
        }
    }
    private func persist() {
        guard dirty, writable else { return }
        do {
            let root = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var url = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            let journalFile = file.appendingPathExtension("journal")
            let size = (try? journalFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if Date().timeIntervalSince(lastCompacted) >= 86400 || size > 2*1024*1024 {
                #if os(iOS)
                try JSONEncoder().encode(items).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try JSONEncoder().encode(items).write(to: file, options: .atomic)
                #endif
                if FileManager.default.fileExists(atPath: journalFile.path) {
                    let handle = try FileHandle(forWritingTo: journalFile)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 0); try handle.synchronize()
                }
                lastCompacted = Date()
            } else {
                if !FileManager.default.fileExists(atPath: journalFile.path) {
                    #if os(iOS)
                    guard FileManager.default.createFile(atPath: journalFile.path, contents: nil,
                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw CocoaError(.fileWriteUnknown) }
                    #else
                    guard FileManager.default.createFile(atPath: journalFile.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                    #endif
                }
                var data = Data()
                for record in journal { data.append(try JSONEncoder().encode(record)); data.append(10) }
                let handle = try FileHandle(forWritingTo: journalFile)
                defer { try? handle.close() }
                let offset = try handle.seekToEnd()
                do { try handle.write(contentsOf: data); try handle.synchronize() }
                catch { try? handle.truncate(atOffset: offset); throw error }
            }
            journal.removeAll()
            dirty = false; storageFailed = false
        } catch { storageFailed = true }
    }
    func pending() -> [ConnectionEvent] {
        load(); prune(now: Date().timeIntervalSince1970)
        return Array(items.lazy.filter { !$0.uploaded }.prefix(100).map(\.event))
    }
    func acknowledged(_ ids: Set<String>) {
        load()
        for i in items.indices where ids.contains(items[i].event.id) { items[i].uploaded = true }
        journal.append(JournalRecord(acknowledged: Array(ids)))
        dirty = true; scheduleWrite()
    }
    func snapshot() -> (events: [ConnectionEvent], pending: Int, failed: Bool) {
        load(); prune(now: Date().timeIntervalSince1970)
        return (items.map(\.event), items.filter { !$0.uploaded }.count, storageFailed)
    }
    func flush() { load(); persist() }
}

@MainActor
final class ConnectionTelemetry {
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }
    private(set) var scope = ""
    private(set) var store: ConnectionEventStore?
    private var state = "unknown"
    private var reason = "startup"
    private var observing = false
    private var lastStateAt = Date.distantPast
    private var networkAvailable: Bool?
    private var heartbeatTask: Task<Void, Never>?
    var canUpload: (() -> Bool)?
    var onUpload: (() -> Void)?

    func configure(address: String, key: String, active: Bool) {
        let newScope = SHA256.hash(data: Data((address + "\n" + key).utf8)).map { String(format:"%02x", $0) }.joined()
        if newScope != scope {
            suspend(reason: "logout"); scope = newScope
            store = ConnectionEventStore(scope: newScope, directory: directory); state = "unknown"; networkAvailable = nil
            observing = false; lastStateAt = .distantPast
            emit(kind: "observer_start", state: "unknown", reason: "startup")
        }
        if active { resume() }
    }
    private func emit(kind: String, state: String = "", reason: String = "") {
        guard let store else { return }
        let event = ConnectionEvent(id: UUID().uuidString.lowercased(), at: Date().timeIntervalSince1970,
                                    layer: "phone", kind: kind, state: state, reason: reason)
        if !state.isEmpty { self.state = state; self.reason = reason; lastStateAt = Date() }
        Task { await store.append(event) }
    }
    func resume() {
        guard store != nil, !observing else { return }
        observing = true; networkAvailable = nil
        emit(kind: "observer_start", state: "unknown", reason: "foreground")
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let self, self.observing else { return }
                // A delayed heartbeat cannot extend an observation across suspension.
                if Date().timeIntervalSince(self.lastStateAt) > 90 {
                    self.emit(kind: "observer_start", state: "unknown", reason: "gap")
                } else if self.state != "online" {
                    self.emit(kind: "observation", state: self.state, reason: self.reason)
                }
                if self.canUpload?() == true { self.onUpload?() }
            }
        }
    }
    func suspend(reason: String = "background") {
        guard observing else { return }
        observing = false; heartbeatTask?.cancel(); heartbeatTask = nil
        emit(kind: "observer_stop", state: "unknown", reason: reason)
        if let store { Task { await store.flush() } }
    }
    func network(available: Bool, changed: Bool) {
        guard observing else { return }
        let previous = networkAvailable; networkAvailable = available
        if !available && previous != false { emit(kind: "network_down", state: "offline", reason: "no_network") }
        else if available && previous == false { emit(kind: "network_up") }
        else if available && changed { emit(kind: "network_change", state: "offline", reason: "network_change") }
    }
    func failed(authentication: Bool) {
        guard observing else { return }
        let next = authentication ? "unknown" : "offline"
        if state != next || (authentication && reason != "auth_failed") {
            emit(kind: authentication ? "auth_failed" : "request_failed", state: next,
                 reason: authentication ? "auth_failed" : "request_failed")
        }
    }
    func attempt() {
        guard observing else { return }
        emit(kind: "retry", state: state == "offline" ? "offline" : "", reason: state == "offline" ? reason : "")
    }
    func success() {
        guard observing else { return }
        if state != "online" { emit(kind: "connected", state: "online") }
        else if Date().timeIntervalSince(lastStateAt) >= 60 { emit(kind: "observation", state: "online") }
    }
    func disconnect() {
        suspend(reason: "logout"); store = nil; scope = ""; state = "unknown"; networkAvailable = nil
    }
}
