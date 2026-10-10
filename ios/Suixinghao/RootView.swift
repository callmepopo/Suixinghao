import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    #if DEBUG
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("--preview-settings") ? 2 : (ProcessInfo.processInfo.arguments.contains("--preview-messages") ? 1 : 0)
    #else
    @State private var selectedTab = 0
    #endif
    var body: some View {
        @Bindable var model = model
        TabView(selection: $selectedTab) {
            PhoneView().tag(0).tabItem { Label("电话", systemImage: "phone.fill") }
            MessagesView().tag(1).tabItem { Label("短信", systemImage: "message.fill") }
            SettingsView().tag(2).tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
        .tint(.teal)
        .task { await model.startup() }
        .onChange(of: phase) { _, value in
            if value == .active { Task { await model.foreground(true) } }
            else if value == .background {
                #if DEBUG
                model.externalCallRoute = "等待系统号码事件"
                #endif
                Task { await model.foreground(false) }
            }
        }
        .onChange(of: model.openSMSFromNotification) { _, open in
            if open { selectedTab = 1; model.openSMSFromNotification = false }
        }
        .onChange(of: model.externalDialNumber) { _, incoming in
            if incoming != nil { selectedTab = 0 }
        }
        .alert("随行号", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("知道了") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .overlay { if phase != .active { Color(.systemBackground).overlay(Label("随行号", systemImage: "lock.fill").font(.title)) } }
    }
}

struct PhoneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var number = ""
    @State private var phoneContacts: [PhoneContact] = []
    @State private var contactMatches: [PhoneContact] = []
    @State private var selectedContact: String?
    @State private var keyFeedback = ""
    @State private var feedbackTask: Task<Void, Never>?
    @State private var showingHistory = false
    @State private var handingOffSystemCall = false
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
    private let keyLetters = ["", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ", "", "+", ""]
    private var owned: Bool { model.ownedCallID != nil }
    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                let compact = viewport.size.height < 650 || viewport.size.width < 390
                let keySize = min(compact ? 60.0 : 72.0, max(44.0, (viewport.size.width - 76) / 3))
                ScrollView {
                    VStack(spacing: compact ? 8 : 12) {
                        HStack(spacing: 10) {
                            Text("随行号").font(.system(size: 28, weight: .bold)).lineLimit(1)
                            Spacer(minLength: 4)
                            Label(model.connectionTitle,
                                  systemImage: model.demo ? "sparkles" : "antenna.radiowaves.left.and.right")
                                .font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                                .foregroundStyle(model.statusFresh ? Color.teal : Color.secondary)
                            if !model.demo {
                                Button { Task { await model.refreshPhone() } } label: {
                                    Image(systemName: "arrow.clockwise").font(.headline).frame(width: 44, height: 44)
                                }.buttonStyle(.plain).background(Color(.secondarySystemGroupedBackground), in: Circle())
                                    .disabled(model.restoringConnection || model.callBusy).accessibilityLabel("刷新状态")
                            }
                        }.frame(height: compact ? 44 : 52)
                        if model.systemCallPreparing {
                            VStack(spacing: 10) {
                                ProgressView("正在建立随行号通话…")
                                Button("取消通话", role: .destructive) { Task { await model.hangup() } }
                                    .buttonStyle(.bordered)
                            }.padding()
                        } else if model.status?.state == "ringing" && !owned {
                            VStack(spacing: 12) {
                                Image(systemName: "phone.connection.fill").font(.largeTitle).foregroundStyle(.teal)
                                Text("模块收到来电").font(.title2.bold())
                                Text(model.callerDisplayName ?? model.status?.caller ?? "号码未知").font(.title3).textSelection(.enabled)
                                HStack {
                                    Button("拒接", role: .destructive) { Task { await model.hangup() } }.buttonStyle(.bordered)
                                    Button("接听") { Task { await model.answer() } }.buttonStyle(.borderedProminent)
                                }.disabled(model.callBusy || model.restoringConnection || !model.statusFresh || model.demo)
                            }.padding()
                        } else if model.status?.hasCall == true {
                            VStack(spacing: 10) {
                                Text(owned ? (model.dialingStage.isEmpty ? (model.status?.title ?? "通话中") : model.dialingStage) : "其他客户端正在通话").font(.title2.bold())
                                if let date = model.callStartedAt { Text(date, style: .timer).font(.title.monospacedDigit()) }
                                if owned {
                                    HStack {
                                        Button { model.toggleMute() } label: { Label(model.muted ? "取消静音" : "静音", systemImage: model.muted ? "mic.slash.fill" : "mic.fill") }
                                        Button { Task { await model.toggleSpeaker() } } label: { Label(model.speakerEnabled ? "听筒" : "扬声器", systemImage: "speaker.wave.2.fill") }
                                    }.buttonStyle(.bordered)
                                    #if DEBUG
                                    Text(model.audioDiagnostics)
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    #endif
                                    Button("挂断", role: .destructive) { Task { await model.hangup() } }.buttonStyle(.borderedProminent).disabled(model.callBusy)
                                }
                            }.padding()
                        }
                        HStack(spacing: 8) {
                            if !owned {
                                Button { showingHistory = true } label: {
                                    Image(systemName: "clock.arrow.circlepath").frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain).accessibilityLabel("通话记录")
                            }
                            Text(owned ? "通话按键" : (number.isEmpty ? "输入号码" : number))
                                .font(.system(size: number.isEmpty ? 22 : 30, weight: .medium, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            if !owned {
                                Button {
                                    number.removeLast(); selectedContact = nil; updateMatches()
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    Image(systemName: "delete.left").frame(width: 48, height: 44)
                                }
                                .buttonStyle(.plain).disabled(number.isEmpty)
                                .opacity(number.isEmpty ? 0 : 1)
                                .accessibilityLabel("删除一位")
                            }
                        }.frame(height: 44)
                            .overlay(alignment: .topLeading) {
                                if !keyFeedback.isEmpty {
                                    Text(keyFeedback).font(.caption2).foregroundStyle(.teal)
                                        .lineLimit(1).offset(y: -10)
                                        .accessibilityAddTraits(.updatesFrequently)
                                }
                            }
                        if !owned && (selectedContact != nil || !contactMatches.isEmpty) {
                            VStack(spacing: 0) {
                                if let selectedContact {
                                    HStack { Image(systemName: "person.crop.circle"); Text(selectedContact); Spacer() }
                                        .font(.subheadline).foregroundStyle(.teal).padding(.horizontal, 12).frame(height: 36)
                                } else {
                                    ForEach(contactMatches) { contact in
                                        Button {
                                            number = contact.dialableNumber
                                            selectedContact = contact.name
                                            contactMatches = []
                                        } label: {
                                            HStack {
                                                Image(systemName: "person.crop.circle").foregroundStyle(.teal)
                                                Text(contact.name).lineLimit(1)
                                                Spacer()
                                                Text(contact.number).foregroundStyle(.secondary).lineLimit(1)
                                            }.font(.subheadline).padding(.horizontal, 12).frame(height: 36)
                                        }.buttonStyle(.plain)
                                    }
                                }
                                Spacer(minLength: 0)
                            }.frame(height: selectedContact != nil ? 36 : CGFloat(contactMatches.count) * 36).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 12 : 18), count: 3), spacing: compact ? 8 : 10) {
                            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                                Button {
                                    if owned {
                                        showKeyFeedback("按键 \(key) 发送中")
                                        Task { showKeyFeedback(await model.dtmf(key) ? "按键 \(key) 已发送" : "按键未发送", haptic: false) }
                                    } else if number.count < 16 {
                                        number += key; selectedContact = nil; updateMatches()
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    }
                                } label: {
                                    VStack(spacing: 0) {
                                        Text(key).font(.system(size: 28, weight: .regular, design: .rounded))
                                        Text(keyLetters[index]).font(.system(size: 9, weight: .medium)).tracking(1)
                                    }.frame(width: keySize, height: keySize).background(Color(.secondarySystemGroupedBackground), in: Circle())
                                }.foregroundStyle(.primary)
                                    .disabled(model.callBusy || (owned && model.status?.state != "active"))
                                    .onLongPressGesture { if key == "0" && !owned && number.isEmpty { number = "+"; updateMatches() } }
                            }
                        }
                        if let hangup = model.hangupMessage { Text(hangup).font(.footnote).foregroundStyle(.orange) }
                        if !model.dialingStage.isEmpty && model.status?.hasCall != true { Text(model.dialingStage).font(.footnote).foregroundStyle(.teal) }
                        Text(model.demo ? "连接自己的服务后即可使用。演示模式不会拨号。" : (model.restoringConnection ? "正在恢复电话连接，短信将在随后加载。" : "连接恢复后即可拨号，已接通的通话可以熄屏继续。"))
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        #if DEBUG
                        Text(model.externalCallRoute).font(.caption2).foregroundStyle(.secondary)
                        #endif
                        if model.status?.recording == true { Label("服务端已开启通话录音", systemImage: "record.circle").font(.footnote).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if model.status?.hasCall != true && !model.systemCallPreparing {
                        dialActions
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(Color(.systemGroupedBackground))
                    }
                }
            }.background(Color(.systemGroupedBackground)).toolbar(.hidden, for: .navigationBar)
                .task { await loadContactsIfAllowed() }
                .onAppear {
                    receiveExternalNumber(model.externalDialNumber)
                    Task { await loadContactsIfAllowed() }
                }
                .onChange(of: phase) { _, value in
                    if value == .active {
                        if !owned && model.status?.hasCall != true && !model.systemCallPreparing && model.externalDialNumber == nil {
                            number = ""
                            selectedContact = nil
                            contactMatches = []
                            keyFeedback = ""
                            feedbackTask?.cancel()
                        }
                        Task { await loadContactsIfAllowed() }
                    }
                }
                .onChange(of: model.externalDialNumber) { _, incoming in
                    receiveExternalNumber(incoming)
                }
                .sheet(isPresented: $showingHistory) {
                    CallHistoryView { chosen in
                        number = chosen
                        selectedContact = nil
                        updateMatches()
                        showingHistory = false
                    }
                }
        }
    }
    private var dialActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button { Task { await dialWithSystem() } } label: {
                Label("系统拨号", systemImage: "iphone")
                    .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 54)
            }.buttonStyle(.plain)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                .disabled(model.callBusy || handingOffSystemCall || number.isEmpty)
            Button { Task { await model.dial(number) } } label: {
                Label("随行号拨号", systemImage: "phone.fill")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }.buttonStyle(.plain).foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
                .disabled(model.demo || model.restoringConnection || model.callBusy || handingOffSystemCall || number.isEmpty || !model.statusFresh)
                .opacity(model.demo || model.restoringConnection || model.callBusy || number.isEmpty || !model.statusFresh ? 0.45 : 1)
        }
    }
    @MainActor private func dialWithSystem() async {
        guard !handingOffSystemCall, !model.callBusy, !model.systemCallPreparing, model.status?.hasCall != true else { return }
        do {
            let url = try API.cellularCallURL(number)
            handingOffSystemCall = true
            defer { handingOffSystemCall = false }
            let opened = await UIApplication.shared.open(url, options: [:])
            if !opened { model.notice = "无法打开系统拨号，请检查手机蜂窝通话是否可用。" }
        } catch { model.notice = error.localizedDescription }
    }
    private func updateMatches() {
        guard selectedContact == nil else { contactMatches = []; return }
        contactMatches = Array(phoneContacts.lazy.filter { $0.matchesDialDigits(number) }.prefix(3))
    }
    private func receiveExternalNumber(_ incoming: String?) {
        guard let incoming else { return }
        number = incoming
        selectedContact = nil
        updateMatches()
        model.externalDialNumber = nil
        #if DEBUG
        model.externalCallRoute = "系统号码已填入拨号页"
        print("Suixinghao incoming number filled in dialer")
        #endif
    }
    private func showKeyFeedback(_ message: String, haptic: Bool = true) {
        if haptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        keyFeedback = message
        feedbackTask?.cancel()
        feedbackTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if !Task.isCancelled { keyFeedback = "" }
        }
    }
    private func loadContactsIfAllowed() async {
        guard PhoneContacts.canRead else { phoneContacts = []; contactMatches = []; return }
        phoneContacts = (try? await PhoneContacts.load()) ?? []
        updateMatches()
    }
}

