import Foundation

// Which books sync (issue #167): the per-book switch "Sync Progress for This Book", the Readest library link the
// iPhone reports, and the pure decision that combines them with the active connector. Also the wire forms of
// both in the WatchConnectivity contexts. See docs/SYNC_CONNECTORS.md ("Which books sync") and
// docs/WATCH_CONNECTIVITY.md ("Per-book sync").

/// Why a book does or does not sync with the active service.
public enum BookSyncDecision: Equatable, Sendable {
    /// The book's position is fetched and pushed as usual.
    case sync
    /// The user turned "Sync Progress for This Book" off: nothing about the book goes to any service.
    case switchedOff
    /// The service keeps a library (Readest) and the book is not in it: a fetch can never find anything and a
    /// push would only create progress for a book the service does not show.
    case notInLibrary

    public var syncs: Bool { self == .sync }
}

/// The pure rule: connector kind x library link x per-book switch.
public enum BookSyncPolicy {
    /// - Parameters:
    ///   - requiresLibraryLink: the active connector syncs only books in its library
    ///     (`SyncConnectorDescriptor.requiresLibraryLink`: Readest yes, KOReader Sync no).
    ///   - linked: whether the book is linked to a row of that library; nil = unknown (an iPhone that has not
    ///     reported it, e.g. an older app or a library not loaded yet), which keeps the behaviour of earlier
    ///     versions: the book syncs.
    ///   - switchedOn: the book's switch (default on).
    /// The user's switch wins over the link: a book switched off says so even when it is also not linked.
    public static func decide(requiresLibraryLink: Bool, linked: Bool?, switchedOn: Bool) -> BookSyncDecision {
        guard switchedOn else { return .switchedOff }
        if requiresLibraryLink, linked == false { return .notInLibrary }
        return .sync
    }
}

/// The per-book switch as one device knows it, with the time it was set (ms since 1970, like `ReadStatusMark`),
/// so the iPhone and the watch merge their copies by last writer wins.
public struct BookSyncSwitch: Sendable, Equatable, Codable {
    public var isOn: Bool
    /// When the switch was set, in ms since 1970; 0 = unknown.
    public var stamp: Int64

    public init(isOn: Bool, stamp: Int64) {
        self.isOn = isOn
        self.stamp = max(0, stamp)
    }

    // Short keys: the switches of a whole library travel in the WatchConnectivity contexts.
    enum CodingKeys: String, CodingKey {
        case isOn = "on"
        case stamp = "t"
    }

    /// Tolerant: a missing or invalid value decodes as on (the default), a missing or invalid stamp as 0, so a
    /// switch from another app version never fails the whole library.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedOn: Bool? = try? c.decodeIfPresent(Bool.self, forKey: .isOn)
        isOn = decodedOn ?? true
        let decodedStamp: Int64? = try? c.decodeIfPresent(Int64.self, forKey: .stamp)
        stamp = max(0, decodedStamp ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isOn, forKey: .isOn)
        try c.encode(stamp, forKey: .stamp)
    }

    /// The switch set to `isOn` now: stamped strictly newer than the one it replaces.
    public static func set(_ isOn: Bool, now: Date, replacing previous: BookSyncSwitch?) -> BookSyncSwitch {
        BookSyncSwitch(isOn: isOn, stamp: max(ReadStatusRules.millis(now), (previous?.stamp ?? 0) + 1))
    }
}

/// Last writer wins, by `stamp`, between the copies of the switches (same rule as `ReadStatusMerge`).
public enum BookSyncSwitchMerge {
    /// An incoming copy replaces the local one only when it is strictly newer; a tie keeps the local copy, so
    /// the periodic resends of WatchConnectivity are idempotent.
    public static func shouldApply(incoming: BookSyncSwitch, local: BookSyncSwitch?) -> Bool {
        guard let local else { return true }
        return incoming.stamp > local.stamp
    }

