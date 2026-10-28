import XCTest
@testable import MauQuotaCore

final class LegacyPreferencesMigrationTests: XCTestCase {
    func testCopiesThreeSupportedSettings() throws {
        let domain = "dev.mau.mauquota.migration-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let count = LegacyPreferencesMigration.migrate(from: [
            "showColoredQuotaRing": false,
            "refreshIntervalMinutes": 15,
            "displayLanguage": "en",
            "secret": "must-not-copy"
        ], into: defaults)
        XCTAssertEqual(count, 3)
        XCTAssertEqual(defaults.bool(forKey: "showColoredQuotaRing"), false)
        XCTAssertEqual(defaults.integer(forKey: "refreshIntervalMinutes"), 15)
        XCTAssertEqual(defaults.string(forKey: "displayLanguage"), "en")
        XCTAssertNil(defaults.object(forKey: "secret"))
    }

    func testDoesNotOverwriteCurrentSettings() throws {
        let domain = "dev.mau.mauquota.migration-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(30, forKey: "refreshIntervalMinutes")
        XCTAssertEqual(LegacyPreferencesMigration.migrate(from: ["refreshIntervalMinutes": 2], into: defaults), 0)
        XCTAssertEqual(defaults.integer(forKey: "refreshIntervalMinutes"), 30)
    }
}
