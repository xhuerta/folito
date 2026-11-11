import XCTest
import SwiftUI
import WatchKit
import ReaderCore
@testable import FolitoWatch

// Logic behind the watch's accessibility / HIG work: messages, formatting, the adjustable word cursor,
// haptics and accessibility-aware rendering. Contrast ratios are tested in ReaderCore
// (ReaderAccessibilityTests) where they also run on Linux.

private final class HapticSpy: HapticPlaying {
    private(set) var events: [HapticEvent] = []
    func play(_ event: HapticEvent) { events.append(event) }
}

final class ReadingProgressFormatTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    func testWholePercentRoundedDown() {
        XCTAssertEqual(ReadingProgressFormat.percent(0, locale: en), "0%")
        XCTAssertEqual(ReadingProgressFormat.percent(0.426, locale: en), "42%")
        XCTAssertEqual(ReadingProgressFormat.percent(0.29, locale: en), "29%", "binary rounding must not drop a percent")
        XCTAssertEqual(ReadingProgressFormat.percent(0.999, locale: en), "99%", "unfinished never shows 100%")
        XCTAssertEqual(ReadingProgressFormat.percent(1, locale: en), "100%")
    }

    func testOutOfRangeValuesAreClamped() {
        XCTAssertEqual(ReadingProgressFormat.percent(-0.5, locale: en), "0%")
        XCTAssertEqual(ReadingProgressFormat.percent(7, locale: en), "100%")
        XCTAssertEqual(ReadingProgressFormat.percent(.nan, locale: en), "0%")
    }

    func testLocaleAwareFormatting() {
        let fr = ReadingProgressFormat.percent(0.42, locale: Locale(identifier: "fr_FR"))
        XCTAssertTrue(fr.hasPrefix("42"))
        XCTAssertNotEqual(fr, "42%", "French puts a (narrow) space before %")
    }

    func testSentences() {
        XCTAssertEqual(ReadingProgressFormat.read(0.5, locale: en), "50% read")
        XCTAssertEqual(ReadingProgressFormat.readOnDevice(0.25, device: "iPad", locale: en), "25% read on iPad")
    }
}

final class WatchMessagesTests: XCTestCase {
    private let allConnections: [SyncCoordinator.ConnectionResult?] = [nil, .ok, .unauthorized, .offline, .notConfigured, .failed, .signInAgain]
    private let allDictionaryErrors: [DictionaryError] = [.noDictionary, .notFound, .unreadable]

    private func assertSpecific(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(message.count, 12, message, file: file, line: line)
        XCTAssertNotEqual(message.trimmingCharacters(in: .punctuationCharacters).lowercased(), "error", file: file, line: line)
        XCTAssertTrue(message.hasSuffix("."), "full sentence: \(message)", file: file, line: line)
    }

    func testConnectionMessagesAreDistinctAndActionable() {
        let messages = allConnections.map(WatchMessages.connection)
        messages.forEach { assertSpecific($0) }
        XCTAssertEqual(Set(messages).count, messages.count)
        XCTAssertTrue(WatchMessages.connection(.unauthorized).contains("iPhone"))
        XCTAssertTrue(WatchMessages.connection(.failed).contains("server address"))
    }

    func testDictionaryMessages() {
        let messages = allDictionaryErrors.map(WatchMessages.dictionary)
        messages.forEach { assertSpecific($0) }
        XCTAssertEqual(Set(messages).count, messages.count)
        XCTAssertTrue(WatchMessages.dictionary(.noDictionary).contains("iPhone"))
    }

    func testDictionaryLabelsAndCredit() {
        let info = DictionaryCatalog.all[0].compactInfo()
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(WatchMessages.dictionaryLabel(info, size: nil, locale: en), "English")
        XCTAssertTrue(WatchMessages.dictionaryLabel(info, size: 41_000_000, locale: en).hasPrefix("English \u{00B7} "))
        let credit = WatchMessages.dictionaryCredit(info)
        assertSpecific(credit)
        XCTAssertTrue(credit.contains("Wiktionary"))
        XCTAssertTrue(credit.contains("CC BY-SA 4.0"))
        XCTAssertTrue(credit.contains("reader.dict"))
    }

