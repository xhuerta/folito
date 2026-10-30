import XCTest
@testable import ReaderCore

final class WordTokenizerTests: XCTestCase {
    func testBasicWordsAndRanges() {
        let text = "Hello, world! It's 1984."
        let t = WordTokenizer.tokens(in: text)
        XCTAssertEqual(t.map(\.text), ["Hello", "world", "It's"])
        XCTAssertEqual(t.map(\.range), [NSRange(location: 0, length: 5), NSRange(location: 7, length: 5),
                                        NSRange(location: 14, length: 4)])
    }

    func testApostrophesAndHyphens() {
        let t = WordTokenizer.tokens(in: "“Don’t,” she said — a well-known l’homme 'quoted' rock-")
        XCTAssertEqual(t.map(\.text), ["Don’t", "she", "said", "a", "well-known", "l’homme", "quoted", "rock"])
    }

    func testUTF16SafetyWithEmojiAndCombining() {
        let text = "😀 café naïve 日本語 e\u{0301}tude"
        let tokens = WordTokenizer.tokens(in: text)
        XCTAssertEqual(tokens.map(\.text), ["café", "naïve", "日本語", "e\u{0301}tude"])
        for tok in tokens {
            let r = WordTokenizer.range(of: tok, in: text)
            XCTAssertNotNil(r)
            XCTAssertEqual(String(text[r!]), tok.text)
        }
        // Emoji counts as two UTF-16 units: "café" starts at 3.
        XCTAssertEqual(tokens[0].range.location, 3)
    }

    func testSupplementaryPlaneLetters() {
        let text = "x 𝒜bc y"   // U+1D49C is a letter outside the BMP
        let tokens = WordTokenizer.tokens(in: text)
        XCTAssertEqual(tokens.map(\.text), ["x", "𝒜bc", "y"])
        XCTAssertEqual(tokens[1].range, NSRange(location: 2, length: 4))
        XCTAssertEqual(String(text[WordTokenizer.range(of: tokens[1], in: text)!]), "𝒜bc")
    }

    func testNumbersAndPunctuationSkipped() {
        XCTAssertTrue(WordTokenizer.tokens(in: "12 , 3.5 --- … 😀").isEmpty)
        XCTAssertTrue(WordTokenizer.tokens(in: "").isEmpty)
        XCTAssertEqual(WordTokenizer.tokens(in: "3rd").map(\.text), ["3rd"])
    }

    func testSoftHyphenStaysInsideWord() {
        let t = WordTokenizer.tokens(in: "inter\u{00AD}national")
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(WordNormalizer.clean(t[0].text), "international")
    }

    func testTokenIndexLookup() {
        let tokens = WordTokenizer.tokens(in: "aa bb cc")
        XCTAssertEqual(WordTokenizer.tokenIndex(at: 0, in: tokens), 0)
        XCTAssertEqual(WordTokenizer.tokenIndex(at: 4, in: tokens), 1)
        XCTAssertEqual(WordTokenizer.tokenIndex(at: 2, in: tokens), 1)
        XCTAssertEqual(WordTokenizer.tokenIndex(at: 99, in: tokens), 2)
        XCTAssertNil(WordTokenizer.tokenIndex(at: 0, in: []))
    }
}

final class WordNormalizerTests: XCTestCase {
    func testClean() {
        XCTAssertEqual(WordNormalizer.clean("“Hello,”"), "Hello")
        XCTAssertEqual(WordNormalizer.clean("don’t"), "don't")
        XCTAssertEqual(WordNormalizer.clean("dog's"), "dog")
        XCTAssertEqual(WordNormalizer.clean("dog’s"), "dog")
        XCTAssertEqual(WordNormalizer.clean("(well‑known)"), "well-known")
        XCTAssertEqual(WordNormalizer.clean("cafe\u{0301}"), "café")   // NFC
        XCTAssertEqual(WordNormalizer.clean("..."), "")
        XCTAssertEqual(WordNormalizer.clean("is"), "is")
    }

    func testPrimaryLanguage() {
        XCTAssertEqual(WordNormalizer.primaryLanguage("en-US"), "en")
        XCTAssertEqual(WordNormalizer.primaryLanguage("ES_es"), "es")
        XCTAssertEqual(WordNormalizer.primaryLanguage("spa"), "es")
        XCTAssertEqual(WordNormalizer.primaryLanguage("zh-Hans-CN"), "zh")
        XCTAssertEqual(WordNormalizer.primaryLanguage(nil), "en")
        XCTAssertEqual(WordNormalizer.primaryLanguage(""), "en")
        XCTAssertEqual(WordNormalizer.primaryLanguage("!!"), "en")
    }

