import AppKit
import Foundation
import OSLog
import Darwin
import MauQuotaCore

@main
final class MauQuotaApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var isFetching = false
    private var isLoggingIn = false
    private var hasChecked = false
    private var lastAccount: CodexAccount?
    private var lastUsage: CodexUsage?
    private var lastError: String?
    private var isLoginError = false
    private let reader = CodexAppServer()
    private let appearanceSettings = MenuBarAppearanceSettings()
    private let preferences = MenuBarPreferences()
    private let logger = Logger(subsystem: "dev.mau.mauquota", category: "usage")

    private var activeLanguage: DisplayLanguage { preferences.language.resolved() }
    private func tr(_ key: MenuLocalization.Key) -> String {
        MenuLocalization.text(key, language: activeLanguage)
    }

    static func main() {
        _ = signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = MauQuotaApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bundle ID changed with the new app name; preserve the user's previous settings.
        let legacy = UserDefaults.standard.persistentDomain(
            forName: LegacyPreferencesMigration.formerBundleIdentifier
        ) ?? [:]
        let copied = LegacyPreferencesMigration.migrate(from: legacy, into: .standard)
        if copied > 0 { logger.info("已迁移 \(copied) 项旧版偏好设置") }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        drawMenu()
        refresh()
        restartRefreshTimer()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Changing the preference always discards the old timer before creating another.
    /// No network request is sent by changing the refresh interval itself.
    private func restartRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(preferences.refreshIntervalMinutes * 60)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = min(15, max(1, interval * 0.1))
        refreshTimer = timer
        logger.info("自动刷新间隔设为 \(self.preferences.refreshIntervalMinutes) 分钟")
    }

    @objc private func didWake() { refresh() }
    @objc private func refreshClicked(_ sender: Any?) { refresh() }
    @objc private func quitClicked(_ sender: Any?) { NSApp.terminate(nil) }
    @objc private func loginClicked(_ sender: Any?) { login() }
    // NSMenu auto-validation disables informational rows without a responding action.
    @objc private func informationalItemClicked(_ sender: Any?) {}

    @objc private func coloredRingToggled(_ sender: Any?) {
        appearanceSettings.showsColoredRing.toggle()
        drawMenu() // UI-only change; no quota request.
    }

    @objc private func coloredNumbersToggled(_ sender: Any?) {
        appearanceSettings.showsColoredNumbers.toggle()
        drawMenu() // UI-only change; no quota request.
    }

    @objc private func redNumberAlignmentCompensationToggled(_ sender: Any?) {
        appearanceSettings.compensatesRedNumberAlignment.toggle()
        drawMenu() // UI-only change; no quota request.
    }

    @objc private func refreshIntervalSelected(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let minutes = item.representedObject as? Int else { return }
        preferences.refreshIntervalMinutes = minutes
        restartRefreshTimer()
        drawMenu()
    }

    @objc private func customRefreshIntervalClicked(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = tr(.customIntervalTitle)
        alert.informativeText = tr(.customIntervalMessage)
        alert.addButton(withTitle: tr(.save))
        alert.addButton(withTitle: tr(.cancel))
        let field = NSTextField(string: String(preferences.refreshIntervalMinutes))
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        field.alignment = .left
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(input),
              (MenuBarPreferences.minimumRefreshMinutes...MenuBarPreferences.maximumRefreshMinutes).contains(minutes) else {
            let invalid = NSAlert()
            invalid.alertStyle = .warning
            invalid.messageText = tr(.invalidIntervalTitle)
            invalid.informativeText = tr(.invalidIntervalMessage)
            invalid.runModal()
            return
        }
        preferences.refreshIntervalMinutes = minutes
        restartRefreshTimer()
        drawMenu()
    }

    @objc private func languageSelected(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let value = item.representedObject as? String,
              let selectedLanguage = DisplayLanguage(rawValue: value) else { return }
        preferences.language = selectedLanguage
        drawMenu() // Language changes instantly; no restart or quota request.
    }

    @objc private func copyDiagnosisClicked(_ sender: Any?) {
        let path = reader.resolvedCLIPath ?? (activeLanguage == .english ? "Not found" : "未找到")
        let login = lastAccount?.label ?? (hasChecked ? (activeLanguage == .english ? "Signed out / unknown" : "未登录/未知") : (activeLanguage == .english ? "Not checked" : "尚未检查"))
        let issue = displayedError() ?? (activeLanguage == .english ? "None" : "无")
        let diagnostic = """
        MauQuota v1.8.6
        Codex CLI: \(path)
        \(tr(.account))\(login)
        \(tr(.refreshInterval)): \(preferences.refreshIntervalMinutes) min
        \(tr(.language)): \(preferences.language.rawValue)
        \(tr(.error))\(issue)
        """
        // Never include the user's email, password, or access token.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostic, forType: .string)
    }

    private func refresh() {
        guard !isFetching, !isLoggingIn else { return }
        isFetching = true
        drawMenu()
        logger.info("开始检查 Codex 账号及额度")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.reader.loadSnapshot() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isFetching = false
                self.hasChecked = true
                switch result {
                case .success(let snapshot):
                    self.apply(snapshot)
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    self.isLoginError = false
                    self.logger.error("账号/额度检查失败：\(error.localizedDescription, privacy: .public)")
                }
                self.drawMenu()
            }
        }
    }

    private func login() {
        guard !isLoggingIn, !isFetching else { return }
        isLoggingIn = true
        lastError = nil
        isLoginError = false
        drawMenu()
        logger.info("开始官方 ChatGPT 浏览器授权")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result {
                try self.reader.loginWithChatGPT { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                return try self.reader.loadSnapshot()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLoggingIn = false
                self.hasChecked = true
                switch result {
                case .success(let snapshot):
                    self.apply(snapshot)
                    self.logger.info("官方 ChatGPT 登录流程结束")
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    self.isLoginError = true
                    self.logger.error("官方登录失败：\(error.localizedDescription, privacy: .public)")
                }
                self.drawMenu()
            }
        }
    }

    private func apply(_ snapshot: CodexSnapshot) {
        if lastAccount != snapshot.account { lastUsage = nil }
        lastAccount = snapshot.account
        lastUsage = snapshot.usage
        lastError = snapshot.quotaError
        isLoginError = false
        if let error = lastError { logger.error("额度读取失败：\(error, privacy: .public)") }
        else { logger.info("账号和额度已更新") }
    }

    private static func coloredTitle(_ title: NSAttributedString, usage: CodexUsage,
                                     compensatesRedAlignment: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: title)
        let text = result.string as NSString
        let rings = QuotaRingState(usage: usage)
        let windows = [(usage.shortWindow, rings.fiveHourRemaining), (usage.longWindow, rings.weeklyRemaining)]
        var position = 0
        for (window, remaining) in windows {
            guard let window else { continue }
            let range = text.range(of: "\(window.remainingPercent)%", options: [],
                                   range: NSRange(location: position, length: text.length - position))
            guard range.location != NSNotFound else { break }
            if let remaining {
                result.addAttribute(.foregroundColor, value: QuotaRingIcon.color(for: remaining), range: range)
                if compensatesRedAlignment && remaining <= 20 {
                    result.addAttribute(.baselineOffset, value: -0.5, range: range)
                }
            }
            position = NSMaxRange(range)
        }
        return result
    }

    private func drawMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu(title: "MauQuota")
        let title: String
        if let usage = lastUsage { title = usage.menuBarTitle + (lastError == nil ? "" : " !") }
        else if isLoggingIn { title = tr(.loggingInTitle) }
        else if isFetching && !hasChecked { title = tr(.checkingTitle) }
        else if hasChecked && lastAccount == nil && lastError == nil { title = tr(.loggedOutTitle) }
        else { title = tr(.errorTitle) }

        if let button = statusItem.button {
            button.title = title // Reset prior colors and retain the system text style.
            if let usage = lastUsage, appearanceSettings.showsColoredNumbers {
                button.attributedTitle = Self.coloredTitle(
                    button.attributedTitle, usage: usage,
                    compensatesRedAlignment: appearanceSettings.compensatesRedNumberAlignment
                )
            }
        }
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.image = appearanceSettings.showsColoredRing
            ? QuotaRingIcon.render(QuotaRingState(usage: lastUsage)) : nil
        statusItem.button?.toolTip = !appearanceSettings.showsColoredRing
            ? tr(.tooltipHidden)
            : (lastUsage == nil ? tr(.tooltipUnknown) : tr(.tooltipRings))

        if isLoggingIn {
            menu.addItem(disabled: tr(.authorizeInBrowser))
        } else if isFetching {
            menu.addItem(disabled: tr(.checkingStatus))
        }

        if let account = lastAccount {
            addInformationItem(tr(.account) + account.label, to: menu)
            if let email = account.email, !email.isEmpty { addInformationItem("    \(email)", to: menu) }
        } else if hasChecked && lastError == nil {
            addInformationItem(tr(.loggedOutDescription), to: menu)
        }

        if let usage = lastUsage {
            menu.addItem(.separator())
            if let short = usage.shortWindow { addDetail(short, to: menu) }
            if let long = usage.longWindow { addDetail(long, to: menu) }
            let date = DateFormatter()
            date.locale = activeLanguage.locale
            date.dateStyle = .none
            date.timeStyle = .medium
            addInformationItem(tr(.updatedAt) + date.string(from: usage.fetchedAt), to: menu)
        }
        if let error = lastError {
            menu.addItem(.separator())
            menu.addItem(disabled: tr(.error) + (displayedError() ?? localizedErrorString(error)))
        }
        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: lastAccount == nil ? tr(.login) : tr(.relogin),
            action: #selector(loginClicked(_:)), keyEquivalent: "l"
        )
        loginItem.target = self
        loginItem.isEnabled = !isLoggingIn && !isFetching
        menu.addItem(loginItem)

        let refreshItem = NSMenuItem(
            title: isFetching ? tr(.refreshing) : tr(.refresh),
            action: #selector(refreshClicked(_:)), keyEquivalent: "r"
        )
        refreshItem.target = self
        refreshItem.isEnabled = !isFetching && !isLoggingIn
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        let coloredRingItem = NSMenuItem(
            title: tr(.ringToggle), action: #selector(coloredRingToggled(_:)), keyEquivalent: ""
        )
        coloredRingItem.target = self
        coloredRingItem.state = appearanceSettings.showsColoredRing ? .on : .off
        menu.addItem(coloredRingItem)
        let numberColorMenu = NSMenu(title: tr(.numberColorToggle))
        let coloredNumbersItem = NSMenuItem(
            title: tr(.numberColorEnabled), action: #selector(coloredNumbersToggled(_:)), keyEquivalent: ""
        )
        coloredNumbersItem.target = self
        coloredNumbersItem.state = appearanceSettings.showsColoredNumbers ? .on : .off
        numberColorMenu.addItem(coloredNumbersItem)
        let alignmentCompensationItem = NSMenuItem(
            title: tr(.redNumberAlignmentCompensation),
            action: #selector(redNumberAlignmentCompensationToggled(_:)), keyEquivalent: ""
        )
        alignmentCompensationItem.target = self
        alignmentCompensationItem.state = appearanceSettings.compensatesRedNumberAlignment ? .on : .off
        alignmentCompensationItem.isEnabled = appearanceSettings.showsColoredNumbers
        numberColorMenu.addItem(alignmentCompensationItem)
        let numberColorItem = NSMenuItem(title: tr(.numberColorToggle), action: nil, keyEquivalent: "")
        numberColorItem.submenu = numberColorMenu
        menu.addItem(numberColorItem)
        addRefreshIntervalMenu(to: menu)
        addLanguageMenu(to: menu)

        menu.addItem(.separator())
        let copyItem = NSMenuItem(title: tr(.copyDiagnostics), action: #selector(copyDiagnosisClicked(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        menu.addItem(.separator())
        menu.addItem(disabled: tr(.version))
        let quitItem = NSMenuItem(title: tr(.quit), action: #selector(quitClicked(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func addRefreshIntervalMenu(to menu: NSMenu) {
        let intervalMenu = NSMenu(title: tr(.refreshInterval))
        let selected = preferences.refreshIntervalMinutes
        for minutes in MenuBarPreferences.presetRefreshMinutes {
            let item = NSMenuItem(title: "\(minutes) min", action: #selector(refreshIntervalSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            item.state = minutes == selected ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalMenu.addItem(.separator())
        let isCustom = !MenuBarPreferences.presetRefreshMinutes.contains(selected)
        let customTitle = tr(.customInterval) + (isCustom ? " (\(selected) min)" : "")
        let custom = NSMenuItem(title: customTitle, action: #selector(customRefreshIntervalClicked(_:)), keyEquivalent: "")
        custom.target = self
        custom.state = isCustom ? .on : .off
        intervalMenu.addItem(custom)
        let root = NSMenuItem(title: "\(tr(.refreshInterval)) (\(selected) min)", action: nil, keyEquivalent: "")
        root.submenu = intervalMenu
        menu.addItem(root)
    }

    private func addLanguageMenu(to menu: NSMenu) {
        let languageMenu = NSMenu(title: tr(.language))
        for language in DisplayLanguage.allCases {
            let key: MenuLocalization.Key
            switch language {
            case .system: key = .followSystem
            case .simplifiedChinese: key = .simplifiedChinese
            case .english: key = .english
            }
            let item = NSMenuItem(title: tr(key), action: #selector(languageSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = preferences.language == language ? .on : .off
            languageMenu.addItem(item)
        }
        let root = NSMenuItem(title: tr(.language), action: nil, keyEquivalent: "")
        root.submenu = languageMenu
        menu.addItem(root)
    }

    /// Core errors are emitted in Chinese by the upstream reader; translate common
    /// diagnostic messages in the UI without altering the original log/diagnostic cause.
    private func displayedError() -> String? {
        guard let error = lastError else { return nil }
        return (isLoginError ? tr(.loginFailure) : "") + localizedErrorString(error)
    }

    private func localizedErrorString(_ message: String) -> String {
        guard activeLanguage == .english else { return message }
        if message.hasPrefix("当前是 ") && message.contains("订阅额度需要 ChatGPT 登录") {
            return "This account uses \(lastAccount?.label ?? "another authentication method"); sign in with ChatGPT to view subscription quotas"
        }
        if message.hasPrefix("Codex 拒绝请求（错误码：") {
            let code = message.replacingOccurrences(of: "Codex 拒绝请求（错误码：", with: "").replacingOccurrences(of: "）", with: "")
            return "Codex rejected the request (error code: \(code))"
        }
        let translations: [String: String] = [
            "未找到 Codex CLI，请先安装官方 Codex CLI": "Codex CLI not found; install the official Codex CLI",
            "无法启动 Codex CLI，请检查安装位置和权限": "Could not launch Codex CLI; check its path and permissions",
            "Codex 连接已断开（写入失败）": "Codex connection closed unexpectedly (write failed)",
            "读取 Codex 数据时发生系统错误": "System error while reading Codex data",
            "连接超时，请检查网络、登录状态或代理": "Connection timed out; check your network, login, or proxy",
            "Codex 提前退出（可能是 CLI 版本或运行环境问题）": "Codex CLI exited early; check its version and environment",
            "Codex 返回的数据过大": "Codex response was too large",
            "Codex 初始化失败，请更新官方 CLI": "Codex initialization failed; update the official CLI",
            "Codex 返回了不兼容的账号数据": "Codex returned incompatible account data",
            "已连接，但服务没有返回可识别的额度": "Connected, but no recognizable quota limits were returned",
            "Codex 返回了不安全或无效的登录地址": "Codex returned an invalid or unsafe login URL",
            "Codex 未提供浏览器登录地址，请更新 CLI": "Codex did not provide a browser login URL; update the CLI",
            "浏览器授权未完成或登录失败，可重新尝试": "Browser authorization was not completed; please try again"
        ]
        return translations[message] ?? message
    }

    private func addDetail(_ window: QuotaWindow, to menu: NSMenu) {
        addInformationItem("\(window.label) \(tr(.remaining)) \(window.remainingPercent)%", to: menu)
        let reset: String
        if let resetsAt = window.resetsAt {
            let formatter = DateFormatter()
            formatter.locale = activeLanguage.locale
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            reset = formatter.string(from: resetsAt)
        } else { reset = tr(.notProvided) }
        addInformationItem("    \(tr(.resetAt))\(reset)", to: menu)
    }

    private func addInformationItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(
            title: title, action: #selector(informationalItemClicked(_:)), keyEquivalent: ""
        )
        item.target = self
        item.attributedTitle = NSAttributedString(
            string: title, attributes: [.foregroundColor: NSColor.labelColor]
        )
        item.isEnabled = true
        menu.addItem(item)
    }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