    func testBookOpenFailures() {
        let newer = WatchMessages.bookOpenFailure(BookStorageError.unsupportedFormat(99))
        let missing = WatchMessages.bookOpenFailure(CocoaError(.fileReadNoSuchFile))
        let damaged = WatchMessages.bookOpenFailure(BookStorageError.unreadable)
        let decoding = WatchMessages.bookOpenFailure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x")))
        [newer, missing, damaged].forEach { assertSpecific($0) }
        XCTAssertTrue(newer.contains("Update"))
        XCTAssertTrue(missing.contains("missing"))
        XCTAssertTrue(damaged.contains("damaged"))
        XCTAssertEqual(decoding, damaged)
    }

    func testSyncGlyphLabels() {
        XCTAssertNil(WatchMessages.syncStatus(.idle))
        for status in [SyncStatus.syncing, .offline, .error] {
            let label = WatchMessages.syncStatus(status)
            XCTAssertNotNil(label)
            XCTAssertFalse(label?.isEmpty ?? true)
        }
    }
}

@MainActor
final class WordCursorAccessibilityTests: XCTestCase {
    private func makeModel(_ text: String = "one two three", provider: MockDictionaryProvider = MockDictionaryProvider.sample)
        -> (WordLookupModel, HapticSpy) {
        let spy = HapticSpy()
        return (WordLookupModel(text: text, language: "en", provider: provider, haptics: spy), spy)
    }

    func testAdjustableActionMovesBetweenWordsAndClamps() {
        let (model, spy) = makeModel()
        XCTAssertEqual(model.currentWord, "one")
        XCTAssertFalse(model.canStepBack)
        model.adjust(.decrement)
        XCTAssertEqual(model.index, 0)
        XCTAssertEqual(spy.events, [], "no haptic when the cursor cannot move")
        model.adjust(.increment)
        XCTAssertEqual(model.currentWord, "two")
        model.adjust(.increment)
        model.adjust(.increment)
        XCTAssertEqual(model.currentWord, "three")
        XCTAssertFalse(model.canStepForward)
        XCTAssertEqual(spy.events, [.cursorMoved, .cursorMoved])
        model.adjust(.decrement)
        XCTAssertEqual(model.currentWord, "two")
        XCTAssertEqual(spy.events.count, 3)
    }

    func testStepReportsMovement() {
        let (model, _) = makeModel()
        XCTAssertTrue(model.step(1))
        XCTAssertTrue(model.step(5), "clamped to the last word, which is still a move")
        XCTAssertEqual(model.index, 2)
        XCTAssertFalse(model.step(1))
    }

    func testAnnouncesWordAndPosition() {
        let (model, _) = makeModel()
        model.adjust(.increment)
        XCTAssertEqual(model.positionText, "Word 2 of 3")
        XCTAssertEqual(model.accessibilityValue, "two, word 2 of 3")
    }

    func testNoWords() {
        let (model, spy) = makeModel("  ,  ")
        XCTAssertFalse(model.hasWords)
        XCTAssertFalse(model.canStepBack)
        XCTAssertFalse(model.canStepForward)
        model.adjust(.increment)
        XCTAssertEqual(spy.events, [])
    }

    func testLookupHaptics() async {
        let (found, spy) = makeModel("run")
        await found.lookup()
        XCTAssertEqual(spy.events, [.lookupSucceeded])

        let (missing, spy2) = makeModel("zzzz", provider: MockDictionaryProvider(entries: [:], error: .notFound))
        await missing.lookup()
        XCTAssertEqual(missing.state, .failed(.notFound))
        XCTAssertEqual(spy2.events, [.lookupFailed])
    }

    func testHapticTypes() {
        XCTAssertEqual(HapticEvent.cursorMoved.hapticType, .click)
        XCTAssertEqual(HapticEvent.lookupSucceeded.hapticType, .success)
        XCTAssertEqual(HapticEvent.lookupFailed.hapticType, .failure)
    }
}

