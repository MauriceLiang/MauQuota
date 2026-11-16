import Foundation
import CryptoKit
import Network
import Security
import Darwin

public struct CodexAccount: Equatable {
    public let type: String
    public let email: String?
    public let planType: String?

    public var isChatGPT: Bool { type == "chatgpt" }
    public var label: String {
        if isChatGPT {
            let plan = CodexPlan.displayName(for: planType)
            return "ChatGPT" + (plan.map { " · \($0)" } ?? "")
        }
        return type
    }
}

public struct CodexSnapshot {
    public let account: CodexAccount?
    public let usage: CodexUsage?
    public let quotaError: String?
}

public struct CodexResetCredit: Equatable, Identifiable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: Date
    public let expiresAt: Date?
    public let title: String?
    public let description: String?
}

public struct CodexResetCredits: Equatable {
    public let availableCount: Int
    public let credits: [CodexResetCredit]?
}

public enum CodexResetConsumeOutcome: String, Equatable {
    case reset
    case alreadyRedeemed
    case nothingToReset
    case noCredit
}

struct CodexOAuthCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var accountID: String
    var email: String?
    var planType: String?
    var expiresAt: Date?
}

protocol CodexCredentialStore {
    func load() throws -> CodexOAuthCredentials?
    func save(_ credentials: CodexOAuthCredentials) throws
    func delete() throws
}

private final class KeychainCredentialStore: CodexCredentialStore {
    private let service = "dev.mau.mauquota.chatgpt-oauth"
    private let account = "primary"

    func load() throws -> CodexOAuthCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CodexAPIClient.ClientError.keychain(status)
        }
        do {
            return try JSONDecoder().decode(CodexOAuthCredentials.self, from: data)
        } catch {
            throw CodexAPIClient.ClientError.invalidStoredCredentials
        }
    }

    func save(_ credentials: CodexOAuthCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CodexAPIClient.ClientError.keychain(updateStatus)
        }
        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CodexAPIClient.ClientError.keychain(addStatus)
        }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexAPIClient.ClientError.keychain(status)
        }
    }
}

struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

