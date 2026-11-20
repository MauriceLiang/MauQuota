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
    private var resetCreditsWindowController: ResetCreditsWindowController?

    // Keep one AppKit menu and update its contents in place. Rebuilding the entire
    // NSMenu tree on every polling tick caused unnecessary long-lived allocations.
    private enum MenuRow: Hashable {
        case progress, account, email, signedOut, usageSeparator
        case shortRemaining, shortReset, longRemaining, longReset, updatedAt
        case errorSeparator, error, login, refresh, reset
        case coloredRing, numberColors, numbersEnabled, redAlignment
        case intervalRoot, intervalCustom, languageRoot
        case diagnostics, version, quit
    }
    private var persistentMenu: NSMenu?
    private var menuRows: [MenuRow: NSMenuItem] = [:]
    private var intervalRows: [Int: NSMenuItem] = [:]
    private var languageRows: [String: NSMenuItem] = [:]
    private var displayedRingState: QuotaRingState?
    private var displayedRingVisible = false
    private var displayedTitle = ""
    private var displayedColoredNumbers = false
    private var displayedRedCompensation = false
    private let reader = CodexAPIClient()
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
        reader.invalidateSession()
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

    @objc private func resetCreditsClicked(_ sender: Any?) {
        guard let account = lastAccount, account.isChatGPT else { return }
        if let controller = resetCreditsWindowController {
            controller.updateUsage(lastUsage)
            controller.present()
            return
        }
        let controller = ResetCreditsWindowController(
            reader: reader,
            account: account,
            usage: lastUsage,
            language: activeLanguage
        ) { [weak self] in
            self?.refresh()
        }
        resetCreditsWindowController = controller
        controller.onWindowClose = { [weak self, weak controller] in
            guard let self, let controller,
                  self.resetCreditsWindowController === controller else { return }
            self.resetCreditsWindowController = nil
        }
        controller.present()
    }

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
        resetCreditsWindowController?.close()
        resetCreditsWindowController = nil
        drawMenu() // Language changes instantly; no restart or quota request.
    }

    @objc private func copyDiagnosisClicked(_ sender: Any?) {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let login = lastAccount?.label ?? (hasChecked ? (activeLanguage == .english ? "Signed out" : "未登录") : (activeLanguage == .english ? "Not checked" : "尚未检查"))
        let credentialState = reader.hasStoredCredentials
            ? (activeLanguage == .english ? "Present" : "已保存")
            : (activeLanguage == .english ? "Not present" : "未保存")
        let issue = displayedError() ?? (activeLanguage == .english ? "None" : "无")
        let diagnostic = """
        MauQuota v\(appVersion)
        Authentication: Native OAuth
        Credential storage: macOS Keychain
        Credentials: \(credentialState)
        Usage endpoint: https://chatgpt.com/backend-api/wham/usage
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
            let result = autoreleasepool {
                Result { try self.reader.loadSnapshot() }
            }
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
            let result = autoreleasepool {
                Result {
                    try self.reader.loginWithChatGPT { url in
                        DispatchQueue.main.sync { NSWorkspace.shared.open(url) }
                    }
                    return try self.reader.loadSnapshot()
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLoggingIn = false
                self.hasChecked = true
                var loginFailureMessage: String?
                switch result {
                case .success(let snapshot):
                    self.apply(snapshot)
                    self.logger.info("官方 ChatGPT 登录流程结束")
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    self.isLoginError = true
                    loginFailureMessage = self.displayedError()
                    self.logger.error("官方登录失败：\(error.localizedDescription, privacy: .public)")
                }
                self.drawMenu()
                if let loginFailureMessage {
                    self.showLoginError(loginFailureMessage)
                }
            }
        }
    }

    private func showLoginError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = activeLanguage == .english ? "ChatGPT sign-in failed" : "ChatGPT 登录失败"
        alert.informativeText = message
        alert.addButton(withTitle: activeLanguage == .english ? "OK" : "确定")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func apply(_ snapshot: CodexSnapshot) {
        if lastAccount != snapshot.account {
            lastUsage = nil
            resetCreditsWindowController?.close()
            resetCreditsWindowController = nil
        }
        lastAccount = snapshot.account
        lastUsage = snapshot.usage
        resetCreditsWindowController?.updateUsage(snapshot.usage)
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

    private func addRow(_ key: MenuRow, to menu: NSMenu,
                        title: String = "", action: Selector? = nil,
                        keyEquivalent: String = "", informational: Bool = false) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        if let action { item.action = action; item.target = self }
        if informational {
            item.view = InformationalMenuItemView(title: title, font: menu.font)
            item.isEnabled = false
        }
        menu.addItem(item)
        menuRows[key] = item
    }

    private func addSeparator(_ key: MenuRow, to menu: NSMenu) {
        let item = NSMenuItem.separator()
        menu.addItem(item)
        menuRows[key] = item
    }

    /// Static layout and action targets are allocated once, including nested submenus.
    /// All ordinary refreshes update the same NSMenuItem and NSView instances.
    private func buildMenu() {
        guard persistentMenu == nil else { return }
        let menu = NSMenu(title: "MauQuota")
        addRow(.progress, to: menu)
        addRow(.account, to: menu, informational: true)
        addRow(.email, to: menu, informational: true)
        addRow(.signedOut, to: menu, informational: true)
        addSeparator(.usageSeparator, to: menu)
        addRow(.shortRemaining, to: menu, informational: true)
        addRow(.shortReset, to: menu, informational: true)
        addRow(.longRemaining, to: menu, informational: true)
        addRow(.longReset, to: menu, informational: true)
        addRow(.updatedAt, to: menu, informational: true)
        addSeparator(.errorSeparator, to: menu)
        addRow(.error, to: menu)
        menu.addItem(.separator())
        addRow(.login, to: menu, action: #selector(loginClicked(_:)), keyEquivalent: "l")
        addRow(.refresh, to: menu, action: #selector(refreshClicked(_:)), keyEquivalent: "r")
        addRow(.reset, to: menu, action: #selector(resetCreditsClicked(_:)))
        menu.addItem(.separator())
        addRow(.coloredRing, to: menu, action: #selector(coloredRingToggled(_:)))

        let numberMenu = NSMenu(title: tr(.numberColorToggle))
        addRow(.numbersEnabled, to: numberMenu, action: #selector(coloredNumbersToggled(_:)))
        addRow(.redAlignment, to: numberMenu,
               action: #selector(redNumberAlignmentCompensationToggled(_:)))
        addRow(.numberColors, to: menu)
        menuRows[.numberColors]?.submenu = numberMenu

        addRefreshIntervalMenu(to: menu)
        addLanguageMenu(to: menu)
        menu.addItem(.separator())
        addRow(.diagnostics, to: menu, action: #selector(copyDiagnosisClicked(_:)))
        menu.addItem(.separator())
        addRow(.version, to: menu)
        addRow(.quit, to: menu, action: #selector(quitClicked(_:)), keyEquivalent: "q")

        // Keep the existing menu attached for the entire app lifetime.
        persistentMenu = menu
        statusItem.menu = menu
    }

    private func setMenuText(_ row: MenuRow, _ value: String?) {
        guard let item = menuRows[row] else { return }
        item.isHidden = (value == nil)
        guard let value, item.title != value else { return }
        item.title = value
        (item.view as? InformationalMenuItemView)?.setTitle(value)
    }

    private func resetLabel(for window: QuotaWindow) -> String {
        guard let date = window.resetsAt else {
            return "    " + tr(.resetAt) + tr(.notProvided)
        }
        let formatter = DateFormatter()
        formatter.locale = activeLanguage.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "    " + tr(.resetAt) + formatter.string(from: date)
    }

    private func setQuotaRows(_ window: QuotaWindow?,
                              remaining: MenuRow, reset: MenuRow) {
        guard let window else {
            setMenuText(remaining, nil)
            setMenuText(reset, nil)
            return
        }
        setMenuText(remaining, "\(window.label) \(tr(.remaining)) \(window.remainingPercent)%")
        setMenuText(reset, resetLabel(for: window))
    }

    private func drawMenu() {
        guard let button = statusItem?.button else { return }
        buildMenu()

        let title: String
        if let usage = lastUsage { title = usage.menuBarTitle + (lastError == nil ? "" : " !") }
        else if isLoggingIn { title = tr(.loggingInTitle) }
        else if isFetching && !hasChecked { title = tr(.checkingTitle) }
        else if hasChecked && lastAccount == nil && lastError == nil { title = tr(.loggedOutTitle) }
        else { title = tr(.errorTitle) }

        let ringState = QuotaRingState(usage: lastUsage)
        let coloredNumbers = appearanceSettings.showsColoredNumbers
        let redCompensation = appearanceSettings.compensatesRedNumberAlignment
        let ringVisible = appearanceSettings.showsColoredRing
        let ringChanged = displayedRingState != ringState

        // Avoid reallocating attributed strings and 21pt NSImage on unchanged quotas.
        if displayedTitle != title || displayedColoredNumbers != coloredNumbers ||
            displayedRedCompensation != redCompensation || ringChanged {
            button.title = title
            if let usage = lastUsage, coloredNumbers {
                button.attributedTitle = Self.coloredTitle(
                    button.attributedTitle, usage: usage,
                    compensatesRedAlignment: redCompensation
                )
            }
            displayedTitle = title
            displayedColoredNumbers = coloredNumbers
            displayedRedCompensation = redCompensation
        }
        if ringChanged || displayedRingVisible != ringVisible {
            button.image = ringVisible ? QuotaRingIcon.render(ringState) : nil
            displayedRingVisible = ringVisible
        }
        displayedRingState = ringState
        button.toolTip = !ringVisible ? tr(.tooltipHidden)
            : (lastUsage == nil ? tr(.tooltipUnknown) : tr(.tooltipRings))

        setMenuText(.progress, isLoggingIn ? tr(.authorizeInBrowser)
            : (isFetching ? tr(.checkingStatus) : nil))
        menuRows[.progress]?.isEnabled = false

        if let account = lastAccount {
            setMenuText(.account, tr(.account) + account.label)
            setMenuText(.email, account.email.flatMap { $0.isEmpty ? nil : "    " + $0 })
        } else {
            setMenuText(.account, nil)
            setMenuText(.email, nil)
        }
        setMenuText(.signedOut, lastAccount == nil && hasChecked && lastError == nil
            ? tr(.loggedOutDescription) : nil)

        let usage = lastUsage
        menuRows[.usageSeparator]?.isHidden = usage == nil
        setQuotaRows(usage?.shortWindow, remaining: .shortRemaining, reset: .shortReset)
        setQuotaRows(usage?.longWindow, remaining: .longRemaining, reset: .longReset)
        if let usage {
            let date = DateFormatter()
            date.locale = activeLanguage.locale
            date.dateStyle = .none
            date.timeStyle = .medium
            setMenuText(.updatedAt, tr(.updatedAt) + date.string(from: usage.fetchedAt))
        } else {
            setMenuText(.updatedAt, nil)
        }

        menuRows[.errorSeparator]?.isHidden = lastError == nil
        setMenuText(.error, lastError.map { tr(.error) + (displayedError() ?? localizedErrorString($0)) })
        menuRows[.error]?.isEnabled = false

        menuRows[.login]?.title = lastAccount == nil ? tr(.login) : tr(.relogin)
        menuRows[.login]?.isEnabled = !isLoggingIn && !isFetching
        menuRows[.refresh]?.title = isFetching ? tr(.refreshing) : tr(.refresh)
        menuRows[.refresh]?.isEnabled = !isFetching && !isLoggingIn
        menuRows[.reset]?.title = activeLanguage == .simplifiedChinese
            ? "使用限额重置…" : "Usage limit resets…"
        menuRows[.reset]?.isEnabled = lastAccount?.isChatGPT == true && !isFetching && !isLoggingIn

        menuRows[.coloredRing]?.title = tr(.ringToggle)
        menuRows[.coloredRing]?.state = ringVisible ? .on : .off
        menuRows[.numberColors]?.title = tr(.numberColorToggle)
        menuRows[.numbersEnabled]?.title = tr(.numberColorEnabled)
        menuRows[.numbersEnabled]?.state = coloredNumbers ? .on : .off
        menuRows[.redAlignment]?.title = tr(.redNumberAlignmentCompensation)
        menuRows[.redAlignment]?.state = redCompensation ? .on : .off
        menuRows[.redAlignment]?.isEnabled = coloredNumbers

        let interval = preferences.refreshIntervalMinutes
        menuRows[.intervalRoot]?.title = "\(tr(.refreshInterval)) (\(interval) min)"
        for (minutes, item) in intervalRows {
            item.state = minutes == interval ? .on : .off
        }
        let custom = !MenuBarPreferences.presetRefreshMinutes.contains(interval)
        menuRows[.intervalCustom]?.title = tr(.customInterval) + (custom ? " (\(interval) min)" : "")
        menuRows[.intervalCustom]?.state = custom ? .on : .off

        menuRows[.languageRoot]?.title = tr(.language)
        for language in DisplayLanguage.allCases {
            let item = languageRows[language.rawValue]
            let key: MenuLocalization.Key
            switch language {
            case .system: key = .followSystem
            case .simplifiedChinese: key = .simplifiedChinese
            case .english: key = .english
            }
            item?.title = tr(key)
            item?.state = preferences.language == language ? .on : .off
        }

        menuRows[.diagnostics]?.title = tr(.copyDiagnostics)
        menuRows[.version]?.title = tr(.version)
        menuRows[.version]?.isEnabled = false
        menuRows[.quit]?.title = tr(.quit)
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
            intervalRows[minutes] = item
        }
        intervalMenu.addItem(.separator())
        let isCustom = !MenuBarPreferences.presetRefreshMinutes.contains(selected)
        let customTitle = tr(.customInterval) + (isCustom ? " (\(selected) min)" : "")
        let custom = NSMenuItem(title: customTitle, action: #selector(customRefreshIntervalClicked(_:)), keyEquivalent: "")
        custom.target = self
        custom.state = isCustom ? .on : .off
        intervalMenu.addItem(custom)
        menuRows[.intervalCustom] = custom
        let root = NSMenuItem(title: "\(tr(.refreshInterval)) (\(selected) min)", action: nil, keyEquivalent: "")
        root.submenu = intervalMenu
        menu.addItem(root)
        menuRows[.intervalRoot] = root
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
            languageRows[language.rawValue] = item
        }
        let root = NSMenuItem(title: tr(.language), action: nil, keyEquivalent: "")
        root.submenu = languageMenu
        menu.addItem(root)
        menuRows[.languageRoot] = root
    }

    /// Core errors are emitted in Chinese by the upstream reader; translate common
    /// diagnostic messages in the UI without altering the original log/diagnostic cause.
    private func displayedError() -> String? {
        guard let error = lastError else { return nil }
        return (isLoginError ? tr(.loginFailure) : "") + localizedErrorString(error)
    }

    private func localizedErrorString(_ message: String) -> String {
        guard activeLanguage == .english else { return message }
        if message.hasPrefix("无法安全读取或保存 ChatGPT 登录凭据") {
            return "Could not access secure ChatGPT credentials in Keychain."
        }
        if message.hasPrefix("额度服务请求失败（HTTP ") {
            return "Quota service request failed: " + message
        }
        if message.hasPrefix("网络请求失败：") {
            return "Network request failed: " + message.replacingOccurrences(of: "网络请求失败：", with: "")
        }
        if message.hasPrefix("ChatGPT OAuth 授权失败：") {
            return "ChatGPT authorization failed: " + message.replacingOccurrences(of: "ChatGPT OAuth 授权失败：", with: "")
        }
        if message.hasPrefix("无法启动本地 OAuth 回调服务：") {
            return "Could not start the local OAuth callback listener: " + message.replacingOccurrences(of: "无法启动本地 OAuth 回调服务：", with: "")
        }
        let translations: [String: String] = [
            "当前尚未登录 ChatGPT，请先登录。": "Not signed in to ChatGPT. Sign in to continue.",
            "ChatGPT 登录已过期或授权失效，请重新登录。": "Your ChatGPT session expired or was revoked. Sign in again.",
            "请求过于频繁（HTTP 429），请稍后重试。": "Too many requests (HTTP 429). Try again later.",
            "无法打开系统浏览器，请检查默认浏览器设置后重试。": "Could not open the system browser; check your default browser and try again.",
            "浏览器授权等待超时，请重新尝试。": "Browser authorization timed out. Please try again.",
            "OAuth 授权校验失败（state 不匹配），请重新登录。": "OAuth state validation failed. Please sign in again.",
            "无法安全读取或保存 ChatGPT 登录凭据（Keychain 错误": "Could not access secure ChatGPT credentials in Keychain.",
            "ChatGPT 当前没有返回可用的重置额度详情，请稍后刷新。": "ChatGPT did not return reset-credit details. Try refreshing later.",
            "ChatGPT 返回了不兼容的数据格式。": "ChatGPT returned an incompatible response.",
            "请求超时，请检查网络或代理后重试。": "Request timed out. Check your network or proxy and try again."
        ]
        return translations[message] ?? message
    }


}

/// A menu row that draws its own text, bypassing AppKit's disabled-item dimming.
private final class InformationalMenuItemView: NSView {
    private let label: NSTextField

    init(title: String, font: NSFont) {
        let label = NSTextField(labelWithString: title)
        label.font = font
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.sizeToFit()

        self.label = label
        let rowHeight: CGFloat = 28
        let leadingInset: CGFloat = 30
        let trailingInset: CGFloat = 12
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: leadingInset + label.frame.width + trailingInset,
            height: rowHeight
        ))

        // Let AppKit expand the view to the menu's full content width.
        autoresizingMask = [.width]
        label.frame.origin = NSPoint(
            x: leadingInset,
            y: (rowHeight - label.frame.height) / 2
        )
        label.autoresizingMask = [.width]
        addSubview(label)
    }

    func setTitle(_ text: String) {
        guard label.stringValue != text else { return }
        label.stringValue = text
        label.sizeToFit()
        // Preserve the original custom informational-row sizing and alignment.
        frame.size.width = 30 + label.frame.width + 12
        label.frame.origin = NSPoint(x: 30, y: (28 - label.frame.height) / 2)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

