import XCTest
import Foundation
@testable import ReaderCore

final class ReadestCFITests: XCTestCase {
    // MARK: Parsing

    func testParsesSpineAndElementSteps() {
        XCTAssertEqual(EPUBCFI("epubcfi(/6/24!/4/2/10/1:0)"), EPUBCFI(spineIndex: 12, elementPath: [1, 5]))
        // Bare path, no offset.
        XCTAssertEqual(EPUBCFI("/6/2!/4/6"), EPUBCFI(spineIndex: 1, elementPath: [3]))
        // Only the body: chapter start.
        XCTAssertEqual(EPUBCFI("epubcfi(/6/8!/4)"), EPUBCFI(spineIndex: 4, elementPath: []))
    }

    func testDropsAssertionsOffsetsAndTheRangeEnd() {
        // foliate-js / Readest range CFI: parent + start; id assertions (with ^ escapes) ignored.
        XCTAssertEqual(EPUBCFI("epubcfi(/6/24[ch12^]x]!/4[body]/2[sec]/14,/1:0,/3:120)"),
                       EPUBCFI(spineIndex: 12, elementPath: [1, 7]))
        XCTAssertEqual(EPUBCFI("epubcfi(/6/14!/4/2,/6/1:5,/8/1:9)"), EPUBCFI(spineIndex: 7, elementPath: [1, 3]))
        // Odd steps (text between elements) end the element path.
        XCTAssertEqual(EPUBCFI("epubcfi(/6/4!/4/2/3/4:7)"), EPUBCFI(spineIndex: 2, elementPath: [1]))
        XCTAssertEqual(EPUBCFI("  epubcfi(/6/4!/4/10~23.5@1:2)  "), EPUBCFI(spineIndex: 2, elementPath: [5]))
    }

    func testRejectsMalformedInput() {
        for bad in ["", "epubcfi(", "epubcfi()", "epubcfi(/6/24/4/2)", "epubcfi(/6/23!/4/2)", "epubcfi(/6!/4)",
                    "epubcfi(/6/x!/4)", "epubcfi(/6/0!/4)", "epubcfi(/6/24!)", "epubcfi(/6/24!/4/2[open)",
                    "epubcfi(/6/24!/4,/2)", "/body/DocFragment[3]/body/p", "epubcfi(/6/24!/4/2"] {
            XCTAssertNil(EPUBCFI(bad), bad)
        }
    }

    // MARK: Mapping

