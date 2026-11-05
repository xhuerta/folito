import Foundation

/// Cumulative `TextLength` of a book's blocks in reading order (the watch reader's "flat index": the blocks of
/// every chapter, chapter after chapter), so the text left from any block is an O(1) subtraction.
public struct BookLengthIndex: Sendable, Equatable {
    /// `prefix[i]` = length of blocks `0..<i`; one more element than there are blocks.
    private let prefix: [TextLength]
    /// For each block, the flat index one past the last block of its chapter.
    private let chapterEnd: [Int]

    public var blockCount: Int { prefix.count - 1 }
    public var total: TextLength { prefix[prefix.count - 1] }

    /// `chapterOfBlock[i]` identifies the chapter of block `i`; consecutive equal values form one chapter.
    public init(blockTexts: [String], chapterOfBlock: [Int]) {
        precondition(blockTexts.count == chapterOfBlock.count, "one chapter id per block")
        var prefix: [TextLength] = [.zero]
        prefix.reserveCapacity(blockTexts.count + 1)
        for text in blockTexts { prefix.append(prefix[prefix.count - 1] + TextLength(text)) }
        var ends = [Int](repeating: blockTexts.count, count: blockTexts.count)
        var i = blockTexts.count - 1
        var end = blockTexts.count
        while i >= 0 {
            if i + 1 < blockTexts.count, chapterOfBlock[i + 1] != chapterOfBlock[i] { end = i + 1 }
            ends[i] = end
            i -= 1
        }
        self.prefix = prefix
        self.chapterEnd = ends
    }

    /// Indexes the blocks of `book` in the same order as the watch reader.
    public init(book: ProcessedBook) {
        var texts: [String] = []
        var chapters: [Int] = []
        for (ci, chapter) in book.chapters.enumerated() {
            for block in chapter.blocks {
                texts.append(block.text)
                chapters.append(ci)
            }
        }
        self.init(blockTexts: texts, chapterOfBlock: chapters)
    }

    /// Length of blocks `from..<to` (clamped; empty when `to <= from`).
    public func length(from: Int, to: Int) -> TextLength {
        let a = min(max(from, 0), blockCount)
        let b = min(max(to, 0), blockCount)
        guard b > a else { return .zero }
        return prefix[b] - prefix[a]
    }

    /// Text left from the start of block `index` (included) to the end of its chapter and of the book.
    public func remaining(fromBlock index: Int) -> (chapter: TextLength, book: TextLength) {
        guard blockCount > 0 else { return (.zero, .zero) }
        let i = min(max(index, 0), blockCount - 1)
        return (length(from: i, to: chapterEnd[i]), length(from: i, to: blockCount))
    }
}

/// Estimated reading time left, as saved with the reading position. Codable and Sendable so a watch
/// complication (or the iPhone, through the watch's library report) can read it without the book.
public struct ReadingTimeRemaining: Codable, Sendable, Equatable {
    /// KOReader partial MD5 of the book (`ProcessedBook.documentHash`).
    public var documentHash: String
    public var bookTitle: String
    /// Seconds left to the end of the current chapter.
    public var chapterSeconds: TimeInterval
    /// Seconds left to the end of the book.
    public var bookSeconds: TimeInterval
    /// 0...1 of the book read (by characters, as in the library list).
    public var fractionRead: Double
    /// When the estimate was saved (the last time the reader moved).
    public var updatedAt: Date

    public init(documentHash: String, bookTitle: String, chapterSeconds: TimeInterval, bookSeconds: TimeInterval,
                fractionRead: Double, updatedAt: Date) {
        self.documentHash = documentHash
        self.bookTitle = bookTitle
        self.chapterSeconds = max(chapterSeconds, 0)
        self.bookSeconds = max(bookSeconds, 0)
        self.fractionRead = fractionRead.isFinite ? min(max(fractionRead, 0), 1) : 0
        self.updatedAt = updatedAt
    }
}

public enum ReadingTimeEstimator {
    /// Time left in the chapter and the book from the start of block `index`, at `speed`.
    public static func estimate(_ index: BookLengthIndex, atBlock block: Int,
                                speed: ReadingSpeed) -> (chapter: TimeInterval, book: TimeInterval) {
        let left = index.remaining(fromBlock: block)
        return (speed.seconds(for: left.chapter), speed.seconds(for: left.book))
    }

    /// Whole minutes to show for `seconds`: rounded up, so anything left shows at least one minute, and to
    /// five minutes above an hour (a precise "3 h 17 min" would suggest more accuracy than an estimate has).
    public static func displayMinutes(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let minutes = Int((seconds / 60).rounded(.up))
        guard minutes > 60 else { return minutes }
        return Int((Double(minutes) / 5).rounded()) * 5
    }
}

/// On-device store of the latest `ReadingTimeRemaining` per book (UserDefaults; never sent to a server).
///
/// Public API for a watch complication: `latest()` is the book read most recently. The watch reader writes it
/// to `UserDefaults.standard` whenever the position changes; a widget extension that cannot read the app's
/// defaults directly can be handed the same JSON (`ReadingTimeRemaining` is Codable).
public final class ReadingTimeStore: @unchecked Sendable {
    public static let key = "reading.timeRemaining"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Every saved estimate, keyed by document hash.
    public func all() -> [String: ReadingTimeRemaining] {
        guard let data = defaults.data(forKey: Self.key),
              let map = try? JSONDecoder().decode([String: ReadingTimeRemaining].self, from: data) else { return [:] }
        return map
    }

    public func load(documentHash: String) -> ReadingTimeRemaining? { all()[documentHash] }

    /// The most recently updated estimate (the book being read), if any.
    public func latest() -> ReadingTimeRemaining? { all().values.max { $0.updatedAt < $1.updatedAt } }

    public func save(_ value: ReadingTimeRemaining) {
        var map = all()
        map[value.documentHash] = value
        write(map)
    }

    public func remove(documentHash: String) {
        var map = all()
        guard map.removeValue(forKey: documentHash) != nil else { return }
        write(map)
    }

    public func removeAll() { defaults.removeObject(forKey: Self.key) }

    private func write(_ map: [String: ReadingTimeRemaining]) {
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: Self.key) }
    }
}
