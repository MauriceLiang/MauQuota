import XCTest
import Foundation
@testable import MauQuotaCore

final class ResetCreditHistoryStoreTests: XCTestCase {
    private func makeStore() -> (ResetCreditHistoryStore, UserDefaults, String) {
        let suite = "ResetCreditHistoryStoreTests.\\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (ResetCreditHistoryStore(defaults: defaults), defaults, suite)
    }

    func testPendingAttemptPersistsAndCanBeCompletedExactlyOnce() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let attempt = PendingResetCreditAttempt(
            idempotencyKey: "attempt-1",
            creditID: "credit-1",
            title: "Full reset",
            expiresAt: Date().addingTimeInterval(86_400),
            accountEmail: "demo@example.com"
        )
        store.savePendingAttempt(attempt)
        XCTAssertEqual(store.pendingAttempt, attempt)

        let completed = store.completePendingAttempt()
        XCTAssertEqual(completed?.idempotencyKey, "attempt-1")
        XCTAssertNil(store.pendingAttempt)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.title, "Full reset")
        XCTAssertNil(store.completePendingAttempt())
    }

    func testPendingAttemptCanBeClearedWithoutAddingHistory() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.savePendingAttempt(PendingResetCreditAttempt(
            idempotencyKey: "attempt-2",
            creditID: nil,
            title: "Next available reset",
            expiresAt: nil,
            accountEmail: nil
        ))
        store.clearPendingAttempt()
        XCTAssertNil(store.pendingAttempt)
        XCTAssertTrue(store.entries.isEmpty)
    }
}