    func testCandidatesOrderAndLowercase() {
        XCTAssertEqual(WordNormalizer.candidates(for: "Running,", language: "en").prefix(2), ["Running", "running"])
        let c = WordNormalizer.candidates(for: "Running", language: "en")
        XCTAssertTrue(c.contains("run"))
        XCTAssertEqual(c.count, Set(c).count, "no duplicates")
        XCTAssertLessThanOrEqual(c.count, 5)
    }

    func testEnglishStems() {
        func stems(_ w: String) -> [String] { WordNormalizer.stems(of: w, language: "en") }
        XCTAssertTrue(stems("cats").contains("cat"))
        XCTAssertTrue(stems("flies").contains("fly"))
        XCTAssertTrue(stems("boxes").contains("box"))
        XCTAssertTrue(stems("stopped").contains("stop"))
        XCTAssertTrue(stems("liked").contains("like"))
        XCTAssertTrue(stems("carried").contains("carry"))
        XCTAssertTrue(stems("making").contains("make"))
        XCTAssertTrue(stems("running").contains("run"))
        XCTAssertTrue(stems("walking").contains("walk"))
        XCTAssertFalse(stems("class").contains("clas"))
        XCTAssertTrue(stems("is").isEmpty)
    }

    func testOtherLanguages() {
        XCTAssertTrue(WordNormalizer.candidates(for: "casas", language: "es-MX").contains("casa"))
        XCTAssertEqual(WordNormalizer.candidates(for: "haus", language: "de").prefix(2), ["haus", "Haus"])
        XCTAssertEqual(WordNormalizer.candidates(for: "走る", language: "ja"), ["走る"])
        XCTAssertEqual(WordNormalizer.candidates(for: "!!!", language: "en"), [])
    }
}

final class HTMLTextTests: XCTestCase {
    func testStripsTagsAndDecodesEntities() {
        XCTAssertEqual(HTMLText.plain("To <a href=\"/x\">move</a> <b>fast</b>&nbsp;&amp; far &#8212; &#x41;"), "To move fast & far — A")
    }

    func testDropsNestedListAndLinkTags() {
        let html = "To move swiftly.\n<ol><li>One <i>sub</i></li><li>Two</li></ol>"
        XCTAssertEqual(HTMLText.plain(html, dropNestedLists: true), "To move swiftly.")
        XCTAssertEqual(HTMLText.plain(html), "To move swiftly. One sub Two")
        XCTAssertEqual(HTMLText.plain("a<link rel=\"x\" href=\"y\"> b<style>.x{}</style>c"), "a bc")
    }

    func testLiteralAngleBracketsAndBrokenInput() {
        XCTAssertEqual(HTMLText.plain("x < y and a > b"), "x < y and a > b")
        XCTAssertEqual(HTMLText.plain("<b>unclosed"), "unclosed")
        XCTAssertEqual(HTMLText.plain("AT&T &bogus; ok"), "AT&T &bogus; ok")
        XCTAssertEqual(HTMLText.plain(""), "")
    }

    func testPunctuationSpacingAfterRemovedTags() {
        XCTAssertEqual(HTMLText.plain("<i>word</i> ."), "word.")
        XCTAssertEqual(HTMLText.plain("(<a>x</a> )"), "(x)")
    }
}

final class MockDictionaryProviderTests: XCTestCase {
    func testMockProvider() async throws {
        let mock = MockDictionaryProvider.sample
        let e = try await mock.lookup("Running,", language: "en")
        XCTAssertEqual(e.word, "run")
        do { _ = try await mock.lookup("xyz", language: "en"); XCTFail() } catch {}
        do { _ = try await MockDictionaryProvider(error: .noDictionary).lookup("run", language: nil); XCTFail() }
        catch { XCTAssertEqual(error as? DictionaryError, .noDictionary) }
    }
}

final class WordContextTests: XCTestCase {
    func testContextWindow() throws {
        let text = "One two, three four five six seven."
        let tokens = WordTokenizer.tokens(in: text)
        let c = try XCTUnwrap(WordContext.make(text: text, tokens: tokens, index: 3, radius: 2))
        XCTAssertEqual(c.word, "four")
        XCTAssertEqual(c.before, "two, three ")
        XCTAssertEqual(c.after, " five six")
        XCTAssertTrue(c.hasMoreBefore)
        XCTAssertTrue(c.hasMoreAfter)
        let edge = try XCTUnwrap(WordContext.make(text: text, tokens: tokens, index: 0, radius: 2))
        XCTAssertEqual(edge.before, "")
        XCTAssertFalse(edge.hasMoreBefore)
        XCTAssertNil(WordContext.make(text: text, tokens: tokens, index: 99))
    }

    func testContextWithEmoji() throws {
        let text = "😀 alpha 😀 beta gamma"
        let tokens = WordTokenizer.tokens(in: text)
        let c = try XCTUnwrap(WordContext.make(text: text, tokens: tokens, index: 1, radius: 1))
        XCTAssertEqual(c.before, "alpha 😀 ")
        XCTAssertEqual(c.after, " gamma")
    }
}
