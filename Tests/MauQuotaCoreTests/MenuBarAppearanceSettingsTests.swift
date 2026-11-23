import XCTest
import Foundation
@testable import MauQuotaCore

final class MenuBarAppearanceSettingsTests: XCTestCase {
    func testColoredRingIsOnByDefault() throws {
        let (settings, suite) = try makeSettings()
        defer { suite.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(settings.showsColoredRing)
    }

    func testColoredRingChoicePersistsBetweenInstances() throws {
        let (settings, suite) = try makeSettings()
        defer { suite.removePersistentDomain(forName: suiteName) }
        settings.showsColoredRing = false
        XCTAssertFalse(MenuBarAppearanceSettings(defaults: suite).showsColoredRing)
        settings.showsColoredRing = true
        XCTAssertTrue(MenuBarAppearanceSettings(defaults: suite).showsColoredRing)
    }

    func testMenuBarNumbersAreShownByDefault() throws {
        let (settings, suite) = try makeSettings()
        defer { suite.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(settings.showsMenuBarNumbers)
        XCTAssertTrue(settings.shouldDisplayRing)
    }

    func testCompactModePersistsAndAlwaysDisplaysRing() throws {
        let (settings, suite) = try makeSettings()
        defer { suite.removePersistentDomain(forName: suiteName) }
        settings.showsColoredRing = false
        XCTAssertFalse(settings.shouldDisplayRing)

        settings.showsMenuBarNumbers = false
        let reloaded = MenuBarAppearanceSettings(defaults: suite)
        XCTAssertFalse(reloaded.showsMenuBarNumbers)
        XCTAssertTrue(reloaded.shouldDisplayRing)

        reloaded.showsMenuBarNumbers = true
        XCTAssertFalse(settings.shouldDisplayRing)
        XCTAssertFalse(settings.showsColoredRing)
    }

    private var suiteName: String { "dev.mau.mauquota.test.\(testName)" }
    private var testName: String { name.replacingOccurrences(of: " ", with: "_") }

    private func makeSettings() throws -> (MenuBarAppearanceSettings, UserDefaults) {
        guard let suite = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "test", code: 1)
        }
        suite.removePersistentDomain(forName: suiteName)
        return (MenuBarAppearanceSettings(defaults: suite), suite)
    }
}
