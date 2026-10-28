import Foundation

public struct QuotaWindow: Equatable {
    public let remainingPercent: Int
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public var label: String {
        guard let minutes = durationMinutes, minutes > 0 else { return "额度" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

public struct CodexUsage: Equatable {
    public let shortWindow: QuotaWindow?
    public let longWindow: QuotaWindow?
    public let fetchedAt: Date

    public var menuBarTitle: String {
        let windows = [shortWindow, longWindow].compactMap { $0 }
        return windows.map { "\($0.label) \($0.remainingPercent)%" }.joined(separator: " · ")
    }
}

public enum UsageParserError: Error, Equatable {
    case invalidJSON
    case missingRateLimits
    case missingWindows
    case serverError
}

/// 只解析公开在 Codex app-server 协议中的额度字段；不处理令牌和账户标识。
public enum UsageParser {
    public static func parseResponse(_ data: Data, now: Date = Date()) throws -> CodexUsage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageParserError.invalidJSON
        }
        if root["error"] != nil { throw UsageParserError.serverError }
        guard let result = root["result"] as? [String: Any] else {
            throw UsageParserError.missingRateLimits
        }

        // 2026 年的新协议支持按配额桶返回多个快照；优先选 Codex 主额度。
        let byID = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        let main = result["rateLimits"] as? [String: Any]
        let selected = byID?["codex"] ?? main ?? (byID?.values.first)
        guard let snapshot = selected else { throw UsageParserError.missingRateLimits }

        let originalWindows: [(QuotaWindow, Int)] = [
            (snapshot["primary"], 0),
            (snapshot["secondary"], 1)
        ].compactMap { entry, index in
            guard let window = parseWindow(entry) else { return nil }
            return (window, index)
        }
        guard !originalWindows.isEmpty else { throw UsageParserError.missingWindows }

        var short: QuotaWindow?
        var long: QuotaWindow?
        for (window, position) in originalWindows {
            // 如果只返回一条 7 天额度，也不能误认为它是 5h。
            if let minutes = window.durationMinutes {
                if minutes >= 2_880 { long = window } else { short = window }
            } else if position == 0 {
                short = window
            } else {
                long = window
            }
        }
        return CodexUsage(shortWindow: short, longWindow: long, fetchedAt: now)
    }

    private static func parseWindow(_ raw: Any?) -> QuotaWindow? {
        guard let object = raw as? [String: Any],
              let used = numeric(object["usedPercent"]), used.isFinite,
              (0...100).contains(used) else { return nil }
        let duration = numeric(object["windowDurationMins"]).flatMap { value -> Int? in
            guard value.isFinite, value > 0, value < Double(Int.max) else { return nil }
            return Int(value)
        }
        let reset = numeric(object["resetsAt"]).flatMap { value -> Date? in
            guard value.isFinite, value > 0 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        return QuotaWindow(
            remainingPercent: max(0, min(100, Int((100 - used).rounded()))),
            durationMinutes: duration,
            resetsAt: reset
        )
    }

    private static func numeric(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

/// 双层进度环的可测试数据模型。窗口不存在与无限额度不可画等号。
public struct QuotaRingState: Equatable {
    public let weeklyRemaining: Int?
    public let fiveHourRemaining: Int?

    public init(usage: CodexUsage?) {
        // 必须具有能确认窗口时长的字段；不根据用户订阅类型猜测额度。
        if let weekly = usage?.longWindow,
           let minutes = weekly.durationMinutes, minutes >= 2_880 {
            weeklyRemaining = weekly.remainingPercent
        } else {
            weeklyRemaining = nil
        }
        if let short = usage?.shortWindow, short.durationMinutes == 300 {
            fiveHourRemaining = short.remainingPercent
        } else {
            fiveHourRemaining = nil
        }
    }
}
