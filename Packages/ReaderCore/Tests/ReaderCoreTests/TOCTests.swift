import XCTest
@testable import ReaderCore

final class TOCTests: XCTestCase {
    private func pos(_ c: Int, _ b: Int, _ o: Int = 0) -> BookPosition { BookPosition(chapterIndex: c, blockIndex: b, characterOffset: o) }

    // MARK: - Parser

    func testNavWithSeveralChaptersPerFileResolvesFragments() throws {
        let book = try EPUBTestSupport.parse("toc_parts")
        XCTAssertEqual(book.tocSource, .nav, "the nav wins over the stale NCX")
        let toc = try XCTUnwrap(book.toc)
        XCTAssertEqual(toc.map(\.title), ["Part One", "Chapter 1", "Chapter 2", "Chapter 3", "Part Two",
                                          "Chapter 4", "Chapter 5", "Chapter 6", "Figure", "Image", "Missing"],
                       "hidden sub-list kept, external link, landmarks and page-list ignored, @title label used")
        XCTAssertEqual(toc.map(\.depth), [0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0])
        XCTAssertEqual(toc.map(\.isGroupHeading), [false, false, false, false, true, false, false, false, false, false, false])
        XCTAssertEqual(toc.map(\.position), [
            pos(0, 0),        // id on h1
            pos(0, 1), pos(0, 3),
            pos(0, 5),        // id on a wrapper div -> its first block
            pos(1, 1, 12),    // span group heading -> first child's position
            pos(1, 1, 12),    // empty <span id> mid-paragraph -> that block, with an offset
            pos(1, 3),        // empty <a id> between paragraphs -> the next block
            pos(1, 5),        // <a name>
            pos(2, 1),        // id inside svg -> the next block
            pos(2, 2),        // image-only paragraph -> the next block
            pos(2, 0),        // unknown id -> the file start
        ])
        XCTAssertTrue(book.chapters[1].blocks[1].text.dropFirst(12).hasPrefix("Chapter four"))
        // Spine chapter titles keep their previous behaviour (first nav label per file).
        XCTAssertEqual(book.chapters.map(\.title), ["Part One", "Chapter 4", "Figure"])
    }

    func testNCXOnlyNestedWithOddHrefs() throws {
        let book = try EPUBTestSupport.parse("toc_ncx")
        XCTAssertEqual(book.tocSource, .ncx)
        let toc = try XCTUnwrap(book.toc)
        XCTAssertEqual(book.chapters.map(\.spineIndex), [1, 3, 4, 5], "blank.xhtml has no text")
        XCTAssertEqual(toc.map(\.title), ["Book One", "Chapter One", "Second Heading", "Book Two", "Été", "Split",
                                          "Notes", "Missing", "Again"], "tree order, playOrder ignored, empty label filled")
        XCTAssertEqual(toc.map(\.depth), [0, 1, 1, 0, 1, 1, 0, 0, 0])
        XCTAssertEqual(toc.map(\.position), [
            pos(0, 0), pos(0, 0),   // percent-encoded file name; id on a <section> wrapper
            pos(0, 2),
            pos(1, 0),              // textless spine item -> the next chapter's start
            pos(1, 1),              // percent-encoded non-ASCII fragment
            pos(2, 0),
            nil, nil,               // file outside the spine, missing file
            pos(0, 0),              // out-of-order duplicate
        ])
        let index = try XCTUnwrap(TOCIndex(book: book))
        XCTAssertFalse(index.isOrdered[8], "a backwards entry is never current nor a boundary")
        XCTAssertEqual(index.currentEntryIndex(at: pos(0, 3)), 2)
        XCTAssertEqual(index.currentEntryIndex(at: pos(3, 0)), 5, "a split chapter is one section over both files")
        XCTAssertNil(index.nextBoundary(after: pos(2, 1)))
        XCTAssertEqual(index.nextBoundary(after: pos(0, 0)), pos(0, 2))
    }

    func testHeadingsFallbackWithoutTOC() throws {
        let book = try EPUBTestSupport.parse("toc_none")
        XCTAssertEqual(book.tocSource, .headings)
        let toc = try XCTUnwrap(book.toc)
        XCTAssertEqual(toc.map(\.title), ["Alpha", "Alpha sub", "Beta"], "h4 is too deep")
        XCTAssertEqual(toc.map(\.depth), [0, 1, 1], "h1 then h3 nests one level, not two")
        XCTAssertEqual(toc.map(\.position), [pos(0, 0), pos(0, 2), pos(1, 0)])
    }

    func testNoTOCAndNoHeadingsLeavesTOCNil() throws {
        let book = try EPUBTestSupport.parse("inline")
        XCTAssertNil(book.toc)
        XCTAssertNil(book.tocSource)
        XCTAssertNil(TOCIndex(book: book))
    }

