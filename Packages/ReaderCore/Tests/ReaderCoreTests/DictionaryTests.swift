import XCTest
@testable import ReaderCore

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Dictionary/\(name)")
    return try Data(contentsOf: url)
}

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

final class DictionaryParserTests: XCTestCase {
    func testWiktionaryRealResponse() throws {
        let entry = try XCTUnwrap(WiktionaryParser.parse(try fixture("wiktionary_en_run.json"), word: "run", language: "en"))
        XCTAssertEqual(entry.source, "Wiktionary")
        XCTAssertEqual(entry.language, "en")
        // Translingual "Symbol" is a different section kind but sits under key "en"; verbs, nouns, adjectives follow.
        let pos = entry.meanings.map(\.partOfSpeech)
        XCTAssertTrue(pos.contains("verb"))
        XCTAssertTrue(pos.contains("noun"))
        XCTAssertTrue(pos.contains("adjective"))
        XCTAssertLessThanOrEqual(entry.meanings.count, DictionaryLimits.meanings)
        let verb = try XCTUnwrap(entry.meanings.first { $0.partOfSpeech == "verb" })
        XCTAssertLessThanOrEqual(verb.senses.count, DictionaryLimits.sensesPerMeaning)
        // Parent gloss with the nested <ol> removed, then the sub-sense, with its example.
        XCTAssertEqual(verb.senses[0].definition, "To move swiftly.")
        XCTAssertTrue(verb.senses[1].definition.hasPrefix("To move forward quickly upon two feet"))
        XCTAssertEqual(verb.senses[1].examples.first, "Run, and you might still catch the train!")
        for m in entry.meanings { for s in m.senses {
            XCTAssertFalse(s.definition.contains("<"), s.definition)
            XCTAssertFalse(s.definition.contains("&amp;"))
            XCTAssertFalse(s.definition.isEmpty)
        } }
        let noun = try XCTUnwrap(entry.meanings.first { $0.partOfSpeech == "noun" })
        XCTAssertEqual(noun.senses[0].definition, "Act or instance of running, of moving rapidly using the feet.")
    }

    func testWiktionaryOtherLanguageSection() throws {
        let data = try fixture("wiktionary_en_run.json")
        let es = try XCTUnwrap(WiktionaryParser.parse(data, word: "run", language: "es"))
        XCTAssertEqual(es.meanings.first?.partOfSpeech, "noun")
        XCTAssertEqual(es.meanings.first?.senses.first?.definition, "armadillo")
        XCTAssertNil(WiktionaryParser.parse(data, word: "run", language: "fr"), "no French section")
    }

    func testWiktionaryRejectsGarbage() {
        XCTAssertNil(WiktionaryParser.parse(Data("nope".utf8), word: "x", language: "en"))
        XCTAssertNil(WiktionaryParser.parse(Data("[]".utf8), word: "x", language: "en"))
        XCTAssertNil(WiktionaryParser.parse(Data("{}".utf8), word: "x", language: "en"))
        XCTAssertNil(WiktionaryParser.parse(Data(#"{"en":[{"partOfSpeech":"Noun","definitions":[{"definition":""}]}]}"#.utf8),
                                            word: "x", language: "en"))
    }

    func testDictionaryAPIRealResponse() throws {
        let entry = try XCTUnwrap(DictionaryAPIParser.parse(try fixture("dictionaryapi_en_hello.json"), language: "en"))
        XCTAssertEqual(entry.word, "hello")
        XCTAssertEqual(entry.pronunciation, "/həˈləʊ/")
        XCTAssertEqual(entry.meanings.map(\.partOfSpeech), ["noun", "verb", "interjection"])
        let interjection = entry.meanings[2]
        XCTAssertEqual(interjection.senses.count, 5)
        XCTAssertEqual(interjection.senses[0].examples, ["Hello, everyone."])
        XCTAssertEqual(entry.meanings[0].senses[0].definition, "\"Hello!\" or an equivalent greeting.")
    }

    func testDictionaryAPINotFoundBodyIsNotAnEntry() throws {
        XCTAssertNil(DictionaryAPIParser.parse(try fixture("dictionaryapi_notfound.json"), language: "en"))
    }
}

// MARK: - Cache

final class DictionaryCacheTests: XCTestCase {
    private func entry(_ word: String, padding: Int = 0) -> DictionaryEntry {
        DictionaryEntry(word: word, language: "en",
                        meanings: [DictionaryMeaning(partOfSpeech: "noun",
                                                     senses: [DictionarySense(definition: "d " + String(repeating: "x", count: padding))])],
                        source: "test")
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dictcache-\(UUID().uuidString)/cache.json")
    }

