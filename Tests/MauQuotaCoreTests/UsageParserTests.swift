import XCTest
@testable import MauQuotaCore

final class UsageParserTests: XCTestCase {
    func testNormalTwoWindows() throws {
        let data = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":21,"windowDurationMins":300,"resetsAt":1793200000},"secondary":{"usedPercent":55,"windowDurationMins":10080,"resetsAt":1793800000}}}}"#.utf8)
        let usage = try UsageParser.parseResponse(data)
        XCTAssertEqual(usage.menuBarTitle, "5h 79% · 7d 45%")
        XCTAssertEqual(usage.shortWindow?.resetsAt?.timeIntervalSince1970, 1_793_200_000)
    }

    func testSingleWeeklyWindowInPrimarySlot() throws {
        let data = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":9,"windowDurationMins":10080,"resetsAt":1793800000},"secondary":null}}}"#.utf8)
        let usage = try UsageParser.parseResponse(data)
        XCTAssertNil(usage.shortWindow)
        XCTAssertEqual(usage.menuBarTitle, "7d 91%")
    }

    func testNoWindowDoesNotPretendFullQuota() {
        let data = Data(#"{"result":{"rateLimits":{"primary":null,"secondary":null}}}"#.utf8)
        XCTAssertThrowsError(try UsageParser.parseResponse(data)) { error in
            XCTAssertEqual(error as? UsageParserError, .missingWindows)
        }
    }

    func testInvalidInput() {
        XCTAssertThrowsError(try UsageParser.parseResponse(Data("!".utf8)))
    }

    func testPreferCodexBucket() throws {
        let data = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":10,"windowDurationMins":300}}}}}"#.utf8)
        XCTAssertEqual(try UsageParser.parseResponse(data).menuBarTitle, "5h 90%")
    }

    func testMalformedDurationDoesNotCrash() throws {
        let data = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":"NaN","resetsAt":"Infinity"}}}}"#.utf8)
        let result = try UsageParser.parseResponse(data)
        XCTAssertEqual(result.menuBarTitle, "额度 99%")
        XCTAssertNil(result.shortWindow?.resetsAt)
    }

    func testUnknownDurationIsNotMisrepresented() throws {
        let data = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":29}}}}"#.utf8)
        XCTAssertEqual(try UsageParser.parseResponse(data).menuBarTitle, "额度 71%")
    }
    func testDoubleRingForTwoConfirmedWindows() throws {
        let data = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300},"secondary":{"usedPercent":60,"windowDurationMins":10080}}}}"#.utf8)
        let ring = QuotaRingState(usage: try UsageParser.parseResponse(data))
        XCTAssertEqual(ring.weeklyRemaining, 40)
        XCTAssertEqual(ring.fiveHourRemaining, 75)
    }

    func testWeeklyOnlyOmitsInnerRing() throws {
        let data = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":10080}}}}"#.utf8)
        let ring = QuotaRingState(usage: try UsageParser.parseResponse(data))
        XCTAssertEqual(ring.weeklyRemaining, 88)
        XCTAssertNil(ring.fiveHourRemaining)
    }

    func testUnknownWindowsNeverFakeProgress() throws {
        let data = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":12}}}}"#.utf8)
        let ring = QuotaRingState(usage: try UsageParser.parseResponse(data))
        XCTAssertNil(ring.weeklyRemaining)
        XCTAssertNil(ring.fiveHourRemaining)
        XCTAssertEqual(QuotaRingState(usage: nil), QuotaRingState(usage: nil))
    }

}
