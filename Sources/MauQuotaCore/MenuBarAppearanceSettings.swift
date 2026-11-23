import Foundation

/// 菜单栏外观偏好（与账号或额度缓存无关）。
/// UserDefaults 会以应用的 bundle identifier 为作用域持久保存。
public final class MenuBarAppearanceSettings {
    private static let menuBarNumbersKey = "showMenuBarQuotaNumbers"
    private static let coloredRingKey = "showColoredQuotaRing"
    private static let coloredNumbersKey = "showColoredQuotaNumbers"
    private static let redNumberAlignmentKey = "compensateRedQuotaNumberAlignment"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 默认保留现有的“圆环 + 数字”展示；关闭后仅显示圆环。
    public var showsMenuBarNumbers: Bool {
        get { defaults.object(forKey: Self.menuBarNumbersKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.menuBarNumbersKey) }
    }

    /// 仅圆环模式始终显示圆环，即使用户之前关闭了彩色圆环。
    /// 恢复数字后沿用之前的圆环开关选择，不覆盖原偏好。
    public var shouldDisplayRing: Bool {
        !showsMenuBarNumbers || showsColoredRing
    }

    /// 首次安装默认展示彩色额度环；用户可随时关闭，再次开启仍保持原状态。
    public var showsColoredRing: Bool {
        get { defaults.object(forKey: Self.coloredRingKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.coloredRingKey) }
    }

    public var showsColoredNumbers: Bool {
        get { defaults.object(forKey: Self.coloredNumbersKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.coloredNumbersKey) }
    }

    public var compensatesRedNumberAlignment: Bool {
        get { defaults.object(forKey: Self.redNumberAlignmentKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.redNumberAlignmentKey) }
    }
}
