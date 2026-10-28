import XCTest
import ReaderCore
@testable import WristReaderWatch

@MainActor
final class TypographyModelTests: XCTestCase {
    private func makeModel(clock: @escaping () -> Int = { 1_000 }) -> (TypographyModel, UserDefaults) {
        let name = "wr-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (TypographyModel(store: TypographyStore(defaults: defaults), clock: clock), defaults)
    }

    func testLegacyFontSizeIsMigrated() {
        let name = "wr-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(21.0, forKey: ReaderSettings.fontSizeKey)
        let model = TypographyModel(store: TypographyStore(defaults: defaults))
        XCTAssertEqual(model.value.fontSize, 21)
    }

    func testLocalEditIsStampedPersistedAndNotified() {
        var now = 1_000
        let (model, defaults) = makeModel(clock: { now })
        var notified: [ReaderTypography] = []
        model.onLocalChange = { notified.append($0) }
        model.update { $0.fontSize = 20 }
        XCTAssertEqual(model.value.fontSize, 20)
        XCTAssertEqual(model.value.stamp, 1_000)
        XCTAssertEqual(notified.count, 1)
        model.update { $0.fontSize = 21 }          // same second: stamp still strictly increases
        XCTAssertEqual(model.value.stamp, 1_001)
        now = 5_000
        model.update { $0.theme = .sepia }
        XCTAssertEqual(model.value.stamp, 5_000)
        XCTAssertEqual(TypographyStore(defaults: defaults).load(), model.value)
    }

    func testNoOpEditDoesNothing() {
        let (model, _) = makeModel()
        var count = 0
        model.onLocalChange = { _ in count += 1 }
        model.update { $0.fontSize = ReaderTypography.defaultFontSize }
        model.update { $0.fontSize = 1_000 }       // clamps to 28: a real change
        model.update { $0.fontSize = 28 }          // no-op
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.value.fontSize, 28)
    }

    func testRemoteLastWriterWins() {
        let (model, _) = makeModel()
        model.update { $0.fontSize = 20 }          // stamp 1000
        var older = ReaderTypography.default; older.theme = .sepia; older.stamp = 999
        var newer = older; newer.stamp = 2_000
        XCTAssertFalse(model.applyRemote(older))
        XCTAssertEqual(model.value.theme, .dark)
        XCTAssertTrue(model.applyRemote(newer))
        XCTAssertEqual(model.value.theme, .sepia)
        XCTAssertFalse(model.applyRemote(newer), "tie keeps local")
    }

    func testResetProducesNewerStampAndDefaultLook() {
        let (model, _) = makeModel()
        model.update { $0.fontSize = 24; $0.theme = .dim }
        let before = model.value.stamp
        model.reset()
        XCTAssertTrue(model.value.sameLook(as: .default))
        XCTAssertGreaterThan(model.value.stamp, before)
    }

    func testStyleFollowsValue() {
        let (model, _) = makeModel()
        let k1 = model.style.key
        model.apply(.largePrint)
        XCTAssertNotEqual(model.style.key, k1)
        XCTAssertEqual(model.style.typography.fontSize, 22)
    }

    func testBindingWritesThroughUpdate() {
        let (model, _) = makeModel()
        let b = model.binding(\.lineSpacing)
        b.wrappedValue = 4
        XCTAssertEqual(model.value.lineSpacing, 4)
        XCTAssertEqual(b.wrappedValue, 4)
    }
}

final class RenderStyleTests: XCTestCase {
    func testEqualityIsByLookNotStamp() {
        var a = ReaderTypography.default
        var b = a; b.stamp = 77
        XCTAssertEqual(ReaderRenderStyle(a), ReaderRenderStyle(b))
        a.fontFamily = .serif
        XCTAssertNotEqual(ReaderRenderStyle(a), ReaderRenderStyle(b))
    }

    func testSpecsCoverAllStyles() {
        let style = ReaderRenderStyle(.default)
        for s in ReaderRenderStyle.allStyles {
            XCTAssertEqual(style.spec(for: s), ReaderTypography.default.spec(for: s))
        }
        XCTAssertEqual(style.spec(for: .heading1).pointSize, 21.6)
    }