    func testExistingFixtureKeepsChapterTitles() throws {
        let book = try EPUBTestSupport.parse("multispine")
        XCTAssertEqual(book.chapters.map(\.title), ["Un", "Deux", "Trois"])
        XCTAssertEqual(book.toc?.map(\.title), ["Un", "Deux", "Trois"])
        XCTAssertEqual(book.toc?.map(\.position), [pos(0, 0), pos(1, 0), pos(2, 0)], "unknown #s1 -> file start")
    }

    func testBlockExtractorAnchors() {
        let html = Data("""
        <html><body><div id="w"><p>One <b id="b">two</b> three<a id="end"/></p></div><p>Four</p></body></html>
        """.utf8)
        let r = BlockExtractor.extract(from: html, wantedIDs: ["w", "b", "end", "nope"])
        XCTAssertEqual(r.blocks.map(\.text), ["One two three", "Four"])
        XCTAssertEqual(r.anchors["w"], AnchorTarget(blockIndex: 0, characterOffset: 0))
        XCTAssertEqual(r.anchors["b"], AnchorTarget(blockIndex: 0, characterOffset: 4))
        XCTAssertEqual(r.anchors["end"], AnchorTarget(blockIndex: 1, characterOffset: 0), "an anchor at a paragraph's end belongs to what follows")
        XCTAssertNil(r.anchors["nope"])
        XCTAssertTrue(BlockExtractor.extract(from: html, wantedIDs: []).anchors.isEmpty)
    }

    // MARK: - Storage compatibility

