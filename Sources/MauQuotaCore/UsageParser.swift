import Foundation

public enum CodexPlan: Equatable {
    case plus, pro, other, unknown

    public static func resolve(_ rawValue: String?) -> CodexPlan {
        guard let rawValue else { return .unknown }
        let normalized = String(rawValue.lowercased().filter { $0.isLetter || $0.isNumber })
        switch normalized {
        case "plus", "chatgptplus": return .plus
        case "pro", "pro100", "pro200", "pro500", "pro5x", "pro20x",
             "chatgptpro", "chatgptpro100", "chatgptpro200", "chatgptpro500": return .pro
        default: return .other
        }
    }

    public static func displayName(for rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = String(rawValue.lowercased().filter { $0.isLetter || $0.isNumber })
        switch normalized {
        case "plus", "chatgptplus": return "Plus"
        case "pro", "chatgptpro": return "Pro"
        case "pro100", "chatgptpro100": return "Pro 100"
        case "pro200", "chatgptpro200": return "Pro 200"
        case "pro500", "chatgptpro500": return "Pro 500"
        default: return rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

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
        [shortWindow, longWindow].compactMap { $0 }
            .map { "\($0.label) \($0.remainingPercent)%" }.joined(separator: " · ")
    }
}

public enum UsageParserError: Error, Equatable {
    case invalidJSON, missingRateLimits, missingWindows, serverError
}

public enum UsageParser {
    public static func parseResponse(_ data: Data, planType: String? = nil,
                                     now: Date = Date()) throws -> CodexUsage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageParserError.invalidJSON
        }
        if root["error"] != nil { throw UsageParserError.serverError }
        let effectivePlan = (root["plan_type"] as? String) ?? (root["planType"] as? String) ?? planType

        if let direct = root["rate_limit"] as? [String: Any] {
            return try parseDirectRateLimit(direct, planType: effectivePlan, now: now)
        }
        guard let result = root["result"] as? [String: Any] else {
            throw UsageParserError.missingRateLimits
        }
        let byID = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        let main = result["rateLimits"] as? [String: Any]
        guard let snapshot = byID?["codex"] ?? main ?? byID?.values.first else {
            throw UsageParserError.missingRateLimits
        }
        let windows: [(QuotaWindow, Int)] = [
            (snapshot["primary"], 0), (snapshot["secondary"], 1)
        ].compactMap { raw, position in
            guard let window = parseAppServerWindow(raw) else { return nil }
            return (window, position)
        }
        return try makeUsage(windows, planType: effectivePlan, now: now)
    }

    private static func parseDirectRateLimit(_ snapshot: [String: Any], planType: String?,
                                             now: Date) throws -> CodexUsage {
        let windows: [(QuotaWindow, Int)] = [
            (snapshot["primary_window"], 0), (snapshot["secondary_window"], 1)
        ].compactMap { raw, position in
            guard let window = parseDirectWindow(raw) else { return nil }
            return (window, position)
        }
        return try makeUsage(windows, planType: planType, now: now)
    }

    private static func makeUsage(_ windows: [(QuotaWindow, Int)], planType: String?,
                                  now: Date) throws -> CodexUsage {
        guard !windows.isEmpty else { throw UsageParserError.missingWindows }
        var short: QuotaWindow?
        var long: QuotaWindow?
        for (window, position) in windows {
            if let minutes = window.durationMinutes {
                if minutes >= 2_880 { long = window } else { short = window }
            } else if position == 0 {
                short = window
            } else {
                long = window
            }
        }
        // Current Pro tiers have a weekly allowance but no five-hour Codex window.
        // Never relabel an ambiguous primary slot as a five-hour limit for Pro.
        if CodexPlan.resolve(planType) == .pro {
            short = nil
            guard long != nil else { throw UsageParserError.missingWindows }
        }
        return CodexUsage(shortWindow: short, longWindow: long, fetchedAt: now)
    }

    private static func parseAppServerWindow(_ raw: Any?) -> QuotaWindow? {
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
        return QuotaWindow(remainingPercent: max(0, min(100, Int((100 - used).rounded()))),
                           durationMinutes: duration, resetsAt: reset)
    }

    private static func parseDirectWindow(_ raw: Any?) -> QuotaWindow? {
        guard let object = raw as? [String: Any],
              let used = numeric(object["used_percent"]), used.isFinite,
              (0...100).contains(used) else { return nil }
        let duration = numeric(object["limit_window_seconds"]).flatMap { seconds -> Int? in
            guard seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return nil }
            return Int((seconds / 60).rounded())
        }
        let resetValue = numeric(object["reset_at"]) ?? numeric(object["resets_at"])
        let reset = resetValue.flatMap { value -> Date? in
            guard value.isFinite, value > 0 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        return QuotaWindow(remainingPercent: max(0, min(100, Int((100 - used).rounded()))),
                           durationMinutes: duration, resetsAt: reset)
    }

    private static func numeric(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

public struct QuotaRingState: Equatable {
    public let weeklyRemaining: Int?
    public let fiveHourRemaining: Int?

    public init(usage: CodexUsage?) {
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
