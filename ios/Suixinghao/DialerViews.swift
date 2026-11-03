import SwiftUI
import UIKit

// Native-style dialer pieces shared by the idle keypad and the in-call keypad.

let dialKeys: [(String, String)] = [("1", ""), ("2", "ABC"), ("3", "DEF"), ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
                                    ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"), ("*", ""), ("0", "+"), ("#", "")]

/// One round keypad key. Like the native keypad, a key enters on touch-down. A key with
/// `onLongPress` (the 0 key) enters on release instead, or runs `onLongPress` after a
/// 0.5 s hold, so one press never produces two characters.
struct DialKey: View {
    let digit: String
    let letters: String
    let size: CGFloat
    var dark = false
    var enabled = true
    let onTap: () -> Void
    var onLongPress: (() -> Void)?
    @State private var pressed = false
    @State private var longFired = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Text(digit).font(.system(size: size * 0.46, weight: .regular))
            Text(letters).font(.system(size: max(9, size * 0.13), weight: .bold)).tracking(2)
                .frame(height: size * 0.16)
        }
        .foregroundStyle(dark ? Color.white : Color.primary)
        .frame(width: size, height: size)
        .background(Circle().fill(fill))
        .contentShape(Circle())
        .opacity(enabled ? 1 : 0.4)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in begin() }
            .onEnded { _ in end() })
        .onDisappear { holdTask?.cancel(); pressed = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(digit)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { onTap() } }
        .accessibilityAction(named: "输入加号") { if enabled, let onLongPress { onLongPress() } }
    }
    private var fill: Color {
        if dark { return Color.white.opacity(pressed ? 0.45 : 0.18) }
        return pressed ? Color(.systemGray3) : Color(.systemGray5)
    }
    private func begin() {
        guard enabled, !pressed else { return }
        pressed = true
        guard let onLongPress else { fire(onTap); return }
        longFired = false
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, pressed else { return }
            longFired = true
            fire(onLongPress)
        }
    }
    private func end() {
        guard pressed else { return }
        pressed = false
        holdTask?.cancel(); holdTask = nil
        if onLongPress != nil, !longFired, enabled { fire(onTap) }
    }
    private func fire(_ action: () -> Void) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        action()
    }
}

struct DialKeypad: View {
    let size: CGFloat
    var dark = false
    var enabled = true
    let onKey: (String) -> Void
    var onLongZero: (() -> Void)?

    var body: some View {
        let gapX = size * 0.36, gapY = size * 0.18
        Grid(horizontalSpacing: gapX, verticalSpacing: gapY) {
            ForEach(0..<4, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let (digit, letters) = dialKeys[row * 3 + column]
                        DialKey(digit: digit, letters: letters, size: size, dark: dark, enabled: enabled,
                                onTap: { onKey(digit) },
                                onLongPress: digit == "0" ? onLongZero : nil)
                    }
                }
            }
        }
    }
    static func height(for size: CGFloat) -> CGFloat { size * 4 + size * 0.18 * 3 }
}

/// Delete key: one character per tap; holding repeats, speeding up, and stops on release.
struct DeleteKey: View {
    let size: CGFloat
    let visible: Bool
    /// Returns false when nothing is left to delete.
    let onDelete: () -> Bool
    var onClear: (() -> Void)?
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: size * 0.34, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if repeatTask == nil { start() } }
                .onEnded { _ in stop() })
            .onDisappear { stop() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("删除一位")
            .accessibilityAddTraits(.isButton)
            .accessibilityHidden(!visible)
            .accessibilityAction { _ = onDelete() }
            .accessibilityAction(named: "全部清除") { onClear?() }
    }
    private func start() {
        repeatTask = Task { @MainActor in
            guard onDelete() else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            try? await Task.sleep(for: .milliseconds(450))
            var count = 0
            while !Task.isCancelled {
                guard onDelete() else { break }
                count += 1
                try? await Task.sleep(for: .milliseconds(count > 8 ? 45 : 100))
            }
        }
    }
    private func stop() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

/// Number display with the system edit menu on long press (copy / paste).
/// Paste goes through the system menu, so iOS does not ask for paste permission.
struct NumberDisplay: UIViewRepresentable {
    let number: String
    let shown: String
    let fontSize: CGFloat
    let onPaste: (String) -> Void

    func makeUIView(context: Context) -> NumberLabel {
        let label = NumberLabel()
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.45
        label.numberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }
    func updateUIView(_ label: NumberLabel, context: Context) {
        label.rawNumber = number
        label.onPaste = onPaste
        label.font = .systemFont(ofSize: fontSize, weight: .regular)
        label.textColor = .label
        label.text = shown
        label.accessibilityLabel = number.isEmpty ? "号码，按住可粘贴" : "号码 \(number)，按住可复制或粘贴"
    }
}

final class NumberLabel: UILabel, UIEditMenuInteractionDelegate {
    var rawNumber = ""
    var onPaste: ((String) -> Void)?
    private lazy var menu = UIEditMenuInteraction(delegate: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        addInteraction(menu)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(showMenu(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeFirstResponder: Bool { true }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return !rawNumber.isEmpty }
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings }
        return false
    }
    override func copy(_ sender: Any?) { UIPasteboard.general.string = rawNumber }
    override func paste(_ sender: Any?) { onPaste?(UIPasteboard.general.string ?? "") }

    @objc private func showMenu(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, becomeFirstResponder() else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let point = CGPoint(x: bounds.midX, y: bounds.minY)
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }
}

/// Round control used on the dark call screen (audio / mute / keypad).
struct CallControl: View {
    let title: String
    let symbol: String
    let size: CGFloat
    var on = false
    var dimmed = false
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .medium))
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: size, height: size)
                .background(Circle().fill(on ? Color.white : Color.white.opacity(0.2)))
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(1).fixedSize()
        }
        .opacity(dimmed ? 0.38 : 1)
        .contentShape(Rectangle())
    }
}

/// Round green / red phone button with a label underneath.
struct RoundCallButton: View {
    let title: String
    let color: Color
    let size: CGFloat
    var hangup = false
    var labelColor: Color = .white
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "phone.fill")
                .font(.system(size: size * 0.4, weight: .medium))
                .rotationEffect(.degrees(hangup ? 135 : 0))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(color))
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(labelColor).lineLimit(1).fixedSize()
        }
        .contentShape(Rectangle())
    }
}