    /// Spine 1: four paragraphs. Spine 2: an image-only page (no chapter). Spine 3: a heading, then a section
    /// with three paragraphs, the second with inline markup. 10 characters per block.
    private func book() -> ProcessedBook {
        var offset = 0
        func block(_ xp: String) -> Block {
            defer { offset += 10 }
            return Block(text: String(repeating: "x", count: 10), xpointer: xp, globalOffset: offset)
        }
        let c1 = Chapter(spineIndex: 1, title: nil, blocks: (1...4).map {
            block("/body/DocFragment[1]/body/p" + ($0 > 1 ? "[\($0)]" : ""))
        })
        let c3 = Chapter(spineIndex: 3, title: nil, blocks: [
            block("/body/DocFragment[3]/body/h2"),
            block("/body/DocFragment[3]/body/div/p"),
            block("/body/DocFragment[3]/body/div/p[2]"),
            block("/body/DocFragment[3]/body/div/p[3]"),
        ])
        return ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: "h", metaHash: "",
                             chapters: [c1, c3], totalCharacters: offset)
    }

    private func position(_ cfi: String) -> BookPosition? {
        EPUBCFI(cfi).flatMap { CFIResolver.position(for: $0, in: book()) }
    }

    func testMapsSpineAndElementIndicesToBlocks() {
        XCTAssertEqual(position("epubcfi(/6/2!/4/6/1:3)"), BookPosition(chapterIndex: 0, blockIndex: 2))
        // h2 = element 1, div = element 2, its p[2] = element 2.
        XCTAssertEqual(position("epubcfi(/6/6!/4/4/4,/1:0,/1:4)"), BookPosition(chapterIndex: 1, blockIndex: 2))
        // Inside inline markup of p[3] (an <em> child): that paragraph.
        XCTAssertEqual(position("epubcfi(/6/6!/4/4/6/2/1:1)"), BookPosition(chapterIndex: 1, blockIndex: 3))
        // Only the container: its first block.
        XCTAssertEqual(position("epubcfi(/6/6!/4/4)"), BookPosition(chapterIndex: 1, blockIndex: 1))
    }

    func testFallsBackToTheChapterStartOrClamps() {
        XCTAssertEqual(position("epubcfi(/6/6!/4)"), BookPosition(chapterIndex: 1, blockIndex: 0))
        // Past the last known element: the last one.
        XCTAssertEqual(position("epubcfi(/6/2!/4/40)"), BookPosition(chapterIndex: 0, blockIndex: 3))
        // A spine item without text: the next chapter's start; none after the last chapter.
        XCTAssertEqual(position("epubcfi(/6/4!/4/2)"), BookPosition(chapterIndex: 1, blockIndex: 0))
        XCTAssertNil(position("epubcfi(/6/8!/4/2)"))
    }

    // MARK: Mixed rows

    /// The watch is at block 1 (12.5 %); the Readest apps' CFI points at chapter 3's p[2] (block 6, 75 %).
    private let watchXP = "/body/DocFragment[1]/body/p[2]"
    private let readestCFI = "epubcfi(/6/6!/4/4/4,/1:0,/1:4)"

    func testMixedRowResolvesToTheCFIPosition() {
        let row = ReadingPosition(xpointer: watchXP, percentage: 2.0 / 8, page: 2, pageCount: 8, cfi: readestCFI)
        let resolved = row.resolvingCFI(in: book())
        XCTAssertEqual(resolved.xpointer, "/body/DocFragment[3]/body/div/p[2]")
        XCTAssertEqual(resolved.percentage, 0.75, accuracy: 1e-9)
        XCTAssertNil(resolved.cfi)
        XCTAssertNil(resolved.page)
    }

    func testAgreeingOrBehindCFIKeepsTheRow() {
        let agreeing = ReadingPosition(xpointer: "/body/DocFragment[3]/body/div/p[2]/text().3", percentage: 0.75,
                                       page: 6, pageCount: 8, cfi: readestCFI)
        XCTAssertEqual(agreeing.resolvingCFI(in: book()), agreeing)
        let behind = ReadingPosition(xpointer: "/body/DocFragment[3]/body/div/p[3]", percentage: 0.7,
                                     page: 7, pageCount: 8, cfi: "epubcfi(/6/2!/4/4)")
        XCTAssertEqual(behind.resolvingCFI(in: book()), behind)
    }

    func testOnlyOneFieldIsUsedAsIs() {
        let cfiOnly = ReadingPosition(xpointer: "", percentage: 0.1, page: 1, pageCount: 10, cfi: readestCFI)
        XCTAssertEqual(cfiOnly.resolvingCFI(in: book()).xpointer, "/body/DocFragment[3]/body/div/p[2]")
        let xpOnly = ReadingPosition(xpointer: watchXP, percentage: 0.25)
        XCTAssertEqual(xpOnly.resolvingCFI(in: book()), xpOnly)
        let unusable = ReadingPosition(xpointer: watchXP, percentage: 0.25, cfi: "garbage")
        XCTAssertEqual(unusable.resolvingCFI(in: book()), unusable)
    }

    func testMapperPassesTheExactRowsLocationButNeverPushesIt() {
        let row = ReadestBookConfig.parse(["book_hash": "h", "xpointer": watchXP, "progress": "[2,8]",
                                           "location": readestCFI])
        XCTAssertEqual(row?.location, readestCFI)
        let pos = ReadestProgressMapper.position(from: [row!], book: BookIdentity(partialMD5: "h"))
        XCTAssertEqual(pos?.cfi, readestCFI)
        let cfg = ReadestProgressMapper.config(for: ReadingPosition(xpointer: watchXP, percentage: 0.25, cfi: readestCFI),
                                               book: BookIdentity(partialMD5: "h"), now: Date())
        let pushed = ReadestSyncClient.pushBody(cfg)["configs"] as? [[String: Any]]
        XCTAssertNil(pushed?.first?["location"])
        // A row with only a CFI is still a position.
        let cfiRow = ReadestBookConfig(bookHash: "h", location: readestCFI)
        XCTAssertEqual(ReadestProgressMapper.position(from: [cfiRow], book: BookIdentity(partialMD5: "h"))?.cfi,
                       readestCFI)
    }
}
