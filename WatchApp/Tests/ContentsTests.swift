import XCTest
import ReaderCore
@testable import FolitoWatch

/// The reader menu's chapter list, "current chapter" and the time-left sections, with and without a TOC.
final class ContentsTests: XCTestCase {
    /// Spine: front matter | "Part One" half-title | Chapter 1 (with a section) | Chapter 2 + Appendix.
    /// Flat indices: 0 | 1 | 2, 3, 4, 5 | 6, 7.
    private func makeBook(toc: [TOCEntry]?) -> ProcessedBook {
        var offset = 0
        func b(_ text: String) -> Block {
            defer { offset += text.count }
            return Block(text: text, xpointer: "/p\(offset)", globalOffset: offset)
        }
        let long = String(repeating: "word ", count: 100)  // 500 characters
        let chapters = [
            Chapter(spineIndex: 1, title: nil, blocks: [b("Copyright page text")]),
            Chapter(spineIndex: 2, title: "Part One", blocks: [b("Part One")]),
            Chapter(spineIndex: 3, title: "Chapter 1", blocks: [b("Chapter 1"), b(long), b("1.1"), b(long)]),
            Chapter(spineIndex: 4, title: "Chapter 2", blocks: [b(long), b("Appendix " + long)]),
        ]
        return ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: "h", metaHash: "m",
                             chapters: chapters, totalCharacters: offset, toc: toc, tocSource: toc == nil ? nil : .nav)
    }

    private let toc = [
        TOCEntry(title: "Part One", depth: 0, position: BookPosition(chapterIndex: 1, blockIndex: 0)),
        TOCEntry(title: "Chapter 1", depth: 1, position: BookPosition(chapterIndex: 2, blockIndex: 0)),
        TOCEntry(title: "Section 1.1", depth: 2, position: BookPosition(chapterIndex: 2, blockIndex: 2)),
        TOCEntry(title: " Chapter 2 ", depth: 1, position: BookPosition(chapterIndex: 3, blockIndex: 0)),
        TOCEntry(title: "Lost", depth: 1, position: nil),
        TOCEntry(title: "Appendix", depth: 0, position: BookPosition(chapterIndex: 3, blockIndex: 1)),
    ]

    func testTOCRowsUseTwoLevelsAndSkipUnresolvedChapters() {
        let flat = FlatBook(makeBook(toc: toc))
        XCTAssertEqual(flat.toc?.chapterLevel, 1)
        XCTAssertEqual(flat.contents.map(\.title), ["Part One", "Chapter 1", "Chapter 2", "Appendix"],
                       "sections below the chapter level are hidden, an entry without a target is left out")
        XCTAssertEqual(flat.contents.map(\.kind), [.group, .chapter, .chapter, .chapter])
        XCTAssertEqual(flat.contents.map(\.isIndented), [false, true, true, false])
        XCTAssertEqual(flat.contents.map(\.groupTitle), [nil, "Part One", "Part One", nil])
        XCTAssertEqual(flat.contents.map(\.startIndex), [1, 2, 6, 7])
    }

    func testCurrentRowAndChapterTitleFollowTheTOC() {
        let flat = FlatBook(makeBook(toc: toc))
        XCTAssertNil(flat.currentContentsRow(at: 0), "front matter before the first entry marks nothing")
        XCTAssertNil(flat.chapterTitle(at: 0))
        XCTAssertEqual(flat.currentContentsRow(at: 1), 0, "the part's half-title marks the part")
        XCTAssertEqual(flat.currentContentsRow(at: 4), 1, "a hidden section marks its chapter")
        XCTAssertEqual(flat.chapterTitle(at: 4), "Chapter 1")
        XCTAssertEqual(flat.currentContentsRow(at: 6), 2)
        XCTAssertEqual(flat.chapterTitle(at: 6), "Chapter 2", "titles are trimmed")
        XCTAssertEqual(flat.currentContentsRow(at: 7), 3, "two entries in one spine item are two chapters")
    }

    func testTimeLeftInChapterEndsAtTheNextTOCChapter() {
        let book = makeBook(toc: toc)
        let flat = FlatBook(book)
        let lengths = FlatBook.lengthIndex(for: book, toc: flat.toc)
        XCTAssertEqual(lengths.blockCount, flat.count)
        XCTAssertEqual(lengths.remaining(fromBlock: 2).chapter, lengths.length(from: 2, to: 6),
                       "the section inside Chapter 1 does not end it")
        XCTAssertEqual(lengths.remaining(fromBlock: 6).chapter, lengths.length(from: 6, to: 7),
                       "Chapter 2 ends where the Appendix starts, inside the same spine item")
        XCTAssertEqual(lengths.remaining(fromBlock: 0).chapter, lengths.length(from: 0, to: 1))
    }

    func testBooksWithoutTOCKeepTheSpineList() {
        let book = makeBook(toc: nil)
        let flat = FlatBook(book)
        XCTAssertNil(flat.toc)
        XCTAssertEqual(flat.contents.map(\.title), flat.chapterRefs.map(\.title))
        XCTAssertEqual(flat.contents.map(\.startIndex), flat.chapterRefs.map(\.startIndex))
        XCTAssertTrue(flat.contents.allSatisfy { $0.kind == .chapter && !$0.isIndented })
        XCTAssertEqual(flat.currentContentsRow(at: 4), flat.chapterRefIndex(containing: 4))
        XCTAssertEqual(flat.chapterTitle(at: 7), "Chapter 2")
        XCTAssertEqual(FlatBook.lengthIndex(for: book, toc: nil), BookLengthIndex(book: book))
    }

    func testATOCWithNothingToListFallsBackToTheSpine() {
        let flat = FlatBook(makeBook(toc: [TOCEntry(title: "Elsewhere", depth: 0, position: nil),
                                           TOCEntry(title: "Outside", depth: 0,
                                                    position: BookPosition(chapterIndex: 9, blockIndex: 0))]))
        XCTAssertNil(flat.toc)
        XCTAssertEqual(flat.contents.map(\.title), flat.chapterRefs.map(\.title))
    }

    func testFlatTOCHasNoGroups() {
        let flat = FlatBook(makeBook(toc: [
            TOCEntry(title: "One", depth: 0, position: BookPosition(chapterIndex: 2, blockIndex: 0)),
            TOCEntry(title: "Two", depth: 0, position: BookPosition(chapterIndex: 3, blockIndex: 0)),
        ]))
        XCTAssertEqual(flat.contents.map(\.kind), [.chapter, .chapter])
        XCTAssertEqual(flat.contents.map(\.isIndented), [false, false])
        XCTAssertEqual(flat.currentContentsRow(at: 5), 0)
    }
}
