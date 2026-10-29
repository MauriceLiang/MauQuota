import AppKit
import MauQuotaCore

/// 双环菜单栏标识：外圈为每周额度，内圈为 5 小时额度，颜色表示剩余比例。
/// 在 18～22pt 的菜单栏里不绘制中心代码括号，确保两圈清楚可辨。
enum QuotaRingIcon {
    static func render(_ state: QuotaRingState) -> NSImage {
        let size = NSSize(width: 21, height: 21)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: 10.5, y: 10.5)
            drawRing(center: center, radius: 8.6, width: 2.5,
                     remaining: state.weeklyRemaining)
            drawRing(center: center, radius: 5.25, width: 2.2,
                     remaining: state.fiveHourRemaining)
            return true
        }
        image.isTemplate = false // macOS 模板图会被统一着色，导致额度颜色丢失。
        return image
    }

    private static func drawRing(center: NSPoint, radius: CGFloat, width: CGFloat,
                                 remaining: Int?) {
        let color: NSColor
        if let remaining {
            if remaining <= 20 { color = .systemRed }
            else if remaining <= 50 { color = .systemOrange }
            else { color = .systemGreen }
        } else {
            color = .labelColor
        }

        let track = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2))
        track.lineWidth = width
        let trackColor = remaining == 0
            ? color.withAlphaComponent(0.65) : NSColor.labelColor.withAlphaComponent(0.13)
        trackColor.setStroke()
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
