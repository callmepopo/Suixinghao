import SwiftUI
import UIKit

/// Dialer tab. Follows the native Phone keypad: status, number, three fixed contact-match
/// rows, keypad, then "系统拨出 / 随行号拨出 / 删除". Content is a single column capped at
/// iPhone width, so the iPhone Duo inner screen shows the same keypad centered, not stretched.
/// Only the presentation changed; dialing, DTMF, hang-up and audio rules live in AppModel.
struct PhoneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var dialInput = DialerInput()
    private var number: String {
        get { dialInput.number }
        nonmutating set { dialInput.number = newValue }
    }
    @State private var phoneContacts: [PhoneContact] = []
    @State private var contactMatches: [PhoneContact] = []
    @State private var selectedContact: String?
    @State private var showingHistory = false
    @State private var handingOffSystemCall = false
    @State private var lastDialed: String?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    #if DEBUG
    private let previewCall: Int? = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--preview-call=") })
        .flatMap { Int($0.split(separator: "=").last ?? "") }
    #else
    private let previewCall: Int? = nil
    #endif
    private var owned: Bool { model.ownedCallID != nil }
    private var showCall: Bool { previewCall != nil || model.systemCallPreparing || owned }
    private var showIncoming: Bool { !showCall && model.status?.state == "ringing" }

    var body: some View {
        NavigationStack {
            Group {
                if showCall {
                    CallScreen(title: callTitle, preparing: model.systemCallPreparing && !owned,
                               preview: previewCall)
                } else if showIncoming {
                    IncomingScreen()
                } else {
                    dialer
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await loadContactsIfAllowed() }
        .onAppear {
            receiveExternalNumber(model.externalDialNumber)
            Task { await loadContactsIfAllowed() }
        }
        .onChange(of: phase) { _, value in
            let inputPhase: DialerInput.Phase = value == .background ? .background : (value == .active ? .active : .inactive)
            if dialInput.transition(to: inputPhase,
                                    callInProgress: owned || model.status?.hasCall == true || model.systemCallPreparing,
                                    pendingExternalNumber: model.externalDialNumber != nil) {
                selectedContact = nil
                contactMatches = []
            }
            if value == .active { Task { await loadContactsIfAllowed() } }
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

    // MARK: Dialer

    private var dialer: some View {
        GeometryReader { viewport in
            let m = DialMetrics(size: viewport.size)
            VStack(spacing: 0) {
                header.frame(height: DialMetrics.headerH)
                numberRow(m).frame(height: m.numberH)
                matches(m).frame(height: DialMetrics.rowH * 3)
                DialKeypad(size: m.key, enabled: !model.callBusy,
                           onKey: { key in
                               if dialInput.append(key) { edited() }
                           },
                           onLongZero: {
                               if dialInput.longPressZero() { edited() }
                           })
                    .padding(.top, m.key * 0.16)
                actionRow(m).padding(.top, m.key * 0.2)
                notes.frame(height: DialMetrics.notesH, alignment: .top).padding(.top, 6)
                Spacer(minLength: 0)
            }
            .frame(width: m.width)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(.systemBackground))
        #if DEBUG
        .onGeometryChange(for: String.self) { proxy in
            "size=\(proxy.size) safe=\(proxy.safeAreaInsets)"
        } action: { value in
            let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            print("SXH-GEO dialer \(value) window=\(window?.bounds.size ?? .zero) windowSafe=\(window?.safeAreaInsets ?? .zero)")
        }
        #endif
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button { showingHistory = true } label: {
                Image(systemName: "clock.arrow.circlepath").font(.body).frame(width: 44, height: 36)
            }.buttonStyle(.plain).foregroundStyle(.teal).accessibilityLabel("通话记录")
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Text("随行号").fontWeight(.semibold)
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText).foregroundStyle(statusColor)
            }
            .font(.footnote).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button { Task { await model.refreshPhone() } } label: {
                Image(systemName: "arrow.clockwise").font(.body).frame(width: 44, height: 36)
            }.buttonStyle(.plain).foregroundStyle(.teal)
                .disabled(model.demo || model.restoringConnection || model.callBusy)
                .opacity(model.demo ? 0 : 1)
                .accessibilityLabel("刷新状态")
        }
    }
    private var statusText: String {
        let title = model.connectionTitle
        return title.hasPrefix("已连接 · ") ? String(title.dropFirst(6)) : title
    }
    private var statusColor: Color {
        if model.connected && model.statusFresh && !model.restoringConnection && !model.demo { return .green }
        if model.restoringConnection || (!model.demo && !model.manuallyDisconnected) { return .orange }
        return .secondary
    }

    private func numberRow(_ m: DialMetrics) -> some View {
        NumberDisplay(number: number, shown: DialerInput.display(number), fontSize: m.numberFont) { pasted in
            guard let cleaned = DialerInput.sanitizedPaste(pasted) else {
                showToast("剪贴板里不是电话号码")
                return
            }
            number = cleaned
            edited()
        }
        .padding(.horizontal, 8)
    }

    private func matches(_ m: DialMetrics) -> some View {
        VStack(spacing: 0) {
            if let selectedContact {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill").foregroundStyle(.teal)
                    Text(selectedContact).lineLimit(1)
                    Spacer()
                }
                .font(.subheadline).foregroundStyle(.teal)
                .padding(.horizontal, 12).frame(height: DialMetrics.rowH)
            } else {
                ForEach(Array(contactMatches.enumerated()), id: \.element.id) { index, contact in
                    Button {
                        number = contact.dialableNumber
                        selectedContact = contact.name
                        contactMatches = []
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle").foregroundStyle(.teal)
                            Text(contact.name).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(contact.number).foregroundStyle(.teal).lineLimit(1)
                        }
                        .font(.subheadline).padding(.horizontal, 12)
                        .frame(height: DialMetrics.rowH).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if index < contactMatches.count - 1 { Divider().padding(.leading, 12) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func actionRow(_ m: DialMetrics) -> some View {
        let gap = m.key * 0.36
        let dialOff = model.demo || model.restoringConnection || model.callBusy || handingOffSystemCall
            || number.isEmpty || !model.statusFresh || model.status?.hasCall == true
        let systemOff = model.callBusy || handingOffSystemCall || number.isEmpty || model.status?.hasCall == true
        return HStack(alignment: .bottom, spacing: gap) {
            Button { Task { await dialWithSystem() } } label: {
                VStack(spacing: 5) {
                    Image(systemName: "iphone")
                        .font(.system(size: m.key * 0.3, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: m.key * 0.78, height: m.key * 0.78)
                        .background(Circle().fill(Color(.systemGray5)))
                    Text("系统拨出").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                .frame(width: m.key).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(systemOff).opacity(systemOff ? 0.4 : 1)
            Button {
                lastDialed = number
                Task { await model.dial(number) }
            } label: {
                RoundCallButton(title: "随行号拨出", color: .green, size: m.key, labelColor: .secondary)
                    .frame(width: m.key)
            }
            .buttonStyle(.plain).disabled(dialOff).opacity(dialOff ? 0.45 : 1)
            DeleteKey(size: m.key, visible: !number.isEmpty,
                      onDelete: {
                          guard dialInput.deleteLast() else { return false }
                          edited()
                          return true
                      },
                      onClear: { number = ""; edited() })
                .padding(.bottom, 20)
        }
    }

    @ViewBuilder private var notes: some View {
        VStack(spacing: 2) {
            Group {
                if let toast {
                    Text(toast).foregroundStyle(.orange)
                } else if let hangup = model.hangupMessage {
                    Text(hangup).foregroundStyle(.orange)
                } else if !model.dialingStage.isEmpty {
                    Text(model.dialingStage).foregroundStyle(.teal)
                } else if model.status?.hasCall == true {
                    HStack(spacing: 6) {
                        Text("其他客户端正在通话")
                        if let date = model.callStartedAt { Text(date, style: .timer).monospacedDigit() }
                    }.foregroundStyle(.orange)
                } else {
                    Text(model.demo ? "连接自己的服务后即可使用。演示模式不会拨号。" : (model.restoringConnection ? "正在恢复电话连接，短信将在随后加载。" : "连接恢复后即可拨号，已接通的通话可以熄屏继续。"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote).lineLimit(1).minimumScaleFactor(0.7)
            #if DEBUG
            Text(model.externalCallRoute).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            #endif
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 8)
    }

    // MARK: Actions

    private func edited() {
        selectedContact = nil
        updateMatches()
    }
    private var callTitle: String {
        if let previewCall { return previewCall > 0 ? "布局测试" : "" }
        let dialed = model.callHistory.first(where: { $0.id == model.ownedCallID })?.number ?? lastDialed
        guard let dialed, !dialed.isEmpty else { return "随行号通话" }
        if let contact = phoneContacts.first(where: { DialerInput.sameNumber($0.number, dialed) }) {
            return contact.name
        }
        return DialerInput.display(dialed)
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
    private func showToast(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toast = nil }
        }
    }
    private func loadContactsIfAllowed() async {
        #if DEBUG
        // Synthetic layout fixtures; never read contacts or connect to a service.
        if let fixture = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--preview-dialer=") }),
           let count = Int(fixture.split(separator: "=").last ?? ""), (0...4).contains(count) {
            number = count == 0 ? "" : "2"
            selectedContact = count == 4 ? "布局测试联系人" : nil
            contactMatches = (0..<min(count, 3)).map {
                PhoneContact(id: "layout-\($0)", name: "布局测试\($0 + 1)", number: "0000000000", dialInitials: "2", dialFullName: "2")
            }
            if selectedContact != nil { contactMatches = [] }
            return
        }
        #endif
        guard PhoneContacts.canRead else { phoneContacts = []; contactMatches = []; return }
        phoneContacts = (try? await PhoneContacts.load()) ?? []
        updateMatches()
    }
}

/// Sizes for the dialer, derived from the space actually given (outer / inner Duo screen,
/// iPhone sizes). Recomputed on every size change, so folding / unfolding relays out.
struct DialMetrics {
    static let maxWidth: CGFloat = 393
    static let headerH: CGFloat = 40
    static let rowH: CGFloat = 36
    static let notesH: CGFloat = 34
    let width: CGFloat
    let key: CGFloat
    let numberH: CGFloat
    let numberFont: CGFloat

    init(size: CGSize) {
        width = max(0, min(size.width, Self.maxWidth) - 24)
        numberH = size.height < 700 ? 48 : 56
        numberFont = size.height < 700 ? 36 : 42
        let fixed = Self.headerH + numberH + Self.rowH * 3 + Self.notesH + 6 + 20 + 12
        // keypad 4.54k, gap above keypad 0.16k, gap above actions 0.2k, green button k.
        let byHeight = (size.height - fixed) / (4.54 + 0.16 + 0.2 + 1)
        let byWidth = width / 3.72
        key = max(50, min(80, byHeight, byWidth))
    }
}

// MARK: Call screens

/// Dark in-call screen in the native layout. "结束" is anchored to the bottom, so it stays
/// at the same place while dialing, in call, and with the keypad shown or hidden.
struct CallScreen: View {
    @Environment(AppModel.self) private var model
    let title: String
    let preparing: Bool
    var preview: Int?
    @State private var showKeypad = false
    @State private var digits = ""
    @State private var feedback = ""
    @State private var feedbackTask: Task<Void, Never>?

    private var isActive: Bool { preview != nil || model.status?.state == "active" }
    private var mediaReady: Bool { preview != nil || model.mediaConnected }

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width, DialMetrics.maxWidth) - 24
            let btn = max(60, min(78, (width - 72) / 3))
            let endH = btn + 26
            let key = max(50, min(78, (geo.size.height - endH - 40 - 104 - 36) / 4.54, width / 3.72))
            let keypadW = key * 3 + key * 0.72
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    if showKeypad { digitsHeader } else { nameHeader }
                    Spacer(minLength: 8)
                    if showKeypad {
                        DialKeypad(size: key, dark: true, enabled: isActive && !model.callBusy, onKey: send)
                    } else {
                        controls(btn)
                    }
                }
                .padding(.top, 28)
                .padding(.bottom, endH + 40 + (showKeypad ? 24 : 40))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                ZStack {
                    Button { Task { await model.hangup() } } label: {
                        RoundCallButton(title: "结束", color: .red, size: btn, hangup: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(preview == nil && model.callBusy && !preparing)
                    .accessibilityLabel(preparing ? "取消通话" : "结束通话")
                    if showKeypad {
                        HStack {
                            Spacer()
                            Button("隐藏") { showKeypad = false }
                                .font(.body.weight(.semibold)).foregroundStyle(.white)
                                .frame(width: key, height: btn)
                        }
                        .frame(width: keypadW)
                        .padding(.bottom, 26)
                    }
                }
                .frame(height: endH)
                .padding(.bottom, 40)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear {
            if preview == 2 { showKeypad = true; digits = "10086 1" }
        }
    }

    private var subtitle: String {
        if preview != nil { return "" }
        if preparing { return "随行号 · " + (model.dialingStage.isEmpty ? "正在建立随行号通话…" : model.dialingStage) }
        if model.status?.state == "active" { return "" }
        if !model.dialingStage.isEmpty { return "随行号 · " + model.dialingStage }
        return "随行号 · " + (model.status?.title ?? "正在呼叫…")
    }

    private var nameHeader: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 32, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.5)
            if let date = model.callStartedAt, model.status?.state == "active" {
                Text(date, style: .timer).font(.title3.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
            } else if preview != nil {
                Text("03:27").font(.title3.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
            } else {
                Text(subtitle).font(.body).foregroundStyle(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.7)
            }
            if model.status?.recording == true || preview != nil {
                Label("服务端录音中", systemImage: "record.circle").font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
            if owned {
                Text("当前声音：" + model.audioRouteName).font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
            if let message = model.audioRouteMessage {
                Text(message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                Button("重试声音") { model.retryCallAudio() }
                    .buttonStyle(.bordered).tint(.white).disabled(model.callBusy)
            }
            #if DEBUG
            if preview == nil {
                Text(model.audioDiagnostics).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            #endif
        }
        .padding(.horizontal, 24)
    }

    private var digitsHeader: some View {
        VStack(spacing: 4) {
            Text(digits.isEmpty ? " " : digits).font(.system(size: 34, weight: .regular))
                .lineLimit(1).minimumScaleFactor(0.5).truncationMode(.head)
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                if let date = model.callStartedAt, model.status?.state == "active" {
                    Text("·"); Text(date, style: .timer).monospacedDigit()
                }
            }
            .font(.footnote).foregroundStyle(.white.opacity(0.65))
            Text(feedback.isEmpty ? " " : feedback).font(.caption2).foregroundStyle(.teal)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(.horizontal, 24)
    }

    private var owned: Bool { model.ownedCallID != nil }

    private func controls(_ size: CGFloat) -> some View {
        let audioOff = preview == nil && (!model.mediaConnected || model.callBusy)
        let speakerOn = model.selectedAudioRoute == CallAudioRoute.speaker
        return HStack(spacing: 36) {
            Menu {
                ForEach(model.audioRoutes) { route in
                    Button { model.selectAudioRoute(route.id) } label: {
                        Label(route.name, systemImage: model.selectedAudioRoute == route.id ? "checkmark" : route.symbol)
                    }
                }
            } label: {
                CallControl(title: "音频", symbol: "speaker.wave.2.fill", size: size, on: speakerOn, dimmed: audioOff)
            }
            .disabled(audioOff)
            .accessibilityLabel("声音设备")
            Button { model.toggleMute() } label: {
                CallControl(title: "静音", symbol: model.muted ? "mic.slash.fill" : "mic.fill", size: size,
                            on: model.muted, dimmed: preparing)
            }
            .buttonStyle(.plain).disabled(preparing)
            .accessibilityLabel(model.muted ? "取消静音" : "静音")
            Button { showKeypad = true } label: {
                CallControl(title: "键盘", symbol: "circle.grid.3x3.fill", size: size)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("显示键盘")
        }
    }

    private func send(_ key: String) {
        digits = String((digits + key).suffix(24))
        guard preview == nil else { return }
        showFeedback("按键 \(key) 发送中")
        Task { showFeedback(await model.dtmf(key) ? "按键 \(key) 已发送" : "按键未发送") }
    }
    private func showFeedback(_ message: String) {
        feedback = message
        feedbackTask?.cancel()
        feedbackTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { feedback = "" }
        }
    }
}

/// A call ringing on the module that this phone has not answered yet.
struct IncomingScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width, DialMetrics.maxWidth) - 24
            let btn = max(60, min(78, (width - 72) / 3))
            let off = model.callBusy || model.restoringConnection || !model.statusFresh || model.demo
            VStack(spacing: 8) {
                Text(model.callerDisplayName ?? model.status?.caller ?? "号码未知")
                    .font(.system(size: 32, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.5)
                    .textSelection(.enabled)
                Text("随行号 · 模块收到来电").font(.body).foregroundStyle(.white.opacity(0.75))
                Spacer()
                HStack {
                    Button { Task { await model.hangup() } } label: {
                        RoundCallButton(title: "拒接", color: .red, size: btn, hangup: true)
                    }.buttonStyle(.plain)
                    Spacer()
                    Button { Task { await model.answer() } } label: {
                        RoundCallButton(title: "接听", color: .green, size: btn)
                    }.buttonStyle(.plain)
                }
                .frame(width: width - 40)
                .disabled(off).opacity(off ? 0.45 : 1)
                .frame(height: btn + 26)
                .padding(.bottom, 40)
            }
            .padding(.top, 60)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }
}
