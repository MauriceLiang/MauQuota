import Foundation

/// 菜单栏外观偏好（与账号或额度缓存无关）。
/// UserDefaults 会以应用的 bundle identifier 为作用域持久保存。
public final class MenuBarAppearanceSettings {
    private static let coloredRingKey = "showColoredQuotaRing"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 首次安装默认展示彩色额度环；用户可随时关闭，再次开启仍保持原状态。
    public var showsColoredRing: Bool {
        get { defaults.object(forKey: Self.coloredRingKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.coloredRingKey) }
    }
}
