import Foundation

/// What the complications and the Smart Stack widget show: the book being read and how far along it is.
///
/// The watch app writes it to the App Group's UserDefaults whenever the reading position is saved and when a
/// book is closed (see `ComplicationPublisher`); the widget extension only reads it. It holds no reading
/// position (XPointer) and never leaves the watch. Compiled into both the watch app and the widget extension.
struct ReadingSnapshot: Codable, Equatable, Sendable {
    /// Version of the stored JSON; bump when a field changes meaning. Unknown versions are ignored.
    static let currentVersion = 1

    var version: Int = ReadingSnapshot.currentVersion
    /// The book's documentHash (KOReader partial MD5), used by the deep link to reopen it.
    var bookID: String
    var title: String
    /// Title of the chapter at the reading position; nil when the book has no usable chapter title.
    var chapterTitle: String?
    /// 0...1 of the whole book.
    var fraction: Double
    /// Estimated minutes left in the current chapter (see `ReaderViewModel.minutesLeftInChapter()`).
    /// Nil while the book's words are being counted or when *Show Time Remaining* is off; hides the line.
    var minutesLeft: Int?
    var updatedAt: Date

    init(bookID: String, title: String, chapterTitle: String?, fraction: Double,
         minutesLeft: Int? = nil, updatedAt: Date = Date()) {
        self.bookID = bookID
        self.title = title
        self.chapterTitle = chapterTitle
        self.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        self.minutesLeft = minutesLeft.map { max(0, $0) }
        self.updatedAt = updatedAt
    }

    /// Whole percent shown on the watch face (rounded down, so an unfinished book never shows 100%).
    var wholePercent: Int {
        min(Int((fraction * 100 + 1e-9).rounded(.down)), 100)
    }

    /// True when what a complication displays would differ (used to avoid needless timeline reloads).
    func differsVisibly(from other: ReadingSnapshot?) -> Bool {
        guard let other else { return true }
        return bookID != other.bookID || title != other.title || chapterTitle != other.chapterTitle
            || wholePercent != other.wholePercent || minutesLeft != other.minutesLeft
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(self)
    }

    static func decode(_ data: Data) -> ReadingSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let value = try? decoder.decode(ReadingSnapshot.self, from: data),
              value.version == currentVersion, !value.bookID.isEmpty else { return nil }
        return value
    }

    /// Sample shown in the widget gallery and as the redacted placeholder.
    static let sample = ReadingSnapshot(bookID: "sample", title: "Pride and Prejudice",
                                        chapterTitle: "Chapter 12", fraction: 0.45,
                                        updatedAt: Date(timeIntervalSince1970: 0))
}

/// Shared storage for the snapshot: the App Group's UserDefaults suite.
///
/// The App Group id comes from the `FolitoAppGroup` Info.plist key (`$(WR_APP_GROUP)` in Config/Base.xcconfig),
/// so a developer build with another bundle id uses its own group. Without the App Group entitlement (e.g. a
/// free Personal Team build, see the README) the suite is not shared and the complication shows its
/// "Start reading" placeholder.
final class ReadingSnapshotStore: @unchecked Sendable {
    static let key = "complication.snapshot"
    static let appGroupInfoKey = "FolitoAppGroup"

    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) { self.defaults = defaults }

    /// The App Group store, or a store that does nothing when no App Group is configured.
    static let shared: ReadingSnapshotStore = {
        let group = (Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !group.isEmpty, !group.contains("$(") else { return ReadingSnapshotStore(defaults: nil) }
        return ReadingSnapshotStore(defaults: UserDefaults(suiteName: group))
    }()

    func load() -> ReadingSnapshot? {
        defaults?.data(forKey: Self.key).flatMap(ReadingSnapshot.decode)
    }

    func save(_ snapshot: ReadingSnapshot) {
        guard let data = snapshot.encoded() else { return }
        defaults?.set(data, forKey: Self.key)
    }

    func clear() {
        defaults?.removeObject(forKey: Self.key)
    }
}
