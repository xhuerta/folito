import XCTest
@testable import ReaderCore

/// Fixtures: scripts/make_dictionary_fixtures.py (tiny StarDict dictionaries written for the tests).
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/Dictionary")

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dict-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func template(_ language: String) -> CompactDictionaryInfo {
    CompactDictionaryInfo(id: "tiny-\(language)", name: "Tiny \(language)", language: language, source: "Tests",
                          license: "CC0", licenseURL: "https://example.org/cc0", attribution: "Written for the tests.",
                          sourceURL: "https://example.org/tiny-\(language).zip", sourceVersion: "")
}

/// Converts a fixture ZIP into a compact file in `dir`.
private func convertFixture(_ language: String, into dir: URL) throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let out = dir.appendingPathComponent("tiny-\(language).\(CompactDictionaryFormat.fileExtension)")
    _ = try StarDictConverter.convert(zip: fixtures.appendingPathComponent("tiny-\(language).zip"),
                                      template: template(language), to: out,
                                      workDirectory: dir.appendingPathComponent("work-\(language)"))
    return out
}

final class StarDictParsingTests: XCTestCase {
    func testIfo() throws {
        let text = try String(contentsOf: fixtures.appendingPathComponent("tiny-en/tiny-en.ifo"), encoding: .utf8)
        let info = try StarDictInfo.parse(text)
        XCTAssertEqual(info.bookName, "tiny-en")
        XCTAssertEqual(info.wordCount, 7)
        XCTAssertEqual(info.synWordCount, 5)
        XCTAssertEqual(info.sameTypeSequence, "h")
        XCTAssertEqual(info.idxOffsetBits, 32)
        XCTAssertEqual(info.date, "2026-10-01")
        XCTAssertThrowsError(try StarDictInfo.parse("not an ifo"))
        XCTAssertThrowsError(try StarDictInfo.parse("StarDict's dict ifo file\nwordcount=x\n"))
        XCTAssertThrowsError(try StarDictInfo.parse("StarDict's dict ifo file\nwordcount=1\nidxfilesize=9\nidxoffsetbits=16\n"))
    }

    func testIdxAndSyn() throws {
        let idx = try StarDictIndex.parseIdx(try Data(contentsOf: fixtures.appendingPathComponent("tiny-en/tiny-en.idx")))
        XCTAssertEqual(idx.map(\.word), ["café", "cat", "empty", "Polish", "polish", "real", "run"])
        XCTAssertEqual(idx[0].offset, 0)
        XCTAssertEqual(idx.first { $0.word == "empty" }?.size, 0)
        let syn = try StarDictIndex.parseSyn(try Data(contentsOf: fixtures.appendingPathComponent("tiny-en/tiny-en.syn")))
        XCTAssertEqual(syn.count, 5)
        XCTAssertEqual(syn.first { $0.word == "ran" }.map { idx[$0.index].word }, "run")
        // Truncated records are rejected rather than read past the end.
        XCTAssertThrowsError(try StarDictIndex.parseIdx(Data("word\0\0\0".utf8)))
        XCTAssertThrowsError(try StarDictIndex.parseSyn(Data("word".utf8)))
    }

    func testIdx64BitOffsets() throws {
        var data = Data("a\0".utf8)
        data += Data([0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3])
        let items = try StarDictIndex.parseIdx(data, offsetBits: 64)
        XCTAssertEqual(items, [StarDictIndex.Item(word: "a", offset: 1 << 32 | 2, size: 3)])
    }

    func testDictzipInflatesAndChecksTrailer() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.dict")
        try Gzip.decompress(fixtures.appendingPathComponent("tiny-en/tiny-en.dict.dz"), to: out)
        let text = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(text.contains("A small coffee shop."))

        // A flipped byte in the CRC trailer is detected.
        var damaged = try Data(contentsOf: fixtures.appendingPathComponent("tiny-en/tiny-en.dict.dz"))
        damaged[damaged.count - 6] ^= 0xFF
        let bad = dir.appendingPathComponent("bad.dz")
        try damaged.write(to: bad)
        XCTAssertThrowsError(try Gzip.decompress(bad, to: dir.appendingPathComponent("bad.dict")))
        try Data("not gzip at all, but long enough".utf8).write(to: bad)
        XCTAssertThrowsError(try Gzip.decompress(bad, to: dir.appendingPathComponent("bad.dict")))
    }
}

