import Foundation

/// A local record of a reset successfully redeemed through MauQuota.
/// This is not the full ChatGPT history; external and automatic resets are not visible here.
public struct ResetCreditHistoryEntry: Codable, Equatable, Identifiable {
    public let idempotencyKey: String
    public let title: String
    public let redeemedAt: Date
    public let expiresAt: Date?

    public var id: String { idempotencyKey }

    public init(idempotencyKey: String, title: String, redeemedAt: Date, expiresAt: Date?) {
        self.idempotencyKey = idempotencyKey
        self.title = title
        self.redeemedAt = redeemedAt
        self.expiresAt = expiresAt
    }
}

/// Persisted before sending a consume request so a timeout can be retried with the same key.
public struct PendingResetCreditAttempt: Codable, Equatable {
    public let idempotencyKey: String
    public let creditID: String?
    public let title: String
    public let expiresAt: Date?
    public let accountEmail: String?
    public let createdAt: Date

    public init(idempotencyKey: String, creditID: String?, title: String,
                expiresAt: Date?, accountEmail: String?, createdAt: Date = Date()) {
        self.idempotencyKey = idempotencyKey
        self.creditID = creditID
        self.title = title
        self.expiresAt = expiresAt
        self.accountEmail = accountEmail
        self.createdAt = createdAt
    }
}

public final class ResetCreditHistoryStore {
    private static let historyKey = "resetCreditHistory.v1"
    private static let pendingKey = "resetCreditPending.v1"
    private static let historyWindow: TimeInterval = 30 * 24 * 60 * 60
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var pendingAttempt: PendingResetCreditAttempt? {
        guard let data = defaults.data(forKey: Self.pendingKey) else { return nil }
        return try? JSONDecoder().decode(PendingResetCreditAttempt.self, from: data)
    }

    public var entries: [ResetCreditHistoryEntry] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.historyWindow)
        return loadEntries()
            .filter { $0.redeemedAt >= cutoff && $0.redeemedAt <= now }
            .sorted { $0.redeemedAt > $1.redeemedAt }
    }

    public func savePendingAttempt(_ attempt: PendingResetCreditAttempt) {
        guard let data = try? JSONEncoder().encode(attempt) else { return }
        defaults.set(data, forKey: Self.pendingKey)
    }

    /// Moves a confirmed or idempotently-retried attempt into local history.
    @discardableResult
    public func completePendingAttempt(at date: Date = Date()) -> ResetCreditHistoryEntry? {
        guard let pending = pendingAttempt else { return nil }
        let entry = ResetCreditHistoryEntry(
            idempotencyKey: pending.idempotencyKey,
            title: pending.title,
            redeemedAt: date,
            expiresAt: pending.expiresAt
        )
        var entries = loadEntries().filter {
            $0.idempotencyKey != pending.idempotencyKey &&
            $0.redeemedAt >= date.addingTimeInterval(-Self.historyWindow)
        }
        entries.append(entry)
        entries.sort { $0.redeemedAt > $1.redeemedAt }
        entries = Array(entries.prefix(100))
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.historyKey)
        }
        defaults.removeObject(forKey: Self.pendingKey)
        return entry
    }

    public func clearPendingAttempt() {
        defaults.removeObject(forKey: Self.pendingKey)
    }

    private func loadEntries() -> [ResetCreditHistoryEntry] {
        guard let data = defaults.data(forKey: Self.historyKey) else { return [] }
        return (try? JSONDecoder().decode([ResetCreditHistoryEntry].self, from: data)) ?? []
    }
}
