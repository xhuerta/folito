import Foundation

/// Open-book decision for any connector.
public enum ProgressDecision: Equatable, Sendable {
    case keepLocal
    case offerRemote(ReadingPosition)
}

public extension ReadingPosition {
    /// Whether two positions name the same spot in the same file: equal non-empty XPointers, or (when an
    /// XPointer is missing) the same `[page, pageCount]` pair. Percentages are not compared because a
    /// service may derive them differently (Readest: `page / pageCount`; Folito: characters before the
    /// block), so the same spot can read "0 %" locally and "1 %" remotely.
    func isSameSpot(as other: ReadingPosition) -> Bool {
        if !xpointer.isEmpty, !other.xpointer.isEmpty { return xpointer == other.xpointer }
        if let p = page, let c = pageCount, let op = other.page, let oc = other.pageCount {
            return p == op && c == oc
        }
        return false
    }
}

public extension SyncConflictPolicy {
    /// Connector-neutral form of `decide(localPercentage:remote:ownDeviceID:)`: the same rule (offer the
    /// remote position when another device is ahead), applied to a `ReadingPosition`. A remote position
    /// without a device id (Readest stores none) counts as another device.
    func decide(localPercentage: Double, remote: ReadingPosition?, ownDeviceID: String) -> ProgressDecision {
        guard let remote else { return .keepLocal }
        let k = KOSyncProgress(document: "", progress: remote.xpointer, percentage: remote.percentage,
                               device: remote.deviceName, device_id: remote.deviceID)
        switch decide(localPercentage: localPercentage, remote: k, ownDeviceID: ownDeviceID) {
        case .keepLocal: return .keepLocal
        case .offerRemote: return .offerRemote(remote)
        }
    }

    /// Open-book decision that also recognises this device's own progress coming back (issue #105).
    ///
    /// Services that store no device id (Readest) cannot say who wrote a position, so the remote position
    /// is never offered when it is the spot the reader is already at (`local`), or the last position this
    /// device pushed for the book (`lastPushed`, persisted by the caller). Only then does the percentage
    /// rule of `decide(localPercentage:remote:ownDeviceID:)` apply.
    func decide(local: ReadingPosition, remote: ReadingPosition?, ownDeviceID: String,
                lastPushed: ReadingPosition? = nil) -> ProgressDecision {
        guard let remote else { return .keepLocal }
        if remote.isSameSpot(as: local) { return .keepLocal }
        if let lastPushed, remote.isSameSpot(as: lastPushed) { return .keepLocal }
        return decide(localPercentage: local.percentage, remote: remote, ownDeviceID: ownDeviceID)
    }
}

/// The last position this device pushed, per connector and book, so that a service without device ids
/// (Readest) can tell its own write from another device's. Backed by `UserDefaults`; bounded.
public final class OwnProgressLog: @unchecked Sendable {
    public static let defaultsKey = "sync.lastPushed.v1"
    /// Oldest entries are dropped past this many books.
    public static let capacity = 300

    private struct Entry: Codable {
        var position: ReadingPosition
        var recordedAt: Date
    }

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = OwnProgressLog.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    private static func slot(_ connectorID: String, _ bookKey: String) -> String { connectorID + "|" + bookKey }

    private func read() -> [String: Entry] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func write(_ entries: [String: Entry]) {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }

    /// Records a position the service accepted.
    public func record(_ position: ReadingPosition, connectorID: String, bookKey: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var entries = read()
        entries[Self.slot(connectorID, bookKey)] = Entry(position: position, recordedAt: now)
        if entries.count > Self.capacity {
            let excess = entries.sorted { $0.value.recordedAt < $1.value.recordedAt }.prefix(entries.count - Self.capacity)
            for (k, _) in excess { entries.removeValue(forKey: k) }
        }
        write(entries)
    }

    public func lastPushed(connectorID: String, bookKey: String) -> ReadingPosition? {
        lock.lock(); defer { lock.unlock() }
        return read()[Self.slot(connectorID, bookKey)]?.position
    }

    /// Forgets a deleted book (every connector).
    public func remove(bookKey: String) {
        lock.lock(); defer { lock.unlock() }
        var entries = read()
        for k in entries.keys where k.hasSuffix("|" + bookKey) { entries.removeValue(forKey: k) }
        write(entries)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
}