    func testBooksWithoutTOCStillDecodeAndUnknownKeysAreIgnored() throws {
        let old = ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: "h", metaHash: "m",
                                chapters: [Chapter(spineIndex: 1, title: nil, blocks: [Block(text: "x", xpointer: "p", globalOffset: 0)])],
                                totalCharacters: 1)
        let oldJSON = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: oldJSON, as: UTF8.self).contains("toc"), "nil TOC is not written")
        XCTAssertNil(try JSONDecoder().decode(ProcessedBook.self, from: oldJSON).toc)

        // A newer writer: extra keys and an unknown TOC source must not break decoding.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: oldJSON) as? [String: Any])
        object["toc"] = [["title": "A", "depth": 0, "position": ["chapterIndex": 0, "blockIndex": 0], "future": 1]]
        object["tocSource"] = "somethingNew"
        object["futureKey"] = true
        let decoded = try JSONDecoder().decode(ProcessedBook.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertEqual(decoded.toc, [TOCEntry(title: "A", depth: 0, position: pos(0, 0))])
        XCTAssertEqual(decoded.tocSource, .unknown)

        var withTOC = old
        withTOC.toc = [TOCEntry(title: "G", depth: 0, position: nil, isGroupHeading: true)]
        withTOC.tocSource = .nav
        XCTAssertEqual(try JSONDecoder().decode(ProcessedBook.self, from: JSONEncoder().encode(withTOC)), withTOC)
    }

    // MARK: - TOCIndex

    /// One chapter per spine item; each block has `length` characters.
    private func book(_ blocksPerChapter: [Int], length: Int = 100, toc: [TOCEntry]) -> ProcessedBook {
        var offset = 0
        var chapters: [Chapter] = []
        for (i, n) in blocksPerChapter.enumerated() {
            var blocks: [Block] = []
            for _ in 0..<n {
                blocks.append(Block(text: String(repeating: "x", count: length), xpointer: "x", globalOffset: offset))
                offset += length
            }
            chapters.append(Chapter(spineIndex: i + 1, title: nil, blocks: blocks))
        }
        return ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: "h", metaHash: "m",
                             chapters: chapters, totalCharacters: offset, toc: toc, tocSource: .nav)
    }

    func testCurrentEntryAndBoundariesWithPartsAndChapters() throws {
        // Hunger Games shape: Part > Chapter, several chapters per file, front matter before the first entry.
        let toc = [
            TOCEntry(title: "Part 1", depth: 0, position: pos(1, 0)),
            TOCEntry(title: "Ch 1", depth: 1, position: pos(1, 1)),
            TOCEntry(title: "Ch 2", depth: 1, position: pos(1, 5)),
            TOCEntry(title: "Part 2", depth: 0, position: pos(2, 0), isGroupHeading: true),
            TOCEntry(title: "Ch 3", depth: 1, position: pos(2, 0)),
        ]
        let b = book([2, 10, 10], toc: toc)
        let index = try XCTUnwrap(TOCIndex(book: b))
        XCTAssertEqual(index.chapterLevel, 1)
        XCTAssertNil(index.currentEntryIndex(at: pos(0, 1)), "front matter")
        XCTAssertEqual(index.currentEntryIndex(at: pos(1, 0)), 0)
        XCTAssertEqual(index.currentEntryIndex(at: pos(1, 4, 50)), 1)
        XCTAssertEqual(index.currentEntryIndex(at: pos(1, 4), maxDepth: 0), 0)
        XCTAssertEqual(index.currentEntryIndex(at: pos(2, 3)), 4, "the deeper entry at the same position wins")
        XCTAssertEqual(index.currentChapterIndex(at: pos(2, 3)), 4)
        XCTAssertEqual(index.nextBoundary(after: pos(1, 2)), pos(1, 5))
        XCTAssertEqual(index.nextBoundary(after: pos(1, 5)), pos(2, 0))
        XCTAssertNil(index.nextBoundary(after: pos(2, 0)))
        XCTAssertEqual(index.nextBoundary(after: pos(1, 2), level: 0), pos(2, 0))

        let sections = index.sectionOfBlock(in: b)
        XCTAssertEqual(sections.count, 22)
        XCTAssertEqual(Array(sections[0..<3]), [-1, -1, 0])
        XCTAssertEqual(Array(sections[3..<7]), [1, 1, 1, 1])
        XCTAssertEqual(Array(sections[7..<12]), [2, 2, 2, 2, 2])
        XCTAssertEqual(Array(sections[12...]), Array(repeating: 4, count: 10))
        // Feeds the existing estimator unchanged.
        let length = BookLengthIndex(blockTexts: b.chapters.flatMap { $0.blocks.map(\.text) }, chapterOfBlock: sections)
        XCTAssertEqual(length.remaining(fromBlock: 4).chapter, length.length(from: 4, to: 7))
    }

    func testChapterLevelSkipsContainerLevels() throws {
        // Volume > Book > Chapter > Section, where volumes and books are half-title pages (one short block).
        let toc = [
            TOCEntry(title: "Volume 1", depth: 0, position: pos(0, 0)),
            TOCEntry(title: "Book 1", depth: 1, position: pos(0, 1)),
            TOCEntry(title: "Chapter 1", depth: 2, position: pos(0, 2)),
            TOCEntry(title: "Section 1", depth: 3, position: pos(0, 3)),
            TOCEntry(title: "Chapter 2", depth: 2, position: pos(0, 6)),
        ]
        let short = book([8], length: 50, toc: toc)
        XCTAssertEqual(TOCIndex(book: short)?.chapterLevel, 2)
        XCTAssertEqual(TOCIndex(book: short)?.currentChapterIndex(at: pos(0, 4)), 2, "Chapter, not Section")
        // Long book-level introductions make the books themselves the chapters.
        let long = book([8], length: 1000, toc: toc)
        XCTAssertEqual(TOCIndex(book: long)?.chapterLevel, 1)
        // War and Peace shape: Volume > Book > Part > Chapter, each container a half-title file of its own.
        let halfTitles = [
            TOCEntry(title: "War and Peace", depth: 0, position: pos(0, 0)),
            TOCEntry(title: "Book I", depth: 1, position: pos(1, 0)),
            TOCEntry(title: "Part I", depth: 2, position: pos(2, 0)),
            TOCEntry(title: "I", depth: 3, position: pos(3, 0)),
            TOCEntry(title: "II", depth: 3, position: pos(3, 3)),
        ]
        XCTAssertEqual(TOCIndex(entries: halfTitles, book: book([1, 1, 1, 6], length: 50, toc: halfTitles)).chapterLevel, 3)
        // Flat and two-level TOCs use their deepest level.
        XCTAssertEqual(TOCIndex(entries: [TOCEntry(title: "A", depth: 0, position: pos(0, 0))], book: short).chapterLevel, 0)
    }

    func testUnresolvedAndOutOfOrderEntriesAreSkipped() {
        let toc = [
            TOCEntry(title: "A", depth: 0, position: pos(0, 2)),
            TOCEntry(title: "Dup", depth: 0, position: pos(0, 0)),
            TOCEntry(title: "Nil", depth: 0, position: nil),
            TOCEntry(title: "B", depth: 0, position: pos(0, 4)),
        ]
        let index = TOCIndex(entries: toc, book: book([6], toc: toc))
        XCTAssertEqual(index.isOrdered, [true, false, false, true])
        XCTAssertEqual(index.currentEntryIndex(at: pos(0, 3)), 0)
        XCTAssertNil(index.currentEntryIndex(at: pos(0, 1)))
        XCTAssertEqual(index.nextBoundary(after: pos(0, 2)), pos(0, 4))
    }
}
