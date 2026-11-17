import XCTest
import Foundation
@testable import MauQuotaCore

final class MenuBarPreferencesTests: XCTestCase {
    func testDefaultsAreTwoMinutesAndSystemLanguage() throws {
        let (settings, defaults) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(settings.refreshIntervalMinutes, 2)
        XCTAssertEqual(settings.language, .system)
    }

    func testRefreshIntervalPersistsAndSupportsCustomValues() throws {
        let (settings, defaults) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.refreshIntervalMinutes = 7
        XCTAssertEqual(MenuBarPreferences(defaults: defaults).refreshIntervalMinutes, 7)
        settings.refreshIntervalMinutes = 30
        XCTAssertEqual(MenuBarPreferences(defaults: defaults).refreshIntervalMinutes, 30)
    }

    func testInvalidIntervalsAreClampedAndCorruptDefaultsFallback() throws {
        let (settings, defaults) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.refreshIntervalMinutes = 0
        XCTAssertEqual(settings.refreshIntervalMinutes, 1)
        settings.refreshIntervalMinutes = 1_000
        XCTAssertEqual(settings.refreshIntervalMinutes, 120)
        defaults.set("invalid", forKey: "refreshIntervalMinutes")
        XCTAssertEqual(settings.refreshIntervalMinutes, 2)
        defaults.set(-15, forKey: "refreshIntervalMinutes")
        XCTAssertEqual(settings.refreshIntervalMinutes, 2)
    }

    func testLanguagePersistsAndFallsBackOnUnknownValues() throws {
        let (settings, defaults) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.language = .english
        XCTAssertEqual(MenuBarPreferences(defaults: defaults).language, .english)
        settings.language = .simplifiedChinese
        XCTAssertEqual(MenuBarPreferences(defaults: defaults).language, .simplifiedChinese)
        defaults.set("xx", forKey: "displayLanguage")
        XCTAssertEqual(settings.language, .system)
    }

    func testSystemLanguageResolutionHandlesBothChineseAndEnglish() {
        XCTAssertEqual(DisplayLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]), .simplifiedChinese)
        XCTAssertEqual(DisplayLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(DisplayLanguage.system.resolved(preferredLanguages: ["en-US"]), .english)
        XCTAssertEqual(DisplayLanguage.system.resolved(preferredLanguages: []), .english)
        XCTAssertEqual(DisplayLanguage.english.resolved(preferredLanguages: ["zh-Hans"]), .english)
    }

    func testTranslationsAreAvailableInBothLanguages() {
        XCTAssertEqual(MenuLocalization.text(.refresh, language: .simplifiedChinese), "立即刷新")
        XCTAssertEqual(MenuLocalization.text(.refresh, language: .english), "Refresh now")
        XCTAssertEqual(MenuLocalization.text(.ringToggle, language: .english), "Show colored quota rings")
        XCTAssertEqual(MenuLocalization.text(.refreshInterval, language: .simplifiedChinese), "自动刷新间隔")
    }

    private var suiteName: String { "dev.mau.mauquota.prefs.test.\(name.replacingOccurrences(of: " ", with: "_"))" }

    private func makeSettings() throws -> (MenuBarPreferences, UserDefaults) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "test", code: 1)
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (MenuBarPreferences(defaults: defaults), defaults)
    }
}