    /// Merges another device's switches into the local ones, per book. Returns the result and the books whose
    /// switch changed.
    public static func merge(local: [String: BookSyncSwitch],
                             incoming: [String: BookSyncSwitch]) -> (switches: [String: BookSyncSwitch], changed: Set<String>) {
        var switches = local
        var changed = Set<String>()
        for (hash, incomingSwitch) in incoming where !hash.isEmpty && shouldApply(incoming: incomingSwitch, local: local[hash]) {
            if switches[hash] != incomingSwitch {
                switches[hash] = incomingSwitch
                changed.insert(hash)
            }
        }
        return (switches, changed)
    }
}

/// What a device knows about which books sync: the switches and, from the iPhone, the books linked to a Readest
/// row. Sendable, so the sync queue can be pruned with it.
public struct BookSyncSettings: Sendable, Equatable, Codable {
    /// Document hashes of the books linked to a row of the user's Readest library; nil = unknown (no report, or
    /// the iPhone does not know: Readest not active there, library not loaded yet).
    public var readestLinked: Set<String>?
    /// Per-book switches; a book without one is on.
    public var switches: [String: BookSyncSwitch]

    public init(readestLinked: Set<String>? = nil, switches: [String: BookSyncSwitch] = [:]) {
        self.readestLinked = readestLinked
        self.switches = switches
    }

    public func isSwitchedOn(_ bookKey: String) -> Bool { switches[bookKey]?.isOn ?? true }

    /// The decision for one book under a connector that does (`requiresLibraryLink`) or does not keep a library.
    public func decision(for bookKey: String, requiresLibraryLink: Bool) -> BookSyncDecision {
        BookSyncPolicy.decide(requiresLibraryLink: requiresLibraryLink,
                              linked: readestLinked.map { $0.contains(bookKey) },
                              switchedOn: isSwitchedOn(bookKey))
    }

    /// The decision under the given connector; nil connector (sync off) never syncs.
    public func decision(for bookKey: String, connector: SyncConnectorDescriptor?) -> BookSyncDecision? {
        guard let connector else { return nil }
        return decision(for: bookKey, requiresLibraryLink: connector.requiresLibraryLink)
    }

    enum CodingKeys: String, CodingKey { case readestLinked, switches }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        readestLinked = try? c.decodeIfPresent(Set<String>.self, forKey: .readestLinked)
        switches = (try? c.decodeIfPresent([String: BookSyncSwitch].self, forKey: .switches)) ?? [:]
    }
}

/// The wire forms in the WatchConnectivity contexts.
///  - `bookSync`: the switches, a JSON object `{"<documentHash>": {"on": false, "t": <ms>}}` as a string, both
///    directions (iPhone `settings` context, watch `library` context). Absent while no book has one.
///  - `readestLinked`: iPhone -> watch only (`settings` context), the array of document hashes linked to a Readest
///    row. Present (possibly empty) only while the iPhone knows the Readest library; absent = unknown, and the
///    watch then syncs every book as earlier versions did.
public enum BookSyncWire {
    public static let switchesKey = "bookSync"
    public static let readestLinkedKey = "readestLinked"

    /// Nothing for an empty map (older apps simply never see the key).
    public static func context(switches: [String: BookSyncSwitch]) -> [String: Any] {
        guard !switches.isEmpty, let data = try? JSONEncoder().encode(switches),
              let json = String(data: data, encoding: .utf8) else { return [:] }
        return [switchesKey: json]
    }

    /// The switches of a context; nil when it carries none or the value is not a JSON object of switches.
    public static func switches(from info: [String: Any]) -> [String: BookSyncSwitch]? {
        guard let json = info[switchesKey] as? String, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: BookSyncSwitch].self, from: data) else { return nil }
        return decoded.filter { !$0.key.isEmpty }
    }

    /// Nothing when the link is unknown (nil); a sorted array otherwise, so an unchanged set gives the same context.
    public static func context(readestLinked: Set<String>?) -> [String: Any] {
        guard let readestLinked else { return [:] }
        return [readestLinkedKey: readestLinked.filter { !$0.isEmpty }.sorted()]
    }

    /// The linked books of a context; nil when the context does not carry the key (unknown).
    public static func readestLinked(from info: [String: Any]) -> Set<String>? {
        guard let list = info[readestLinkedKey] as? [String] else { return nil }
        return Set(list.filter { !$0.isEmpty })
    }
}
