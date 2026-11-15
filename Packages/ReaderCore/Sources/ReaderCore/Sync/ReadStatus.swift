import Foundation

// Read status of a book ("Finished", issue #113): the model, the rules for setting it, the last-writer-wins
// merge used between the iPhone, the watch and Readest, and the WatchConnectivity wire form.
// See docs/WATCH_CONNECTIVITY.md ("Read status") and docs/READEST_SYNC.md ("Reading status").

/// A book's read status. The raw values are Readest's `ReadingStatus`
/// (apps/readest-app/src/types/book.ts: `'unread' | 'reading' | 'finished' | 'abandoned'`), so a status
/// read from a `books` row is written back unchanged. Folito itself sets only `.finished` and `.unread`
/// ("Mark as Finished" / "Mark as Unread", the same two actions as Readest's book menu).
public enum ReadStatus: String, Codable, Sendable, CaseIterable {
    case unread
    case reading
    case finished
    /// Readest's "On hold".
    case abandoned
}

/// The status one device knows for a book and when it was set. `stamp` is milliseconds since 1970, the clock
/// of Readest's `reading_status_updated_at`, so the three copies (iPhone, watch, Readest) compare directly.
public struct ReadStatusMark: Sendable, Equatable, Codable {
    /// nil = no status (Readest's null, e.g. after "Clear Status" in the Readest app).
    public var status: ReadStatus?
    /// When the status was set, in ms since 1970; 0 = unknown (a Readest row without a timestamp).
    public var stamp: Int64

    public init(status: ReadStatus?, stamp: Int64) {
        self.status = status
        self.stamp = max(0, stamp)
    }

    public var isFinished: Bool { status == .finished }

    // Short keys: the marks of a whole library travel in the WatchConnectivity contexts.
    enum CodingKeys: String, CodingKey {
        case status = "s"
        case stamp = "t"
    }

    /// Tolerant: an unknown status (a newer app, a new Readest value) decodes as "no status", a missing or
    /// invalid stamp as 0, so a mark from another app version never fails the whole library.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw: String? = try? c.decodeIfPresent(String.self, forKey: .status)
        status = raw.flatMap(ReadStatus.init(rawValue:))
        let decoded: Int64? = try? c.decodeIfPresent(Int64.self, forKey: .stamp)
        stamp = max(0, decoded ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(status?.rawValue, forKey: .status)
        try c.encode(stamp, forKey: .stamp)
    }
}

/// When and how the status is set.
public enum ReadStatusRules {
    /// Slack, in points, below the viewport's bottom edge within which the end of the last block still counts as
    /// on screen (layout rounding).
    public static let endTolerance: Double = 8

    /// The reader has reached the end of the book: the bottom of the book's last block is on screen.
    /// The watch reader scrolls continuously and saves the line at the top edge, so its percentage never reaches
    /// 100 % (the last screen starts before the end); the end being visible is the precise signal.
    /// `lastBlockMaxY` is nil while the last block is not laid out (far from the end).
    public static func reachedEnd(lastBlockMaxY: Double?, viewportBottom: Double) -> Bool {
        guard let lastBlockMaxY, lastBlockMaxY.isFinite, viewportBottom.isFinite else { return false }
        return lastBlockMaxY <= viewportBottom + endTolerance
    }

    /// Books shorter than this (in characters, about ten watch screens) get no offer: a sample or an excerpt is
    /// scrolled through in a few swipes, so its end coming on screen says nothing about having finished a book,
    /// and a modal question there only interrupts. The reader menu still has Mark as Finished for them.
    public static let minimumOfferCharacters = 10_000

    /// Whether the watch offers "Mark as Finished?": only when the reader *arrives* at the end while reading
    /// (not when the book merely opens there), only once per opening (`alreadyOffered`: shown or declined), never
    /// for a book that is already finished, and only for a book of at least `minimumOfferCharacters`. A book is
    /// never marked finished automatically: readers jump to the end for the notes or an epilogue.
    public static func shouldOfferFinish(wasAtEnd: Bool, isAtEnd: Bool, isFinished: Bool, alreadyOffered: Bool,
                                         bookCharacters: Int) -> Bool {
        isAtEnd && !wasAtEnd && !isFinished && !alreadyOffered && bookCharacters >= minimumOfferCharacters
    }

    /// Milliseconds since 1970.
    public static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// Stamp for a local change: the clock, but strictly newer than the mark it replaces, so two changes within
    /// the same millisecond (or a clock that went back) still order and the change is never lost to a tie.
    public static func nextStamp(now: Date, after previous: ReadStatusMark?) -> Int64 {
        max(millis(now), (previous?.stamp ?? 0) + 1)
    }

