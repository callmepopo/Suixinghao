import CoreGraphics

/// Sizes for the dialer, derived from the space actually given (outer / inner Duo screen,
/// iPhone sizes). Recomputed on every size change, so folding / unfolding relays out.
struct DialMetrics {
    static let maxWidth: CGFloat = 393
    let width: CGFloat
    let key: CGFloat
    let headerH: CGFloat
    let numberH: CGFloat
    let numberFont: CGFloat
    let rowH: CGFloat
    let notesH: CGFloat
    let keypadGap: CGFloat
    let actionGap: CGFloat

    init(size: CGSize) {
        // Short screens (iPhone SE: about 560pt between status bar and tab bar) tighten
        // everything except the keypad, keeping the three fixed match rows.
        let compact = size.height < 600
        width = max(0, min(size.width, Self.maxWidth) - 24)
        headerH = compact ? 32 : 40
        numberH = compact ? 40 : (size.height < 700 ? 48 : 56)
        numberFont = compact ? 32 : (size.height < 700 ? 36 : 42)
        rowH = compact ? 30 : 36
        notesH = compact ? 18 : 22
        let gapRatio: (CGFloat, CGFloat) = compact ? (0.1, 0.14) : (0.16, 0.2)
        // Keypad 4.54k, gaps, green button k plus its 18pt label, notes and slack.
        let fixed = headerH + numberH + rowH * 3 + notesH + 6 + 18 + (compact ? 4 : 14)
        let byHeight = (size.height - fixed) / (4.54 + gapRatio.0 + gapRatio.1 + 1)
        let byWidth = width / 3.72
        key = max(50, min(80, byHeight, byWidth))
        keypadGap = key * gapRatio.0
        actionGap = key * gapRatio.1
    }

    /// Height the dialer column needs: header, number, three match rows, keypad (4.54k),
    /// green button with its label, notes. Must fit the given height (dialer-layout-check).
    var requiredHeight: CGFloat {
        headerH + numberH + rowH * 3 + keypadGap + key * 4.54 + actionGap + key + 18 + 6 + notesH
    }

    /// Smallest iPad window the dialer is laid out for. iPad windows can be resized freely,
    /// so smaller windows are refused rather than clipping the call button.
    static let minimumPadWindow = CGSize(width: 375, height: 640)
}
