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

        // Running: a 60-word page in 20 s (180 wpm, a plausible sample) is not learned. Auto-scroll reports the
        // position itself; the scroll view underneath stands still and its frames are ignored meanwhile.
        model.startAutoScroll(reduceMotion: false)
        clock += 20
        model.autoScrollPositionChanged(.init(index: 1, offset: 0), blockHeight: 100, force: true)
        XCTAssertEqual(model.currentIndex, 1)
        model.blockFramesChanged(frames(top: 6))
        XCTAssertEqual(model.currentIndex, 1, "the hidden scroll view does not move the position")
        // Paused but still on: not learned either.
        model.pauseAutoScroll()
        clock += 20
        model.blockFramesChanged(frames(top: 2))
        XCTAssertEqual(model.currentIndex, 2, "paused: the crown scrolls by hand and the position follows")
        model.resumeAutoScroll()
        clock += 20
        model.autoScrollPositionChanged(.init(index: 3, offset: 0), blockHeight: 100, force: true)
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
    // MARK: Motion, position and hand-back (#67, build 45 feedback)

    private final class Clock {
        var date = Date(timeIntervalSinceReferenceDate: 2_000_000)
    }

    /// A reader on `clock` whose opening restore has settled, the two 1000 pt blocks of `book()` laid out from
    /// the reading line (viewport 0...200).
    private func settledReader(_ d: UserDefaults, clock: Clock) async throws -> ReaderViewModel {
        let model = ReaderViewModel(book: book(), positions: PositionStore(defaults: d),
                                    sync: SyncCoordinator(defaults: d, credentials: { nil }),
                                    now: { clock.date }, settings: d)
        model.openSettleDelay = 10_000_000
        model.settleDelay = 10_000_000
        model.viewportTop = 0
        model.viewportHeight = 200
        model.restoreInitialPosition()
        model.blockFramesChanged([0: BlockFrame(minY: 0, maxY: 1000), 1: BlockFrame(minY: 1010, maxY: 2010)])
        try await settle(model)
        return model
    }

    private func settle(_ model: ReaderViewModel) async throws {
        for _ in 0..<300 where model.isRestoring {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isRestoring)
    }

    /// The crown changes the speed of the running text at any moment: the distance goes on from where it was
    /// (no jump) at the new slope, and pausing freezes it.
    func testSpeedChangeWhileRunningContinuesSmoothly() async throws {
        let clock = Clock()
        let model = try await settledReader(defaults(), clock: clock)
        XCTAssertEqual(model.autoScrollLines(at: clock.date), 0, "off: nothing moves")

        model.startAutoScroll(reduceMotion: false)
        let start = clock.date
        clock.date += 10
        let slow = AutoScroll.linesPerSecond(level: AutoScroll.defaultLevel)
        XCTAssertEqual(model.autoScrollLines(at: clock.date), 10 * slow, accuracy: 1e-9)

        // One detent up after 10 s, then 10 s more: continuous at the change, faster after it.
        model.setAutoScrollLevel(AutoScroll.defaultLevel + 1)
        XCTAssertEqual(model.autoScrollLines(at: clock.date), 10 * slow, accuracy: 1e-9, "no jump")
        let fast = AutoScroll.linesPerSecond(level: AutoScroll.defaultLevel + 1)
        XCTAssertEqual(model.autoScrollLines(at: clock.date + 10), 10 * slow + 10 * fast, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(fast / slow, AutoScroll.minLevelRatio)

        // Turned up again later (any time, not only at the start).
        clock.date += 10
        model.setAutoScrollLevel(AutoScroll.levels.upperBound)
        let top = AutoScroll.linesPerSecond(level: AutoScroll.levels.upperBound)
        XCTAssertEqual(model.autoScrollLines(at: clock.date + 5), 10 * slow + 10 * fast + 5 * top, accuracy: 1e-9)

        // Paused: frozen; resumed: on from there.
        clock.date += 5
        model.pauseAutoScroll()
        let frozen = model.autoScrollLines(at: clock.date)
        XCTAssertEqual(model.autoScrollLines(at: clock.date + 60), frozen, accuracy: 1e-9)
        clock.date += 60
        model.resumeAutoScroll()
        XCTAssertEqual(model.autoScrollLines(at: clock.date + 2), frozen + 2 * top, accuracy: 1e-9)
        // A speed change while paused does not move it.
        model.pauseAutoScroll()
        model.setAutoScrollLevel(1)
        XCTAssertEqual(model.autoScrollLines(at: clock.date + 100), model.autoScrollLines(at: clock.date), accuracy: 1e-9)
        XCTAssertGreaterThan(clock.date, start)
    }

    /// While the text moves, the position is saved every `AutoScroll.commitInterval` seconds, not per frame,
    /// and at once when forced (pause, stop, leaving).
    func testPositionIsCommittedAtALowRate() async throws {
        let clock = Clock()
        let d = defaults()
        let model = try await settledReader(d, clock: clock)
        model.startAutoScroll(reduceMotion: false)

        XCTAssertTrue(model.autoScrollPositionChanged(.init(index: 0, offset: 100), blockHeight: 1000))
        let first = model.currentOffset
        XCTAssertGreaterThan(first, 0, "10% into the block")
        clock.date += 1
        XCTAssertFalse(model.autoScrollPositionChanged(.init(index: 0, offset: 300), blockHeight: 1000),
                       "1 s later: not yet")
        XCTAssertEqual(model.currentOffset, first)
        clock.date += AutoScroll.commitInterval
        XCTAssertTrue(model.autoScrollPositionChanged(.init(index: 1, offset: 0), blockHeight: 1000))
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.currentOffset, 0)
        clock.date += 0.1
        XCTAssertTrue(model.autoScrollPositionChanged(.init(index: 1, offset: 500), blockHeight: 1000, force: true),
                      "forced: at once")
        XCTAssertGreaterThan(model.currentOffset, 0)
        // Saved for the next opening.
        XCTAssertEqual(PositionStore(defaults: d).load("autoscroll")?.position.blockIndex,
                       model.flat.position(at: 1)?.blockIndex)
    }

    /// On pause the scroll view is brought to the exact point auto-scroll showed: the jump is anchored with
    /// the scrollTo math, re-issued until it lands within half a point, and only then is the restore over.
    func testHandBackLandsOnTheExactPoint() async throws {
        let clock = Clock()
        let model = try await settledReader(defaults(), clock: clock)
        model.startAutoScroll(reduceMotion: false)
        clock.date += 30
        model.pauseAutoScroll()

        // Auto-scroll showed block 1 with 137.25 pt of it above the reading line.
        let shown: [Int: AutoScroll.Span] = [0: .init(minY: -1147.25, maxY: -147.25), 1: .init(minY: -137.25, maxY: 862.75)]
        model.handBackAutoScroll(at: .init(index: 1, offset: 137.25), frames: shown)
        XCTAssertTrue(model.isRestoring)
        let jump = try XCTUnwrap(model.jumpRequest)
        XCTAssertEqual(jump.index, 1)
        let expected = try XCTUnwrap(AutoScroll.scrollTarget(.init(index: 1, offset: 137.25), frames: shown,
                                                             viewportTop: 0, viewportHeight: 200))
        XCTAssertEqual(try XCTUnwrap(jump.anchorY), expected.anchorY, accuracy: 1e-9)
        XCTAssertEqual(model.currentIndex, 1, "the position is saved at once")

        // The scroll view lands 3 pt off: the jump is corrected (a word-start restore would accept 8 pt).
        model.blockFramesChanged([1: BlockFrame(minY: -134.25, maxY: 865.75), 2: BlockFrame(minY: 870, maxY: 900)])
        for _ in 0..<300 where model.jumpRequest?.token == jump.token {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let correction = try XCTUnwrap(model.jumpRequest)
        XCTAssertNotEqual(correction.token, jump.token, "re-issued")
        XCTAssertTrue(model.isRestoring, "not over while off")
        // Lands exactly: done.
        model.blockFramesChanged([1: BlockFrame(minY: -137.25, maxY: 862.75)])
        try await settle(model)
        XCTAssertEqual(model.currentIndex, 1)
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