    /// The mark for setting `status` now ("Mark as Finished" / "Mark as Unread").
    public static func mark(_ status: ReadStatus?, now: Date, replacing previous: ReadStatusMark?) -> ReadStatusMark {
        ReadStatusMark(status: status, stamp: nextStamp(now: now, after: previous))
    }

    /// The menu's toggle: a finished book becomes unread (Readest's "Mark as Unread"), any other one finished.
    public static func toggledFinished(_ current: ReadStatusMark?, now: Date) -> ReadStatusMark {
        mark(current?.isFinished == true ? .unread : .finished, now: now, replacing: current)
    }

    /// Finished books after the others; each group keeps its order (stable).
    public static func finishedLast<T>(_ items: [T], isFinished: (T) -> Bool) -> [T] {
        var open: [T] = []
        var finished: [T] = []
        for item in items {
            if isFinished(item) { finished.append(item) } else { open.append(item) }
        }
        return open + finished
    }
}

/// Last writer wins, by `stamp`, between the copies of a book's status.
public enum ReadStatusMerge {
    /// An incoming copy replaces the local one only when it is strictly newer; a tie keeps the local copy, so
    /// the periodic resends of WatchConnectivity are idempotent.
    public static func shouldApply(incoming: ReadStatusMark, local: ReadStatusMark?) -> Bool {
        guard let local else { return true }
        return incoming.stamp > local.stamp
    }

    /// The newer of two copies; `a` on a tie.
    public static func newer(_ a: ReadStatusMark?, _ b: ReadStatusMark?) -> ReadStatusMark? {
        guard let a else { return b }
        guard let b else { return a }
        return b.stamp > a.stamp ? b : a
    }

    /// Merges another device's marks into the local ones, per book. Returns the result and the books whose mark
    /// changed.
    public static func merge(local: [String: ReadStatusMark],
                             incoming: [String: ReadStatusMark]) -> (marks: [String: ReadStatusMark], changed: Set<String>) {
        var marks = local
        var changed = Set<String>()
        for (hash, mark) in incoming where !hash.isEmpty && shouldApply(incoming: mark, local: local[hash]) {
            if marks[hash] != mark {
                marks[hash] = mark
                changed.insert(hash)
            }
        }
        return (marks, changed)
    }

    /// What to do about a book that has a local copy (iPhone) and a Readest row.
    public enum ReadestAction: Equatable, Sendable {
        /// Both copies agree (or the difference does not matter): nothing to do.
        case inSync
        /// Readest's status is newer: take it locally (and so to the watch).
        case adoptRemote(ReadStatusMark)
        /// The local status is newer and differs: write it to Readest.
        case pushLocal(ReadStatusMark)
    }

    /// Never overwrites a newer Readest value: the local mark is pushed only when its stamp is strictly newer
    /// and its status differs (the server also resolves `reading_status` by `reading_status_updated_at`, ties to
    /// the client, so a race with another device still keeps the newest).
    public static func reconcile(local: ReadStatusMark?, remote: ReadStatusMark?) -> ReadestAction {
        switch (local, remote) {
        case (nil, nil):
            return .inSync
        case (nil, let remote?):
            return .adoptRemote(remote)
        case (let local?, nil):
            return local.status == nil ? .inSync : .pushLocal(local)
        case (let local?, let remote?):
            if remote.stamp > local.stamp { return remote == local ? .inSync : .adoptRemote(remote) }
            if local.stamp > remote.stamp && local.status != remote.status { return .pushLocal(local) }
            return .inSync
        }
    }
}

/// The marks in the WatchConnectivity contexts (iPhone `settings` context, watch `library` context): a JSON
/// object `{"<documentHash>": {"s": "finished", "t": <ms>}}` as a string, like `TypographySync`.
public enum ReadStatusSync {
    public static let key = "readStatus"

    /// Nothing for an empty map (older apps simply never see the key).
    public static func context(for marks: [String: ReadStatusMark]) -> [String: Any] {
        guard !marks.isEmpty, let data = try? JSONEncoder().encode(marks),
              let json = String(data: data, encoding: .utf8) else { return [:] }
        return [key: json]
    }

    /// The marks of a context; nil when it carries none or the value is not a JSON object of marks.
    public static func decode(from info: [String: Any]) -> [String: ReadStatusMark]? {
        guard let json = info[key] as? String, let data = json.data(using: .utf8),
              let marks = try? JSONDecoder().decode([String: ReadStatusMark].self, from: data) else { return nil }
        return marks.filter { !$0.key.isEmpty }
    }
}
