import Foundation
import XCTest
@testable import MauQuotaCore

private final class CountingCredentialStore: CodexCredentialStore {
    var value: CodexOAuthCredentials?
    var loadCount = 0
    var saveCount = 0
    var deleteCount = 0
    var failNextLoad = false

    func load() throws -> CodexOAuthCredentials? {
        loadCount += 1
        if failNextLoad {
            failNextLoad = false
            throw NSError(domain: "simulated-keychain", code: 1)
        }
        return value
    }

    func save(_ credentials: CodexOAuthCredentials) throws {
        saveCount += 1
        value = credentials
    }

    func delete() throws {
        deleteCount += 1
        value = nil
    }
}

final class SessionCredentialStoreTests: XCTestCase {
    private func credentials(_ token: String = "token-1") -> CodexOAuthCredentials {
        CodexOAuthCredentials(
            accessToken: token,
            refreshToken: "refresh",
            idToken: nil,
            accountID: "account",
            email: nil,
            planType: "plus",
            expiresAt: Date().addingTimeInterval(60 * 60)
        )
    }

    func testRepeatedLoadsAccessUnderlyingKeychainOnlyOnce() throws {
        let underlying = CountingCredentialStore()
        underlying.value = credentials()
        let session = SessionCredentialStore(underlying: underlying)
        XCTAssertEqual(try session.load()?.accessToken, "token-1")
        XCTAssertEqual(try session.load()?.accessToken, "token-1")
        XCTAssertEqual(underlying.loadCount, 1)
    }

    func testConcurrentLoadsUseSingleUnderlyingRead() {
        let underlying = CountingCredentialStore()
        underlying.value = credentials()
        let session = SessionCredentialStore(underlying: underlying)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            _ = try? session.load()
        }
        XCTAssertEqual(underlying.loadCount, 1)
    }

    func testSaveRefreshesCacheWithoutReloadingKeychain() throws {
        let underlying = CountingCredentialStore()
        underlying.value = credentials()
        let session = SessionCredentialStore(underlying: underlying)
        _ = try session.load()
        try session.save(credentials("token-2"))
        XCTAssertEqual(try session.load()?.accessToken, "token-2")
        XCTAssertEqual(underlying.loadCount, 1)
        XCTAssertEqual(underlying.saveCount, 1)
    }

    func testDeleteClearsSessionCache() throws {
        let underlying = CountingCredentialStore()
        underlying.value = credentials()
        let session = SessionCredentialStore(underlying: underlying)
        _ = try session.load()
        try session.delete()
        XCTAssertNil(try session.load())
        XCTAssertEqual(underlying.loadCount, 1)
        XCTAssertEqual(underlying.deleteCount, 1)
    }

    func testFailedKeychainReadCanBeRetried() throws {
        let underlying = CountingCredentialStore()
        underlying.value = credentials()
        underlying.failNextLoad = true
        let session = SessionCredentialStore(underlying: underlying)
        XCTAssertThrowsError(try session.load())
        XCTAssertEqual(try session.load()?.accessToken, "token-1")
        XCTAssertEqual(underlying.loadCount, 2)
    }

    func testNewApplicationSessionStartsWithFreshKeychainRead() throws {
        let underlying = CountingCredentialStore()
        underlying.value = credentials()
        _ = try SessionCredentialStore(underlying: underlying).load()
        _ = try SessionCredentialStore(underlying: underlying).load()
        XCTAssertEqual(underlying.loadCount, 2)
    }
}