    func testPersistsAcrossInstances() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        DictionaryCache(fileURL: url).put(entry("a"), for: "en|a")
        XCTAssertEqual(DictionaryCache(fileURL: url).get("en|a")?.word, "a")
    }

    func testEvictsLeastRecentlyUsedByCount() {
        let cache = DictionaryCache(fileURL: nil, maxEntries: 3)
        cache.put(entry("a"), for: "a"); cache.put(entry("b"), for: "b"); cache.put(entry("c"), for: "c")
        _ = cache.get("a")                      // a is now the most recent
        cache.put(entry("d"), for: "d")         // evicts b
        XCTAssertNil(cache.get("b"))
        XCTAssertNotNil(cache.get("a")); XCTAssertNotNil(cache.get("c")); XCTAssertNotNil(cache.get("d"))
        XCTAssertEqual(cache.count, 3)
    }

    func testEvictsByBytes() {
        let cache = DictionaryCache(fileURL: nil, maxEntries: 100, maxBytes: 2_500)
        for i in 0..<10 { cache.put(entry("w\(i)", padding: 400), for: "k\(i)") }
        XCTAssertLessThanOrEqual(cache.totalBytes, 2_500)
        XCTAssertNotNil(cache.get("k9"))
        XCTAssertNil(cache.get("k0"))
    }

    func testOversizedEntryIsNotStoredAndOverwriteReplaces() {
        let cache = DictionaryCache(fileURL: nil, maxEntries: 5, maxBytes: 1_000)
        cache.put(entry("huge", padding: 5_000), for: "h")
        XCTAssertNil(cache.get("h"))
        cache.put(entry("a"), for: "a"); cache.put(entry("a2"), for: "a")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.get("a")?.word, "a2")
    }

    func testRecencyPersistedByFlush() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let c1 = DictionaryCache(fileURL: url, maxEntries: 2)
        c1.put(entry("a"), for: "a"); c1.put(entry("b"), for: "b")
        _ = c1.get("a"); c1.flush()
        let c2 = DictionaryCache(fileURL: url, maxEntries: 2)
        c2.put(entry("c"), for: "c")            // evicts b, not a
        XCTAssertNotNil(c2.get("a")); XCTAssertNil(c2.get("b"))
    }

    func testCorruptFileIsEmpty() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{broken".utf8).write(to: url)
        let cache = DictionaryCache(fileURL: url)
        XCTAssertEqual(cache.count, 0)
        cache.put(entry("a"), for: "a")
        XCTAssertEqual(DictionaryCache(fileURL: url).count, 1)
    }

    func testRemoveAll() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = DictionaryCache(fileURL: url)
        cache.put(entry("a"), for: "a")
        cache.removeAll()
        XCTAssertEqual(DictionaryCache(fileURL: url).count, 0)
    }
}

// MARK: - Service

private final class FakeFetcher: DictionaryHTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requested: [String] = []
    var responses: [String: (Data, Int)] = [:]
    var error: DictionaryError?

    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        lock.lock(); requested.append(url.absoluteString); lock.unlock()
        if let error { throw error }
        return responses[url.absoluteString] ?? (Data("{}".utf8), 404)
    }
}

final class DictionaryServiceTests: XCTestCase {
    private let runURL = "https://en.wiktionary.org/api/rest_v1/page/definition/run"

    private func service(_ f: FakeFetcher, cache: DictionaryCache? = DictionaryCache(fileURL: nil)) -> DictionaryService {
        .online(cache: cache, fetcher: f)
    }

