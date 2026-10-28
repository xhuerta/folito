import XCTest
@testable import ReaderCore

final class XPointerTests: XCTestCase {
    let gen = XPointerGenerator()
    let res = XPointerResolver()

    // MARK: fixture

    /// Chapter spine 1: div/p[1..3]; spine 3: div[1]/p, div[2]/h2, div[2]/p[1]; spine 5 empty.
    func makeBook() -> ProcessedBook {
        func b(_ t: String, _ x: String, _ g: Int, _ s: BlockStyle = .paragraph) -> Block {
            Block(text: t, style: s, xpointer: x, globalOffset: g)
        }
        let c1 = Chapter(spineIndex: 1, title: nil, blocks: [
            b("Hello world", "/body/DocFragment[1]/body/div/p[1]/text().0", 0),
            b("Second 😀 para", "/body/DocFragment[1]/body/div/p[2]", 11),
            b("Third", "/body/DocFragment[1]/body/div/p[3]/text().0", 25),
        ])
        let c3 = Chapter(spineIndex: 3, title: "Three", blocks: [
            b("Intro", "/body/DocFragment[3]/body/div[1]/p", 30),
            b("Heading", "/body/DocFragment[3]/body/div[2]/h2", 35, .heading2),
            b("Body text here", "/body/DocFragment[3]/body/div[2]/p", 42),
        ])
        let c5 = Chapter(spineIndex: 5, title: nil, blocks: [])
        return ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: "h", metaHash: "m",
                             chapters: [c1, c3, c5], totalCharacters: 56)
    }

    func pos(_ c: Int, _ b: Int, _ o: Int = 0) -> BookPosition {
        BookPosition(chapterIndex: c, blockIndex: b, characterOffset: o)
    }

    // MARK: generator

    func testGeneratorBasic() {
        XCTAssertEqual(gen.xpointer(spineIndex: 12, path: [.init(name: "div", index: 1), .init(name: "p", index: 3)],
                                    textOffset: 123),
                       "/body/DocFragment[12]/body/div/p[3]/text().123")
    }

    func testGeneratorOmitsTextWhenNoOffset() {
        XCTAssertEqual(gen.xpointer(spineIndex: 2, path: [.init(name: "p", index: 2)], textOffset: nil),
                       "/body/DocFragment[2]/body/p[2]")
    }

    func testGeneratorEmptyPathAndClamping() {
        XCTAssertEqual(gen.xpointer(spineIndex: 0, path: [], textOffset: nil), "/body/DocFragment[1]/body")
        XCTAssertEqual(gen.xpointer(spineIndex: 1, path: [], textOffset: -4), "/body/DocFragment[1]/body/text().0")
    }

    // MARK: parser (real-world shapes)

    func testParseRealWorldExamples() {
        // crengine / KOReader
        XCTAssertEqual(ParsedXPointer.parse("/body/DocFragment[11]/body/div/p[3]/text().5"),
                       ParsedXPointer(spineIndex: 11, steps: [.init(name: "div", index: 1), .init(name: "p", index: 3)],
                                      hasTextStep: true, textIndex: 1, offset: 5))
        XCTAssertEqual(ParsedXPointer.parse("/body/DocFragment[2]/body/div[1]/p[2]/text()[2].17")?.textIndex, 2)
        XCTAssertEqual(ParsedXPointer.parse("/body/DocFragment[2]/body/div[1]/p[2]/text()[2].17")?.offset, 17)
        // element point (".0" without text())
        let ep = ParsedXPointer.parse("/body/DocFragment[7]/body/div[1].0")
        XCTAssertEqual(ep?.steps, [.init(name: "div", index: 1)])
        XCTAssertEqual(ep?.hasTextStep, false)
        XCTAssertEqual(ep?.offset, 0)
        // Readest-style progress without text()
        XCTAssertEqual(ParsedXPointer.parse("/body/DocFragment[4]/body/div/section[2]/p[10]")?.steps.count, 3)
        // single-fragment documents have no [N]
        XCTAssertEqual(ParsedXPointer.parse("/body/DocFragment/body/p")?.spineIndex, 1)
        // body[1], trailing slash, whitespace, uppercase tags
        XCTAssertEqual(ParsedXPointer.parse(" /body/DocFragment[3]/body[1]/DIV/P[2]/ \n")?.steps,
                       [.init(name: "div", index: 1), .init(name: "p", index: 2)])
        XCTAssertEqual(ParsedXPointer.parse("/body/DocFragment[3]/body")?.steps, [])
        XCTAssertEqual(ParsedXPointer.parse("/body/DocFragment[3]")?.steps, [])
    }

    func testParseMalformed() {
        let bad = ["", "/", "garbage", "/body", "/body/DocFragment[abc]/body/p", "/body/DocFragment[0]/body/p",
                   "/body/DocFragment[1/body/p", "/body/DocFragment[1]/p", "/body/DocFragment[1]/body//p",
                   "/body/DocFragment[1]/body/p[0]", "/body/DocFragment[1]/body/p[x]", "/body/DocFragment[1]/body/p[2",
                   "/body/DocFragment[1]/body/text()/p", "/body/DocFragment[1]/body/p/text().x",
                   "/body/DocFragment[1]/body/p/text().-3", "/body/DocFragment[1]/body/p/text()[0].1",
                   "/body/DocFragment[1]/body/p.5/span", "/body/DocFragment[1]/body/1p",
                   "/html/body/div/p[14]/text().113", "/FictionBook/body/section/p",
                   "/body/DocFragment[99999999999999999999]/body/p", "/body/DocFragment[1]/body/p/text().99999999999999999999",
                   "\u{0}", "/body/DocFragment[1]/body/<p>"]
        for s in bad { XCTAssertNil(ParsedXPointer.parse(s), s) }
    }

    // MARK: resolver

    func testResolveExactWithOffset() {
        let book = makeBook()
        XCTAssertEqual(res.resolve("/body/DocFragment[1]/body/div/p[1]/text().6", percentage: 0.9, in: book),
                       .position(pos(0, 0, 6), trimmedSteps: 0))
        // explicit [1] on div is equivalent
        XCTAssertEqual(res.resolve("/body/DocFragment[1]/body/div[1]/p[3]/text().2", percentage: nil, in: book),
                       .position(pos(0, 2, 2), trimmedSteps: 0))
    }

    func testResolveOffsetCountsCodePointsNotCharacters() {
        let book = makeBook()
        // "Second " = 7 scalars, emoji = 1 scalar (2 UTF-16), then " para"
        XCTAssertEqual(res.resolve("/body/DocFragment[1]/body/div/p[2]/text().8", percentage: nil, in: book),
                       .position(pos(0, 1, 8), trimmedSteps: 0))
    }

    func testResolveOffsetClamped() {
        let book = makeBook()
        XCTAssertEqual(res.resolve("/body/DocFragment[1]/body/div/p[3]/text().500", percentage: nil, in: book),
                       .position(pos(0, 2, 5), trimmedSteps: 0))
    }

    func testResolveByDocFragmentIndexNotPosition() {
        let book = makeBook()
        XCTAssertEqual(res.resolve("/body/DocFragment[3]/body/div[2]/p/text().4", percentage: nil, in: book),
                       .position(pos(1, 2, 4), trimmedSteps: 0))
        XCTAssertEqual(res.resolve("/body/DocFragment[3]/body/div[2]/p[1]", percentage: nil, in: book),
                       .position(pos(1, 2, 0), trimmedSteps: 0))
    }

    func testResolveWithoutTextAndElementPoint() {
        let book = makeBook()
        XCTAssertEqual(res.resolve("/body/DocFragment[1]/body/div/p[2]", percentage: nil, in: book),
                       .position(pos(0, 1, 0), trimmedSteps: 0))
        XCTAssertEqual(res.resolve("/body/DocFragment[3]/body/div[2]/h2.0", percentage: nil, in: book),
                       .position(pos(1, 1, 0), trimmedSteps: 0))
    }

    func testResolveSecondTextNodeUsesBlockStart() {
        let book = makeBook()
        XCTAssertEqual(res.resolve("/body/DocFragment[1]/body/div/p[1]/text()[2].3", percentage: nil, in: book),
                       .position(pos(0, 0, 0), trimmedSteps: 0))
    }

    func testResolveInlineDescendantMapsToBlockStart() {
        let book = makeBook()
        XCTAssertEqual(res.resolve("/body/DocFragment[1]/body/div/p[1]/span/text().3", percentage: nil, in: book),
                       .position(pos(0, 0, 0), trimmedSteps: 0))
    }

    func testResolveContainerPointsToFirstBlockInside() {
        let book = makeBook()
        XCTAssertEqual(res.resolve("/body/DocFragment[3]/body/div[2]", percentage: nil, in: book),
                       .position(pos(1, 1, 0), trimmedSteps: 0))
        XCTAssertEqual(res.resolve("/body/DocFragment[3]/body", percentage: nil, in: book),
                       .position(pos(1, 0, 0), trimmedSteps: 0))
    }

    func testTrimsBackwards() {
        let book = makeBook()
        // p[9] missing -> trim 1 -> div container -> first block inside
        XCTAssertEqual(res.resolve("/body/DocFragment[1]/body/div/p[9]/text().4", percentage: 0.5, in: book),
                       .position(pos(0, 0, 0), trimmedSteps: 1))
        // div[2]/section/p: trim 1 gives div[2]/section (no), trim 2 gives div[2] container
        XCTAssertEqual(res.resolve("/body/DocFragment[3]/body/div[2]/section/p", percentage: nil, in: book),
                       .position(pos(1, 1, 0), trimmedSteps: 2))
        // unrelated top-level path in chapter: trims to nothing -> percentage preferred when available
        XCTAssertEqual(res.resolve("/body/DocFragment[1]/body/nav/ol/li[2]", percentage: 0.3, in: book),
                       .percentage(0.3))
        // ...otherwise chapter start
        XCTAssertEqual(res.resolve("/body/DocFragment[1]/body/nav/ol/li[2]", percentage: nil, in: book),
                       .position(pos(0, 0, 0), trimmedSteps: 3))
    }

    func testFallsBackToPercentage() {
        let book = makeBook()
        // unknown fragment
        XCTAssertEqual(res.resolve("/body/DocFragment[42]/body/p", percentage: 0.25, in: book), .percentage(0.25))
        // empty chapter
        XCTAssertEqual(res.resolve("/body/DocFragment[5]/body/p", percentage: 0.8, in: book), .percentage(0.8))
        // malformed
        XCTAssertEqual(res.resolve("nonsense", percentage: 0.5, in: book), .percentage(0.5))
        XCTAssertEqual(res.resolve("", percentage: 1.7, in: book), .percentage(1))
        XCTAssertEqual(res.resolve("", percentage: -2, in: book), .percentage(0))
    }

    func testNothingUsableReturnsNil() {
        let book = makeBook()
        XCTAssertNil(res.resolve("nonsense", percentage: nil, in: book))
        XCTAssertNil(res.resolve("nonsense", percentage: .nan, in: book))
        XCTAssertNil(res.resolve("/body/DocFragment[42]/body/p", percentage: nil, in: book))
        let empty = ProcessedBook(metadata: BookMetadata(title: "", authors: []), documentHash: "", metaHash: "",
                                  chapters: [], totalCharacters: 0)
        XCTAssertNil(res.resolve("/body/DocFragment[1]/body/p", percentage: nil, in: empty))
    }

    // MARK: reverse

    func testLocateRoundTrip() {
        let book = makeBook()
        let r = res.locate(pos(0, 1, 9), in: book)!   // "Second 😀 para": 9 chars -> 9 scalars? emoji is 1 char, 1 scalar
        XCTAssertEqual(r.xpointer, "/body/DocFragment[1]/body/div/p[2]/text().9")
        XCTAssertEqual(r.percentage, Double(11 + 9) / 56, accuracy: 1e-12)
        XCTAssertEqual(res.resolve(r.xpointer, percentage: nil, in: book), .position(pos(0, 1, 9), trimmedSteps: 0))
    }

    func testLocateOffsetZeroKeepsBlockXPointerAndClamps() {
        let book = makeBook()
        XCTAssertEqual(res.locate(pos(1, 0, 0), in: book)?.xpointer, "/body/DocFragment[3]/body/div[1]/p")
        XCTAssertEqual(res.locate(pos(1, 0, 0), in: book)?.percentage ?? -1, 30.0 / 56, accuracy: 1e-12)
        let end = res.locate(pos(1, 2, 999), in: book)!
        XCTAssertEqual(end.xpointer, "/body/DocFragment[3]/body/div[2]/p/text().14")
        XCTAssertEqual(end.percentage, 1, accuracy: 1e-12)
    }

    func testLocateInvalidPosition() {
        let book = makeBook()
        XCTAssertNil(res.locate(pos(9, 0), in: book))
        XCTAssertNil(res.locate(pos(0, 9), in: book))
        XCTAssertNil(res.locate(pos(-1, 0), in: book))
    }

    func testLocateScalarOffsetWithCombiningCharacters() {
        // "e" + combining acute is one Character but two scalars.
        let blk = Block(text: "e\u{301}x", xpointer: "/body/DocFragment[1]/body/p", globalOffset: 0)
        let book = ProcessedBook(metadata: BookMetadata(title: "", authors: []), documentHash: "", metaHash: "",
                                 chapters: [Chapter(spineIndex: 1, title: nil, blocks: [blk])], totalCharacters: 2)
        let r = res.locate(pos(0, 0, 1), in: book)!
        XCTAssertEqual(r.xpointer, "/body/DocFragment[1]/body/p/text().2")
        XCTAssertEqual(res.resolve(r.xpointer, percentage: nil, in: book), .position(pos(0, 0, 1), trimmedSteps: 0))
    }
}
