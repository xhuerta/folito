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
    // MARK: Ticks (#67 feedback: the crown changed the level but the text did not visibly speed up)

    /// A reader whose restore has settled, with the two 1000 pt blocks of `book()` laid out from the reading line.
    private func settledReader(_ d: UserDefaults) async throws -> ReaderViewModel {
        let model = reader(d)
        model.openSettleDelay = 10_000_000
        model.settleDelay = 10_000_000
        model.viewportTop = 0
        model.viewportHeight = 200
        model.restoreInitialPosition()
        model.blockFramesChanged([0: BlockFrame(minY: 0, maxY: 1000), 1: BlockFrame(minY: 1010, maxY: 2010)])
        for _ in 0..<200 where model.isRestoring {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isRestoring)
        return model
    }

    private let line = AutoScroll.lineHeight(pointSize: 16, lineSpacing: 0)

    func testTicksMoveByTheCurrentLevelAndASpeedChangeAppliesAtOnce() async throws {
        let d = defaults()
        let model = try await settledReader(d)
        XCTAssertEqual(model.autoScrollTick(elapsed: 0.1, lineHeight: line), .idle, "not running: nothing moves")

        model.startAutoScroll(reduceMotion: false)
        XCTAssertEqual(model.autoScrollLevel, AutoScroll.defaultLevel)
        // The first tick measures where the text is.
        XCTAssertEqual(model.autoScrollTick(elapsed: 0.1, lineHeight: line), .idle)
        XCTAssertEqual(model.autoScrollCursor, AutoScroll.Cursor(index: 0, offset: 0))

        guard case .scroll(let first) = model.autoScrollTick(elapsed: 0.1, lineHeight: line) else {
            return XCTFail("a running tick scrolls")
        }
        XCTAssertEqual(first.index, 0)
        let slow = try XCTUnwrap(model.autoScrollCursor).offset
        XCTAssertEqual(slow, AutoScroll.step(level: AutoScroll.defaultLevel, lineHeight: line, elapsed: 0.1), accuracy: 1e-9)

        // The crown turns it up one detent while it runs: the very next tick uses the new level.
        model.setAutoScrollLevel(AutoScroll.defaultLevel + 1)
        guard case .scroll = model.autoScrollTick(elapsed: 0.1, lineHeight: line) else {
            return XCTFail("still scrolling after a speed change")
        }
        let faster = try XCTUnwrap(model.autoScrollCursor).offset - slow
        XCTAssertEqual(faster, AutoScroll.step(level: AutoScroll.defaultLevel + 1, lineHeight: line, elapsed: 0.1),
                       accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(faster / slow, AutoScroll.minLevelRatio - 1e-9, "one detent is a visible change")

        // All the way up: several times the default pace.
        model.setAutoScrollLevel(AutoScroll.levels.upperBound)
        let before = try XCTUnwrap(model.autoScrollCursor).offset
        _ = model.autoScrollTick(elapsed: 0.1, lineHeight: line)
        let fastest = try XCTUnwrap(model.autoScrollCursor).offset - before
        XCTAssertGreaterThan(fastest / slow, 3)
        XCTAssertEqual(d.integer(forKey: ReaderSettings.autoScrollSpeedKey), AutoScroll.levels.upperBound)
    }

    /// The screen going dark (wrist down, Always On) pauses auto-scroll; nothing moves while paused, and resuming
    /// measures the text again where it is instead of jumping to where the old cursor was.
    func testPauseStopsTheTicksAndResumeContinuesFromTheText() async throws {
        let model = try await settledReader(defaults())
        model.startAutoScroll(reduceMotion: false)
        _ = model.autoScrollTick(elapsed: 0.1, lineHeight: line)
        _ = model.autoScrollTick(elapsed: 0.1, lineHeight: line)
        XCTAssertNotNil(model.autoScrollCursor)

        model.pauseAutoScroll()
        XCTAssertEqual(model.autoScroll, .paused)
        XCTAssertNil(model.autoScrollCursor)
        XCTAssertEqual(model.autoScrollTick(elapsed: 0.1, lineHeight: line), .idle, "paused: the text stays put")

        // Meanwhile the text sits 40 pt into block 0 (the last scroll before the pause landed there).
        model.blockFramesChanged([0: BlockFrame(minY: -40, maxY: 960), 1: BlockFrame(minY: 970, maxY: 1970)])
        model.resumeAutoScroll()
        XCTAssertEqual(model.autoScrollTick(elapsed: 5, lineHeight: line), .idle, "the first tick only measures")
        XCTAssertEqual(model.autoScrollCursor, AutoScroll.Cursor(index: 0, offset: 40))
        _ = model.autoScrollTick(elapsed: 0.1, lineHeight: line)
        XCTAssertEqual(try XCTUnwrap(model.autoScrollCursor).offset,
                       40 + AutoScroll.step(level: model.autoScrollLevel, lineHeight: line, elapsed: 0.1), accuracy: 1e-9)
    }

    func testCrownHintOnlyTheFirstTime() {
        let d = defaults()
        let model = reader(d)
        XCTAssertFalse(model.autoScrollShowsCrownHint)
        model.startAutoScroll(reduceMotion: false)
        XCTAssertTrue(model.autoScrollShowsCrownHint, "first start: say how to change the speed")
        model.dismissAutoScrollCrownHint()
        XCTAssertFalse(model.autoScrollShowsCrownHint)
        model.stopAutoScroll()
        model.startAutoScroll(reduceMotion: false)
        XCTAssertFalse(model.autoScrollShowsCrownHint, "once")
        // In another book too.
        let other = reader(d, hash: "other")
        other.startAutoScroll(reduceMotion: false)
        XCTAssertFalse(other.autoScrollShowsCrownHint)

        // Turning the crown while the hint is up: it has done its job.
        let fresh = reader(defaults())
        fresh.startAutoScroll(reduceMotion: false)
        XCTAssertTrue(fresh.autoScrollShowsCrownHint)
        fresh.setAutoScrollLevel(AutoScroll.defaultLevel + 1)
        XCTAssertFalse(fresh.autoScrollShowsCrownHint)

        // Reset Preferences shows it again.
        ReaderSettings.resetPreferences(d)
        let reset = reader(d)
        reset.startAutoScroll(reduceMotion: false)
        XCTAssertTrue(reset.autoScrollShowsCrownHint)
    }
}
