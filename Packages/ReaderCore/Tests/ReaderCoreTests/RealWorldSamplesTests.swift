import XCTest
@testable import ReaderCore

/// XPointer strings observed in the wild (KOReader / crengine output and third-party kosync clients),
/// taken from public bug reports:
/// - gotson/komga#2482 (single-spine EPUB: `/body/DocFragment/body/...` has no index)
/// - grimmory-tools/grimmory#2881 (`text()[1].N` indexed text step)
/// - uxjulia/CrossInk#853 (KOReader's `section/p[134]/text().354` vs a client that dropped `<section>`)
final class RealWorldSamplesTests: XCTestCase {
    func testParseObservedStrings() {
        func p(_ s: String) -> ParsedXPointer? { ParsedXPointer.parse(s) }
        XCTAssertEqual(p("/body/DocFragment[2]/body/section/p[3]/text().0"),
                       ParsedXPointer(spineIndex: 2, steps: [PathStep(name: "section", index: 1), PathStep(name: "p", index: 3)],
                                      hasTextStep: true, textIndex: 1, offset: 0))
        XCTAssertEqual(p("/body/DocFragment/body/section/h2/text().0")?.spineIndex, 1)   // no index == 1
        XCTAssertEqual(p("/body/DocFragment[1]/body/div/p/text().3")?.offset, 3)
        XCTAssertEqual(p("/body/DocFragment[1]/body/div/p/text()[1].3")?.offset, 3)
        XCTAssertEqual(p("/body/DocFragment[1]/body/div/p/text()[1].3")?.textIndex, 1)
        XCTAssertEqual(p("/body/DocFragment[3]/body/section[1]/p[4]/b[1]/text()[1].2")?.steps.map(\.name), ["section", "p", "b"])
        XCTAssertEqual(p("/body/DocFragment[12]/body/section/p[134]/text().354")?.offset, 354)
        XCTAssertEqual(p("/body/DocFragment[12]/body/section/p[134]/text().354")?.steps.last, PathStep(name: "p", index: 134))
    }

    private func book() -> ProcessedBook {
        func block(_ xp: String, _ text: String, _ off: Int) -> Block { Block(text: text, xpointer: xp, globalOffset: off) }
        let text = String(repeating: "x", count: 400)
        let c1 = Chapter(spineIndex: 1, title: "single", blocks: [block("/body/DocFragment[1]/body/section/h2", "Title", 0)])
        let c12 = Chapter(spineIndex: 12, title: "twelve", blocks: [
            block("/body/DocFragment[12]/body/section/p[133]", text, 5),
            block("/body/DocFragment[12]/body/section/p[134]", text, 405),
        ])
        return ProcessedBook(metadata: BookMetadata(title: "t", authors: []), documentHash: "h", metaHash: "m",
                             chapters: [c1, c12], totalCharacters: 805)
    }

    func testResolveObservedStrings() {
        let r = XPointerResolver(), b = book()
        XCTAssertEqual(r.resolve("/body/DocFragment/body/section/h2/text().0", percentage: nil, in: b),
                       .position(BookPosition(chapterIndex: 0, blockIndex: 0, characterOffset: 0), trimmedSteps: 0))
        XCTAssertEqual(r.resolve("/body/DocFragment[12]/body/section/p[134]/text().354", percentage: 0.9, in: b),
                       .position(BookPosition(chapterIndex: 1, blockIndex: 1, characterOffset: 354), trimmedSteps: 0))
        // A client that dropped the <section> wrapper: cannot match exactly; must not crash and must stay in the chapter
        // or fall back to the percentage.
        switch r.resolve("/body/DocFragment[12]/body/p[134]", percentage: 0.9, in: b) {
        case .percentage(let p)?: XCTAssertEqual(p, 0.9)
        case .position(let pos, _)?: XCTAssertEqual(pos.chapterIndex, 1)
        case nil: XCTFail()
        }
    }
}
