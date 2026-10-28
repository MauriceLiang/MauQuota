import Foundation

/// One-time migration from the former CodexMeter bundle identifier.
/// Copies only explicitly-set appearance preferences; never touches Codex credentials.
public enum LegacyPreferencesMigration {
    public static let formerBundleIdentifier = "dev.mau.codexmeter"
    public static let keys = ["showColoredQuotaRing", "refreshIntervalMinutes", "displayLanguage"]

    /// Does not overwrite an existing value in the current app domain.
    /// Preferences classes validate saved values when read.
    @discardableResult
    public static func migrate(from oldValues: [String: Any], into defaults: UserDefaults) -> Int {
        var count = 0
        for key in keys where defaults.object(forKey: key) == nil {
            guard let value = oldValues[key] else { continue }
            defaults.set(value, forKey: key)
            count += 1
        }
        return count
    }
}
