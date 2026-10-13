import SwiftUI

struct ConnectionHistoryView: View {
    @Environment(AppModel.self) private var model
    private var summaries: [ConnectionSummary] {
        var result = model.connectionHistory?.summaries.filter { $0.layer != "phone" } ?? []
        if let local = model.localConnectionSummary { result.insert(local, at: 0) }
        return result
    }
    private var outages: [ConnectionOutage] { Array((model.connectionHistory?.outages ?? []).reversed()) }
    private var reconnectTimes: [Double] {
        outages.compactMap {
            guard !$0.incomplete, let end = $0.end, let network = $0.network_restored,
                  end >= network, end >= Date().timeIntervalSince1970-86400 else { return nil }
            return end-network
        }
    }
    var body: some View {
        List {
            Section {
                Text("手机检测主要在 App 前台或通话期间进行。普通后台暂停与采样过期记为未检测，不代表服务离线。覆盖率是最近 24 小时有效检测时长的占比，不能用于判断锁屏推送是否可用。").font(.footnote).foregroundStyle(.secondary)
                LabeledContent("本次连续有效检测", value: model.currentObservationSeconds.map(ConnectionHistory.duration) ?? "已暂停或等待新检测")
                Text("本次检测恢复后重新计时；下方最近 24 小时累计记录保留。数据在进入页面或刷新时更新。").font(.caption).foregroundStyle(.secondary)
                if !model.connectionHistoryMessage.isEmpty {
                    Text(model.connectionHistoryMessage).font(.footnote)
                }
                if let history = model.connectionHistory {
                    LabeledContent("远端汇总更新") { Text(Date(timeIntervalSince1970: history.generated_at), style: .time) }
                }
            }
            ForEach(summaries) { summary in
                Section(summary.title + " · 最近 24 小时") {
                    LabeledContent("检测期间在线率", value: summary.rateText)
                    LabeledContent("检测覆盖率", value: summary.coverageText)
                    LabeledContent("最近 24 小时有效检测", value: ConnectionHistory.duration(summary.online_seconds + summary.offline_seconds))
                    LabeledContent("检测到的在线时长", value: ConnectionHistory.duration(summary.online_seconds))
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            Color.teal.frame(width: geometry.size.width * summary.online_seconds / 86400)
                            Color.orange.frame(width: geometry.size.width * summary.offline_seconds / 86400)
                            Color.gray.opacity(0.2)
                        }
                    }.frame(height: 8).clipShape(Capsule()).accessibilityLabel("在线 \(summary.rateText)，覆盖 \(summary.coverageText)")
                    LabeledContent("检测到的离线时长", value: ConnectionHistory.duration(summary.offline_seconds))
                    LabeledContent("未检测时长", value: ConnectionHistory.duration(summary.unknown_seconds))
                    LabeledContent("离线段数", value: "\(summary.interruptions)")
                }
            }
            Section("网络恢复后的重连 · 最近 24 小时") {
                if let longest = reconnectTimes.max() {
                    LabeledContent("完整记录", value: "\(reconnectTimes.count) 次")
                    LabeledContent("平均耗时", value: ConnectionHistory.duration(reconnectTimes.reduce(0,+)/Double(reconnectTimes.count)))
                    LabeledContent("最长耗时", value: ConnectionHistory.duration(longest))
                } else { Text("暂无完整的网络恢复与连接成功记录").foregroundStyle(.secondary) }
            }
            Section {
                if outages.isEmpty { Text("暂无已同步的断线记录").foregroundStyle(.secondary) }
                ForEach(outages) { outage in
                    NavigationLink {
                        Form {
                            Section("断线过程") {
                                LabeledContent("发现断线") { Text(outage.date, format: .dateTime.month().day().hour().minute().second()) }
                                LabeledContent("触发类型", value: ["no_network":"手机无网络", "request_failed":"服务请求失败", "network_change":"手机网络切换"][outage.reason] ?? "原因未确定")
                                if let network = outage.network_restored {
                                    LabeledContent("检测到网络恢复") { Text(Date(timeIntervalSince1970: network), style: .time) }
                                }
                                if let end = outage.end {
                                    LabeledContent("连接服务成功") { Text(Date(timeIntervalSince1970: end), style: .time) }
                                }
                                LabeledContent("中断时长", value: outage.durationText)
                                LabeledContent("网络恢复后重连", value: outage.reconnectText)
                                LabeledContent("恢复尝试次数", value: "\(outage.attempts)")
                            }
                            Text("时间是 App 检测到变化的时间。检测中断的记录不推算完整离线时长。").font(.footnote).foregroundStyle(.secondary)
                        }.navigationTitle("断线详情")
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(outage.date, format: .dateTime.month().day().hour().minute().second())
                            Text(outage.durationText + " · 尝试 \(outage.attempts) 次").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("断线记录") } footer: { Text("保留 30 天，展示最近 100 条已同步记录。离线期间可先查看下方本机事件。") }
            Section("手机本机事件") {
                if model.localConnectionEvents.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
                ForEach(model.localConnectionEvents) { event in eventRow(event) }
            }
            Section("远端模块事件") {
                let events = model.connectionHistory?.events.filter { $0.layer != "phone" } ?? []
                if events.isEmpty { Text("暂无已同步记录").foregroundStyle(.secondary) }
                ForEach(events) { event in eventRow(event) }
            }
            Section {
                Text("只记录状态、时间、重试次数及模块信号采样；不记录号码、短信或凭据。手机每分钟最多补传 100 条，通话期间暂停补传；事件列表展示最近 200 条状态变化。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("连接历史")
        .toolbar {
            Button { Task { await model.refreshConnectionHistory() } } label: {
                if model.loadingConnectionHistory { ProgressView() } else { Image(systemName: "arrow.clockwise") }
            }.disabled(model.loadingConnectionHistory).accessibilityLabel("刷新连接历史")
        }
        .task { await model.refreshConnectionHistory() }
        .refreshable { await model.refreshConnectionHistory() }
    }
    private func eventRow(_ event: ConnectionEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title)
            HStack {
                Text(event.date, format: .dateTime.month().day().hour().minute().second())
                if let rssi = event.rssi { Text("信号 \(rssi)/31") }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}