final class StarDictDefinitionTests: XCTestCase {
    func testReaderDictMarkup() throws {
        let html = "/rʌn/\n<p><b>Verb</b></p><ol><li>To move fast on foot.</li>"
            + "<ol style=\"list-style-type:lower-alpha\"><li>(<i>sports</i>) To take part in a race.</li></ol>"
            + "<li>To operate &amp; work.</li></ol><p><b>Noun</b> <i>m.</i></p><ol><li>An act of running.</li></ol>"
        let e = try XCTUnwrap(StarDictDefinition.parse(html, word: "run", language: "en", source: "S"))
        XCTAssertEqual(e.pronunciation, "/rʌn/")
        XCTAssertEqual(e.meanings.map(\.partOfSpeech), ["Verb", "Noun m."])
        XCTAssertEqual(e.meanings[0].senses.map(\.definition), ["To move fast on foot.", "To operate & work."])
        XCTAssertEqual(e.meanings[0].senses[0].subsenses, ["(sports) To take part in a race."])
        XCTAssertEqual(e.source, "S")
    }

    func testListNestedInsideItemAndUnclosedItems() throws {
        let html = "<p><b>Noun</b></p><ol><li>Parent<ol><li>Child one</li><li>Child two</ol></li><li>Second</ol>"
        let e = try XCTUnwrap(StarDictDefinition.parse(html, word: "w", language: "en", source: "S"))
        XCTAssertEqual(e.meanings[0].senses.map(\.definition), ["Parent", "Second"])
        XCTAssertEqual(e.meanings[0].senses[0].subsenses, ["Child one", "Child two"])
    }

    func testRubyAndRepeatedHeadingsMerge() throws {
        let html = "<p><b>名詞</b></p><ol><li><ruby>小犬<rp>（</rp><rt>こいぬ</rt><rp>）</rp></ruby></li></ol>"
            + "<p><b>名詞</b></p><ol><li>二つ目</li></ol>"
        let e = try XCTUnwrap(StarDictDefinition.parse(html, word: "犬", language: "ja", source: "S"))
        XCTAssertEqual(e.meanings.count, 1)
        XCTAssertEqual(e.meanings[0].senses.map(\.definition), ["小犬（こいぬ）", "二つ目"])
        XCTAssertNil(e.pronunciation)
    }

    func testLimitsAndEmptyInput() throws {
        let long = String(repeating: "a", count: 1000)
        let items = (0..<20).map { "<li>sense \($0) \(long)</li>" }.joined()
        let e = try XCTUnwrap(StarDictDefinition.parse("<ol>\(items)</ol>", word: "w", language: "en", source: "S"))
        XCTAssertEqual(e.meanings.count, 1)
        XCTAssertEqual(e.meanings[0].partOfSpeech, "")
        XCTAssertEqual(e.meanings[0].senses.count, DictionaryLimits.sensesPerMeaning)
        XCTAssertEqual(e.meanings[0].senses[0].definition.count, DictionaryLimits.maxDefinitionLength)
        XCTAssertTrue(e.meanings[0].senses[0].definition.hasSuffix("\u{2026}"))
        XCTAssertNil(StarDictDefinition.parse("", word: "w", language: "en", source: "S"))
        XCTAssertNil(StarDictDefinition.parse("<p><b>Noun</b></p><ol></ol>", word: "w", language: "en", source: "S"))
    }

    func testPlainTextDefinitions() throws {
        let e = try XCTUnwrap(StarDictDefinition.parse("first line\n\nsecond", word: "w", language: "en", source: "S", type: "m"))
        XCTAssertEqual(e.meanings[0].senses.map(\.definition), ["first line", "second"])
        // HTML without any list: the text itself is the definition.
        let loose = try XCTUnwrap(StarDictDefinition.parse("<b>just</b> text", word: "w", language: "en", source: "S"))
        XCTAssertEqual(loose.meanings[0].senses.map(\.definition), ["just text"])
    }
}

final class CompactDictionaryTests: XCTestCase {
    func testEntryCodecRoundTrip() throws {
        let entry = MockDictionaryProvider.sample.entries["run"]!
        let bytes = EntryCodec.encode(entry)
        let decoded = try EntryCodec.decode(bytes[...], language: entry.language, source: entry.source)
        XCTAssertEqual(decoded, entry)
        XCTAssertThrowsError(try EntryCodec.decode(bytes.dropLast(3), language: "en", source: "S"))
    }

    func testVarint() throws {
        for value: UInt64 in [0, 1, 127, 128, 300, 1 << 32, UInt64.max] {
            var out: [UInt8] = []
            Varint.append(value, to: &out)
            var p = 0
            XCTAssertEqual(try out.withUnsafeBufferPointer { try Varint.read($0, &p) }, value)
            XCTAssertEqual(p, out.count)
        }
    }

