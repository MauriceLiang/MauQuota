import AppKit
import MauQuotaCore

/// 与 AppIcon 一致的双环菜单栏标识：
/// 橙色外圈 = 7 天额度，灰色内圈 = 服务端明确返回的 5 小时额度。
/// 在 18～22pt 的菜单栏里不绘制中心代码括号，确保两圈清楚可辨。
enum QuotaRingIcon {
    static func render(_ state: QuotaRingState) -> NSImage {
        let size = NSSize(width: 21, height: 21)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: 10.5, y: 10.5)
            drawRing(center: center, radius: 8.6, width: 2.5,
                     remaining: state.weeklyRemaining,
                     color: NSColor(calibratedRed: 1.0, green: 0.47, blue: 0.11, alpha: 1.0))
            if let short = state.fiveHourRemaining {
                drawRing(center: center, radius: 5.25, width: 2.2,
                         remaining: short,
                         color: NSColor(calibratedRed: 0.55, green: 0.57, blue: 0.61, alpha: 1.0))
            }
            return true
        }
        image.isTemplate = false // macOS 模板图会被统一着色，导致橙/灰丢失。
        return image
    }

    private static func drawRing(center: NSPoint, radius: CGFloat, width: CGFloat,
                                 remaining: Int?, color: NSColor) {
        let track = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2))
        track.lineWidth = width
        NSColor.labelColor.withAlphaComponent(0.13).setStroke()
        track.stroke()

        guard let remaining, remaining > 0 else { return }
        let percent = CGFloat(min(100, max(0, remaining))) / 100
        let progress = NSBezierPath()
        progress.lineWidth = width
        progress.lineCapStyle = .round
        progress.appendArc(withCenter: center, radius: radius,
                           startAngle: 90, endAngle: 90 - 360 * percent,
                           clockwise: true)
        color.setStroke()
        progress.stroke()
    }
}
