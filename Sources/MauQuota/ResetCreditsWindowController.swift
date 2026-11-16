import AppKit
import Foundation
import MauQuotaCore

/// NSScrollView normally uses a bottom-left document origin. A flipped document
/// view keeps short content pinned to the visible top of the scroll viewport.
private final class TopAlignedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class ResetCreditsWindowController: NSWindowController, NSWindowDelegate {
    private enum Tab: Int {
        case available = 0
        case history = 1
    }

    private let reader: CodexAPIClient
    private let account: CodexAccount
    private let language: DisplayLanguage
    private let historyStore = ResetCreditHistoryStore()
    private let onResetSuccess: () -> Void

    private var usage: CodexUsage?
    private var resetCredits: CodexResetCredits?
    private var displayedCredits: [CodexResetCredit] = []
    private var isLoading = false
    private var isConsuming = false
    private var loadError: String?
    private var statusMessage: String?
    private var selectedTab: Tab = .available

    private let tabs: NSSegmentedControl
    private let contentStack = TopAlignedStackView()
    private let scrollView = NSScrollView()
    private let refreshButton: NSButton
    var onWindowClose: (() -> Void)?

    private var isChinese: Bool { language == .simplifiedChinese }

    init(reader: CodexAPIClient,
         account: CodexAccount,
         usage: CodexUsage?,
         language: DisplayLanguage,
         onResetSuccess: @escaping () -> Void) {
        self.reader = reader
        self.account = account
        self.usage = usage
        self.language = language
        self.onResetSuccess = onResetSuccess

        tabs = NSSegmentedControl(
            labels: [language == .simplifiedChinese ? "可用" : "Available",
                     language == .simplifiedChinese ? "历史记录" : "History"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        refreshButton = NSButton(
            title: language == .simplifiedChinese ? "刷新" : "Refresh",
            target: nil,
            action: nil
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = language == .simplifiedChinese ? "使用限额重置" : "Usage limit resets"
        window.minSize = NSSize(width: 620, height: 460)
        window.center()
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildInterface()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }


    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        reload()
    }

    func updateUsage(_ usage: CodexUsage?) {
        self.usage = usage
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectedTab = sender.selectedSegment == 1 ? .history : .available
        statusMessage = nil
        render()
    }

    @objc private func refreshClicked(_ sender: Any?) {
        reload()
    }

    @objc private func openOfficialHistory(_ sender: Any?) {
        guard let url = URL(string: "https://chatgpt.com/codex/settings/usage") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func useCreditClicked(_ sender: NSButton) {
        guard !isConsuming, historyStore.pendingAttempt == nil else { return }
        let credit = sender.tag >= 0 && sender.tag < displayedCredits.count
            ? displayedCredits[sender.tag] : nil
        let title = credit.map(displayTitle(for:)) ?? genericResetTitle
        let attempt = PendingResetCreditAttempt(
            idempotencyKey: UUID().uuidString,
            creditID: credit?.id,
            title: title,
            expiresAt: credit?.expiresAt,
            accountEmail: account.email
        )
        confirmAndConsume(attempt, isRetry: false)
    }

    @objc private func retryPendingClicked(_ sender: Any?) {
        guard !isConsuming, let pending = historyStore.pendingAttempt,
              pendingBelongsToCurrentAccount(pending) else { return }
        confirmAndConsume(pending, isRetry: true)
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }
        // Keep the reading column centered and comfortably narrow on wide windows.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)

        let preferredWidth = container.widthAnchor.constraint(
            equalTo: contentView.widthAnchor,
            constant: -56
        )
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            container.topAnchor.constraint(equalTo: contentView.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 920),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            preferredWidth
        ])

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.distribution = .fill
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 26, left: 0, bottom: 22, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 7
        let title = label(isChinese ? "使用限额重置" : "Usage limit resets",
                          size: 25, weight: .semibold, color: .labelColor)
        let subtitle = label(
            isChinese
                ? "使用一次重置，即可恢复当前套餐支持的 Codex 使用限额。"
                : "Use a banked reset to restore the Codex allowances covered by your plan.",
            size: 14, weight: .regular, color: .secondaryLabelColor
        )
        subtitle.maximumNumberOfLines = 2
        title.alignment = .left
        subtitle.alignment = .left
        header.addArrangedSubview(title)
        header.addArrangedSubview(subtitle)
        root.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let headerDivider = separator()
        root.addArrangedSubview(headerDivider)
        headerDivider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let tabRow = NSStackView()
        tabRow.orientation = .horizontal
        tabRow.alignment = .centerY
        tabRow.distribution = .fill
        tabRow.spacing = 12
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        tabs.selectedSegment = 0
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))
        refreshButton.bezelStyle = .rounded
        tabRow.addArrangedSubview(tabs)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabRow.addArrangedSubview(spacer)
        tabRow.addArrangedSubview(refreshButton)
        root.addArrangedSubview(tabRow)
        tabRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        // Keep all dynamic content grouped at the top of the scroll view.
        // The scroll view may fill the window, but its document content must not
        // distribute spare height between rows.
        contentStack.distribution = .gravityAreas
        contentStack.spacing = 13
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentStack
        root.addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        contentStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

    }

    private func reload(preservingStatus: Bool = false) {
        guard !isLoading, !isConsuming else { return }
        isLoading = true
        loadError = nil
        if !preservingStatus { statusMessage = nil }
        render()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = autoreleasepool {
                Result { try self.reader.loadResetCredits() }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let credits):
                    self.resetCredits = credits
                    self.loadError = nil
                case .failure(let error):
                    self.loadError = error.localizedDescription
                    self.resetCredits = nil
                }
                self.render()
            }
        }
    }

    private func render() {
        tabs.setLabel(
            (isChinese ? "可用" : "Available") + (resetCredits.map { " \($0.availableCount)" } ?? ""),
            forSegment: 0
        )
        tabs.setLabel(isChinese ? "历史记录" : "History", forSegment: 1)
        tabs.selectedSegment = selectedTab.rawValue
        refreshButton.isEnabled = !isLoading && !isConsuming
        clearContent()

        if let statusMessage {
            addContent(messageRow(statusMessage, color: .secondaryLabelColor))
        }

        switch selectedTab {
        case .available:
            renderAvailable()
        case .history:
            renderHistory()
        }

        // The note is part of the page content, not a bottom-pinned footer.
        // This keeps both tabs in a natural top-to-bottom reading order.
        let footer = label(
            isChinese
                ? "重置额度是一次性权益，不会累加为永久额度。"
                : "Resets are one-time benefits; they do not permanently increase your plan limits.",
            size: 12, weight: .regular, color: .secondaryLabelColor
        )
        footer.maximumNumberOfLines = 2
        addContent(footer)
        scrollContentToTop()
    }

    /// Re-anchor the flipped document view after rebuilding either tab.
    private func scrollContentToTop() {
        scrollView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        clipView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func renderAvailable() {
        if isLoading {
            addContent(messageRow(
                isChinese ? "正在读取可用重置额度…" : "Loading available resets…",
                color: .secondaryLabelColor
            ))
            return
        }
        if let loadError {
            addContent(messageRow(
                (isChinese ? "读取失败：" : "Could not load resets: ") + loadError,
                color: .systemRed
            ))
            return
        }
        guard let resetCredits else {
            addContent(messageRow(
                isChinese ? "尚未读取重置额度。" : "Reset availability has not been loaded.",
                color: .secondaryLabelColor
            ))
            return
        }

        let pending = historyStore.pendingAttempt
        if let pending {
            let belongs = pendingBelongsToCurrentAccount(pending)
            let pendingText: String
            if belongs {
                pendingText = isChinese
                    ? "上次重置的结果尚未确认。安全重试会复用同一个请求编号，不会创建新的重置请求。"
                    : "The previous reset outcome is unknown. A safe retry reuses the same idempotency key."
            } else {
                pendingText = isChinese
                    ? "存在另一个账号发起的待确认操作。请切换回 \(pending.accountEmail ?? "原账号") 后再处理。"
                    : "A pending reset belongs to another account. Sign back in as \(pending.accountEmail ?? "the original account") to resolve it."
            }
            addContent(messageRow(pendingText, color: .systemOrange))
            if belongs {
                let retry = NSButton(
                    title: isChinese ? "安全重试上次操作…" : "Safely retry previous operation…",
                    target: self,
                    action: #selector(retryPendingClicked(_:))
                )
                retry.bezelStyle = .rounded
                retry.isEnabled = !isConsuming
                addContent(leadingControlRow(retry))
            }
            addContent(separator())
        }

        let countTitle = label(
            isChinese ? "可用 \(resetCredits.availableCount) 张重置额度" : "\(resetCredits.availableCount) reset(s) available",
            size: 16, weight: .semibold, color: .labelColor
        )
        addContent(countTitle)

        guard resetCredits.availableCount > 0 else {
            addContent(messageRow(
                isChinese ? "当前没有可用的重置额度。" : "No usage limit resets are currently available.",
                color: .secondaryLabelColor
            ))
            return
        }

        let sorted = (resetCredits.credits ?? [])
            .filter { $0.status == "available" }
            .sorted {
                switch ($0.expiresAt, $1.expiresAt) {
                case let (left?, right?): return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return $0.grantedAt < $1.grantedAt
                }
            }
        displayedCredits = Array(sorted.prefix(resetCredits.availableCount))

        if resetCredits.credits == nil || sorted.isEmpty {
            addContent(messageRow(
                isChinese
                    ? "服务只返回了可用数量，没有返回卡片详情。使用时将由官方服务选择下一张可用额度。"
                    : "The service returned the count but no card details. The official service will select the next available reset.",
                color: .secondaryLabelColor
            ))
            let useNext = NSButton(
                title: isChinese ? "使用下一张可用额度…" : "Use next available reset…",
                target: self,
                action: #selector(useCreditClicked(_:))
            )
            useNext.tag = -1
            useNext.bezelStyle = .rounded
            useNext.isEnabled = pending == nil && !isConsuming
            addContent(leadingControlRow(useNext))
            return
        }

        for (index, credit) in displayedCredits.enumerated() {
            addContent(makeCreditRow(credit, index: index, enabled: pending == nil && !isConsuming))
            if index < displayedCredits.count - 1 {
                addContent(separator())
            }
        }

        if displayedCredits.count < resetCredits.availableCount {
            let missing = resetCredits.availableCount - displayedCredits.count
            addContent(messageRow(
                isChinese
                    ? "官方服务当前仅返回了 \(displayedCredits.count) 张卡片详情；可用总数为 \(resetCredits.availableCount)，另有 \(missing) 张暂不可单独选择。"
                    : "The service returned details for \(displayedCredits.count) of \(resetCredits.availableCount) available resets. The remaining \(missing) cannot be selected individually yet.",
                color: .secondaryLabelColor
            ))
        }

        addContent(messageRow(
            isChinese
                ? "只有至少一项受支持的限额剩余低于 80% 时，重置才会生效；否则卡片会保留。"
                : "A reset is applied only when at least one covered allowance has less than 80% remaining. Otherwise, the card is kept.",
            color: .secondaryLabelColor
        ))
    }

    private func renderHistory() {
        let heading = label(
            isChinese ? "MauQuota 本机记录" : "MauQuota local history",
            size: 16, weight: .semibold, color: .labelColor
        )
        addContent(heading)
        addContent(messageRow(
            isChinese
                ? "这里只记录通过 MauQuota 发起并确认成功的重置。其他设备、Codex CLI、自动重置，以及收到但尚未使用的记录不会显示。"
                : "This list only records resets successfully redeemed through MauQuota. It does not include other devices, Codex CLI, automatic resets, or received-but-unused resets.",
            color: .secondaryLabelColor
        ))

        let entries = historyStore.entries
        if entries.isEmpty {
            addContent(messageRow(
                isChinese ? "暂无 MauQuota 重置记录。" : "No resets have been redeemed through MauQuota yet.",
                color: .secondaryLabelColor
            ))
        } else {
            for (index, entry) in entries.enumerated() {
                let row = NSStackView()
                row.orientation = .vertical
                row.alignment = .leading
                row.spacing = 5
                row.addArrangedSubview(label(entry.title, size: 15, weight: .medium, color: .labelColor))
                row.addArrangedSubview(label(
                    (isChinese ? "重置成功 · " : "Reset used · ") + formatDate(entry.redeemedAt),
                    size: 13, weight: .regular, color: .secondaryLabelColor
                ))
                addContent(row)
                if index < entries.count - 1 { addContent(separator()) }
            }
        }

        let official = NSButton(
            title: isChinese ? "在 ChatGPT 中查看完整历史记录" : "View full history in ChatGPT",
            target: self,
            action: #selector(openOfficialHistory(_:))
        )
        official.bezelStyle = .rounded
        addContent(leadingControlRow(official))
        addContent(messageRow(
            isChinese
                ? "ChatGPT 官方历史记录覆盖最近 30 天的已收到和已使用记录。"
                : "ChatGPT's official history includes received and used reset activity from the past 30 days.",
            color: .secondaryLabelColor
        ))
    }

    private func makeCreditRow(_ credit: CodexResetCredit, index: Int, enabled: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 18

        let details = NSStackView()
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6
        details.addArrangedSubview(label(displayTitle(for: credit), size: 16, weight: .medium, color: .labelColor))
        details.addArrangedSubview(label(displayDescription(for: credit), size: 13, weight: .regular, color: .secondaryLabelColor))
        let expiration = credit.expiresAt.map {
            (isChinese ? "将于 " : "Expires ") + formatDate($0)
        } ?? (isChinese ? "无到期时间" : "Does not expire")
        details.addArrangedSubview(label(expiration, size: 13, weight: .regular, color: .secondaryLabelColor))
        details.setContentHuggingPriority(.defaultLow, for: .horizontal)
        details.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(details)

        let button = NSButton(
            title: isChinese ? "使用重置额度" : "Use reset",
            target: self,
            action: #selector(useCreditClicked(_:))
        )
        button.tag = index
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.isEnabled = enabled
        row.addArrangedSubview(button)
        return row
    }

    private var genericResetTitle: String {
        if isChinese { return "Codex 使用限额重置" }
        return "Codex usage limit reset"
    }

    private func displayTitle(for credit: CodexResetCredit) -> String {
        let provided = credit.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let generic = ["rate-limit reset", "full reset", "reset"]
        if !provided.isEmpty && !generic.contains(provided.lowercased()) { return provided }
        switch account.planType?.lowercased() {
        case "plus", "business":
            return isChinese ? "完全重置（每周 + 5 小时）" : "Full reset (weekly + 5-hour)"
        case "pro":
            return isChinese ? "完全重置（每周）" : "Full reset (weekly)"
        case "go":
            return isChinese ? "完全重置（月度）" : "Full reset (monthly)"
        default:
            return genericResetTitle
        }
    }

    private func displayDescription(for credit: CodexResetCredit) -> String {
        let provided = credit.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let generic = [
            "reset an eligible codex rate-limit window.",
            "reset your current usage limits"
        ]
        if !provided.isEmpty && !generic.contains(provided.lowercased()) { return provided }
        switch account.planType?.lowercased() {
        case "plus", "business":
            return isChinese ? "恢复当前套餐的 5 小时和每周 Codex 限额" : "Restores the 5-hour and weekly Codex allowances on this plan"
        case "pro":
            return isChinese ? "恢复当前套餐的每周 Codex 限额" : "Restores the weekly Codex allowance on this plan"
        case "go":
            return isChinese ? "恢复当前套餐的月度 Codex 限额" : "Restores the monthly Codex allowance on this plan"
        default:
            return isChinese ? "恢复当前套餐支持的 Codex 使用限额" : "Restores the Codex allowances covered by this plan"
        }
    }

    private func confirmAndConsume(_ attempt: PendingResetCreditAttempt, isRetry: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isRetry
            ? (isChinese ? "确认安全重试？" : "Confirm safe retry?")
            : (isChinese ? "确认使用这张重置额度？" : "Use this reset?")
        let currentUsage = usageSummary
        let retryNote = isRetry
            ? (isChinese ? "\n将复用上次请求编号，不会新建一次重置操作。" : "\nThe previous idempotency key will be reused.")
            : ""
        alert.informativeText = (isChinese
            ? "\(attempt.title)\n\(attempt.expiresAt.map { "到期时间：" + formatDate($0) } ?? "无到期时间")\n\n当前额度：\(currentUsage)\n\n重置额度为一次性权益，成功使用后无法退回。若所有覆盖限额均剩余 80% 或以上，服务不会消耗这张卡。"
            : "\(attempt.title)\n\(attempt.expiresAt.map { "Expires: " + formatDate($0) } ?? "No expiration")\n\nCurrent allowances: \(currentUsage)\n\nA redeemed reset cannot be returned. If every covered allowance has 80% or more remaining, the service will keep this card.") + retryNote
        alert.addButton(withTitle: isChinese ? "确认使用" : "Confirm use")
        alert.addButton(withTitle: isChinese ? "取消" : "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if !isRetry { historyStore.savePendingAttempt(attempt) }
        performConsume(attempt)
    }

    private func performConsume(_ attempt: PendingResetCreditAttempt) {
        guard !isConsuming else { return }
        isConsuming = true
        statusMessage = isChinese ? "正在使用重置额度…" : "Redeeming reset…"
        render()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = autoreleasepool {
                Result {
                    try self.reader.consumeResetCredit(
                        creditID: attempt.creditID,
                        idempotencyKey: attempt.idempotencyKey
                    )
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isConsuming = false
                switch result {
                case .success(.reset), .success(.alreadyRedeemed):
                    self.historyStore.completePendingAttempt()
                    self.statusMessage = self.isChinese
                        ? "重置已确认成功，正在刷新额度和可用卡片。"
                        : "Reset confirmed. Refreshing usage and available resets."
                    self.onResetSuccess()
                    self.reload(preservingStatus: true)
                case .success(.nothingToReset):
                    self.historyStore.clearPendingAttempt()
                    self.statusMessage = self.isChinese
                        ? "当前额度无需重置，重置卡未被消耗。"
                        : "Your usage does not need a reset. The card was not consumed."
                    self.reload(preservingStatus: true)
                case .success(.noCredit):
                    self.historyStore.clearPendingAttempt()
                    self.statusMessage = self.isChinese
                        ? "这张重置卡已不可用或已过期，请刷新列表。"
                        : "This reset is no longer available or has expired. Refresh the list."
                    self.reload(preservingStatus: true)
                case .failure(let error):
                    // Keep the exact key and credit ID. A retry cannot consume a second card.
                    self.statusMessage = (self.isChinese
                        ? "重置结果暂时无法确认：\(error.localizedDescription)。请使用“安全重试上次操作”，不要重新选择另一张卡。"
                        : "The reset outcome is unknown: \(error.localizedDescription). Use the safe retry action; do not start a new redemption.")
                    self.render()
                }
            }
        }
    }

    private func pendingBelongsToCurrentAccount(_ pending: PendingResetCreditAttempt) -> Bool {
        guard let oldEmail = pending.accountEmail?.lowercased(),
              let currentEmail = account.email?.lowercased() else { return true }
        return oldEmail == currentEmail
    }

    private var usageSummary: String {
        let windows = [usage?.shortWindow, usage?.longWindow].compactMap { $0 }
        guard !windows.isEmpty else { return isChinese ? "暂不可用" : "Unavailable" }
        return windows.map { "\($0.label) \($0.remainingPercent)%" }.joined(separator: " · ")
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.timeZone = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.alignment = .left
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }

    /// Adds one full-width item to the reading column. Text labels explicitly align left.
    private func addContent(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addView(view, in: .top)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    /// Keeps intrinsic-size controls on the left without stretching them across the row.
    private func leadingControlRow(_ control: NSView) -> NSView {
        let row = NSView()
        row.addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    private func messageRow(_ text: String, color: NSColor) -> NSView {
        let field = label(text, size: 13, weight: .regular, color: color)
        field.maximumNumberOfLines = 0
        let container = NSView()
        container.addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])
        return container
    }

    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    func windowWillClose(_ notification: Notification) {
        let handler = onWindowClose
        onWindowClose = nil
        handler?()
    }

    private func clearContent() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}
