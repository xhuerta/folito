import XCTest
@testable import ReaderCore

final class TapPositionTests: XCTestCase {
    func testLineCountFromHeight() {
        // 16 pt: about 19.2 pt a line.
        XCTAssertEqual(TapPosition.Layout(width: 170, height: 19, pointSize: 16).lineCount, 1)
        XCTAssertEqual(TapPosition.Layout(width: 170, height: 96, pointSize: 16).lineCount, 5)
        // With 4 pt line spacing: 5 lines are 5 * 19.2 + 4 * 4 = 112 pt.
        XCTAssertEqual(TapPosition.Layout(width: 170, height: 112, pointSize: 16, lineSpacing: 4).lineCount, 5)
        XCTAssertEqual(TapPosition.Layout(width: 170, height: 0, pointSize: 16).lineCount, 1)
    }

    func testTapPicksLineAndColumn() {
        // 4 lines of 20 characters (x is spread over the width).
        let layout = TapPosition.Layout(width: 160, height: 4 * 19.2, pointSize: 16)
        let count = 80
        XCTAssertEqual(TapPosition.characterOffset(x: 0, y: 1, layout: layout, characterCount: count), 0)
        // Start of the third line.
        XCTAssertEqual(TapPosition.characterOffset(x: 0, y: 2.5 * 19.2, layout: layout, characterCount: count), 40)
        // Middle of the second line.
        XCTAssertEqual(TapPosition.characterOffset(x: 80, y: 1.5 * 19.2, layout: layout, characterCount: count), 30)
        // Out of bounds stays inside the text.
        XCTAssertEqual(TapPosition.characterOffset(x: 999, y: 999, layout: layout, characterCount: count), 79)
        XCTAssertEqual(TapPosition.characterOffset(x: -5, y: -5, layout: layout, characterCount: count), 0)
    }

    func testShortSingleLineUsesFontWidth() {
        // "Hello world" (11 characters, about 88 pt at 16 pt) on a 170 pt wide block: a tap at 60 pt is
        // in "world", a tap past the end is the last character.
        let layout = TapPosition.Layout(width: 170, height: 19, pointSize: 16)
        XCTAssertEqual(TapPosition.characterOffset(x: 60, y: 10, layout: layout, characterCount: 11), 7)
        XCTAssertEqual(TapPosition.characterOffset(x: 160, y: 10, layout: layout, characterCount: 11), 10)
    }

    func testTokenIndexAtOffset() {
        let text = "It is a truth, universally acknowledged."
        let tokens = WordTokenizer.tokens(in: text)
        XCTAssertEqual(TapPosition.tokenIndex(forCharacterOffset: 0, in: text, tokens: tokens), 0)
        XCTAssertEqual(TapPosition.tokenIndex(forCharacterOffset: 9, in: text, tokens: tokens), 3)   // "truth"
        // On the space after "is": the next word.
        XCTAssertEqual(TapPosition.tokenIndex(forCharacterOffset: 5, in: text, tokens: tokens), 2)
        XCTAssertEqual(TapPosition.tokenIndex(forCharacterOffset: 999, in: text, tokens: tokens), tokens.count - 1)
        XCTAssertEqual(TapPosition.tokenIndex(forCharacterOffset: 3, in: "", tokens: []), 0)
    }

    func testTokenIndexWithEmoji() {
        let text = "😀😀 word"
        let tokens = WordTokenizer.tokens(in: text)
        XCTAssertEqual(TapPosition.tokenIndex(forCharacterOffset: 3, in: text, tokens: tokens), 0)
        XCTAssertEqual(TapPosition.tokenIndex(forCharacterOffset: 0, in: text, tokens: tokens), 0)
    }
}
