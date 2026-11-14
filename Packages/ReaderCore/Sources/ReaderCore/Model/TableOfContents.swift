import Foundation

/// Where a book's table of contents came from.
public enum TOCSource: String, Codable, Sendable, Equatable {
    /// The EPUB 3 navigation document (`<nav epub:type="toc">`).
    case nav
    /// The EPUB 2 NCX (`navMap`), used when there is no usable nav.
    case ncx
    /// Built from h1–h3 headings because the book has no usable TOC.
    case headings
    /// A source added by a newer app version; decoding never fails on it (older watch builds read new books).
    case unknown

    public init(from decoder: Decoder) throws {
        self = TOCSource(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// One entry of the book's table of contents, stored flat in document (tree pre-)order.
///
/// The TOC is independent of `Chapter`, which stays one per spine item (KOSync `DocFragment[N]` and Readest
/// CFIs depend on that). Several entries can point into one spine item through `#fragment`s.
public struct TOCEntry: Codable, Sendable, Equatable {
    /// Trimmed label.
    public var title: String
    /// 0-based nesting depth in the nav/NCX tree. A child always has `depth == parent.depth + 1`.
    public var depth: Int
    /// Resolved start of the entry, nil when the target could not be resolved (e.g. a file outside the spine).
    /// A group heading without a link of its own gets its first descendant's position.
    public var position: BookPosition?
    /// True for a nav `<li><span>` heading that has no link of its own (e.g. "Part One" with no page).
    public var isGroupHeading: Bool

    public init(title: String, depth: Int, position: BookPosition?, isGroupHeading: Bool = false) {
        self.title = title
        self.depth = depth
        self.position = position
        self.isGroupHeading = isGroupHeading
    }

    enum CodingKeys: String, CodingKey { case title, depth, position, isGroupHeading }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        depth = max(0, try c.decodeIfPresent(Int.self, forKey: .depth) ?? 0)
        position = try c.decodeIfPresent(BookPosition.self, forKey: .position)
        isGroupHeading = try c.decodeIfPresent(Bool.self, forKey: .isGroupHeading) ?? false
    }

    /// Omits the defaults (`isGroupHeading == false`, nil position) to keep books with hundreds of entries small.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(depth, forKey: .depth)
        try c.encodeIfPresent(position, forKey: .position)
        if isGroupHeading { try c.encode(true, forKey: .isGroupHeading) }
    }
}

extension BookPosition: Comparable {
    public static func < (a: BookPosition, b: BookPosition) -> Bool {
        (a.chapterIndex, a.blockIndex, a.characterOffset) < (b.chapterIndex, b.blockIndex, b.characterOffset)
    }
}

/// Lookups over a flat TOC: the current entry for a reading position, and chapter-level sections for
/// "time left in chapter".
///
/// Entries whose resolved position goes backwards (duplicates or out-of-order entries) are kept for display
/// but never become the current entry or a section boundary, a simplified form of KOReader's TOC validation.
public struct TOCIndex: Sendable, Equatable {
    public let entries: [TOCEntry]
    /// `isOrdered[i]`: entry `i` has a position that does not go backwards relative to the earlier ordered entries.
    public let isOrdered: [Bool]
    /// The deepest depth whose entries count as chapter boundaries (0-based). See `chapterLevel(for:in:)`.
    public let chapterLevel: Int

    /// Nil when the book has no TOC.
    public init?(book: ProcessedBook) {
        guard let toc = book.toc, !toc.isEmpty else { return nil }
        self.init(entries: toc, book: book)
    }

    public init(entries: [TOCEntry], book: ProcessedBook) {
        self.entries = entries
        var ordered = [Bool](repeating: false, count: entries.count)
        var last: BookPosition?
        for (i, e) in entries.enumerated() {
            guard let p = e.position else { continue }
            if last == nil || p >= last! { ordered[i] = true; last = p }
        }
        isOrdered = ordered
        chapterLevel = Self.chapterLevel(for: entries, isOrdered: ordered, in: book)
    }

