import XCTest
import Foundation
@testable import MauQuotaCore

private final class MemoryCredentialStore: CodexCredentialStore {
    var value: CodexOAuthCredentials?

    init(_ value: CodexOAuthCredentials? = nil) {
        self.value = value
    }

    func load() throws -> CodexOAuthCredentials? { value }
    func save(_ credentials: CodexOAuthCredentials) throws { value = credentials }
    func delete() throws { value = nil }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        handler = nil
        requests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.requests.append(request)
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CodexAPIClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(store: MemoryCredentialStore) -> CodexAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return CodexAPIClient(timeoutSeconds: 2, session: session, credentialStore: store)
    }

    private func credentials(expiry: Date = Date().addingTimeInterval(3_600)) -> CodexOAuthCredentials {
        CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: nil,
            accountID: "account-123",
            email: "demo@example.com",
            planType: "plus",
            expiresAt: expiry
        )
    }

    private let usageJSON = Data(#"{
      "account_id":"account-123",
      "plan_type":"plus",
      "rate_limit":{
        "primary_window":{"used_percent":21,"limit_window_seconds":18000,"reset_at":1793200000},
        "secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_at":1793800000}
      }
    }"#.utf8)

    func testUnauthenticatedSnapshotIsExplicitlySignedOut() throws {
        let client = makeClient(store: MemoryCredentialStore())
        let snapshot = try client.loadSnapshot()
        XCTAssertNil(snapshot.account)
        XCTAssertNil(snapshot.usage)
        XCTAssertNil(snapshot.quotaError)
    }

    func testUsageRequestUsesOAuthAndAccountHeaders() throws {
        let store = MemoryCredentialStore(credentials())
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/backend-api/wham/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "codex_cli_rs")
            return (200, self.usageJSON)
        }

        let snapshot = try makeClient(store: store).loadSnapshot()
        XCTAssertEqual(snapshot.account?.email, "demo@example.com")
        XCTAssertEqual(snapshot.account?.planType, "plus")
        XCTAssertEqual(snapshot.usage?.shortWindow?.remainingPercent, 79)
        XCTAssertEqual(snapshot.usage?.longWindow?.remainingPercent, 45)
        XCTAssertNil(snapshot.quotaError)
    }

    func testUnauthorizedUsageRefreshesTokenAndRetriesOnce() throws {
        let store = MemoryCredentialStore(credentials())
        StubURLProtocol.handler = { request in
            if request.url?.path == "/backend-api/wham/usage" {
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token" {
                    return (401, Data("{}".utf8))
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
                return (200, self.usageJSON)
            }
            XCTAssertEqual(request.url?.host, "auth.openai.com")
            XCTAssertEqual(request.url?.path, "/oauth/token")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("refresh-token"))
            return (200, Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8))
        }

        let snapshot = try makeClient(store: store).loadSnapshot()
        XCTAssertEqual(snapshot.usage?.shortWindow?.remainingPercent, 79)
        XCTAssertEqual(store.value?.accessToken, "new-access")
        XCTAssertEqual(store.value?.refreshToken, "new-refresh")
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
    }

    func testResetCreditsDecodeSnakeCaseAndISO8601Dates() throws {
        let store = MemoryCredentialStore(credentials())
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/backend-api/wham/rate-limit-reset-credits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "codex-1")
            return (200, Data(#"{
              "available_count":1,
              "credits":[{
                "id":"credit-1",
                "reset_type":"codex_rate_limits",
                "status":"available",
                "granted_at":"2026-11-15T12:00:00Z",
                "expires_at":"2026-12-15T12:00:00.123Z",
                "title":"Full reset",
                "description":"Restore eligible Codex windows"
              }]
            }"#.utf8))
        }

        let result = try makeClient(store: store).loadResetCredits()
        XCTAssertEqual(result.availableCount, 1)
        XCTAssertEqual(result.credits?.first?.id, "credit-1")
        XCTAssertEqual(result.credits?.first?.resetType, "codex_rate_limits")
        XCTAssertEqual(result.credits?.first?.title, "Full reset")
        XCTAssertEqual(result.credits?.first?.expiresAt?.timeIntervalSince1970, 1_765_796_400.123, accuracy: 0.01)
    }

    func testResetCreditsSupportCountWithoutCardDetails() throws {
        let store = MemoryCredentialStore(credentials())
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"available_count":3,"credits":null}"#.utf8))
        }
        let result = try makeClient(store: store).loadResetCredits()
        XCTAssertEqual(result.availableCount, 3)
        XCTAssertNil(result.credits)
    }

    func testConsumeUsesPersistedIdempotencyKeyAndMapsBackendOutcome() throws {
        let store = MemoryCredentialStore(credentials())
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/backend-api/wham/rate-limit-reset-credits/consume")
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String]
            XCTAssertEqual(body?["redeem_request_id"], "attempt-123")
            XCTAssertEqual(body?["credit_id"], "credit-1")
            return (200, Data(#"{"code":"already_redeemed","windows_reset":0}"#.utf8))
        }

        let result = try makeClient(store: store).consumeResetCredit(
            creditID: "credit-1",
            idempotencyKey: "attempt-123"
        )
        XCTAssertEqual(result, .alreadyRedeemed)
    }

    func testConsumeOmitsCreditIDWhenUsingNextAvailableCredit() throws {
        let store = MemoryCredentialStore(credentials())
        StubURLProtocol.handler = { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String]
            XCTAssertEqual(body?["redeem_request_id"], "attempt-456")
            XCTAssertNil(body?["credit_id"])
            return (200, Data(#"{"code":"reset","windows_reset":2}"#.utf8))
        }
        XCTAssertEqual(
            try makeClient(store: store).consumeResetCredit(creditID: nil, idempotencyKey: "attempt-456"),
            .reset
        )
    }

    func testPKCEAuthorizationURLIncludesRequiredSecurityParameters() throws {
        let pair = CodexOAuthCore.pkcePair()
        let expected = Data(SHA256.hash(data: Data(pair.verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(pair.challenge, expected)

        let url = CodexOAuthCore.authorizationURL(challenge: pair.challenge, state: "state-123")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["code_challenge"], pair.challenge)
        XCTAssertEqual(query["state"], "state-123")
        XCTAssertEqual(query["redirect_uri"], CodexOAuthCore.redirectURI)
    }

    func testJWTClaimsExtractChatGPTAccountIdentity() throws {
        let payload: [String: Any] = [
            "email": "demo@example.com",
            "exp": 1_800_000_000,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account-123",
                "chatgpt_plan_type": "pro"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(encoded).signature"
        let response = OAuthTokenResponse(accessToken: token, refreshToken: "refresh", idToken: token, expiresIn: nil)
        let claims = CodexOAuthCore.accountClaims(from: response)
        XCTAssertEqual(claims.accountID, "account-123")
        XCTAssertEqual(claims.email, "demo@example.com")
        XCTAssertEqual(claims.planType, "pro")
        XCTAssertEqual(claims.expiresAt?.timeIntervalSince1970, 1_800_000_000)
    }
}
