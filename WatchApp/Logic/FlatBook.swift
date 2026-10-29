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

    func position(at index: Int) -> BookPosition? {
        guard !blocks.isEmpty else { return nil }
        let i = clamped(index)
        let ci = chapterOfBlock[i]
        return BookPosition(chapterIndex: ci, blockIndex: i - chapterStarts[ci], characterOffset: 0)
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
}
