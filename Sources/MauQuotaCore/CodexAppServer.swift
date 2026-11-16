import Foundation
#if os(macOS)
import SystemConfiguration
#endif

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Non-secret account metadata returned by the official Codex app-server.
public struct CodexAccount: Equatable {
    public let type: String
    public let email: String?
    public let planType: String?

    public var isChatGPT: Bool { type == "chatgpt" }
    public var label: String {
        if isChatGPT { return "ChatGPT" + (planType.map { " · \($0.capitalized)" } ?? "") }
        if type == "apiKey" { return "API Key" }
        return type
    }
}

public struct CodexSnapshot {
    public let account: CodexAccount?
    public let usage: CodexUsage?
    public let quotaError: String?
}

/// A banked Codex usage reset returned by the official App Server.
public struct CodexResetCredit: Equatable, Identifiable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: Date
    public let expiresAt: Date?
    public let title: String?
    public let description: String?
}

/// A nil credits array means the service returned only the authoritative count.
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

/// Uses Codex's supported browser OAuth flow and its app-server account/usage RPCs.
/// The app neither requests passwords nor handles tokens.
public final class CodexAppServer {
    public enum ClientError: LocalizedError {
        case missingRuntime
        case cannotStart
        case writeFailed
        case readFailed
        case timeout
        case unexpectedEOF
        case oversizedResponse
        case invalidHandshake
        case invalidResponse
        case rateLimitUnavailable
        case loginInvalidURL
        case loginRejected
        case loginFailed
        case browserOpenFailed
        case requestRejected(Int?)
        case chatGPTAuthRequired
        case resetCreditsUnavailable

        public var errorDescription: String? {
            switch self {
            case .missingRuntime: return "未找到可用的 Codex App Server 运行组件，请重新安装 MauQuota"
            case .cannotStart: return "无法启动 Codex App Server，请检查应用完整性和执行权限"
            case .writeFailed: return "Codex 连接已断开（写入失败）"
            case .readFailed: return "读取 Codex 数据时发生系统错误"
            case .timeout: return "连接超时，请检查网络、登录状态或代理"
            case .unexpectedEOF: return "Codex App Server 提前退出（可能是版本或运行环境问题）"
            case .oversizedResponse: return "Codex 返回的数据过大"
            case .invalidHandshake: return "Codex 初始化失败，请更新 MauQuota"
            case .invalidResponse: return "Codex 返回了不兼容的账号数据"
            case .rateLimitUnavailable: return "已连接，但服务没有返回可识别的额度"
            case .loginInvalidURL: return "Codex 返回了不安全或无效的登录地址"
            case .loginRejected: return "官方 Codex App Server 未提供浏览器登录地址，请更新 MauQuota"
            case .loginFailed: return "浏览器授权未完成或登录失败，可重新尝试"
            case .browserOpenFailed: return "无法打开系统浏览器，请检查默认浏览器设置后重试"
            case .requestRejected(let code): return "Codex 拒绝请求（错误码：\(code.map(String.init) ?? "未知")）"
            case .chatGPTAuthRequired: return "使用重置额度需要先登录 ChatGPT 账号"
            case .resetCreditsUnavailable: return "Codex 当前没有提供重置额度详情，请稍后刷新"
            }
        }
    }

    private let timeoutSeconds: TimeInterval
    private let cliExecutable: String?
    private let bundledAppServerExecutable: String?

    public init(timeoutSeconds: TimeInterval = 30,
                cliExecutable: String? = nil,
                bundledAppServerExecutable: String? = nil) {
        self.timeoutSeconds = max(0.1, timeoutSeconds)
        self.cliExecutable = cliExecutable
        self.bundledAppServerExecutable = bundledAppServerExecutable
    }

    public var resolvedRuntimePath: String? { findRuntime()?.executable }
    public var resolvedRuntimeSource: String? { findRuntime()?.source }

    /// Login status and quotas are checked separately: a quota failure will not hide a valid login.
    public func loadSnapshot() throws -> CodexSnapshot {
        try withSession(timeout: timeoutSeconds) { session in
            let response = try session.request(id: 2, method: "account/read", params: ["refreshToken": false])
            let result = try Self.checkedResult(response)
            guard result.keys.contains("account") else { throw ClientError.invalidResponse }
            guard let accountObject = result["account"] as? [String: Any] else {
                // `account: null` is the official not-signed-in response.
                return CodexSnapshot(account: nil, usage: nil, quotaError: nil)
            }
            guard let type = accountObject["type"] as? String else { throw ClientError.invalidResponse }
            let account = CodexAccount(type: type,
                                       email: accountObject["email"] as? String,
                                       planType: accountObject["planType"] as? String)
            guard account.isChatGPT else {
                return CodexSnapshot(account: account, usage: nil,
                                     quotaError: "当前是 \(account.label) 认证；订阅额度需要 ChatGPT 登录")
            }
            do {
                let usage = try session.request(id: 3, method: "account/rateLimits/read")
                _ = try Self.checkedResult(usage)
                return CodexSnapshot(account: account,
                                     usage: try Self.parseQuota(usage), quotaError: nil)
            } catch {
                return CodexSnapshot(account: account, usage: nil, quotaError: error.localizedDescription)
            }
        }
    }

