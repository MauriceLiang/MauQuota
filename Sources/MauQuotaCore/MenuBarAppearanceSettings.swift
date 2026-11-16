import Foundation

public enum AppearanceColorKey: String, CaseIterable, Equatable {
    case fiveHourRing, weeklyRing
    case fiveHourNumber, weeklyNumber
    case fiveHourDetail, weeklyDetail
}

public final class MenuBarAppearanceSettings {
    private static let coloredRingKey = "showColoredQuotaRing"
    private static let coloredNumbersKey = "showColoredQuotaNumbers"
    private static let redNumberAlignmentKey = "compensateRedQuotaNumberAlignment"
    private static let customColorPrefix = "appearance.customColor."
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var showsColoredRing: Bool {
        get { defaults.object(forKey: Self.coloredRingKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.coloredRingKey) }
    }
    public var showsColoredNumbers: Bool {
        get { defaults.object(forKey: Self.coloredNumbersKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.coloredNumbersKey) }
    }
    public var compensatesRedNumberAlignment: Bool {
        get { defaults.object(forKey: Self.redNumberAlignmentKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.redNumberAlignmentKey) }
    }

    /// nil keeps the built-in threshold or system-label color for this element.
    public func customColorHex(for key: AppearanceColorKey) -> String? {
        guard let stored = defaults.string(forKey: Self.customColorPrefix + key.rawValue) else { return nil }
        return Self.normalizedHex(stored)
    }

    public func setCustomColorHex(_ hex: String?, for key: AppearanceColorKey) {
        let storageKey = Self.customColorPrefix + key.rawValue
        guard let hex, let normalized = Self.normalizedHex(hex) else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        defaults.set(normalized, forKey: storageKey)
    }

    public func resetCustomColors() {
        for key in AppearanceColorKey.allCases {
            defaults.removeObject(forKey: Self.customColorPrefix + key.rawValue)
        }
    }

    private static func normalizedHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + digits.uppercased()
    }
}