struct CallHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selectNumber: (String) -> Void
    @State private var confirmingClear = false
    @State private var names: [String: String] = [:]
    private func normalized(_ raw: String) -> String {
        var digits = raw.filter(\.isNumber)
        if digits.hasPrefix("0086") { digits = String(digits.dropFirst(4)) }
        else if digits.hasPrefix("86") && digits.count == 13 { digits = String(digits.dropFirst(2)) }
        return digits
    }
    var body: some View {
        NavigationStack {
            List {
                if model.callHistory.isEmpty {
                    ContentUnavailableView("暂无通话记录", systemImage: "clock", description: Text("此手机使用随行号产生的通话会显示在这里。"))
                }
                ForEach(model.callHistory) { record in
                    Button { selectNumber(record.number) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: record.direction == "来电" ? "phone.arrow.down.left" : "phone.arrow.up.right")
                                .foregroundStyle(record.result == "未接来电" ? .red : .teal)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(names[normalized(record.number)] ?? record.number)
                                    .font(.headline).foregroundStyle(.primary)
                                if names[normalized(record.number)] != nil {
                                    Text(record.number).font(.caption).foregroundStyle(.secondary)
                                }
                                Text("\(record.direction) · \(record.result)" + (record.answeredAt == nil ? "" : " · \(Int(record.duration)) 秒"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(record.startedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("通话记录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) { confirmingClear = true }
                        .disabled(model.callHistory.isEmpty)
                }
            }
            .confirmationDialog("清空此服务器在本机的通话记录？", isPresented: $confirmingClear) {
                Button("清空通话记录", role: .destructive) { model.clearCallHistory() }
            }
            .task {
                guard PhoneContacts.canRead, let contacts = try? await PhoneContacts.load() else { return }
                names = Dictionary(contacts.map { (normalized($0.number), $0.name) }, uniquingKeysWith: { first, _ in first })
            }
        }
    }
}

struct MessagesView: View {
    @Environment(AppModel.self) private var model
    @State private var composing = false
    @State private var deletingContact: SMSContact?
    @State private var deleting = false
    @State private var deletionError: String?
    var body: some View {
        NavigationStack {
            List {
                if model.demo { Section { Label("以下为演示数据，不会发送短信", systemImage: "sparkles").font(.footnote).foregroundStyle(.secondary) } }
                Section {
                    if model.visibleContacts.isEmpty && (model.restoringConnection || model.loadingContent) { ProgressView(model.restoringConnection ? "正在恢复连接" : "正在加载短信") }
                    else if model.visibleContacts.isEmpty { ContentUnavailableView("暂无短信", systemImage: "message", description: Text("下拉刷新服务器中的会话。")) }
                    ForEach(model.visibleContacts) { contact in
                        NavigationLink { ThreadView(contact: contact) } label: {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "message.fill").foregroundStyle(.teal).frame(width: 42, height: 42).background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { Text(contact.peer).font(.headline); Spacer(); if contact.unread_count > 0 { Circle().fill(.teal).frame(width: 8, height: 8) } }
                                    Text(contact.last_content).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.padding(.vertical, 8)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("删除会话", role: .destructive) { deletingContact = contact }
                                .disabled(model.demo || !model.connected || deleting)
                        }
                    }
                } footer: { Text("模块 SIM 的短信 · 与 iPhone 系统信息独立") }
            }.navigationTitle("短信").refreshable { await model.refresh() }
                .toolbar { Button { composing = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("新建短信").disabled(model.demo || model.busy) }
                .sheet(isPresented: $composing) { ComposeView() }
                .confirmationDialog("删除整个短信会话？", isPresented: Binding(get: { deletingContact != nil }, set: { if !$0 { deletingContact = nil } }), titleVisibility: .visible) {
                    if let contact = deletingContact {
                        Button("删除整个会话", role: .destructive) {
                            Task {
                                deleting = true
                                defer { deleting = false }
                                do { try await model.deleteSMS(contact: contact) }
                                catch { deletionError = error.localizedDescription }
                            }
                        }
                    }
                } message: { Text("将删除服务器中该 SIM 与对方的全部历史短信（含未显示的消息），其他设备也会同步。无法撤销。") }
                .alert("删除未完成", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
                    Button("好", role: .cancel) { deletionError = nil }
                } message: { Text(deletionError ?? "") }
        }
    }
}

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let contact: SMSContact
    @State private var messages: [SMSMessage] = []
    @State private var error: String?
    @State private var loading = true
    @State private var draft = ""
    @State private var sending = false
    @State private var replyStatus = ""
    @State private var deletingMessage: SMSMessage?
    @State private var deleting = false
    @State private var deletionError: String?
    private var replyDevice: String? {
        guard (try? API.normalizedSMSReplyNumber(contact.peer)) != nil else { return nil }
        guard let id = contact.device_id, model.devices.contains(where: { $0.id == id }) else { return nil }
        return id
    }
    var body: some View {
        ScrollViewReader { proxy in
            List {
                if loading { ProgressView("读取短信…") }
                if let error { Text(error).foregroundStyle(.red); Button("重试") { Task { await load() } } }
                ForEach(messages) { message in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message.content).textSelection(.enabled)
                        Text("\(message.type == 1 ? "收到" : "发出") · \(message.timestamp)").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8).id(message.id)
                        .swipeActions(allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { deletingMessage = message }
                                .disabled(model.demo || !model.connected || deleting || sending || loading)
                        }
                }
                if !loading && error == nil { Text("显示最近 100 条；打开后同步已读状态。").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle(contact.peer).navigationBarTitleDisplayMode(.inline).task { await load() }
                .confirmationDialog("删除这条短信？", isPresented: Binding(get: { deletingMessage != nil }, set: { if !$0 { deletingMessage = nil } }), titleVisibility: .visible) {
                    if let message = deletingMessage {
                        Button("删除短信", role: .destructive) {
                            Task {
                                deleting = true
                                defer { deleting = false }
                                do {
                                    try await model.deleteSMS(contact: contact, messageID: message.id)
                                    messages.removeAll { $0.id == message.id }
                                    await load()
                                } catch { deletionError = error.localizedDescription }
                            }
                        }
                    }
                } message: { Text("将删除服务器中的这条历史短信，其他设备也会同步。无法撤销。") }
                .alert("删除未完成", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
                    Button("好", role: .cancel) { deletionError = nil }
                } message: { Text(deletionError ?? "") }
                .onChange(of: loading) { _, reading in
                    guard !reading, let latestID = messages.last?.id else { return }
                    // Run after the asynchronously loaded rows enter the List's layout.
                    DispatchQueue.main.async { proxy.scrollTo(latestID, anchor: .bottom) }
                }
                .safeAreaInset(edge: .bottom) {
                    if !model.demo {
                        VStack(alignment: .leading, spacing: 4) {
                            if replyDevice == nil {
                                Text("当前会话无法直接回复，请确认发送号码和在线 SIM。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else if !replyStatus.isEmpty {
                                Text(replyStatus).font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack(alignment: .bottom, spacing: 10) {
                                TextField("回复短信", text: $draft, axis: .vertical)
                                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
                                    .disabled(replyDevice == nil || sending || deleting)
                                Button { Task { await reply() } } label: {
                                    if sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                                }
                                .disabled(replyDevice == nil || sending || deleting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityLabel("发送回复")
                            }
                        }
                        .padding(.horizontal).padding(.vertical, 8)
                        .background(.regularMaterial)
                    }
                }
        }
    }
    private func reply() async {
        guard let device = replyDevice else { return }
        replyStatus = ""
        sending = true
        let text = draft
        if await model.send(number: contact.peer, message: text, device: device, showNotice: false, allowShortCode: true) {
            draft = ""
            replyStatus = "已提交发送，是否送达以对方收到为准。"
            await load()
        }
        sending = false
    }
    private func load() async {
        loading = true; error = nil
        do {
            messages = try await model.messages(contact)
            try await model.markRead(contact, throughID: messages.map(\.id).max())
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var message = ""
    @State private var device = ""
    @State private var confirming = false
    var body: some View {
        NavigationStack {
            Form {
                Section("收件人") { TextField("国内手机号或 + 国际号码", text: $number).keyboardType(.phonePad) }
                Section("发送设备") {
                    Picker("模块", selection: $device) {
                        Text("请选择").tag("")
                        ForEach(model.devices) { item in Text(item.name ?? item.id).tag(item.id) }
                    }
                    if model.devices.isEmpty { Text("没有可用设备，请返回刷新。 ").foregroundStyle(.secondary) }
                }
                Section("正文") { TextEditor(text: $message).frame(minHeight: 160) }
                Section { Text("发送会使用模块 SIM，可能产生运营商短信费用。11 位国内手机号会自动补 +86。接口成功不代表已送达。").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("新短信").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(model.busy) }
                    ToolbarItem(placement: .confirmationAction) { Button(model.busy ? "发送中…" : "发送") { confirming = true }.disabled(model.busy || device.isEmpty || number.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
                .confirmationDialog("发送到 \(number)？", isPresented: $confirming, titleVisibility: .visible) {
                    Button("发送短信") { Task { if await model.send(number: number, message: message, device: device) { dismiss() } } }
                }
                .interactiveDismissDisabled(model.busy)
                .onAppear { if model.devices.count == 1 { device = model.devices[0].id } }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @AppStorage("serverAddress") private var address = ""
    @State private var key = ""
    @State private var contactsPermission = PhoneContacts.permissionDescription
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.connected {
                        LabeledContent("服务地址", value: model.endpoint).font(.footnote)
                        Button("断开", role: .destructive) { Task { await model.logout() } }
                            .disabled(model.busy || model.callBusy || model.restoringConnection)
                    } else {
                        TextField("https://服务器:端口", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("鉴权 Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { Task { await model.connect(address: address, key: key) } } label: {
                            HStack { Text("连接并验证"); Spacer(); if model.busy || model.restoringConnection { ProgressView() } else { Image(systemName: "arrow.right") } }
                        }.disabled(model.busy || model.restoringConnection || key.isEmpty || address.isEmpty)

                    }
                    Button("获取电话授权（麦克风）") { Task { await model.authorizeMicrophone() } }
                    Button("开启或重试短信提醒") { Task { await model.enableSMSNotifications() } }.disabled(!model.connected)
                Group {
                    LabeledContent("访问权限", value: contactsPermission)
                    Button(contactsPermission == "未授权" ? "前往系统设置授权" : "获取或刷新通讯录权限") {
                        Task {
                            if contactsPermission == "未授权" {
                                if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
                            } else {
                                _ = try? await PhoneContacts.load()
                                contactsPermission = PhoneContacts.permissionDescription
                            }
                        }
                    }
                    Text("授权后，拨号键盘输入数字会匹配联系人姓名拼音首字母和电话号码；来电也会在本机匹配姓名。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                } header: { Text("连接配置与电话授权") } footer: {
                    Text("填写服务 HTTPS 根地址和独立 App Key。断开后保留最近一次地址和 Key，点击连接并验证即可恢复。电话授权用于通话麦克风和锁屏接听。")
                }
                Section("当前状态") {
                    Label(model.connectionTitle, systemImage: model.connected ? "checkmark.circle.fill" : "link").foregroundStyle(.teal)
                    if !model.connected { Text(model.manuallyDisconnected ? "已断开，连接配置已保留。" : model.connectionMessage).font(.footnote).foregroundStyle(.secondary) }
                    LabeledContent("电话服务", value: model.connected ? (model.status?.title ?? "待刷新") : "未连接")
                    LabeledContent("录音策略", value: model.status?.recording.map { $0 ? "开启" : "关闭" } ?? "未知")
                    LabeledContent("短信提醒", value: model.smsNotificationState)
                    if model.connected {
                        LabeledContent("手机 → 服务", value: model.statusFresh ? "可达" : model.connectionMessage)
                        if let rtt = model.serviceRTT { LabeledContent("服务响应耗时", value: "\(rtt) ms") }
                        if let checked = model.lastServiceCheck { LabeledContent("最近服务检测") { Text(checked, style: .time) } }
                        if let d = model.diagnostics {
                            LabeledContent("服务 → 模块", value: d.module_available ? "可达 · \(d.module_rtt_ms) ms" : "暂不可达")
                            LabeledContent("SIM", value: d.sim_status)
                            LabeledContent("SIM 网络", value: d.network_status)
                            if let signal = d.signal_rssi { LabeledContent("信号", value: "\(signal)/31") }
                            if let date = d.network_checked_at { Text("网络检测：" + date).font(.caption).foregroundStyle(.secondary) }
                            LabeledContent("服务版本", value: d.server_version)
                            Text("网络注册成功仍需实际验证语音可用；通话期间显示最近的网络检测结果。").font(.footnote).foregroundStyle(.secondary)
                        }
                        if let message = model.diagnosticMessage { Text(message).foregroundStyle(.secondary) }

                        Button("刷新连接诊断") { model.refreshDiagnostics() }
                        Button("刷新状态和短信") { Task { await model.refresh() } }.disabled(model.busy)
                        #if DEBUG
                        Button("检查扬声器声音（不拨号）") { Task { await model.testSpeakerWithoutCall() } }
                            .disabled(model.busy || model.callBusy || model.ownedCallID != nil)
                        #endif
                    }
                }
                Section {
                    NavigationLink { ConnectionHistoryView() } label: { Label("连接历史", systemImage: "clock.arrow.circlepath") }
                        .disabled(!model.connected)
                } header: { Text("历史状态") } footer: {
                    Text("查看最近 24 小时在线率、检测覆盖率及断线重连记录。连接服务后可查看。")
                }
            }.navigationTitle("设置")
                .toolbar { NavigationLink("关于") { Form {
                Section("数据与推送") {
                    Text("通讯录只在本机匹配。电话和短信连接你配置的服务器；录音是否开启由该服务器决定，请在通话前告知参与者。")
                    Text("系统来电与短信提醒由 Apple 投递。若服务器启用官方推送中继，发布者会临时处理设备推送标识和随机来电标识，不接收电话音频、号码或短信正文。")
                }
                .font(.footnote)
                Section("关于随行号") {
                    LabeledContent("App版本", value: AppVersion.current)
                    LabeledContent("构建号", value: AppVersion.build)
                    LabeledContent("构建渠道", value: AppVersion.channel)
                    LabeledContent("源码提交", value: AppSource.current.commit ?? "未关联")
                        .textSelection(.enabled)
                    if let url = AppSource.current.url {
                        Link("查看对应源码", destination: url)
                    } else {
                        LabeledContent("源码链接", value: "未关联")
                    }
                    Text("从 App Store 获取的版本通过 App Store 更新。自行构建版本由构建者维护。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                    Section("鉴权说明") { Text("在服务网页的「App 接入」中使用账号密码登录，创建独立 Key。每台手机建议使用不同 Key；撤销后无法继续访问。") }
                    Section { Text("服务地址和 Key 仅保存在本机钥匙串；短信正文仅保留在内存中。") }
                }.navigationTitle("关于随行号") } }
                .task { fillSavedConnection(); model.refreshDiagnostics() }
                .onChange(of: model.connected) { _, connected in if !connected { fillSavedConnection() } else { key = "" } }
                .onChange(of: phase) { _, value in if value == .active { contactsPermission = PhoneContacts.permissionDescription } }
        }
    }
    private func fillSavedConnection() {
        guard !model.connected, let saved = ConnectionStore.load() else { return }
        address = saved.address; key = saved.key
    }
}
