import Foundation
import ReaderCore

/// A `ProcessedBook` flattened into one array of blocks so the reader can use a single
/// `LazyVStack` and a single integer ("flat index") as scroll identity.
/// Pure value type; no UI dependencies.
struct FlatBook {
    struct ChapterRef: Equatable {
        let chapterIndex: Int
        let title: String
        /// Flat index of the first block of the chapter.
        let startIndex: Int
    }

    let blocks: [Block]
    /// For each flat index, the chapter that contains it.
    let chapterOfBlock: [Int]
    /// Per-chapter flat start index (same count as `book.chapters`; empty chapters point at the next block).
    let chapterStarts: [Int]
    /// Chapters that have at least one block, for the index sheet.
    let chapterRefs: [ChapterRef]
    let totalCharacters: Int
    /// The book's table of contents, nil for books without one (sent before it existed, or with neither a TOC
    /// nor headings): those keep the spine chapter list (`chapterRefs`).
    let toc: TOCIndex?
    /// Rows of the reader menu's chapter list: the TOC when there is one, else one per `chapterRefs` entry.
    let contents: [ContentsRow]
    /// Row in `contents` of each displayed TOC entry, by entry index.
    private let rowOfTOCEntry: [Int: Int]

    /// One row of the reader menu's chapter list.
    struct ContentsRow: Equatable {
        enum Kind: Equatable {
            /// A chapter (a spine chapter, or a TOC entry at the chapter level, or a leaf above it).
            case chapter
            /// A TOC entry above the chapter level that has children ("Part One"), shown as a header-style row.
            case group
        }
        let title: String
        let kind: Kind
        /// Shown with a small leading indent, under a group row.
        let isIndented: Bool
        /// Flat index the row jumps to; nil when it cannot be tapped (a group whose target was not resolved).
        let startIndex: Int?
        /// Character offset in `startIndex` (a TOC target inside a block).
        let characterOffset: Int
        /// Title of the nearest group row above it, for VoiceOver ("Chapter 3, in Part One").
        let groupTitle: String?
    }

    init(_ book: ProcessedBook) {
        var blocks: [Block] = []
        var chapterOfBlock: [Int] = []
        var starts: [Int] = []
        var refs: [ChapterRef] = []
        for (ci, chapter) in book.chapters.enumerated() {
            starts.append(blocks.count)
            if !chapter.blocks.isEmpty {
                let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let shown = (title?.isEmpty == false) ? title!
                    : String(localized: "Chapter \(ci + 1)", comment: "Name of an untitled chapter in the contents list")
                refs.append(ChapterRef(chapterIndex: ci, title: shown, startIndex: blocks.count))
            }
            for block in chapter.blocks {
                blocks.append(block)
                chapterOfBlock.append(ci)
            }
        }
        self.blocks = blocks
        self.chapterOfBlock = chapterOfBlock
        self.chapterStarts = starts
        self.chapterRefs = refs
        // Prefer the declared total; fall back to the sum implied by the last block.
        if book.totalCharacters > 0 {
            self.totalCharacters = book.totalCharacters
        } else if let last = blocks.last {
            self.totalCharacters = last.globalOffset + last.text.count
        } else {
            self.totalCharacters = 0
        }
        // A TOC none of whose entries resolve to the text (nothing to list) is ignored like a missing one.
        let index = blocks.isEmpty ? nil : TOCIndex(book: book)
        let built = index.map { Self.contentsRows($0, chapterStarts: starts, blockCount: blocks.count) }
        if let index, let built, !built.rows.isEmpty {
            toc = index
            contents = built.rows
            rowOfTOCEntry = built.rowOf
        } else {
            toc = nil
            contents = refs.map {
                ContentsRow(title: $0.title, kind: .chapter, isIndented: false, startIndex: $0.startIndex,
                            characterOffset: 0, groupTitle: nil)
            }
            rowOfTOCEntry = [:]
        }
    }

    /// The TOC as at most two visual levels: entries deeper than the chapter level are hidden (the current one
    /// then marks its chapter), entries above it that have children become group rows, and the rest are
    /// chapter rows, indented when they sit below a group. A chapter row whose target could not be resolved is
    /// left out, since tapping it could not go anywhere; a group row without one stays as a plain header so
    /// its chapters keep their context.
    private static func contentsRows(_ toc: TOCIndex, chapterStarts: [Int], blockCount: Int) -> (rows: [ContentsRow], rowOf: [Int: Int]) {
        let entries = toc.entries
        let level = toc.chapterLevel
        var rows: [ContentsRow] = []
        var rowOf: [Int: Int] = [:]
        var groups: [(depth: Int, title: String)] = []
        for (i, entry) in entries.enumerated() where entry.depth <= level {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            while let last = groups.last, last.depth >= entry.depth { groups.removeLast() }
            let hasChildren = i + 1 < entries.count && entries[i + 1].depth > entry.depth
            let isGroup = entry.depth < level && hasChildren
            let start = entry.position.flatMap { flatIndex(for: $0, chapterStarts: chapterStarts, blockCount: blockCount) }
            guard isGroup || start != nil else { continue }
            rowOf[i] = rows.count
            rows.append(ContentsRow(title: title, kind: isGroup ? .group : .chapter,
                                    isIndented: !isGroup && !groups.isEmpty, startIndex: start,
                                    characterOffset: start == nil ? 0 : max(entry.position?.characterOffset ?? 0, 0),
                                    groupTitle: groups.last?.title))
            if isGroup { groups.append((entry.depth, title)) }
        }
        return (rows, rowOf)
    }

