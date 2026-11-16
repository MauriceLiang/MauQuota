import AppKit
import MauQuotaCore

/// Native macOS appearance editor. NSColorWell opens the system color picker.
final class AppearanceSettingsWindowController: NSWindowController {
    private let settings: MenuBarAppearanceSettings
    private let language: DisplayLanguage
    private let onChange: () -> Void
    private var colorWells: [AppearanceColorKey: NSColorWell] = [:]
    private var customToggles: [AppearanceColorKey: NSButton] = [:]
    private var isChinese: Bool { language == .simplifiedChinese }

    init(settings: MenuBarAppearanceSettings,
         language: DisplayLanguage,
         onChange: @escaping () -> Void) {
        self.settings = settings
        self.language = language
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 450),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = language == .simplifiedChinese ? "外观自定义" : "Customize Appearance"
        window.center()
        super.init(window: window)
        window.isReleasedWhenClosed = false
        buildInterface()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.distribution = .fill
        root.spacing = 9
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])

        let title = NSTextField(labelWithString: isChinese ? "外观自定义" : "Customize Appearance")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: isChinese
            ? "选择自定义颜色后会立即生效；取消勾选即可恢复默认配色。"
            : "Custom colors apply immediately. Turn a color off to restore the default appearance.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        root.addArrangedSubview(subtitle)

        addSection(isChinese ? "圆环颜色" : "Quota ring colors", to: root)
        addColorRow(.fiveHourRing, to: root)
        addColorRow(.weeklyRing, to: root)

        addSection(isChinese ? "菜单栏数字颜色" : "Menu bar percentage colors", to: root)
        addColorRow(.fiveHourNumber, to: root)
        addColorRow(.weeklyNumber, to: root)

        addSection(isChinese ? "额度详情文字颜色" : "Quota detail text colors", to: root)
        addColorRow(.fiveHourDetail, to: root)
        addColorRow(.weeklyDetail, to: root)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .equalSpacing
        footer.spacing = 10
        footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let reset = NSButton(
            title: isChinese ? "恢复默认配色" : "Reset colors",
            target: self,
            action: #selector(resetClicked(_:))
        )
        let close = NSButton(
            title: isChinese ? "完成" : "Done",
            target: self,
            action: #selector(closeClicked(_:))
        )
        footer.addArrangedSubview(reset)
        footer.addArrangedSubview(close)
        root.addArrangedSubview(footer)
    }

    private func addSection(_ title: String, to root: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        root.addArrangedSubview(label)
    }

    private func addColorRow(_ key: AppearanceColorKey, to root: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12

        let title = NSTextField(labelWithString: rowTitle(for: key))
        title.font = .systemFont(ofSize: 13)
        title.widthAnchor.constraint(equalToConstant: 218).isActive = true

        let toggle = NSButton(
            checkboxWithTitle: isChinese ? "自定义" : "Custom",
            target: self,
            action: #selector(customColorToggled(_:))
        )
        toggle.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
        toggle.state = settings.customColorHex(for: key) == nil ? .off : .on
        customToggles[key] = toggle

        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 46, height: 26))
        well.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
        well.color = NSColor(mauQuotaHex: settings.customColorHex(for: key) ?? defaultHex(for: key))
            ?? .systemGreen
        well.isEnabled = settings.customColorHex(for: key) != nil
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.widthAnchor.constraint(equalToConstant: 46).isActive = true
        well.heightAnchor.constraint(equalToConstant: 26).isActive = true
        colorWells[key] = well

        row.addArrangedSubview(title)
        row.addArrangedSubview(toggle)
        row.addArrangedSubview(well)
        root.addArrangedSubview(row)
    }

    private func rowTitle(for key: AppearanceColorKey) -> String {
        switch key {
        case .fiveHourRing: return isChinese ? "5 小时额度圆环" : "5-hour quota ring"
        case .weeklyRing: return isChinese ? "7 天额度圆环" : "7-day quota ring"
        case .fiveHourNumber: return isChinese ? "菜单栏 5 小时百分比" : "Menu bar 5-hour percentage"
        case .weeklyNumber: return isChinese ? "菜单栏 7 天百分比" : "Menu bar 7-day percentage"
        case .fiveHourDetail: return isChinese ? "5 小时额度及重置时间" : "5-hour quota and reset text"
        case .weeklyDetail: return isChinese ? "7 天额度及重置时间" : "7-day quota and reset text"
        }
    }

    private func defaultHex(for key: AppearanceColorKey) -> String {
        switch key {
        case .weeklyRing, .weeklyNumber, .weeklyDetail: return "#0A84FF"
        case .fiveHourRing, .fiveHourNumber, .fiveHourDetail: return "#30A46C"
        }
    }

    @objc private func customColorToggled(_ sender: NSButton) {
        guard let key = sender.identifier.flatMap({ AppearanceColorKey(rawValue: $0.rawValue) }) else {
            return
        }
        if sender.state == .on {
            let hex = colorWells[key].flatMap { $0.color.mauQuotaHex } ?? defaultHex(for: key)
            settings.setCustomColorHex(hex, for: key)
        } else {
            settings.setCustomColorHex(nil, for: key)
        }
        colorWells[key]?.isEnabled = sender.state == .on
        onChange()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let key = sender.identifier.flatMap({ AppearanceColorKey(rawValue: $0.rawValue) }),
              settings.customColorHex(for: key) != nil,
              let hex = sender.color.mauQuotaHex else { return }
        settings.setCustomColorHex(hex, for: key)
        onChange()
    }

    @objc private func resetClicked(_ sender: Any?) {
        settings.resetCustomColors()
        for key in AppearanceColorKey.allCases {
            customToggles[key]?.state = .off
            colorWells[key]?.color = NSColor(mauQuotaHex: defaultHex(for: key)) ?? .systemGreen
            colorWells[key]?.isEnabled = false
        }
        onChange()
    }

    @objc private func closeClicked(_ sender: Any?) { close() }
}

extension NSColor {
    convenience init?(mauQuotaHex: String) {
        let trimmed = mauQuotaHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6, digits.allSatisfy({ $0.isHexDigit }),
              let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var mauQuotaHex: String? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}