    /// Index of the current entry: the last ordered entry with `depth <= maxDepth` whose position is at or before
    /// `position`. Nil in front matter before the first such entry.
    public func currentEntryIndex(at position: BookPosition, maxDepth: Int = .max) -> Int? {
        var found: Int?
        for (i, e) in entries.enumerated() where isOrdered[i] && e.depth <= maxDepth {
            guard let p = e.position else { continue }
            if p <= position { found = i } else { break }
        }
        return found
    }

    /// The current entry at chapter level (what the complication and "time left in chapter" name).
    public func currentChapterIndex(at position: BookPosition) -> Int? {
        currentEntryIndex(at: position, maxDepth: chapterLevel)
    }

    /// Start of the next chapter-level section after `position` (the first ordered entry with
    /// `depth <= level` that starts strictly after it), or nil when the section runs to the end of the book.
    public func nextBoundary(after position: BookPosition, level: Int? = nil) -> BookPosition? {
        let level = level ?? chapterLevel
        for (i, e) in entries.enumerated() where isOrdered[i] && e.depth <= level {
            if let p = e.position, p > position { return p }
        }
        return nil
    }

    /// One section id per block of the book (blocks of all chapters, in order), for
    /// `BookLengthIndex(blockTexts:chapterOfBlock:)`: the index of the chapter-level entry the block belongs to,
    /// or -1 for front matter before the first one.
    public func sectionOfBlock(in book: ProcessedBook, level: Int? = nil) -> [Int] {
        let level = level ?? chapterLevel
        let starts: [(BookPosition, Int)] = entries.indices.compactMap { i in
            guard isOrdered[i], entries[i].depth <= level, let p = entries[i].position else { return nil }
            return (BookPosition(chapterIndex: p.chapterIndex, blockIndex: p.blockIndex), i)
        }
        var out: [Int] = []
        var next = 0
        var current = -1
        for (ci, ch) in book.chapters.enumerated() {
            for bi in ch.blocks.indices {
                let here = BookPosition(chapterIndex: ci, blockIndex: bi)
                while next < starts.count, starts[next].0 <= here { current = starts[next].1; next += 1 }
                out.append(current)
            }
        }
        return out
    }

    /// Below this many characters of its own text before its first child, a parent entry is only a container
    /// (a "Part One" half-title page), roughly one watch screen.
    static let containerTextLimit = 400

    /// Chapter level: the deepest depth <= 1, or deeper while every parent at the levels above is only a
    /// container. Depth 2 needs short parents at depths 0 and 1 (Volume > Book > Chapter); each further level
    /// also needs its parents to be half-title files (the first child starts in a later spine item), so that
    /// Chapter > Section in non-fiction, which usually shares a file, keeps the chapter as the unit.
    /// Part-only headings above chapters then never hide the real chapter.
    static func chapterLevel(for entries: [TOCEntry], isOrdered: [Bool], in book: ProcessedBook) -> Int {
        let maxDepth = entries.map(\.depth).max() ?? 0
        guard maxDepth >= 2 else { return maxDepth }
        func offset(_ p: BookPosition) -> Int? {
            guard book.chapters.indices.contains(p.chapterIndex) else { return nil }
            let blocks = book.chapters[p.chapterIndex].blocks
            guard blocks.indices.contains(p.blockIndex) else { return nil }
            return blocks[p.blockIndex].globalOffset + p.characterOffset
        }
        /// Whether the parents at `depth` are all containers, and whether there is at least one.
        func containers(atDepth depth: Int, halfTitleFiles: Bool) -> (all: Bool, any: Bool) {
            var any = false
            for (i, e) in entries.enumerated() where e.depth == depth {
                guard i + 1 < entries.count, entries[i + 1].depth > e.depth else { continue }  // leaf
                any = true
                guard let p = e.position, let q = entries[i + 1].position, let a = offset(p), let b = offset(q) else { continue }
                if b - a >= containerTextLimit { return (false, true) }
                if halfTitleFiles, q.chapterIndex == p.chapterIndex { return (false, true) }
            }
            return (true, any)
        }
        let top = containers(atDepth: 0, halfTitleFiles: false), second = containers(atDepth: 1, halfTitleFiles: false)
        guard top.all, second.all, top.any || second.any else { return 1 }
        var level = 2
        while level < maxDepth {
            let next = containers(atDepth: level, halfTitleFiles: true)
            guard next.all, next.any else { break }
            level += 1
        }
        return level
    }
}
