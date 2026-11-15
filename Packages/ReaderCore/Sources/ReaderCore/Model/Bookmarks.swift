import Foundation

/// A place the reader marked in a book (#65). Kept per book on the watch (`BookmarkStore`); not synced.
///
/// The bookmark keeps both the `BookPosition` it was made at and the XPointer of that position: a book the
/// iPhone sends again (same document hash) may be processed into different blocks, and the XPointer still
/// finds the marked text there (`resolvedPosition(in:)`). The percentage is the last fallback.
public struct Bookmark: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var position: BookPosition
    /// XPointer of `position` (with the in-block offset), as the sync services use it; nil when unknown.
    public var xpointer: String?
    /// 0...1 of the whole book at `position`.
    public var percentage: Double
    /// Title of the chapter at `position` when the bookmark was made (nil in untitled front matter).
    public var chapterTitle: String?
    /// The first words at `position`, shown in the bookmark list.
    public var snippet: String
    public var createdAt: Date

    public init(id: UUID = UUID(), position: BookPosition, xpointer: String? = nil, percentage: Double,
                chapterTitle: String?, snippet: String, createdAt: Date) {
        self.id = id
        self.position = position
        self.xpointer = xpointer
        self.percentage = Self.clampedFraction(percentage)
        self.chapterTitle = Self.cleanTitle(chapterTitle)
        self.snippet = snippet
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, position, xpointer, percentage, chapterTitle, snippet, createdAt }

    /// Lenient: only the id and the position are required, so a later version can add or drop other fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        position = try c.decode(BookPosition.self, forKey: .position)
        xpointer = try c.decodeIfPresent(String.self, forKey: .xpointer)
        percentage = Self.clampedFraction(try c.decodeIfPresent(Double.self, forKey: .percentage) ?? 0)
        chapterTitle = Self.cleanTitle(try c.decodeIfPresent(String.self, forKey: .chapterTitle))
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    /// A bookmark at `position` in `book`: its XPointer, percentage and snippet come from the book. Nil when
    /// the position is not in the book.
    public static func make(at position: BookPosition, in book: ProcessedBook, chapterTitle: String?,
                            createdAt: Date, id: UUID = UUID()) -> Bookmark? {
        guard book.chapters.indices.contains(position.chapterIndex),
              book.chapters[position.chapterIndex].blocks.indices.contains(position.blockIndex) else { return nil }
        let text = book.chapters[position.chapterIndex].blocks[position.blockIndex].text
        var clamped = position
        clamped.characterOffset = min(max(position.characterOffset, 0), text.count)
        let located = XPointerResolver().locate(clamped, in: book)
        return Bookmark(id: id, position: clamped, xpointer: located?.xpointer, percentage: located?.percentage ?? 0,
                        chapterTitle: chapterTitle, snippet: snippet(from: text, at: clamped.characterOffset),
                        createdAt: createdAt)
    }

    /// Where the bookmark is in `book`: its XPointer resolved to the same element (so a re-sent, re-processed
    /// copy of the book still opens at the marked text), else the stored position if the book still has that
    /// block. Nil when neither fits: jump to `percentage` then.
    public func resolvedPosition(in book: ProcessedBook,
                                 resolver: XPointerResolving = XPointerResolver()) -> BookPosition? {
        if let xpointer, !xpointer.isEmpty,
           case .position(let found, let trimmed)? = resolver.resolve(xpointer, percentage: nil, in: book),
           trimmed == 0 {
            return found
        }
        guard book.chapters.indices.contains(position.chapterIndex) else { return nil }
        let blocks = book.chapters[position.chapterIndex].blocks
        guard blocks.indices.contains(position.blockIndex) else { return nil }
        var p = position
        p.characterOffset = min(max(p.characterOffset, 0), blocks[p.blockIndex].text.count)
        return p
    }

    /// Default length of `snippet(from:at:)`, in characters (a couple of lines on the smallest watch).
    public static let snippetLength = 60
    /// How far `snippet` goes back to find the start of a word.
    static let maxWordLength = 24

    /// The words of `text` from `characterOffset` on: started at the beginning of the word the offset falls in,
    /// whitespace collapsed, cut after a whole word near `maxLength` characters and ended with "…". At the very
    /// end of a block (nothing left after the offset) the block's opening words are used instead.
    public static func snippet(from text: String, at characterOffset: Int, maxLength: Int = Bookmark.snippetLength) -> String {
        let chars = Array(text)
        let offset = min(max(characterOffset, 0), chars.count)
        // Back to the start of the word, but not far: text without spaces (Chinese, Japanese) has no word
        // start to go back to, and the snippet must stay at the marked line.
        var start = offset
        func insideWord(_ i: Int) -> Bool {
            i > 0 && i < chars.count && joinsWord(chars[i - 1]) && joinsWord(chars[i])
        }
        while insideWord(start), offset - start < maxWordLength { start -= 1 }
        if insideWord(start) { start = offset }
        var words = chars[start...].split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        if words.isEmpty { words = chars.split(whereSeparator: { $0.isWhitespace }).map { String($0) } }
        let collapsed = Array(words.joined(separator: " "))
        let limit = max(maxLength, 1)
        guard collapsed.count > limit else { return String(collapsed) }
        let cut = Array(collapsed.prefix(limit))
        // The cut falls right after a whole word: keep it.
        if collapsed[limit] == " " { return String(cut) + "…" }
        // Cut at the last space in the second half, so a long first word is still shortened.
        if let space = cut.lastIndex(of: " "), space >= limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// Whether `c` belongs to a space-separated word: not whitespace, and not a Chinese or Japanese character
    /// or CJK punctuation, which stand on their own.
    private static func joinsWord(_ c: Character) -> Bool {
        guard !c.isWhitespace, let scalar = c.unicodeScalars.first else { return false }
        if scalar.properties.isIdeographic { return false }
        switch scalar.value {
        case 0x3000...0x30FF, 0xFF00...0xFFEF: return false
        default: return true
        }
    }

    private static func clampedFraction(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private static func cleanTitle(_ title: String?) -> String? {
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// The bookmarks of one book, newest first, at most one per position.
public struct BookmarkList: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public private(set) var items: [Bookmark]

    public init(_ items: [Bookmark] = []) {
        var seenIDs = Set<UUID>()
        var kept: [Bookmark] = []
        for b in items.sorted(by: Self.newestFirst)
        where !seenIDs.contains(b.id) && !kept.contains(where: { $0.position == b.position }) {
            seenIDs.insert(b.id)
            kept.append(b)
        }
        self.items = kept
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// What `add` did.
    public enum AddResult: Equatable, Sendable {
        case added(Bookmark)
        /// There already is a bookmark at that position (returned); nothing changed.
        case duplicate(Bookmark)
    }

    /// The bookmark at exactly `position`, if any.
    public func bookmark(at position: BookPosition) -> Bookmark? {
        items.first { $0.position == position }
    }

    public func contains(_ position: BookPosition) -> Bool { bookmark(at: position) != nil }

    /// Adds `bookmark` unless one at the same position exists.
    @discardableResult
    public mutating func add(_ bookmark: Bookmark) -> AddResult {
        if let existing = self.bookmark(at: bookmark.position) { return .duplicate(existing) }
        items.removeAll { $0.id == bookmark.id }
        items.append(bookmark)
        items.sort(by: Self.newestFirst)
        return .added(bookmark)
    }

    /// Removes the bookmark with `id`; false when there is none.
    @discardableResult
    public mutating func remove(id: UUID) -> Bool {
        let before = items.count
        items.removeAll { $0.id == id }
        return items.count != before
    }

    /// Removes the bookmarks at `offsets` of `items` (a list's swipe to delete).
    public mutating func remove(atOffsets offsets: IndexSet) {
        let ids = Set(offsets.filter { items.indices.contains($0) }.map { items[$0].id })
        items.removeAll { ids.contains($0.id) }
    }

    /// Newest first; equal dates (same clock tick) further into the book first, then by id, so the order is stable.
    static func newestFirst(_ a: Bookmark, _ b: Bookmark) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        if a.percentage != b.percentage { return a.percentage > b.percentage }
        return a.id.uuidString < b.id.uuidString
    }

    // MARK: Coding

    enum CodingKeys: String, CodingKey { case version, bookmarks }

    /// A bookmark that fails to decode is skipped; the others are kept.
    private struct LossyBookmark: Decodable {
        let value: Bookmark?
        init(from decoder: Decoder) throws { value = try? Bookmark(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = try c.decodeIfPresent([LossyBookmark].self, forKey: .bookmarks) ?? []
        self.init(lossy.compactMap(\.value))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(items, forKey: .bookmarks)
    }
}

/// Bookmarks per book (keyed by document hash) in `UserDefaults`, next to the reading positions. A book the
/// iPhone sends again keeps its document hash and so its bookmarks; deleting the book removes them.
public final class BookmarkStore: @unchecked Sendable {
    public static let key = "reading.bookmarks"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Every book's bookmarks, keyed by document hash.
    public func all() -> [String: BookmarkList] {
        guard let data = defaults.data(forKey: Self.key),
              let map = try? JSONDecoder().decode([String: BookmarkList].self, from: data) else { return [:] }
        return map
    }

    public func load(documentHash: String) -> BookmarkList {
        all()[documentHash] ?? BookmarkList()
    }

    /// Saves `list` for the book; an empty list removes the book's entry.
    public func save(_ list: BookmarkList, documentHash: String) {
        var map = all()
        map[documentHash] = list.isEmpty ? nil : list
        write(map)
    }

    @discardableResult
    public func add(_ bookmark: Bookmark, documentHash: String) -> BookmarkList.AddResult {
        var list = load(documentHash: documentHash)
        let result = list.add(bookmark)
        if case .added = result { save(list, documentHash: documentHash) }
        return result
    }

    /// Removes one bookmark and returns the book's remaining list.
    @discardableResult
    public func remove(id: UUID, documentHash: String) -> BookmarkList {
        var list = load(documentHash: documentHash)
        if list.remove(id: id) { save(list, documentHash: documentHash) }
        return list
    }

    /// Removes every bookmark of one book (the book was deleted).
    public func remove(documentHash: String) {
        var map = all()
        guard map.removeValue(forKey: documentHash) != nil else { return }
        write(map)
    }

    /// Removes the bookmarks of every book (Reset).
    public func removeAll() { defaults.removeObject(forKey: Self.key) }

    private func write(_ map: [String: BookmarkList]) {
        if map.isEmpty { defaults.removeObject(forKey: Self.key); return }
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: Self.key) }
    }
}
