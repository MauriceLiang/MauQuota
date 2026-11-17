import Foundation

/// Keeps OAuth credentials in memory for the lifetime of one MauQuota process.
/// Avoids repeated Keychain authorization prompts during periodic refresh,
/// reset-credit requests and the diagnostics menu.
///
/// A failing Keychain read is never cached: a later user retry may succeed.
/// Successful saves and deletes update the cache only after Keychain succeeds.
final class SessionCredentialStore: CodexCredentialStore {
    private enum CachedState {
        case notLoaded
        case loaded(CodexOAuthCredentials?)
    }

    private let underlying: CodexCredentialStore
    private let lock = NSLock()
    private var state: CachedState = .notLoaded

    init(underlying: CodexCredentialStore) {
        self.underlying = underlying
    }

    func load() throws -> CodexOAuthCredentials? {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .loaded(let credentials):
            return credentials
        case .notLoaded:
            let credentials = try underlying.load()
            state = .loaded(credentials)
            return credentials
        }
    }

    func save(_ credentials: CodexOAuthCredentials) throws {
        lock.lock()
        defer { lock.unlock() }
        try underlying.save(credentials)
        state = .loaded(credentials)
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        try underlying.delete()
        state = .loaded(nil)
    }
}
