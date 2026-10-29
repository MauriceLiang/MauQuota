import Foundation

/// Preferences for the menu-bar utility. No account information or secrets are stored here.
public final class MenuBarPreferences {
    public static let defaultRefreshMinutes = 2
    public static let minimumRefreshMinutes = 1
    public static let maximumRefreshMinutes = 120
    public static let presetRefreshMinutes = [1, 2, 5, 10, 15, 30, 60]

    private static let refreshKey = "refreshIntervalMinutes"
    private static let languageKey = "displayLanguage"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Rejects invalid persisted values and constrains any programmatic writes.
    public var refreshIntervalMinutes: Int {
        get {
            guard let minutes = defaults.object(forKey: Self.refreshKey) as? Int,
                  (Self.minimumRefreshMinutes...Self.maximumRefreshMinutes).contains(minutes) else {
                return Self.defaultRefreshMinutes
            }
            return minutes
        }
        set {
            defaults.set(min(Self.maximumRefreshMinutes, max(Self.minimumRefreshMinutes, newValue)),
                         forKey: Self.refreshKey)
        }
    }

    public var language: DisplayLanguage {
        get { DisplayLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Self.languageKey) }
    }
}

public enum DisplayLanguage: String, CaseIterable, Equatable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> DisplayLanguage {
        guard self == .system else { return self }
        guard let preferred = preferredLanguages.first?.lowercased() else { return .english }
        return preferred == "zh" || preferred.hasPrefix("zh-") || preferred.hasPrefix("zh_")
            ? .simplifiedChinese : .english
    }

    public var locale: Locale {
        Locale(identifier: self == .simplifiedChinese ? "zh_CN" : "en_US")
    }
}

/// A resource-free bilingual string table, available to unit tests on Linux.
public enum MenuLocalization {
    public enum Key {
        case tooltipHidden, tooltipUnknown, tooltipRings
        case loggingInTitle, checkingTitle, loggedOutTitle, errorTitle
        case authorizeInBrowser, checkingStatus, account, loggedOutDescription
        case remaining, resetAt, notProvided, updatedAt, error
        case login, relogin, refresh, refreshing
        case ringToggle, numberColorToggle, numberColorEnabled, redNumberAlignmentCompensation
        case refreshInterval, customInterval, language
        case followSystem, simplifiedChinese, english, copyDiagnostics, version, quit
        case customIntervalTitle, customIntervalMessage, save, cancel
        case invalidIntervalTitle, invalidIntervalMessage, loginFailure
    }

    public static func text(_ key: Key, language: DisplayLanguage) -> String {
        let chinese = language == .simplifiedChinese
        switch key {
        case .tooltipHidden: return chinese ? "Codex 额度 · 点击查看账号、额度和设置" : "Codex quotas · Click for account, quotas and settings"
        case .tooltipUnknown: return chinese ? "Codex 额度未知 · 点击查看详情" : "Codex quotas unavailable · Click for details"
        case .tooltipRings: return chinese ? "外圈：每周额度；内圈：5 小时额度。绿色 >50%，橙色 21–50%，红色 ≤20%" : "Outer ring: weekly quota; inner ring: 5-hour quota. Green >50%, orange 21–50%, red ≤20%"
        case .loggingInTitle: return chinese ? "Codex 登录中…" : "Codex Signing in…"
        case .checkingTitle: return "Codex …"
        case .loggedOutTitle: return chinese ? "Codex 未登录" : "Codex Signed out"
        case .errorTitle: return "Codex !"
        case .authorizeInBrowser: return chinese ? "请在浏览器完成 ChatGPT 授权" : "Complete ChatGPT authorization in your browser"
        case .checkingStatus: return chinese ? "正在检查账号与额度…" : "Checking account and quotas…"
        case .account: return chinese ? "账号：" : "Account: "
        case .loggedOutDescription: return chinese ? "当前尚未登录 ChatGPT" : "Not signed in to ChatGPT"
        case .remaining: return chinese ? "剩余" : "remaining"
        case .resetAt: return chinese ? "重置时间：" : "Resets: "
        case .notProvided: return chinese ? "暂未提供" : "Not available"
        case .updatedAt: return chinese ? "更新于 " : "Updated "
        case .error: return chinese ? "错误：" : "Error: "
        case .login: return chinese ? "使用 ChatGPT 登录…" : "Sign in with ChatGPT…"
        case .relogin: return chinese ? "重新登录 ChatGPT…" : "Sign in to ChatGPT again…"
        case .refresh: return chinese ? "立即刷新" : "Refresh now"
        case .refreshing: return chinese ? "正在检查…" : "Refreshing…"
        case .ringToggle: return chinese ? "显示彩色额度圆环" : "Show colored quota rings"
        case .numberColorToggle: return chinese ? "显示彩色额度数字" : "Show colored quota numbers"
        case .numberColorEnabled: return chinese ? "启用彩色额度数字" : "Enable colored quota numbers"
        case .redNumberAlignmentCompensation: return chinese ? "红色数字视觉偏移补偿" : "Red number alignment compensation"
        case .refreshInterval: return chinese ? "自动刷新间隔" : "Auto-refresh interval"
        case .customInterval: return chinese ? "自定义…" : "Custom…"
        case .language: return chinese ? "语言 / Language" : "Language / 语言"
        case .followSystem: return chinese ? "跟随系统" : "Follow system"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .copyDiagnostics: return chinese ? "复制诊断信息" : "Copy diagnostic information"
        case .version: return chinese ? "MauQuota v1.8.5 · DMG 发布支持" : "MauQuota v1.8.5 · DMG distribution"
        case .quit: return chinese ? "退出 MauQuota" : "Quit MauQuota"
        case .customIntervalTitle: return chinese ? "自定义刷新间隔" : "Custom refresh interval"
        case .customIntervalMessage: return chinese ? "请输入 1–120 之间的整数分钟。新间隔会立即重新计时，不会立即发送请求。" : "Enter a whole number of minutes from 1 to 120. The next interval starts now; no immediate request is made."
        case .save: return chinese ? "保存" : "Save"
        case .cancel: return chinese ? "取消" : "Cancel"
        case .invalidIntervalTitle: return chinese ? "无效的刷新间隔" : "Invalid refresh interval"
        case .invalidIntervalMessage: return chinese ? "只能填写 1–120 之间的整数分钟。" : "Enter a whole number of minutes between 1 and 120."
        case .loginFailure: return chinese ? "登录失败：" : "Sign-in failed: "
        }
    }
}