final class AccessibleRenderStyleTests: XCTestCase {
    func testDefaultAccessibilityMatchesPlainStyle() {
        let plain = ReaderRenderStyle(.default)
        let none = ReaderRenderStyle(.default, accessibility: .none)
        XCTAssertEqual(plain, none)
        XCTAssertEqual(plain.layoutKey, none.layoutKey)
    }

    func testColourOnlyChangesKeepLayout() {
        let base = ReaderRenderStyle(.default)
        let contrast = ReaderRenderStyle(.default, accessibility: ReaderAccessibility(increaseContrast: true))
        let alwaysOn = ReaderRenderStyle(.default, accessibility: ReaderAccessibility(luminanceReduced: true))
        XCTAssertNotEqual(base, contrast)
        XCTAssertNotEqual(base, alwaysOn)
        XCTAssertEqual(base.layoutKey, contrast.layoutKey)
        XCTAssertEqual(base.layoutKey, alwaysOn.layoutKey)
    }

    func testBoldTextAndDynamicTypeChangeLayout() {
        let base = ReaderRenderStyle(.default)
        let bold = ReaderRenderStyle(.default, accessibility: ReaderAccessibility(boldText: true))
        XCTAssertNotEqual(base.layoutKey, bold.layoutKey)
        XCTAssertTrue(bold.spec(for: .paragraph).bold)

        // Text scale only matters with "Match System Text Size".
        let scaled = ReaderAccessibility(textScale: 1.5)
        XCTAssertEqual(ReaderRenderStyle(.default, accessibility: scaled).layoutKey, base.layoutKey)
        var matching = ReaderTypography.default
        matching.matchSystemTextSize = true
        let style = ReaderRenderStyle(matching, accessibility: scaled)
        XCTAssertEqual(style.spec(for: .paragraph).pointSize, 24)
        XCTAssertNotEqual(style.layoutKey, ReaderRenderStyle(matching).layoutKey)
    }

    func testLightPageDetection() {
        var sepia = ReaderTypography.default
        sepia.theme = .sepia
        XCTAssertTrue(ReaderRenderStyle(sepia).isLightPage)
        XCTAssertFalse(ReaderRenderStyle(sepia, accessibility: ReaderAccessibility(luminanceReduced: true)).isLightPage)
        XCTAssertFalse(ReaderRenderStyle(.default).isLightPage)
    }

    func testHeadingLevels() {
        XCTAssertEqual(ReaderRenderStyle.headingLevel(for: .heading1), .h1)
        XCTAssertEqual(ReaderRenderStyle.headingLevel(for: .heading6), .h6)
        XCTAssertNil(ReaderRenderStyle.headingLevel(for: .paragraph))
        XCTAssertNil(ReaderRenderStyle.headingLevel(for: .quote))
    }

    @MainActor
    func testModelCachesAccessibleStyle() {
        let name = "wr-test-\(UUID().uuidString)"
        let model = TypographyModel(store: TypographyStore(defaults: UserDefaults(suiteName: name)!))
        let a = ReaderAccessibility(boldText: true)
        let first = model.style(for: a)
        XCTAssertEqual(model.style(for: a), first)
        XCTAssertEqual(model.style(for: .none), model.style)
        model.update { $0.fontSize = 20 }
        XCTAssertEqual(model.style(for: a).spec(for: .paragraph).pointSize, 20, "cache invalidated by an edit")
    }

    func testLocalizedNamesExistForEveryCase() {
        for t in ReaderTypography.Theme.allCases { XCTAssertFalse(t.localizedName.isEmpty) }
        for f in ReaderTypography.FontFamily.allCases { XCTAssertFalse(f.localizedName.isEmpty) }
        for a in ReaderTypography.Alignment.allCases { XCTAssertFalse(a.localizedName.isEmpty) }
        for p in ReaderTypography.Preset.allCases { XCTAssertFalse(p.localizedName.isEmpty) }
    }
}