    func testNormalizedKey() {
        XCTAssertEqual(CompactDictionaryFormat.normalizedKey("Cafe\u{0301}"), Array("café".utf8))
        XCTAssertEqual(CompactDictionaryFormat.normalizedKey("ÉTÉ"), Array("été".utf8))
        XCTAssertEqual(CompactDictionaryFormat.normalizedKey(String(repeating: "x", count: 500)).count,
                       CompactDictionaryFormat.maxKeyBytes)
    }

    func testConvertAndLookUp() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var fractions: [Double] = []
        let out = dir.appendingPathComponent("en.\(CompactDictionaryFormat.fileExtension)")
        let info = try StarDictConverter.convert(zip: fixtures.appendingPathComponent("tiny-en.zip"), template: template("en"),
                                                 to: out, workDirectory: dir.appendingPathComponent("work"),
                                                 progress: { fractions.append($0) })
        XCTAssertEqual(info.headwordCount, 6, "the empty definition is skipped")
        XCTAssertEqual(info.sourceVersion, "2026-10-01", "taken from the .ifo when the template has none")
        XCTAssertEqual(fractions.last, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("work/inflated.dict").path))

        let dict = try CompactDictionary(url: out)
        XCTAssertEqual(dict.info, info)
        XCTAssertEqual(dict.info.license, "CC0")

        let run = try dict.entries(for: "run")
        XCTAssertEqual(run.map(\.word), ["run"])
        XCTAssertEqual(run[0].pronunciation, "/rʌn/")
        XCTAssertEqual(run[0].language, "en")
        XCTAssertEqual(run[0].source, "Tests")
        // Synonyms / inflected forms point at their headword, whatever the case.
        XCTAssertEqual(try dict.entries(for: "ran").map(\.word), ["run"])
        XCTAssertEqual(try dict.entries(for: "RUNNING").map(\.word), ["run"])
        XCTAssertEqual(try dict.entries(for: "cats").map(\.word), ["cat"])
        // Several headwords share a key.
        XCTAssertEqual(Set(try dict.entries(for: "polish").map(\.word)), ["Polish", "polish"])
        // NFC and case folding.
        XCTAssertEqual(try dict.entries(for: "CAFE\u{0301}").map(\.word), ["café"])
        XCTAssertTrue(try dict.entries(for: "missing").isEmpty)
        XCTAssertTrue(try dict.entries(for: "empty").isEmpty)
        XCTAssertTrue(try dict.entries(for: "").isEmpty)
        XCTAssertTrue(try dict.entries(for: "zzzz").isEmpty, "after the last key")
        XCTAssertTrue(try dict.entries(for: "a").isEmpty, "before the first key")
    }

    func testManyKeysSpanBucketsAndBlocks() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("many.folidict")
        let writer = try CompactDictionaryWriter(url: url, blockSize: 512)
        var refs: [String: CompactEntryRef] = [:]
        for i in 0..<1_000 {
            let word = String(format: "w%04d", i)
            let entry = DictionaryEntry(word: word, language: "xx", meanings: [
                DictionaryMeaning(partOfSpeech: "n", senses: [DictionarySense(definition: "Definition number \(i).")]),
            ], source: "")
            let ref = try writer.add(entry)
            refs[word] = ref
            writer.addKey(word, ref: ref)
        }
        // One key with more entries than kept, crossing a bucket boundary (128 records per bucket).
        for i in 0..<10 { writer.addKey("w0127", ref: refs[String(format: "w%04d", 900 + i)]!, isHeadword: false) }
        let info = try writer.finish(info: template("xx"))
        XCTAssertGreaterThan(info.blockCount, 10)
        XCTAssertGreaterThan(info.bucketCount, 5)

        let dict = try CompactDictionary(url: url)
        for i in stride(from: 0, to: 1_000, by: 37) {
            let word = String(format: "w%04d", i)
            XCTAssertEqual(try dict.entries(for: word).first?.meanings[0].senses[0].definition, "Definition number \(i).")
        }
        let shared = try dict.entries(for: "w0127")
        XCTAssertEqual(shared.first?.word, "w0127", "the headword comes before synonym hits")
        XCTAssertEqual(shared.count, CompactDictionaryFormat.maxRefsPerKey)
        XCTAssertTrue(try dict.entries(for: "w0063x").isEmpty)
        XCTAssertTrue(try dict.entries(for: "w1000").isEmpty)
    }

    func testRejectsDamagedFiles() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try convertFixture("en", into: dir)
        let data = try Data(contentsOf: good)

        let bad = dir.appendingPathComponent("bad.folidict")
        try Data("FOLIDIC1 but nothing else".utf8).write(to: bad)
        XCTAssertThrowsError(try CompactDictionary(url: bad))
        try data.dropLast(1).write(to: bad)
        XCTAssertThrowsError(try CompactDictionary(url: bad))
        XCTAssertThrowsError(try CompactDictionary(url: dir.appendingPathComponent("missing.folidict")))

        // Garbage in the data sections opens (the footer is fine) but lookups fail cleanly.
        var corrupted = data
        for i in 8..<min(corrupted.count - 600, 400) { corrupted[i] = 0xFF }
        try corrupted.write(to: bad)
        if let dict = try? CompactDictionary(url: bad) {
            XCTAssertThrowsError(try dict.entries(for: "run"))
        }
    }

    func testRejectsNonStarDictZip() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notZip = dir.appendingPathComponent("x.zip")
        try Data("hello".utf8).write(to: notZip)
        XCTAssertThrowsError(try StarDictConverter.convert(zip: notZip, template: template("en"),
                                                           to: dir.appendingPathComponent("o"), workDirectory: dir))
        // A valid ZIP (an EPUB fixture) without StarDict files.
        let epub = fixtures.deletingLastPathComponent().appendingPathComponent("simple.epub")
        XCTAssertThrowsError(try StarDictConverter.convert(zip: epub, template: template("en"),
                                                           to: dir.appendingPathComponent("o"),
                                                           workDirectory: dir.appendingPathComponent("w"))) {
            XCTAssertEqual($0 as? DictionaryImportError, .notAStarDict)
        }
    }

    func testCancellation() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try StarDictConverter.convert(zip: fixtures.appendingPathComponent("tiny-en.zip"),
                                                           template: template("en"), to: dir.appendingPathComponent("o"),
                                                           workDirectory: dir.appendingPathComponent("w"),
                                                           isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}

