// Dialer sizing for iPhone and iPad window sizes: keys stay usable (50-80 pt), the column
// fits horizontally, and the whole column (through the call button and notes) fits the
// height. Sizes are the dialer viewport (window minus status/tab bars), measured with the
// Debug SXH-GEO log where available. Layout math only; not a screenshot or device check.
import CoreGraphics
import Foundation

struct Case { let name: String; let size: CGSize; var minKey: CGFloat = 50 }

@main struct DialerLayoutCheck {
    static func main() {
        let cases = [
            Case(name: "iPhone SE 竖屏", size: CGSize(width: 375, height: 560), minKey: 60),
            Case(name: "iPhone 15 Pro 竖屏", size: CGSize(width: 393, height: 710), minKey: 70),
            // iPad mini (A20 Pro) window 756x1158; tab bar on top (SXH-GEO 2026-11-08: 756x1042 portrait).
            Case(name: "iPad mini 竖屏", size: CGSize(width: 756, height: 1042), minKey: 78),
            Case(name: "iPad mini 横屏", size: CGSize(width: 1158, height: 640), minKey: 62),
            Case(name: "iPad mini 横屏半屏", size: CGSize(width: 575, height: 640), minKey: 62),
            Case(name: "iPad Air 11 竖屏", size: CGSize(width: 820, height: 1064), minKey: 78),
            Case(name: "iPad Air 11 横屏", size: CGSize(width: 1180, height: 704), minKey: 70),
            Case(name: "iPad Pro 13 竖屏", size: CGSize(width: 1032, height: 1260), minKey: 78),
            Case(name: "iPad Pro 13 横屏", size: CGSize(width: 1376, height: 916), minKey: 78),
            // Smallest iPad window allowed (DialMetrics.minimumPadWindow) minus ~116 pt of bars.
            Case(name: "iPad 最小窗口", size: CGSize(width: DialMetrics.minimumPadWindow.width,
                                               height: DialMetrics.minimumPadWindow.height - 116)),
        ]
        var failures = 0
        for c in cases {
            let m = DialMetrics(size: c.size)
            let fitsWidth = m.key * 3.72 <= m.width + 0.5
            let fitsHeight = m.requiredHeight <= c.size.height + 0.5
            let usable = m.key >= c.minKey && m.key <= 80
            let ok = fitsWidth && fitsHeight && usable
            if !ok { failures += 1 }
            print(String(format: "%@：%@ 键%.0fpt 需高%.0f/可用%.0f 列宽%.0f", ok ? "通过" : "失败", c.name,
                         m.key, m.requiredHeight, c.size.height, m.width))
        }
        precondition(failures == 0, "dialer layout does not fit")
        precondition(DialMetrics(size: CGSize(width: 1376, height: 916)).width == DialMetrics.maxWidth - 24, "iPad must not stretch the column")
        print("拨号盘尺寸检查 \(cases.count) 项通过（布局计算，不代表截图或真机）")
    }
}
