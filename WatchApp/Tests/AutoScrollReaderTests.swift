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
}
