import XCTest
import Foundation
@testable import MauQuotaCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class CodexAppServerTests: XCTestCase {
    private func makeMock(_ lines: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("codex")
        try ("#!/bin/sh\n" + lines + "\n").write(to: file, atomically: true, encoding: .utf8)
        guard chmod(file.path, 0o755) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return file
    }

    func testNormalHandshakeAndRateLimitResponse() throws {
        let cli = try makeMock("""
        IFS= read -r init
        printf '%s\\n' '{"id":1,"result":{"userAgent":"test"}}'
        IFS= read -r initialized
        IFS= read -r usage
        printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":40,"windowDurationMins":10080}}}}'
        """)
        let usage = try CodexAppServer(timeoutSeconds: 3, cliExecutable: cli.path).loadUsage()
        XCTAssertEqual(usage.shortWindow?.remainingPercent, 80)
        XCTAssertEqual(usage.longWindow?.remainingPercent, 60)
    }

    func testNotificationsBeforeResponse() throws {
        let cli = try makeMock("""
        IFS= read -r init
        printf '%s\\n' '{"method":"notice","params":{}}'
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r usage
        printf '%s\\n' '{"method":"randomNotification"}'
        printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":300}}}}'
        """)
        let usage = try CodexAppServer(timeoutSeconds: 3, cliExecutable: cli.path).loadUsage()
        XCTAssertEqual(usage.shortWindow?.remainingPercent, 95)
    }

    func testEarlySubprocessExitReportsError() throws {
        // In the real macOS menu-bar app SIGPIPE is ignored before any IPC.
        _ = signal(SIGPIPE, SIG_IGN)
        let cli = try makeMock("exit 7")
        XCTAssertThrowsError(try CodexAppServer(timeoutSeconds: 2, cliExecutable: cli.path).loadUsage()) { error in
            XCTAssertTrue(error is CodexAppServer.ClientError)
        }
    }

    func testStalledSubprocessTimesOutAndIsKilled() throws {
        let cli = try makeMock("exec sleep 8")
        let begin = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try CodexAppServer(timeoutSeconds: 0.3, cliExecutable: cli.path).loadUsage()) { error in
            guard case CodexAppServer.ClientError.timeout = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 3.5)
    }

    func testNotLoggedInReturnsExplicitStateWithoutQuotaRequest() throws {
        let cli = try makeMock("""
        IFS= read -r init
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r account
        printf '%s\n' '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}'
        """)
        let snapshot = try CodexAppServer(timeoutSeconds: 3, cliExecutable: cli.path).loadSnapshot()
        XCTAssertNil(snapshot.account)
        XCTAssertNil(snapshot.usage)
        XCTAssertNil(snapshot.quotaError)
    }

    func testLoggedInAccountAndQuota() throws {
        let cli = try makeMock("""
        IFS= read -r init
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r account
        printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"demo@example.com","planType":"plus"}}}'
        IFS= read -r quota
        printf '%s\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":37,"windowDurationMins":300}}}}'
        """)
        let snapshot = try CodexAppServer(timeoutSeconds: 3, cliExecutable: cli.path).loadSnapshot()
        XCTAssertEqual(snapshot.account?.email, "demo@example.com")
        XCTAssertEqual(snapshot.account?.planType, "plus")
        XCTAssertEqual(snapshot.usage?.shortWindow?.remainingPercent, 63)
        XCTAssertNil(snapshot.quotaError)
    }

    func testQuotaErrorPreservesLoginStatus() throws {
        let cli = try makeMock("""
        IFS= read -r init
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r account
        printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"pro"}}}'
        IFS= read -r quota
        printf '%s\n' '{"id":3,"error":{"code":401,"message":"access token secret must not surface"}}'
        """)
        let snapshot = try CodexAppServer(timeoutSeconds: 3, cliExecutable: cli.path).loadSnapshot()
        XCTAssertEqual(snapshot.account?.planType, "pro")
        XCTAssertNil(snapshot.usage)
        XCTAssertNotNil(snapshot.quotaError)
        XCTAssertFalse(snapshot.quotaError!.contains("secret"))
    }

    func testAPIKeyLoginDoesNotClaimChatGPTSubscriptionQuota() throws {
        let cli = try makeMock("""
        IFS= read -r init
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r account
        printf '%s\n' '{"id":2,"result":{"account":{"type":"apiKey"}}}'
        """)
        let snapshot = try CodexAppServer(timeoutSeconds: 3, cliExecutable: cli.path).loadSnapshot()
        XCTAssertEqual(snapshot.account?.type, "apiKey")
        XCTAssertNil(snapshot.usage)
        XCTAssertNotNil(snapshot.quotaError)
    }

    func testChatGPTBrowserAuthorizationAndCompletion() throws {
        let cli = try makeMock("""
        IFS= read -r init
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r login
        printf '%s\n' '{"method":"account/login/completed","params":{"loginId":"ignored","success":false}}'
        printf '%s\n' '{"id":2,"result":{"type":"chatgpt","loginId":"id-123","authUrl":"https://chatgpt.com/auth"}}'
        printf '%s\n' '{"method":"account/login/completed","params":{"loginId":"id-123","success":true}}'
        """)
        var opened: URL?
        try CodexAppServer(timeoutSeconds: 3, cliExecutable: cli.path).loginWithChatGPT { opened = $0 }
        XCTAssertEqual(opened?.host, "chatgpt.com")
    }

    func testBrowserLoginRejectsMaliciousAddress() throws {
        let cli = try makeMock("""
        IFS= read -r init
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r login
        printf '%s\n' '{"id":2,"result":{"type":"chatgpt","loginId":"id-123","authUrl":"https://evil.example/login"}}'
        """)
        XCTAssertThrowsError(try CodexAppServer(timeoutSeconds: 3, cliExecutable: cli.path).loginWithChatGPT { _ in
            XCTFail("Untrusted URL must not open")
        }) { error in
            guard case CodexAppServer.ClientError.loginInvalidURL = error else { return XCTFail("Unexpected: \(error)") }
        }
        XCTAssertTrue(CodexAppServer.isTrustedLoginURL(URL(string: "https://auth.openai.com/codex")!))
        XCTAssertFalse(CodexAppServer.isTrustedLoginURL(URL(string: "http://chatgpt.com/login")!))
        XCTAssertFalse(CodexAppServer.isTrustedLoginURL(URL(string: "https://chatgpt.com.evil.example")!))
    }

    func testRejectedRateLimitResponse() throws {
        let cli = try makeMock("""
        IFS= read -r init
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r usage
        printf '%s\\n' '{"id":2,"error":{"code":401,"message":"denied"}}'
        """)
        XCTAssertThrowsError(try CodexAppServer(timeoutSeconds: 3, cliExecutable: cli.path).loadUsage()) { error in
            guard case CodexAppServer.ClientError.requestRejected(let code) = error else {
                return XCTFail("Expected request rejection, got \(error)")
            }
            XCTAssertEqual(code, 401)
        }
    }
}
