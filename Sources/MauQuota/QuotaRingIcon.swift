import AppKit
import MauQuotaCore

/// Outer ring: weekly usage. Inner ring: five-hour usage, only when the plan has that window.
enum QuotaRingIcon {
    static func color(for remaining: Int) -> NSColor {
        if remaining == 0 { return NSColor.systemRed.withAlphaComponent(0.65) }
        if remaining <= 20 { return .systemRed }
        if remaining <= 50 { return .systemOrange }
        return .systemGreen
    }

    static func render(_ state: QuotaRingState,
                       settings: MenuBarAppearanceSettings) -> NSImage {
        let size = NSSize(width: 21, height: 21)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: 10.5, y: 10.5)
            if let weekly = state.weeklyRemaining {
                let custom = settings.customColorHex(for: .weeklyRing)
                    .flatMap { NSColor(mauQuotaHex: $0) }
                drawRing(center: center, radius: 8.6, width: 2.5,
                         remaining: weekly, customColor: custom)
            }
            if let fiveHour = state.fiveHourRemaining {
                let custom = settings.customColorHex(for: .fiveHourRing)
                    .flatMap { NSColor(mauQuotaHex: $0) }
                drawRing(center: center, radius: 5.25, width: 2.2,
                         remaining: fiveHour, customColor: custom)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawRing(center: NSPoint, radius: CGFloat, width: CGFloat,
                                 remaining: Int, customColor: NSColor?) {
        let color = customColor ?? Self.color(for: remaining)
        let track = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2))
        track.lineWidth = width
        let trackColor = remaining == 0 ? color : NSColor.labelColor.withAlphaComponent(0.13)
        trackColor.setStroke()
        track.stroke()

        guard remaining > 0 else { return }
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
