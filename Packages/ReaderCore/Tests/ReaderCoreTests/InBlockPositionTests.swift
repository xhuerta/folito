import XCTest
@testable import ReaderCore

/// Position inside a block (#108): storage, XPointer carriage and the restore anchor math.
final class InBlockPositionTests: XCTestCase {
    // MARK: storage

    func testBookPositionRoundTripsTheOffset() throws {
        let p = BookPosition(chapterIndex: 2, blockIndex: 7, characterOffset: 314)
        let back = try JSONDecoder().decode(BookPosition.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }

    func testBlockOnlyPositionDecodesWithOffsetZero() throws {
        let old = Data(#"{"chapterIndex":3,"blockIndex":12}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(BookPosition.self, from: old),
                       BookPosition(chapterIndex: 3, blockIndex: 12, characterOffset: 0))
        // A stored position wrapper (the watch's `StoredPosition` shape) reads the same way.
        struct Stored: Codable { var position: BookPosition; var percentage: Double }
        let wrapped = Data(#"{"position":{"chapterIndex":1,"blockIndex":4},"percentage":0.25}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Stored.self, from: wrapped).position.characterOffset, 0)
        let negative = Data(#"{"chapterIndex":0,"blockIndex":0,"characterOffset":-5}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(BookPosition.self, from: negative).characterOffset, 0)
    }

    // MARK: offset <-> fraction

    let text = "The quick brown fox jumps over the lazy dog and keeps on running far away."

    func testOffsetSnapsBackToWordStart() {
        // 0.5 of 74 chars = 37, inside "lazy" (starts at 35).
        XCTAssertEqual(InBlockPosition.characterOffset(forFraction: 0.5, in: text), 35)
        XCTAssertEqual(InBlockPosition.characterOffset(forFraction: 0, in: text), 0)
        XCTAssertEqual(InBlockPosition.characterOffset(forFraction: -1, in: text), 0)
        XCTAssertEqual(InBlockPosition.characterOffset(forFraction: .nan, in: text), 0)
        XCTAssertEqual(InBlockPosition.characterOffset(forFraction: 1, in: text), text.count)
        XCTAssertEqual(InBlockPosition.characterOffset(forFraction: 0.5, in: ""), 0)
    }

    func testFractionScrolledPast() {
        XCTAssertEqual(InBlockPosition.fractionScrolledPast(minY: -50, maxY: 150, viewportTop: 0), 0.25)
        XCTAssertEqual(InBlockPosition.fractionScrolledPast(minY: -50, maxY: 150, viewportTop: 30), 0.4)
        XCTAssertEqual(InBlockPosition.fractionScrolledPast(minY: 20, maxY: 150, viewportTop: 0), 0)
        XCTAssertEqual(InBlockPosition.fractionScrolledPast(minY: -500, maxY: -10, viewportTop: 0), 1)
        XCTAssertEqual(InBlockPosition.fractionScrolledPast(minY: 10, maxY: 10, viewportTop: 0), 0)
    }

    /// Save at one text size, lay the block out taller at a bigger size, restore, read back: same word.
    func testTextSizeChangeKeepsTheSameCharacter() {
        let saved = InBlockPosition.characterOffset(forFraction: 0.6, in: text)
        for height in [180.0, 260.0, 420.0] {
            let f = InBlockPosition.fraction(forCharacterOffset: saved, in: text)
            let minY = InBlockPosition.wantedMinY(fraction: f, blockHeight: height, viewportTop: 31)
            let measured = InBlockPosition.fractionScrolledPast(minY: minY, maxY: minY + height, viewportTop: 31)
            XCTAssertEqual(InBlockPosition.characterOffset(forFraction: measured, in: text), saved)
        }
    }

    // MARK: XPointer

    func testOffsetTravelsInTheXPointerBothWays() {
        let block = Block(text: "Ünïcode 🇪🇸 flag then words", style: .paragraph,
                          xpointer: "/body/DocFragment[2]/body/section/p[4]", globalOffset: 100)
        let book = ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: "h", metaHash: "m",
                                 chapters: [Chapter(spineIndex: 2, title: nil, blocks: [block])],
                                 totalCharacters: 200)
        let resolver = XPointerResolver()
        // "Ünïcode 🇪🇸 " = 10 characters; the flag is 2 code points, so crengine's offset is 11.
        let pos = BookPosition(chapterIndex: 0, blockIndex: 0, characterOffset: 10)
        let located = resolver.locate(pos, in: book)!
        XCTAssertEqual(located.xpointer, "/body/DocFragment[2]/body/section/p[4]/text().11")
        XCTAssertEqual(located.percentage, 110.0 / 200, accuracy: 1e-12)
        XCTAssertEqual(resolver.resolve(located.xpointer, percentage: nil, in: book), .position(pos, trimmedSteps: 0))
        // KOReader-written pointer with an explicit first text node.
        XCTAssertEqual(resolver.resolve("/body/DocFragment[2]/body/section/p[4]/text()[1].11", percentage: nil, in: book),
                       .position(pos, trimmedSteps: 0))
        // Offset 0 keeps the plain block XPointer (old format).
        XCTAssertEqual(resolver.locate(BookPosition(chapterIndex: 0, blockIndex: 0), in: book)?.xpointer,
                       "/body/DocFragment[2]/body/section/p[4]")
    }

    // MARK: restore anchor

    /// Where `scrollTo(id, anchor: UnitPoint(y: a))` puts the block's top: block point a·H on viewport point a·V.
    private func landedMinY(anchor a: Double, blockHeight h: Double, viewportHeight v: Double) -> Double {
        a * v - a * h
    }

    func testAnchorPutsTheSavedLineAtTheTopEdge() {
        let cases: [(f: Double, h: Double, v: Double, top: Double)] = [
            (0.25, 120, 224, 0), (0.5, 120, 224, 31), (0.4, 600, 224, 31), (0.9, 600, 224, 31), (0.1, 900, 200, 0),
        ]
        for c in cases {
            let a = InBlockPosition.anchorY(fraction: c.f, blockHeight: c.h, viewportHeight: c.v, viewportTop: c.top)!
            let minY = landedMinY(anchor: a, blockHeight: c.h, viewportHeight: c.v)
            XCTAssertEqual(c.top - minY, c.f * c.h, accuracy: 1e-9, "\(c)")
            XCTAssertEqual(minY, InBlockPosition.wantedMinY(fraction: c.f, blockHeight: c.h, viewportTop: c.top),
                           accuracy: 1e-9)
        }
    }

    func testAnchorDegenerateCasesUseTop() {
        XCTAssertNil(InBlockPosition.anchorY(fraction: 0, blockHeight: 100, viewportHeight: 200, viewportTop: 0))
        XCTAssertNil(InBlockPosition.anchorY(fraction: 0.5, blockHeight: 0, viewportHeight: 200, viewportTop: 0))
        XCTAssertNil(InBlockPosition.anchorY(fraction: 0.5, blockHeight: 200, viewportHeight: 0, viewportTop: 0))
        XCTAssertNil(InBlockPosition.anchorY(fraction: 0.5, blockHeight: 200, viewportHeight: 200.5, viewportTop: 0))
        let clamped = InBlockPosition.anchorY(fraction: 0.5, blockHeight: 200, viewportHeight: 201.5, viewportTop: 0)!
        XCTAssertEqual(abs(clamped), InBlockPosition.maxAnchorMagnitude)
    }

    /// A wrong viewport height (e.g. the safe area counted differently) is corrected from where the jump landed.
    func testCorrectionConvergesWithAWrongViewportHeight() {
        let h = 500.0, trueV = 224.0, assumedV = 190.0, top = 31.0, f = 0.55
        let wanted = InBlockPosition.wantedMinY(fraction: f, blockHeight: h, viewportTop: top)
        var a = InBlockPosition.anchorY(fraction: f, blockHeight: h, viewportHeight: assumedV, viewportTop: top)!
        var error = landedMinY(anchor: a, blockHeight: h, viewportHeight: trueV) - wanted
        XCTAssertGreaterThan(abs(error), InBlockPosition.tolerance)
        for _ in 0..<3 where abs(error) > InBlockPosition.tolerance {
            a = InBlockPosition.correctedAnchorY(a, error: error, blockHeight: h, viewportHeight: assumedV)
            error = landedMinY(anchor: a, blockHeight: h, viewportHeight: trueV) - wanted
        }
        XCTAssertLessThanOrEqual(abs(error), InBlockPosition.tolerance)
    }
}