    /// Retained for existing integrations and unit tests.
    public func loadUsage() throws -> CodexUsage {
        try withSession(timeout: timeoutSeconds) { session in
            let response = try session.request(id: 2, method: "account/rateLimits/read")
            _ = try Self.checkedResult(response)
            return try Self.parseQuota(response)
        }
    }

    /// Reads banked reset credits using the official account/rateLimits/read response.
    public func loadResetCredits() throws -> CodexResetCredits {
        try withSession(timeout: timeoutSeconds) { session in
            let accountResponse = try session.request(
                id: 2, method: "account/read", params: ["refreshToken": false]
            )
            let accountResult = try Self.checkedResult(accountResponse)
            guard let account = accountResult["account"] as? [String: Any],
                  account["type"] as? String == "chatgpt" else {
                throw ClientError.chatGPTAuthRequired
            }
            let response = try session.request(id: 3, method: "account/rateLimits/read")
            return try Self.parseResetCredits(response)
        }
    }

    /// Consumes exactly the selected reset credit. Reuse the same idempotency key
    /// if the outcome of a network request is uncertain.
    public func consumeResetCredit(creditID: String?,
                                   idempotencyKey: String) throws -> CodexResetConsumeOutcome {
        guard !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              creditID?.isEmpty != true else {
            throw ClientError.invalidResponse
        }
        return try withSession(timeout: timeoutSeconds) { session in
            let accountResponse = try session.request(
                id: 2, method: "account/read", params: ["refreshToken": false]
            )
            let accountResult = try Self.checkedResult(accountResponse)
            guard let account = accountResult["account"] as? [String: Any],
                  account["type"] as? String == "chatgpt" else {
                throw ClientError.chatGPTAuthRequired
            }
            let params = Self.resetConsumeParams(creditID: creditID, idempotencyKey: idempotencyKey)
            let response = try session.request(
                id: 3, method: "account/rateLimitResetCredit/consume", params: params
            )
            let result = try Self.checkedResult(response)
            guard let rawOutcome = result["outcome"] as? String,
                  let outcome = CodexResetConsumeOutcome(rawValue: rawOutcome) else {
                throw ClientError.invalidResponse
            }
            return outcome
        }
    }

    /// Browser login: Codex starts a localhost OAuth callback listener and owns all credentials.
    /// `openURL` must hand the URL to a genuine system browser, not an embedded web view.
    public func loginWithChatGPT(openURL: (URL) -> Bool) throws {
        try withSession(timeout: timeoutSeconds) { session in
            let response = try session.request(id: 2, method: "account/login/start", params: ["type": "chatgpt"])
            let result = try Self.checkedResult(response)
            guard let urlText = result["authUrl"] as? String,
                  let url = URL(string: urlText),
                  Self.isTrustedLoginURL(url) else { throw ClientError.loginInvalidURL }
            guard let loginId = result["loginId"] as? String, !loginId.isEmpty else {
                throw ClientError.loginRejected
            }
            session.extendDeadline(to: 10 * 60)
            guard openURL(url) else { throw ClientError.browserOpenFailed }
            while true {
                let notification = try session.nextNotification(method: "account/login/completed")
                guard let params = notification["params"] as? [String: Any],
                      params["loginId"] as? String == loginId else { continue }
                guard params["success"] as? Bool == true else { throw ClientError.loginFailed }
                return
            }
        }
    }

    public static func isTrustedLoginURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else { return false }
        return ["chatgpt.com", "openai.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func parseQuota(_ response: [String: Any]) throws -> CodexUsage {
        guard let raw = try? JSONSerialization.data(withJSONObject: response),
              let usage = try? UsageParser.parseResponse(raw) else { throw ClientError.rateLimitUnavailable }
        return usage
    }

    static func resetConsumeParams(creditID: String?, idempotencyKey: String) -> [String: Any] {
        var params: [String: Any] = ["idempotencyKey": idempotencyKey]
        if let creditID { params["creditId"] = creditID }
        return params
    }