final class TimeRemainingFormatTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    func testVisibleLineIsAbbreviated() {
        let value = ReadingTimeRemaining(documentHash: "h", bookTitle: "T", chapterSeconds: 12 * 60,
                                         bookSeconds: 3 * 3600 + 20 * 60, fractionRead: 0.4, updatedAt: Date())
        let line = TimeRemainingFormat.line(value, locale: en)
        XCTAssertTrue(line.hasPrefix("12 min left in chapter · 3 hr"), line)
        XCTAssertTrue(line.hasSuffix("20 min in book"), line)
    }

    func testVoiceOverGetsFullSentences() {
        let value = ReadingTimeRemaining(documentHash: "h", bookTitle: "T", chapterSeconds: 12 * 60,
                                         bookSeconds: 3600, fractionRead: 0.4, updatedAt: Date())
        let spoken = TimeRemainingFormat.spoken(value, locale: en)
        XCTAssertEqual(spoken, "12 minutes left in chapter. 1 hour left in book.")
    }

    func testNeverShowsZeroMinutes() {
        XCTAssertEqual(TimeRemainingFormat.chapter(5, style: .full, locale: en), "1 minute left in chapter")
        XCTAssertEqual(TimeRemainingFormat.chapter(0, style: .full, locale: en), "1 minute left in chapter")
    }

    func testShowTimeRemainingIsResetWithPreferences() {
        let defaults = UserDefaults(suiteName: "TimeRemainingFormatTests")!
        defaults.set(false, forKey: ReaderSettings.showTimeRemainingKey)
        ReaderSettings.resetPreferences(defaults)
        XCTAssertNil(defaults.object(forKey: ReaderSettings.showTimeRemainingKey))
    }

    @MainActor
    func testReaderEstimatesAndSavesTimeRemaining() async throws {
        let name = "TimeRemainingReaderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let positions = PositionStore(defaults: defaults)
        let words = Array(repeating: "word", count: 200).joined(separator: " ")
        let book = ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: "h", metaHash: "",
                                 chapters: [Chapter(spineIndex: 1, title: nil,
                                                    blocks: [Block(text: words, xpointer: "/a", globalOffset: 0),
                                                             Block(text: words, xpointer: "/b", globalOffset: 999)])],
                                 totalCharacters: 1_998)
        let model = ReaderViewModel(book: book, positions: positions, sync: SyncCoordinator(defaults: defaults, credentials: { nil }))
        for _ in 0..<100 where model.timeRemaining == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let value = try XCTUnwrap(model.timeRemaining)
        XCTAssertEqual(value.bookSeconds, 120, accuracy: 0.001) // 400 words at the default 200 wpm
        XCTAssertEqual(value.chapterSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(positions.readingTimes.load(documentHash: "h")?.bookSeconds ?? 0, 120, accuracy: 0.001)
        positions.remove("h")
        XCTAssertNil(positions.readingTimes.latest())
    }

    /// The reader menu's progress line: the same wording and number as the book's Library row.
    @MainActor
    func testReaderMenuShowsPercentRead() throws {
        let name = "ReaderMenuProgressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let positions = PositionStore(defaults: defaults)
        let book = ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: "p", metaHash: "",
                                 chapters: [Chapter(spineIndex: 1, title: nil,
                                                    blocks: [Block(text: "a", xpointer: "/a", globalOffset: 0),
                                                             Block(text: "b", xpointer: "/b", globalOffset: 500),
                                                             Block(text: "c", xpointer: "/c", globalOffset: 990)])],
                                 totalCharacters: 1_000)
        let model = ReaderViewModel(book: book, positions: positions, sync: SyncCoordinator(defaults: defaults, credentials: { nil }))
        XCTAssertEqual(model.progressText(locale: en), "0% read")
        model.jump(to: 1)
        XCTAssertEqual(model.progressText(locale: en), "50% read")
        XCTAssertEqual(model.progressText(locale: en), ReadingProgressFormat.read(model.localPercentage, locale: en))
        model.jump(to: 2)
        XCTAssertEqual(model.progressText(locale: en), "99% read", "an unfinished book never shows 100%")
        positions.remove("p")
    }
}
