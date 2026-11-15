import XCTest
import ReaderCore
@testable import FolitoWatch

private final class AutoScrollHapticSpy: HapticPlaying {
    private(set) var events: [HapticEvent] = []
    func play(_ event: HapticEvent) { events.append(event) }
}

/// Auto-scroll state in the reader (#67): started only on request, paused and resumed, stopped on leaving, and
/// its speed remembered per user (one setting for every book). The speed math is in ReaderCore (`AutoScrollTests`).
@MainActor
final class AutoScrollReaderTests: XCTestCase {
    private func book(_ hash: String = "autoscroll") -> ProcessedBook {
        let long = String(repeating: "word ", count: 40)
        let chapters = [Chapter(spineIndex: 1, title: "One",
                                blocks: [Block(text: long, xpointer: "/body/DocFragment[1]/body/p", globalOffset: 0),
                                         Block(text: long, xpointer: "/body/DocFragment[1]/body/p[2]", globalOffset: 200)])]
        return ProcessedBook(metadata: BookMetadata(title: "Book", authors: []), documentHash: hash,
                             metaHash: "", chapters: chapters, totalCharacters: 400)
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "AutoScrollReaderTests.\(UUID().uuidString)")!
    }

    private func reader(_ defaults: UserDefaults, hash: String = "autoscroll") -> ReaderViewModel {
        ReaderViewModel(book: book(hash), positions: PositionStore(defaults: defaults),
                        sync: SyncCoordinator(defaults: defaults, credentials: { nil }), settings: defaults)
    }

    func testOffUntilStartedThenPausesResumesAndStops() {
        let model = reader(defaults())
        let spy = AutoScrollHapticSpy()
        model.haptics = spy
        XCTAssertEqual(model.autoScroll, .off, "never on by itself")
        model.resumeAutoScroll()
        XCTAssertEqual(model.autoScroll, .off, "resuming does not start it")
        model.pauseAutoScroll()
        XCTAssertEqual(model.autoScroll, .off)

        model.startAutoScroll(reduceMotion: false)
        XCTAssertEqual(model.autoScroll, .running)
        XCTAssertTrue(model.isAutoScrollActive)
        model.pauseAutoScroll()
        XCTAssertEqual(model.autoScroll, .paused)
        XCTAssertTrue(model.isAutoScrollActive)
        model.resumeAutoScroll()
        XCTAssertEqual(model.autoScroll, .running)
        model.stopAutoScroll()
        XCTAssertEqual(model.autoScroll, .off)
        XCTAssertEqual(spy.events, [.autoScrollStarted, .autoScrollStopped, .autoScrollStarted, .autoScrollStopped])
    }

    func testLeavingTheBookStopsIt() {
        let model = reader(defaults())
        model.startAutoScroll(reduceMotion: false)
        model.leave()
        XCTAssertEqual(model.autoScroll, .off)
    }

    func testSpeedIsRememberedPerUserNotPerBook() {
        let d = defaults()
        let model = reader(d)
        XCTAssertEqual(model.autoScrollLevel, AutoScroll.defaultLevel)
        model.setAutoScrollLevel(6)
        XCTAssertEqual(model.autoScrollLevel, 6)
        model.setAutoScrollLevel(99)
        XCTAssertEqual(model.autoScrollLevel, AutoScroll.levels.upperBound, "clamped")
        XCTAssertEqual(d.integer(forKey: ReaderSettings.autoScrollSpeedKey), AutoScroll.levels.upperBound)
        // Another book starts at the same speed.
        let other = reader(d, hash: "other")
        XCTAssertEqual(other.autoScrollLevel, AutoScroll.levels.upperBound)
        other.startAutoScroll(reduceMotion: false)
        XCTAssertEqual(other.autoScrollLevel, AutoScroll.levels.upperBound)
        // Reset Preferences forgets it.
        ReaderSettings.resetPreferences(d)
        XCTAssertEqual(reader(d).autoScrollLevel, AutoScroll.defaultLevel)
    }

    func testReduceMotionStartsAtAGentleSpeed() {
        let d = defaults()
        let model = reader(d)
        model.setAutoScrollLevel(7)
        model.startAutoScroll(reduceMotion: true)
        XCTAssertEqual(model.autoScrollLevel, AutoScroll.reduceMotionMaxLevel)
        XCTAssertEqual(d.integer(forKey: ReaderSettings.autoScrollSpeedKey), 7, "the saved speed is kept")
    }

    /// A book of `count` blocks of 60 words each: every block is one timed page for the speed learner.
    private func pagedBook(_ count: Int) -> ProcessedBook {
        let text = String(repeating: "word ", count: 60)
        let blocks = (0..<count).map { Block(text: text, xpointer: "/body/DocFragment[1]/body/p[\($0 + 1)]",
                                             globalOffset: $0 * text.count) }
        return ProcessedBook(metadata: BookMetadata(title: "Pages", authors: []), documentHash: "pages",
                             metaHash: "", chapters: [Chapter(spineIndex: 1, title: "One", blocks: blocks)],
                             totalCharacters: count * text.count)
    }

    /// Block `index` at the reading line (top edge), the next one below it.
    private func frames(top index: Int) -> [Int: BlockFrame] {
        [index: BlockFrame(minY: 0, maxY: 100), index + 1: BlockFrame(minY: 110, maxY: 210)]
    }

    /// Auto-scroll sets the pace itself, so the pages it scrolls (running or paused) never teach the reading
    /// speed used for the time left; after it stops, reading by hand is timed from the moment it stopped.
    func testAutoScrollDoesNotTeachTheReadingSpeed() async throws {
        let d = defaults()
        let speeds = ReadingSpeedStore(defaults: d)
        var clock = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let model = ReaderViewModel(book: pagedBook(8), positions: PositionStore(defaults: d),
                                    sync: SyncCoordinator(defaults: d, credentials: { nil }), speeds: speeds,
                                    now: { clock }, settings: d)
        model.openSettleDelay = 10_000_000
        model.settleDelay = 10_000_000
        model.viewportHeight = 200
        model.restoreInitialPosition()
        model.blockFramesChanged(frames(top: 0))
        for _ in 0..<200 where model.lengths == nil || model.isRestoring {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(model.lengths, "the words are counted")
        XCTAssertFalse(model.isRestoring)

        // Running: a 60-word page in 20 s (180 wpm, a plausible sample) is not learned.
        model.startAutoScroll(reduceMotion: false)
        clock += 20
        model.blockFramesChanged(frames(top: 1))
        XCTAssertEqual(model.currentIndex, 1)
        // Paused but still on: not learned either.
        model.pauseAutoScroll()
        clock += 20
        model.blockFramesChanged(frames(top: 2))
        model.resumeAutoScroll()
        clock += 20
        model.blockFramesChanged(frames(top: 3))
        XCTAssertEqual(model.currentIndex, 3)
        XCTAssertNil(d.data(forKey: ReadingSpeedStore.key), "nothing learned while auto-scroll was on")

        // A long session, then stop: the next hand-read page is timed from the stop, not across the session.
        clock += 600
        model.stopAutoScroll()
        clock += 15
        model.blockFramesChanged(frames(top: 4))
        XCTAssertNotNil(d.data(forKey: ReadingSpeedStore.key), "reading by hand right after stopping is learned")
        // 60 words in 15 s = 240 wpm, smoothed from the default 200.
        XCTAssertGreaterThan(speeds.load().wordsPerMinute, ReadingSpeed.defaultWordsPerMinute)
        XCTAssertLessThan(speeds.load().wordsPerMinute, 240)
    }
}