    private static func parseResetCredits(_ response: [String: Any]) throws -> CodexResetCredits {
        let result = try checkedResult(response)
        guard let summary = result["rateLimitResetCredits"] as? [String: Any],
              let countValue = summary["availableCount"] as? NSNumber else {
            throw ClientError.resetCreditsUnavailable
        }
        let count = countValue.intValue
        guard count >= 0 else { throw ClientError.invalidResponse }

        guard let rawCredits = summary["credits"], !(rawCredits is NSNull) else {
            return CodexResetCredits(availableCount: count, credits: nil)
        }
        guard let rows = rawCredits as? [[String: Any]] else { throw ClientError.invalidResponse }
        let credits = try rows.map { row -> CodexResetCredit in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let resetType = row["resetType"] as? String, !resetType.isEmpty,
                  let status = row["status"] as? String, !status.isEmpty,
                  let grantedAtValue = row["grantedAt"] as? NSNumber,
                  grantedAtValue.doubleValue.isFinite, grantedAtValue.doubleValue > 0 else {
                throw ClientError.invalidResponse
            }
            let expiry: Date?
            if let rawExpiry = row["expiresAt"], !(rawExpiry is NSNull) {
                guard let value = rawExpiry as? NSNumber,
                      value.doubleValue.isFinite, value.doubleValue > 0 else {
                    throw ClientError.invalidResponse
                }
                expiry = Date(timeIntervalSince1970: value.doubleValue)
            } else {
                expiry = nil
            }
            return CodexResetCredit(
                id: id,
                resetType: resetType,
                status: status,
                grantedAt: Date(timeIntervalSince1970: grantedAtValue.doubleValue),
                expiresAt: expiry,
                title: row["title"] as? String,
                description: row["description"] as? String
            )
        }
        return CodexResetCredits(availableCount: count, credits: credits)
    }

    private static func checkedResult(_ response: [String: Any]) throws -> [String: Any] {
        if let error = response["error"] as? [String: Any] {
            throw ClientError.requestRejected((error["code"] as? NSNumber)?.intValue)
        }
        guard let result = response["result"] as? [String: Any] else { throw ClientError.invalidResponse }
        return result
    }

    private func withSession<T>(timeout: TimeInterval, body: (CodexSession) throws -> T) throws -> T {
        guard let resolved = findRuntime() else { throw ClientError.missingRuntime }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved.executable)
        process.arguments = resolved.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = resolved.path
        Self.applyMacOSSystemProxy(to: &environment)
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let stopped = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in stopped.signal() }
        do { try process.run() } catch { throw ClientError.cannotStart }
        defer { Self.cleanup(process, stdin: stdin, stdout: stdout, stopped: stopped) }

        let session = CodexSession(input: stdin.fileHandleForWriting,
                                   output: stdout.fileHandleForReading,
                                   deadline: ProcessInfo.processInfo.systemUptime + timeout)
        let initResponse = try session.request(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "mauquota_macos", "title": "MauQuota", "version": "1.8.6-preview.4"],
            "capabilities": [:]
        ])
        guard initResponse["result"] is [String: Any] else { throw ClientError.invalidHandshake }
        try session.notify(method: "initialized", params: [:])
        return try body(session)
    }

    /// Finder apps do not inherit .zshrc proxy exports. When a static system proxy
    /// is enabled, propagate it to the Rust Codex subprocess, without overwriting
    /// explicitly supplied environment variables. PAC is intentionally not guessed.
    private static func applyMacOSSystemProxy(to environment: inout [String: String]) {
        #if os(macOS)
        guard let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return }
        func proxy(enabled: String, host: String, port: String, scheme: String) -> String? {
            guard (settings[enabled] as? NSNumber)?.intValue == 1,
                  let address = settings[host] as? String, !address.isEmpty,
                  let numericPort = (settings[port] as? NSNumber)?.intValue,
                  (1...65535).contains(numericPort) else { return nil }
            // Proxy hostnames should not include user info, paths or fragments.
            var components = URLComponents()
            components.scheme = scheme
            components.host = address
            components.port = numericPort
            return components.url?.absoluteString
        }
        if environment["HTTP_PROXY"] == nil && environment["http_proxy"] == nil {
            environment["HTTP_PROXY"] = proxy(enabled: kSCPropNetProxiesHTTPEnable as String,
                host: kSCPropNetProxiesHTTPProxy as String, port: kSCPropNetProxiesHTTPPort as String,
                scheme: "http")
        }
        if environment["HTTPS_PROXY"] == nil && environment["https_proxy"] == nil {
            environment["HTTPS_PROXY"] = proxy(enabled: kSCPropNetProxiesHTTPSEnable as String,
                host: kSCPropNetProxiesHTTPSProxy as String, port: kSCPropNetProxiesHTTPSPort as String,
                scheme: "http")
        }
        if environment["ALL_PROXY"] == nil && environment["all_proxy"] == nil {
            environment["ALL_PROXY"] = proxy(enabled: kSCPropNetProxiesSOCKSEnable as String,
                host: kSCPropNetProxiesSOCKSProxy as String, port: kSCPropNetProxiesSOCKSPort as String,
                scheme: "socks5h")
        }
        #endif
    }

    private static func cleanup(_ process: Process, stdin: Pipe, stdout: Pipe, stopped: DispatchSemaphore) {
        try? stdin.fileHandleForWriting.close()
        if stopped.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
            if process.isRunning { process.terminate() }
            if stopped.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                _ = stopped.wait(timeout: .now() + .milliseconds(600))
            }
        }
        try? stdout.fileHandleForReading.close()
    }

    private func findRuntime() -> (executable: String, path: String, source: String, arguments: [String])? {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/sbin",
            "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin",
            "\(home)/.bun/bin", "\(home)/.local/share/pnpm",
            "\(home)/Library/pnpm", "\(home)/.asdf/shims",
            "\(home)/.hermes/node/bin", "\(home)/.codex/bin",
            "\(home)/.local/share/mise/shims"
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            directories += versions.sorted().reversed().map { "\(nvm)/\($0)/bin" }
        }
        var visited = Set<String>()
        directories = directories.filter { visited.insert($0).inserted }

        if let cliExecutable, FileManager.default.isExecutableFile(atPath: cliExecutable) {
            return (cliExecutable, directories.joined(separator: ":"), "explicit Codex CLI", ["app-server", "--stdio"])
        }
        if let explicit = env["CODEXMETER_CODEX_PATH"],
           FileManager.default.isExecutableFile(atPath: explicit) {
            return (explicit, directories.joined(separator: ":"), "environment override", ["app-server", "--stdio"])
        }

        // Prefer the official standalone App Server binary bundled in MauQuota.
        let bundled = bundledAppServerExecutable
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/codex-app-server").path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            let helperDirectory = URL(fileURLWithPath: bundled).deletingLastPathComponent().path
            let runtimePath = ([helperDirectory] + directories).joined(separator: ":")
            return (bundled, runtimePath, "bundled App Server", ["--listen", "stdio://"])
        }

        // Retain compatibility with existing Codex CLI installations.
        let path = directories.joined(separator: ":")
        for directory in directories {
            let candidate = "\(directory)/codex"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return (candidate, path, "system Codex CLI", ["app-server", "--stdio"])
            }
        }
        return nil
    }
}