enum CodexOAuthCore {
    static let issuer = URL(string: "https://auth.openai.com")!
    // This is the public OAuth client identifier currently used by Codex CLI.
    // It is not a client secret or a guarantee of a supported third-party API.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let callbackPort: UInt16 = 1455
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let callbackPath = "/auth/callback"
    static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    static func randomURLSafeString(byteCount: Int = 64) -> String {
        Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }).base64URLString
    }

    static func pkcePair() -> (verifier: String, challenge: String) {
        let verifier = randomURLSafeString()
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return (verifier, Data(digest).base64URLString)
    }

    static func authorizationURL(challenge: String, state: String) -> URL {
        var components = URLComponents(url: issuer.appendingPathComponent("oauth/authorize"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "codex_cli_rs")
        ]
        return components.url!
    }

    static func formEncoded(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func authorizationCodeBody(code: String, verifier: String) -> Data {
        formEncoded([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier)
        ])
    }

    static func refreshBody(refreshToken: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email"
        ])
    }

    static func jwtClaims(_ token: String?) -> [String: Any] {
        guard let token else { return [:] }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 { encoded += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    static func accountClaims(from tokens: OAuthTokenResponse) -> (accountID: String?, email: String?, planType: String?, expiresAt: Date?) {
        let idClaims = jwtClaims(tokens.idToken)
        let accessClaims = jwtClaims(tokens.accessToken)
        let claims = idClaims.isEmpty ? accessClaims : idClaims
        let idAuth = idClaims["https://api.openai.com/auth"] as? [String: Any]
        let accessAuth = accessClaims["https://api.openai.com/auth"] as? [String: Any]
        let auth = idAuth ?? accessAuth ?? [:]
        let accountID = (auth["chatgpt_account_id"] as? String)
            ?? (auth["account_id"] as? String)
        let planType = (auth["chatgpt_plan_type"] as? String)
            ?? (auth["plan_type"] as? String)
        let email = claims["email"] as? String
        let expiry = (accessClaims["exp"] as? NSNumber)?.doubleValue
        let expiresAt = expiry.map(Date.init(timeIntervalSince1970:))
            ?? tokens.expiresIn.map { Date().addingTimeInterval($0) }
        return (accountID, email, planType, expiresAt)
    }

    static func refreshedCredentials(_ old: CodexOAuthCredentials,
                                     response: OAuthTokenResponse) -> CodexOAuthCredentials {
        let claims = accountClaims(from: response)
        let idClaims = jwtClaims(response.idToken)
        let accessClaims = jwtClaims(response.accessToken)
        let auth = (idClaims["https://api.openai.com/auth"] as? [String: Any])
            ?? (accessClaims["https://api.openai.com/auth"] as? [String: Any])
            ?? [:]
        let accountID = (auth["chatgpt_account_id"] as? String)
            ?? (auth["account_id"] as? String)
            ?? old.accountID
        return CodexOAuthCredentials(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? old.refreshToken,
            idToken: response.idToken ?? old.idToken,
            accountID: accountID,
            email: claims.email ?? old.email,
            planType: claims.planType ?? old.planType,
            expiresAt: claims.expiresAt
        )
    }
}

private extension Data {
    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public final class CodexAPIClient {
    public enum ClientError: LocalizedError {
        case notAuthenticated
        case reauthenticationRequired
        case unauthorized
        case httpStatus(Int)
        case network(String)
        case timeout
        case invalidResponse
        case invalidStoredCredentials
        case missingAccountID
        case keychain(OSStatus)
        case callbackPortBusy
        case callbackListener(String)
        case callbackTimeout
        case stateMismatch
        case providerRejected(String)
        case tokenExchange(Int)
        case browserOpenFailed
        case resetCreditsUnavailable

        public var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "当前尚未登录 ChatGPT，请先登录。"
            case .reauthenticationRequired, .unauthorized:
                return "ChatGPT 登录已过期或授权失效，请重新登录。"
            case .httpStatus(403):
                return "ChatGPT 后端拒绝了请求（HTTP 403），可能是账号权限或接口策略发生变化。"
            case .httpStatus(429):
                return "请求过于频繁（HTTP 429），请稍后重试。"
            case .httpStatus(let code):
                return "额度服务请求失败（HTTP \(code)）。"
            case .network(let message):
                return "网络请求失败：\(message)"
            case .timeout:
                return "请求超时，请检查网络或代理后重试。"
            case .invalidResponse:
                return "ChatGPT 返回了不兼容的数据格式。"
            case .invalidStoredCredentials:
                return "本机保存的 ChatGPT 登录凭据无法读取，请重新登录。"
            case .missingAccountID:
                return "OAuth 授权没有返回 ChatGPT 账号标识，无法查询额度。"
            case .keychain(let status):
                return "无法安全读取或保存 ChatGPT 登录凭据（Keychain 错误 \(status)）。"
            case .callbackPortBusy:
                return "本地 OAuth 回调端口 1455 已被占用，请关闭占用该端口的程序后重试。"
            case .callbackListener(let message):
                return "无法启动本地 OAuth 回调服务：\(message)"
            case .callbackTimeout:
                return "浏览器授权等待超时，请重新尝试。"
            case .stateMismatch:
                return "OAuth 授权校验失败（state 不匹配），请重新登录。"
            case .providerRejected(let message):
                return "ChatGPT OAuth 授权失败：\(message)"
            case .tokenExchange(let code):
                return "无法交换 OAuth Token（HTTP \(code)）。"
            case .browserOpenFailed:
                return "无法打开系统浏览器，请检查默认浏览器设置后重试。"
            case .resetCreditsUnavailable:
                return "ChatGPT 当前没有返回可用的重置额度详情，请稍后刷新。"
            }
        }
    }

    private let timeoutSeconds: TimeInterval
    private let session: URLSession
    private let credentialStore: CodexCredentialStore
    private let requestObserver: ((URLRequest) -> Void)?
    private let refreshLock = NSLock()
    private let baseURL = URL(string: "https://chatgpt.com/backend-api/")!

    public init(timeoutSeconds: TimeInterval = 25) {
        let timeout = max(1, timeoutSeconds)
        self.timeoutSeconds = timeout
        self.session = URLSession(
            configuration: Self.makeSessionConfiguration(timeoutSeconds: timeout)
        )
        self.credentialStore = KeychainCredentialStore()
        self.requestObserver = nil
    }

    /// Creates a session for a token-based API client. MauQuota does not use
    /// cookies, HTTP authentication caches, or response caching.
    static func makeSessionConfiguration(timeoutSeconds: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = max(1, timeoutSeconds)
        configuration.timeoutIntervalForResource = max(3, timeoutSeconds + 2)
        return configuration
    }

    init(timeoutSeconds: TimeInterval = 25,
         session: URLSession,
         credentialStore: CodexCredentialStore,
         requestObserver: ((URLRequest) -> Void)? = nil) {
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.session = session
        self.credentialStore = credentialStore
        self.requestObserver = requestObserver
    }

    public var hasStoredCredentials: Bool {
        (try? credentialStore.load()) != nil
    }

    public func logout() throws {
        try credentialStore.delete()
    }

    /// Cancels outstanding requests and releases this client's session resources.
    /// Called when the menu bar application is terminating.
    public func invalidateSession() {
        session.invalidateAndCancel()
    }

    public func loadSnapshot() throws -> CodexSnapshot {
        guard let credentials = try credentialStore.load() else {
            return CodexSnapshot(account: nil, usage: nil, quotaError: nil)
        }
        let account = CodexAccount(type: "chatgpt", email: credentials.email, planType: credentials.planType)
        do {
            let data = try authenticatedRequest(path: "wham/usage", method: "GET", body: nil)
            let plan = Self.planType(from: data) ?? credentials.planType
            let usage = try UsageParser.parseResponse(data, planType: plan)
            let updatedAccount = CodexAccount(type: "chatgpt", email: credentials.email, planType: plan)
            return CodexSnapshot(account: updatedAccount, usage: usage, quotaError: nil)
        } catch {
            return CodexSnapshot(account: account, usage: nil, quotaError: error.localizedDescription)
        }
    }

    public func loginWithChatGPT(openURL: (URL) -> Bool) throws {
        let pkce = CodexOAuthCore.pkcePair()
        let state = CodexOAuthCore.randomURLSafeString(byteCount: 32)
        let callbackServer = try OAuthCallbackServer(port: CodexOAuthCore.callbackPort, expectedState: state)
        defer { callbackServer.stop() }
        try callbackServer.start()

        let url = CodexOAuthCore.authorizationURL(challenge: pkce.challenge, state: state)
        guard openURL(url) else { throw ClientError.browserOpenFailed }
        let callback = try callbackServer.waitForCallback(timeout: 600)
        if let error = callback["error"] {
            throw ClientError.providerRejected(callback["error_description"] ?? error)
        }
        guard callback["state"] == state else { throw ClientError.stateMismatch }
        guard let code = callback["code"], !code.isEmpty else {
            throw ClientError.invalidResponse
        }

        let tokenResponse = try exchangeAuthorizationCode(code, verifier: pkce.verifier)
        let claims = CodexOAuthCore.accountClaims(from: tokenResponse)
        guard let accountID = claims.accountID, !accountID.isEmpty else {
            throw ClientError.missingAccountID
        }
        let credentials = CodexOAuthCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            idToken: tokenResponse.idToken,
            accountID: accountID,
            email: claims.email,
            planType: claims.planType,
            expiresAt: claims.expiresAt
        )
        try credentialStore.save(credentials)
    }

    public func loadResetCredits() throws -> CodexResetCredits {
        let data = try authenticatedRequest(path: "wham/rate-limit-reset-credits", method: "GET", body: nil)
        return try Self.parseResetCredits(data)
    }

    public func consumeResetCredit(creditID: String?,
                                   idempotencyKey: String) throws -> CodexResetConsumeOutcome {
        guard !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              creditID?.isEmpty != true else {
            throw ClientError.invalidResponse
        }
        var body: [String: Any] = ["redeem_request_id": idempotencyKey]
        if let creditID { body["credit_id"] = creditID }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let response = try authenticatedRequest(
            path: "wham/rate-limit-reset-credits/consume",
            method: "POST",
            body: data
        )
        guard let root = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let code = root["code"] as? String else {
            throw ClientError.invalidResponse
        }
        switch code {
        case "reset": return .reset
        case "already_redeemed": return .alreadyRedeemed
        case "nothing_to_reset": return .nothingToReset
        case "no_credit": return .noCredit
        default: throw ClientError.invalidResponse
        }
    }

    private func exchangeAuthorizationCode(_ code: String, verifier: String) throws -> OAuthTokenResponse {
        var request = URLRequest(url: URL(string: "oauth/token", relativeTo: CodexOAuthCore.issuer)!.absoluteURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = CodexOAuthCore.authorizationCodeBody(code: code, verifier: verifier)
        let data = try perform(request)
        do {
            let response = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
            guard !response.accessToken.isEmpty else { throw ClientError.invalidResponse }
            return response
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.invalidResponse
        }
    }

    private func refreshCredentials(_ credentials: CodexOAuthCredentials) throws -> CodexOAuthCredentials {
        refreshLock.lock()
        defer { refreshLock.unlock() }

        // Another in-flight request may already have rotated this refresh token.
        if let latest = try credentialStore.load(),
           latest.accessToken != credentials.accessToken || latest.refreshToken != credentials.refreshToken {
            return latest
        }
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw ClientError.reauthenticationRequired
        }
        var request = URLRequest(url: CodexOAuthCore.issuer.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try CodexOAuthCore.refreshBody(refreshToken: refreshToken)
        let data = try perform(request)
        let response: OAuthTokenResponse
        do {
            response = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        } catch {
            throw ClientError.invalidResponse
        }
        guard !response.accessToken.isEmpty else { throw ClientError.invalidResponse }
        let updated = CodexOAuthCore.refreshedCredentials(credentials, response: response)
        try credentialStore.save(updated)
        return updated
    }

    private func authenticatedRequest(path: String,
                                      method: String,
                                      body: Data?) throws -> Data {
        guard var credentials = try credentialStore.load() else { throw ClientError.notAuthenticated }
        if let expiry = credentials.expiresAt, expiry <= Date().addingTimeInterval(60) {
            credentials = try refreshCredentials(credentials)
        }
        do {
            return try perform(authenticatedURLRequest(path: path, method: method, body: body,
                                                       credentials: credentials))
        } catch ClientError.unauthorized {
            credentials = try refreshCredentials(credentials)
            // Retry once with the rotated token. A POST uses the same persisted idempotency key.
            return try perform(authenticatedURLRequest(path: path, method: method, body: body,
                                                       credentials: credentials))
        }
    }

    private func authenticatedURLRequest(path: String,
                                         method: String,
                                         body: Data?,
                                         credentials: CodexOAuthCredentials) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        request.httpMethod = method
        request.timeoutInterval = timeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("MauQuota/2.1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if path.contains("rate-limit-reset-credits") {
            request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest) throws -> Data {
        requestObserver?(request)
        let semaphore = DispatchSemaphore(value: 0)
        var receivedData: Data?
        var receivedResponse: URLResponse?
        var receivedError: Error?
        let task = session.dataTask(with: request) { data, response, error in
            receivedData = data
            receivedResponse = response
            receivedError = error
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + request.timeoutInterval + 2) == .success else {
            task.cancel()
            throw ClientError.timeout
        }
        if let error = receivedError {
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut { throw ClientError.timeout }
            throw ClientError.network(error.localizedDescription)
        }
        guard let response = receivedResponse as? HTTPURLResponse,
              let data = receivedData else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw ClientError.unauthorized }
            throw ClientError.httpStatus(response.statusCode)
        }
        guard data.count <= 2 * 1_024 * 1_024 else { throw ClientError.invalidResponse }
        return data
    }

    private static func planType(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["plan_type"] as? String) ?? (root["planType"] as? String)
    }

    private static func parseResetCredits(_ data: Data) throws -> CodexResetCredits {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = (root["available_count"] as? NSNumber)?.intValue,
              count >= 0 else {
            throw ClientError.resetCreditsUnavailable
        }
        guard let rawCredits = root["credits"], !(rawCredits is NSNull) else {
            return CodexResetCredits(availableCount: count, credits: nil)
        }
        guard let rows = rawCredits as? [[String: Any]] else { throw ClientError.invalidResponse }
        let credits = try rows.map { row -> CodexResetCredit in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let resetType = row["reset_type"] as? String, !resetType.isEmpty,
                  let status = row["status"] as? String, !status.isEmpty,
                  let grantedAtText = row["granted_at"] as? String,
                  let grantedAt = Self.parseISO8601(grantedAtText) else {
                throw ClientError.invalidResponse
            }
            let expiresAt: Date?
            if let rawExpiry = row["expires_at"], !(rawExpiry is NSNull) {
                guard let text = rawExpiry as? String,
                      let date = Self.parseISO8601(text) else {
                    throw ClientError.invalidResponse
                }
                expiresAt = date
            } else {
                expiresAt = nil
            }
            return CodexResetCredit(
                id: id,
                resetType: resetType,
                status: status,
                grantedAt: grantedAt,
                expiresAt: expiresAt,
                title: row["title"] as? String,
                description: row["description"] as? String
            )
        }
        return CodexResetCredits(availableCount: count, credits: credits)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private final class OAuthCallbackServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.mau.mauquota.oauth-callback")
    private let expectedState: String
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let callbackSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var startupError: Error?
    private var callbackResult: Result<[String: String], CodexAPIClient.ClientError>?
    private var didFinish = false

    init(port: UInt16, expectedState: String) throws {
        self.expectedState = expectedState
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!
        )
        do {
            listener = try NWListener(using: parameters)
        } catch {
            let nsError = error as NSError
            if nsError.code == Int(EADDRINUSE) {
                throw CodexAPIClient.ClientError.callbackPortBusy
            }
            throw CodexAPIClient.ClientError.callbackListener(error.localizedDescription)
        }
    }

    func start() throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.readySemaphore.signal()
            case .failed(let error):
                self.lock.lock()
                self.startupError = error
                self.lock.unlock()
                self.readySemaphore.signal()
                self.finish(.failure(.callbackListener(error.localizedDescription)))
            default:
                break
            }
        }
        listener.start(queue: queue)
        guard readySemaphore.wait(timeout: .now() + 5) == .success else {
            throw CodexAPIClient.ClientError.callbackListener("等待本地监听端口启动超时")
        }
        lock.lock()
        let error = startupError
        lock.unlock()
        if let error {
            throw CodexAPIClient.ClientError.callbackListener(error.localizedDescription)
        }
    }

    func waitForCallback(timeout: TimeInterval) throws -> [String: String] {
        guard callbackSemaphore.wait(timeout: .now() + timeout) == .success else {
            throw CodexAPIClient.ClientError.callbackTimeout
        }
        lock.lock()
        let result = callbackResult
        lock.unlock()
        guard let result else { throw CodexAPIClient.ClientError.invalidResponse }
        return try result.get()
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let requestText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = requestText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            guard let request = Self.parseRequest(firstLine),
                  request.path == CodexOAuthCore.callbackPath else {
                self.respond(connection, status: "404 Not Found",
                             html: "<h1>Not found</h1>")
                return
            }
            guard request.query["state"] == self.expectedState else {
                self.respond(connection, status: "400 Bad Request",
                             html: "<h1>Authorization state mismatch</h1>")
                return
            }
            if let error = request.query["error"] {
                self.respond(connection, status: "200 OK",
                             html: "<h1>ChatGPT authorization failed</h1><p>You can close this page.</p>")
                self.finish(.failure(.providerRejected(request.query["error_description"] ?? error)))
            } else if request.query["code"] != nil {
                self.respond(connection, status: "200 OK",
                             html: "<h1>ChatGPT authorization completed</h1><p>You can close this page and return to MauQuota.</p>")
                self.finish(.success(request.query))
            } else {
                self.respond(connection, status: "400 Bad Request", html: "<h1>Missing authorization code</h1>")
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, html: String) {
        let body = Data(("<!doctype html><html><head><meta charset=\"utf-8\"><title>MauQuota</title></head><body style=\"font-family:-apple-system,system-ui;padding:48px;text-align:center\">\(html)</body></html>").utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<[String: String], CodexAPIClient.ClientError>) {
        lock.lock()
        guard !didFinish else { lock.unlock(); return }
        didFinish = true
        callbackResult = result
        lock.unlock()
        callbackSemaphore.signal()
    }

    private static func parseRequest(_ line: String) -> (path: String, query: [String: String])? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://localhost\(parts[1])") else {
            return nil
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return (components.path, query)
    }
}