    func testBlockTextScalesMatchCore() {
        for s in ReaderRenderStyle.allStyles {
            XCTAssertEqual(BlockText.scale(for: s), s.baseScale)
            XCTAssertEqual(BlockText.isHeading(s), s.isHeading)
        }
    }

    func testAttributedCacheIsStableAcrossTypography() {
        let block = Block(text: "Hello world", spans: [StyleSpan(location: 0, length: 5, bold: true, italic: false)],
                          xpointer: "/p", globalOffset: 5)
        let cache = AttributedBlockCache()
        let first = cache.attributed(for: block)
        XCTAssertEqual(first, cache.attributed(for: block))
        XCTAssertEqual(first, BlockText.attributed(text: block.text, spans: block.spans))
    }

    func testLibraryContextCarriesTypography() {
        var t = ReaderTypography.default
        t.fontSize = 20; t.stamp = 42
        let c = ConnectivityReceiver.libraryContext(hashes: ["b", "a"], typography: t)
        XCTAssertEqual(c["type"] as? String, "library")
        XCTAssertEqual(c["hashes"] as? [String], ["a", "b"])
        XCTAssertEqual(TypographySync.decode(from: c), t)
        XCTAssertNil(TypographySync.decode(from: ConnectivityReceiver.libraryContext(hashes: [])))
    }
}

@MainActor
final class WordLookupModelTests: XCTestCase {
    private let text = "It was a bright cold day, and the clocks were striking thirteen."

    func testCursorClampsAndStepsOverWords() {
        let model = WordLookupModel(text: text, language: "en", provider: MockDictionaryProvider.sample)
        XCTAssertEqual(model.currentWord, "It")
        model.step(-1)
        XCTAssertEqual(model.index, 0)
        model.cursor = 3.4
        XCTAssertEqual(model.currentWord, "bright")
        model.cursor = 500
        XCTAssertEqual(model.currentWord, "thirteen")
        model.step(1)
        XCTAssertEqual(model.currentWord, "thirteen")
        XCTAssertEqual(model.context?.word, "thirteen")
    }

    func testNoWords() {
        let model = WordLookupModel(text: "123 ... 😀", language: nil, provider: MockDictionaryProvider.sample)
        XCTAssertFalse(model.hasWords)
        XCTAssertEqual(model.currentWord, "")
        XCTAssertGreaterThan(model.maxCursor, 0)
    }

    func testLookupLoadsEntryAndHandlesErrors() async {
        let ok = WordLookupModel(text: "running fast", language: "en", provider: MockDictionaryProvider.sample)
        await ok.lookup()
        if case .loaded(let e) = ok.state { XCTAssertEqual(e.word, "run") } else { XCTFail("\(ok.state)") }

        let missing = WordLookupModel(text: "fast zzz", language: "en", provider: MockDictionaryProvider.sample)
        await missing.lookup()
        XCTAssertEqual(missing.state, .failed(.notFound))

        let offline = WordLookupModel(text: "run", language: "en", provider: MockDictionaryProvider(error: .offline))
        await offline.lookup()
        XCTAssertEqual(offline.state, .failed(.offline))
    }

    func testStaleResultIsDropped() async {
        let model = WordLookupModel(text: "running walking", language: "en",
                                    provider: MockDictionaryProvider(entries: MockDictionaryProvider.sample.entries,
                                                                     delayNanoseconds: 50_000_000))
        let pending = Task { await model.lookup() }
        try? await Task.sleep(nanoseconds: 10_000_000)   // request is now in flight
        model.step(1)
        await pending.value
        XCTAssertEqual(model.state, .loading, "result for the previous word must not be shown")
    }

    func testHighlightedContextText() {
        let c = WordContext(before: "a ", word: "b", after: " c", hasMoreBefore: true, hasMoreAfter: false)
        let attr = WordPickerView.highlighted(c)
        XCTAssertEqual(String(attr.characters), "\u{2026}a b c")
    }
}