    /// Flat index of `position`, nil when it points outside the book (an unresolvable TOC target).
    private static func flatIndex(for position: BookPosition, chapterStarts: [Int], blockCount: Int) -> Int? {
        let ci = position.chapterIndex
        guard chapterStarts.indices.contains(ci), position.blockIndex >= 0 else { return nil }
        let end = ci + 1 < chapterStarts.count ? chapterStarts[ci + 1] : blockCount
        let i = chapterStarts[ci] + position.blockIndex
        return i < end ? i : nil
    }

    var isEmpty: Bool { blocks.isEmpty }
    var count: Int { blocks.count }

    func clamped(_ index: Int) -> Int {
        guard !blocks.isEmpty else { return 0 }
        return min(max(index, 0), blocks.count - 1)
    }

    /// Flat index for a `BookPosition`; out-of-range values are clamped. nil only for an empty book.
    func flatIndex(for position: BookPosition) -> Int? {
        guard !blocks.isEmpty, !chapterStarts.isEmpty else { return nil }
        let ci = min(max(position.chapterIndex, 0), chapterStarts.count - 1)
        let start = chapterStarts[ci]
        let end = ci + 1 < chapterStarts.count ? chapterStarts[ci + 1] : blocks.count
        let local = min(max(position.blockIndex, 0), max(end - start - 1, 0))
        return clamped(start + local)
    }

    func position(at index: Int, characterOffset: Int = 0) -> BookPosition? {
        guard !blocks.isEmpty else { return nil }
        let i = clamped(index)
        let ci = chapterOfBlock[i]
        return BookPosition(chapterIndex: ci, blockIndex: i - chapterStarts[ci],
                            characterOffset: clampedOffset(characterOffset, in: i))
    }

    /// `offset` limited to the text of block `index` (0 for an empty book).
    func clampedOffset(_ offset: Int, in index: Int) -> Int {
        guard !blocks.isEmpty else { return 0 }
        return min(max(offset, 0), blocks[clamped(index)].text.count)
    }

    /// Fraction 0...1 of the book before the start of block `index` (plus `characterOffset`).
    func percentage(at index: Int, characterOffset: Int = 0) -> Double {
        guard !blocks.isEmpty, totalCharacters > 0 else { return 0 }
        let b = blocks[clamped(index)]
        let chars = b.globalOffset + max(0, min(characterOffset, b.text.count))
        return min(max(Double(chars) / Double(totalCharacters), 0), 1)
    }

    /// Block containing the character at `fraction` of the book (binary search on `globalOffset`).
    func index(forPercentage fraction: Double) -> Int {
        guard !blocks.isEmpty else { return 0 }
        let f = min(max(fraction, 0), 1)
        let target = Int((f * Double(totalCharacters)).rounded(.down))
        var lo = 0, hi = blocks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if blocks[mid].globalOffset <= target { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Index into `chapterRefs` of the chapter containing flat block `index`.
    func chapterRefIndex(containing index: Int) -> Int? {
        guard !blocks.isEmpty else { return nil }
        let i = clamped(index)
        return chapterRefs.lastIndex(where: { $0.startIndex <= i })
    }

    /// Row of `contents` to mark as the current one at flat block `index` (and `characterOffset` in it): the
    /// current TOC entry at the displayed levels, or the spine chapter without a TOC. Nil in front matter
    /// before the first TOC entry.
    func currentContentsRow(at index: Int, characterOffset: Int = 0) -> Int? {
        guard let toc else { return chapterRefIndex(containing: index) }
        guard let position = position(at: index, characterOffset: characterOffset),
              let entry = toc.currentEntryIndex(at: position, maxDepth: toc.chapterLevel) else { return nil }
        return rowOfTOCEntry[entry]
    }

    /// Title of the chapter at flat block `index`, as the complication shows it: the TOC entry at the chapter
    /// level (nil in front matter before the first one), or the spine chapter's title without a TOC.
    func chapterTitle(at index: Int, characterOffset: Int = 0) -> String? {
        guard let toc else { return chapterRefIndex(containing: index).map { chapterRefs[$0].title } }
        guard let position = position(at: index, characterOffset: characterOffset),
              let entry = toc.currentChapterIndex(at: position) else { return nil }
        let title = toc.entries[entry].title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Word counts for the time-remaining estimate. With a TOC a "chapter" is a chapter-level TOC section
    /// (`TOCIndex.sectionOfBlock`, front matter before the first entry is a section of its own), so "min left
    /// in chapter" matches the chapter the list marks; without one it is the spine chapter.
    static func lengthIndex(for book: ProcessedBook, toc: TOCIndex?) -> BookLengthIndex {
        guard let toc else { return BookLengthIndex(book: book) }
        let texts = book.chapters.flatMap { $0.blocks.map(\.text) }
        return BookLengthIndex(blockTexts: texts, chapterOfBlock: toc.sectionOfBlock(in: book))
    }
}
