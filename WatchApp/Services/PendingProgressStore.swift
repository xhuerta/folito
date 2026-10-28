import Foundation
import ReaderCore

/// Progress that could not be pushed yet. At most one (the latest) entry per document,
/// persisted as JSON in UserDefaults so it survives app restarts.
final class PendingProgressStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "sync.pendingProgress") {
        self.defaults = defaults
        self.key = key
    }

    func all() -> [KOSyncProgress] {
        lock.lock(); defer { lock.unlock() }
        return read().values.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
    }

    var isEmpty: Bool { all().isEmpty }

    /// Replaces any older pending entry for the same document.
    func upsert(_ progress: KOSyncProgress) {
        lock.lock(); defer { lock.unlock() }
        var dict = read()
        dict[progress.document] = progress
        write(dict)
    }

    /// Removes the entry only if it is still the one that was pushed (a newer one may have replaced it).
    func remove(_ progress: KOSyncProgress) {
        lock.lock(); defer { lock.unlock() }
        var dict = read()
        if dict[progress.document] == progress {
            dict.removeValue(forKey: progress.document)
            write(dict)
        }
    }

    func removeDocument(_ document: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = read()
        dict.removeValue(forKey: document)
        write(dict)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }

    private func read() -> [String: KOSyncProgress] {
        guard let data = defaults.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: KOSyncProgress].self, from: data) else { return [:] }
        return dict
    }

    private func write(_ dict: [String: KOSyncProgress]) {
        if let data = try? JSONEncoder().encode(dict) { defaults.set(data, forKey: key) }
    }
}