/// Strictly newline-delimited JSON-RPC. Reads never block indefinitely.
private final class CodexSession {
    private let input: FileHandle
    private let output: FileHandle
    private var deadline: TimeInterval
    private var buffer = Data()
    private let maxBytes = 2 * 1024 * 1024
    private var notifications = [[String: Any]]()

    init(input: FileHandle, output: FileHandle, deadline: TimeInterval) {
        self.input = input
        self.output = output
        self.deadline = deadline
    }

    func extendDeadline(to seconds: TimeInterval) {
        deadline = ProcessInfo.processInfo.systemUptime + seconds
    }

    func notify(method: String, params: [String: Any]) throws {
        try send(["method": method, "params": params])
    }

    func request(id: Int, method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)
        while true {
            let reply = try readLine()
            if let responseId = reply["id"] as? NSNumber, responseId.intValue == id {
                return reply
            }
            if reply["method"] is String {
                notifications.append(reply)
                if notifications.count > 100 { notifications.removeFirst() }
            }
        }
    }

    func nextNotification(method: String) throws -> [String: Any] {
        while true {
            if let index = notifications.firstIndex(where: { $0["method"] as? String == method }) {
                return notifications.remove(at: index)
            }
            let message = try readLine()
            if message["method"] as? String == method { return message }
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else {
            throw CodexAppServer.ClientError.writeFailed
        }
        data.append(0x0A)
        // SIGPIPE is ignored in the macOS entry point to convert broken pipes to errors.
        do { try input.write(contentsOf: data) }
        catch { throw CodexAppServer.ClientError.writeFailed }
    }

    private func readLine() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let dict = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    return dict
                }
                continue
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CodexAppServer.ClientError.timeout }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let millis = Int32(min(1000, max(1, remaining * 1000)))
            let ready = poll(&descriptor, 1, millis)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw CodexAppServer.ClientError.readFailed
            }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = chunk.withUnsafeMutableBytes { pointer in
                read(output.fileDescriptor, pointer.baseAddress, pointer.count)
            }
            if count == 0 { throw CodexAppServer.ClientError.unexpectedEOF }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CodexAppServer.ClientError.readFailed
            }
            buffer.append(contentsOf: chunk.prefix(count))
            if buffer.count > maxBytes { throw CodexAppServer.ClientError.oversizedResponse }
        }
    }
}