    func testLemmaFallbackFindsRunForRunning() async throws {
        let f = FakeFetcher()
        f.responses[runURL] = (try fixture("wiktionary_en_run.json"), 200)
        let entry = try await service(f).lookup("“Running,”", language: "en-GB")
        XCTAssertEqual(entry.word, "run")
        XCTAssertTrue(f.requested.contains("https://en.wiktionary.org/api/rest_v1/page/definition/Running"))
        XCTAssertTrue(f.requested.contains(runURL))
    }

    func testCacheServesRepeatedLookupWithoutNetworkAndOffline() async throws {
        let f = FakeFetcher()
        f.responses[runURL] = (try fixture("wiktionary_en_run.json"), 200)
        let cache = DictionaryCache(fileURL: nil)
        _ = try await service(f, cache: cache).lookup("run", language: "en")
        let count = f.requested.count
        f.error = .offline
        let again = try await service(f, cache: cache).lookup("Run", language: "en")
        XCTAssertEqual(again.word, "run")
        XCTAssertEqual(f.requested.count, count, "served from cache")
    }

    func testOfflineWithoutCache() async {
        let f = FakeFetcher(); f.error = .offline
        do { _ = try await service(f).lookup("run", language: "en"); XCTFail() }
        catch { XCTAssertEqual(error as? DictionaryError, .offline) }
        XCTAssertEqual(f.requested.count, 1, "stops at the first network failure")
    }

    func testRateLimited() async {
        let f = FakeFetcher()
        f.responses[runURL] = (Data("slow down".utf8), 429)
        do { _ = try await service(f).lookup("run", language: "en"); XCTFail() }
        catch { XCTAssertEqual(error as? DictionaryError, .rateLimited) }
    }

    func testNotFoundTriesCandidatesThenFallbackSourceThenFails() async {
        let f = FakeFetcher()
        do { _ = try await service(f).lookup("zzzqqxx", language: "en"); XCTFail() }
        catch { XCTAssertEqual(error as? DictionaryError, .notFound) }
        XCTAssertTrue(f.requested.contains { $0.contains("api.dictionaryapi.dev/api/v2/entries/en/zzzqqxx") })
    }

    func testFallsBackToDictionaryAPI() async throws {
        let f = FakeFetcher()
        f.responses["https://api.dictionaryapi.dev/api/v2/entries/en/hello"] = (try fixture("dictionaryapi_en_hello.json"), 200)
        let entry = try await service(f).lookup("hello", language: nil)
        XCTAssertEqual(entry.source, "dictionaryapi.dev")
    }

    func testNonEnglishNeverHitsDictionaryAPI() async {
        let f = FakeFetcher()
        do { _ = try await service(f).lookup("casa", language: "es"); XCTFail() }
        catch { XCTAssertEqual(error as? DictionaryError, .notFound) }
        XCTAssertFalse(f.requested.contains { $0.contains("dictionaryapi.dev") })
    }

    func testServerErrorReportedAfterTryingEverything() async {
        let f = FakeFetcher()
        f.responses[runURL] = (Data(), 500)
        do { _ = try await service(f).lookup("run", language: "en"); XCTFail() }
        catch { XCTAssertEqual(error as? DictionaryError, .server(status: 500)) }
    }

    func testWordIsPercentEncoded() {
        XCTAssertEqual(WiktionarySource.url(for: "café")?.absoluteString,
                       "https://en.wiktionary.org/api/rest_v1/page/definition/caf%C3%A9")
        XCTAssertEqual(WiktionarySource.url(for: "a/b")?.absoluteString,
                       "https://en.wiktionary.org/api/rest_v1/page/definition/a%2Fb")
    }

    func testMockProvider() async throws {
        let mock = MockDictionaryProvider.sample
        let e = try await mock.lookup("Running,", language: "en")
        XCTAssertEqual(e.word, "run")
        do { _ = try await mock.lookup("xyz", language: "en"); XCTFail() } catch {}
        do { _ = try await MockDictionaryProvider(error: .offline).lookup("run", language: nil); XCTFail() }
        catch { XCTAssertEqual(error as? DictionaryError, .offline) }
    }
}