final class OfflineDictionaryServiceTests: XCTestCase {
    private var dir: URL!
    private var installed: InstalledDictionaries!

    override func setUpWithError() throws {
        dir = try temporaryDirectory()
        installed = InstalledDictionaries(directory: dir.appendingPathComponent("installed"))
        for lang in ["en", "es"] {
            try installed.install(fileAt: try convertFixture(lang, into: dir))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testInstalledListAndReload() throws {
        XCTAssertEqual(installed.infos.map(\.id), ["tiny-en", "tiny-es"])
        let again = InstalledDictionaries(directory: installed.directory)
        XCTAssertEqual(again.infos.map(\.id), ["tiny-en", "tiny-es"])
        XCTAssertGreaterThan(again.totalSize, 0)
        // A stray or damaged file is ignored.
        try Data("junk".utf8).write(to: installed.directory.appendingPathComponent("junk.folidict"))
        again.reload()
        XCTAssertEqual(again.infos.map(\.id), ["tiny-en", "tiny-es"])
        again.remove(id: "tiny-en")
        XCTAssertEqual(again.infos.map(\.id), ["tiny-es"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.url(for: "tiny-en").path))
    }

    func testInstallVerifiesChecksumAndReplaces() throws {
        let file = try convertFixture("en", into: dir.appendingPathComponent("again"))
        XCTAssertThrowsError(try installed.install(fileAt: file, sha256: String(repeating: "0", count: 64))) {
            XCTAssertEqual($0 as? DictionaryImportError, .checksumMismatch)
        }
        XCTAssertThrowsError(try installed.install(fileAt: file, size: 1))
        let sha = try FileDigest.sha256(of: file)
        XCTAssertEqual(sha.count, 64)
        let info = try installed.install(fileAt: file, size: FileDigest.size(of: file), sha256: sha.uppercased())
        XCTAssertEqual(info.id, "tiny-en")
        XCTAssertEqual(installed.infos.count, 2)
        let junk = dir.appendingPathComponent("junk.folidict")
        try Data("junk".utf8).write(to: junk)
        XCTAssertThrowsError(try installed.install(fileAt: junk)) {
            XCTAssertEqual($0 as? DictionaryImportError, .invalidCompactFile)
        }
    }

    func testFileNamesAreSanitized() {
        XCTAssertEqual(InstalledDictionaries.fileName(for: "../../etc/x"), "etcx.folidict")
        XCTAssertEqual(InstalledDictionaries.fileName(for: "readerdict-en"), "readerdict-en.folidict")
    }

    func testBookLanguageFirstThenOthers() async throws {
        let service = OfflineDictionaryService(installed: installed)
        let es = try await service.lookup("real", language: "es-ES")
        XCTAssertEqual(es.language, "es")
        XCTAssertEqual(es.meanings[0].senses[0].definition, "Que existe de verdad.")
        let en = try await service.lookup("real", language: "en")
        XCTAssertEqual(en.language, "en")
        // Not in the book's language: falls back to another installed dictionary.
        let casa = try await service.lookup("casas", language: "en")
        XCTAssertEqual(casa.word, "casa")
        XCTAssertEqual(casa.pronunciation, "[ˈkasa]")
        // No language: English first.
        let unknown = try await service.lookup("real", language: nil)
        XCTAssertEqual(unknown.language, "en")
    }

    func testNormalizationAndCandidates() async throws {
        let service = OfflineDictionaryService(installed: installed)
        let running = try await service.lookup("“Running,”", language: "en")
        XCTAssertEqual(running.word, "run")
        let cats = try await service.lookup("Cats", language: "en")
        XCTAssertEqual(cats.word, "cat")
        let cafe = try await service.lookup("CAFÉ", language: "en")
        XCTAssertEqual(cafe.word, "café")
        // The exact-case headword wins; the other one's meanings follow.
        let polish = try await service.lookup("Polish", language: "en")
        XCTAssertEqual(polish.word, "Polish")
        XCTAssertEqual(polish.meanings.map(\.partOfSpeech), ["Adjective", "Verb"])
        let lower = try await service.lookup("polish", language: "en")
        XCTAssertEqual(lower.word, "polish")
    }

    func testMergeRanking() {
        func entry(_ w: String) -> DictionaryEntry {
            DictionaryEntry(word: w, language: "en", meanings: [DictionaryMeaning(partOfSpeech: w, senses: [DictionarySense(definition: w)])], source: "")
        }
        // Sentence-initial capital: the lower-case headword beats an inflection pointing elsewhere.
        XCTAssertEqual(OfflineDictionaryService.merge([entry("thee"), entry("the")], preferring: "The")?.word, "the")
        // Lower-case word: a base form beats a capitalised place name with the same spelling.
        XCTAssertEqual(OfflineDictionaryService.merge([entry("Maisons"), entry("maison")], preferring: "maisons")?.word, "maison")
        XCTAssertEqual(OfflineDictionaryService.merge([entry("House"), entry("house")], preferring: "houses")?.word, "house")
        let merged = OfflineDictionaryService.merge([entry("run"), entry("ran")], preferring: "ran")
        XCTAssertEqual(merged?.word, "ran")
        XCTAssertEqual(merged?.meanings.map(\.partOfSpeech), ["ran", "run"])
        XCTAssertNil(OfflineDictionaryService.merge([], preferring: "x"))
    }

    func testErrors() async throws {
        let service = OfflineDictionaryService(installed: installed)
        do { _ = try await service.lookup("zzzz", language: "en"); XCTFail() }
        catch { XCTAssertEqual(error as? DictionaryError, .notFound) }
        do { _ = try await service.lookup("...", language: "en"); XCTFail() }
        catch { XCTAssertEqual(error as? DictionaryError, .notFound) }
        let empty = OfflineDictionaryService(installed: InstalledDictionaries(directory: dir.appendingPathComponent("none")))
        do { _ = try await empty.lookup("run", language: "en"); XCTFail() }
        catch { XCTAssertEqual(error as? DictionaryError, .noDictionary) }
    }
}

final class DictionaryCatalogTests: XCTestCase {
    func testCatalogCoversAppLanguages() {
        let languages = Set(DictionaryCatalog.all.map(\.language))
        XCTAssertEqual(languages, ["en", "es", "fr", "de", "it", "pt", "ja", "zh"])
        XCTAssertEqual(Set(DictionaryCatalog.all.map(\.id)).count, DictionaryCatalog.all.count)
        for d in DictionaryCatalog.all {
            XCTAssertEqual(d.downloadURL.scheme, "https")
            XCTAssertGreaterThan(d.downloadSize, 0)
            XCTAssertGreaterThan(d.installedSize, 0)
            XCTAssertEqual(d.license, "CC BY-SA 4.0")
            let info = d.compactInfo(sourceVersion: "2026-10-01")
            XCTAssertEqual(info.id, d.id)
            XCTAssertEqual(info.language, d.language)
            XCTAssertTrue(info.attribution.contains("Wiktionary"))
            XCTAssertTrue(info.attribution.contains("CC BY-SA 4.0"))
            XCTAssertEqual(InstalledDictionaries.fileName(for: d.id), d.id + ".folidict")
        }
        XCTAssertEqual(DictionaryCatalog.descriptor(id: "readerdict-ja")?.language, "ja")
        XCTAssertNil(DictionaryCatalog.descriptor(id: "nope"))
    }
}
