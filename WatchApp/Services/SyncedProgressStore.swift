import Foundation
import ReaderCore

/// Identifies one remote position as the service returned it (before the CFI is placed in the book), so a
/// declined "Continue where you left off?" offer is not repeated until the remote position changes.
struct RemoteFingerprint: Codable, Equatable, Sendable {
    var xpointer: String
    var cfi: String?
    var percentage: Double
    var timestamp: Date?

    init(_ remote: ReadingPosition) {
        xpointer = remote.xpointer
        cfi = remote.cfi
        percentage = remote.percentage
        timestamp = remote.timestamp
    }

    /// Same row content: XPointer, CFI, fraction and (when the service gives one) the save time.
    func matches(_ remote: ReadingPosition) -> Bool {
        xpointer == remote.xpointer && cfi == remote.cfi && abs(percentage - remote.percentage) < 1e-9
            && timestamp == remote.timestamp
    }
}

/// What the watch remembers about remote positions per book (keyed by documentHash), on this watch only:
/// - the *synced* position: a remote position ahead of the local one, found by the background refresh, that
///   the complications and the Library show until the book is opened (#132);
/// - the *declined* remote position: the offer the user answered "Stay Here" to, not offered again until the
///   service holds another position;
/// - the book's sync identity (Readest meta hash, title, authors), recorded when the book is opened, so the
///   refresh can ask for it without decoding the whole book.
/// Backed by `UserDefaults`; removed with the book and by Settings › Reset.
final class SyncedProgressStore: @unchecked Sendable {
    static let syncedKey = "sync.synced.v1"
    static let declinedKey = "sync.declined.v1"
    static let identityKey = "sync.identity.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func read<T: Decodable>(_ key: String) -> [String: T] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: T].self, from: data)) ?? [:]
    }

    private func update<T: Codable>(_ key: String, _ change: (inout [String: T]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var map: [String: T] = read(key)
        change(&map)
        if map.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: key)
        }
    }

    private func value<T: Decodable>(_ key: String, _ bookKey: String) -> T? {
        lock.lock(); defer { lock.unlock() }
        let map: [String: T] = read(key)
        return map[bookKey]
    }

    // MARK: Synced position

    func synced(for bookKey: String) -> ReadingPosition? { value(Self.syncedKey, bookKey) }

    func setSynced(_ position: ReadingPosition, for bookKey: String) {
        update(Self.syncedKey) { (m: inout [String: ReadingPosition]) in m[bookKey] = position }
    }

    func clearSynced(for bookKey: String) {
        update(Self.syncedKey) { (m: inout [String: ReadingPosition]) in m.removeValue(forKey: bookKey) }
    }

    /// Sync turned off: the local positions are shown again.
    func clearAllSynced() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.syncedKey)
    }

    // MARK: Declined offer

    func declined(for bookKey: String) -> RemoteFingerprint? { value(Self.declinedKey, bookKey) }

    func setDeclined(_ fingerprint: RemoteFingerprint, for bookKey: String) {
        update(Self.declinedKey) { (m: inout [String: RemoteFingerprint]) in m[bookKey] = fingerprint }
    }

    func clearDeclined(for bookKey: String) {
        update(Self.declinedKey) { (m: inout [String: RemoteFingerprint]) in m.removeValue(forKey: bookKey) }
    }

    // MARK: Identity

    func identity(for bookKey: String) -> BookIdentity? { value(Self.identityKey, bookKey) }

    func setIdentity(_ book: BookIdentity) {
        guard identity(for: book.key) != book else { return }
        update(Self.identityKey) { (m: inout [String: BookIdentity]) in m[book.key] = book }
    }

    // MARK: Removal

    /// Forgets a deleted book.
    func remove(bookKey: String) {
        clearSynced(for: bookKey)
        clearDeclined(for: bookKey)
        update(Self.identityKey) { (m: inout [String: BookIdentity]) in m.removeValue(forKey: bookKey) }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        for key in [Self.syncedKey, Self.declinedKey, Self.identityKey] { defaults.removeObject(forKey: key) }
    }
}
