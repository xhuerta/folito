import XCTest
import ReaderCore
@testable import FolitoWatch

/// The reader's top bar (#106): auto-hide rules, the reading line it must not move, and the sync note.
final class ReaderChromeTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Scrolls in small steps (like the crown) from `from` to `to`, starting at `start` seconds, 10 ms apart.
    private func scroll(_ bar: inout BarAutoHide, from: CGFloat, to: CGFloat, start: TimeInterval,
                        voiceOver: Bool = false) -> TimeInterval {
        var time = start
        let step: CGFloat = from < to ? 5 : -5
        for offset in stride(from: from, through: to, by: step) {
            bar.scrolled(to: offset, at: at(time), voiceOver: voiceOver)
            time += 0.01
        }
        return time
    }

    func testHidesWhenScrollingDownAndShowsWhenScrollingUpALittle() {
        var bar = BarAutoHide()
        var time = scroll(&bar, from: 0, to: 300, start: 0)
        XCTAssertTrue(bar.isHidden)
        time += 1 // past the settle window
        // A small move back up (less than showDistance) keeps it hidden...
        time = scroll(&bar, from: 300, to: 280, start: time)
        XCTAssertTrue(bar.isHidden)
        // ...a little more brings it back.
        time = scroll(&bar, from: 280, to: 250, start: time)
        XCTAssertFalse(bar.isHidden)
        time += 1
        time = scroll(&bar, from: 250, to: 290, start: time)
        XCTAssertTrue(bar.isHidden)
    }

    func testStaysVisibleAtTheStartOfTheBook() {
        var bar = BarAutoHide()
        _ = scroll(&bar, from: 0, to: 55, start: 0) // past hideDistance, but still at the start
        XCTAssertFalse(bar.isHidden)
        let time = scroll(&bar, from: 60, to: 300, start: 1)
        XCTAssertTrue(bar.isHidden)
        bar.scrolled(to: 0, at: at(time + 1), voiceOver: false) // back at the start (e.g. a chapter jump)
        XCTAssertFalse(bar.isHidden)
    }

    func testNeverHidesWithVoiceOver() {
        var bar = BarAutoHide()
        _ = scroll(&bar, from: 0, to: 1_000, start: 0, voiceOver: true)
        XCTAssertFalse(bar.isHidden)
        XCTAssertFalse(bar.tapped(at: at(20), voiceOver: true))
    }

    func testProgrammaticJumpDoesNotHide() {
        var bar = BarAutoHide()
        bar.scrolled(to: 0, at: at(0), voiceOver: false)
        bar.scrolled(to: 25_000, at: at(0.5), voiceOver: false) // restore to a saved position
        XCTAssertFalse(bar.isHidden)
        _ = scroll(&bar, from: 25_000, to: 25_100, start: 1)
        XCTAssertTrue(bar.isHidden)
    }

    func testInsetChangeWhileSettlingCannotFlipTheBarBack() {
        var bar = BarAutoHide()
        let time = scroll(&bar, from: 0, to: 70, start: 0) // hides at 60
        XCTAssertTrue(bar.isHidden)
        // The safe area shrinks as the bar hides: the measured offset jumps by the bar's height.
        bar.scrolled(to: 70 - 45, at: at(time + 0.1), voiceOver: false)
        bar.scrolled(to: 70 + 5, at: at(time + 0.2), voiceOver: false)
        XCTAssertTrue(bar.isHidden)
        // Once settled, only a real scroll back up shows it.
        bar.scrolled(to: 70 + 5, at: at(time + 1), voiceOver: false)
        XCTAssertTrue(bar.isHidden)
    }

    func testTapShowsTheBarThenItHidesAgain() {
        var bar = BarAutoHide()
        let time = scroll(&bar, from: 0, to: 300, start: 0) + 1
        XCTAssertTrue(bar.isHidden)
        XCTAssertTrue(bar.tapped(at: at(time), voiceOver: false))
        XCTAssertFalse(bar.isHidden)
        // With the bar visible a tap is the word lookup again.
        XCTAssertFalse(bar.tapped(at: at(time + 1), voiceOver: false))
        bar.tick(at: at(time + 1), voiceOver: false)
        XCTAssertFalse(bar.isHidden)
        bar.tick(at: at(time + BarAutoHide.tapRevealDuration), voiceOver: false)
        XCTAssertTrue(bar.isHidden)
    }

    func testTapRevealDoesNotHideWithVoiceOverOn() {
        var bar = BarAutoHide()
        let time = scroll(&bar, from: 0, to: 300, start: 0) + 1
        XCTAssertTrue(bar.tapped(at: at(time), voiceOver: false))
        bar.tick(at: at(time + 5), voiceOver: true)
        XCTAssertFalse(bar.isHidden)
    }

    /// Hiding the bar shrinks the measured top inset to 0; the reading line (and with it the saved position
    /// and the restore anchors of #116) must stay at the bottom edge of the bar.
    func testReadingLineIgnoresTheHiddenBar() {
        var line: CGFloat = 0
        line = ReadingLine.updated(current: line, measured: 44, barShown: true)
        XCTAssertEqual(line, 44)
        for inset in stride(from: CGFloat(44), through: 0, by: -11) { // hide animation
            line = ReadingLine.updated(current: line, measured: inset, barShown: false)
        }
        XCTAssertEqual(line, 44)
        for inset in stride(from: CGFloat(0), through: 44, by: 11) { // show animation
            line = ReadingLine.updated(current: line, measured: inset, barShown: true)
        }
        XCTAssertEqual(line, 44)

        // Same frames, same line: the position does not move when the bar hides or shows.
        let frames: [Int: BlockFrame] = [3: BlockFrame(minY: 10, maxY: 80), 4: BlockFrame(minY: 90, maxY: 200)]
        XCTAssertEqual(VisibleBlockResolver.topIndex(frames: frames, viewportTop: line), 3)
        XCTAssertEqual(InBlockPosition.fractionScrolledPast(minY: 10, maxY: 80, viewportTop: Double(line)),
                       InBlockPosition.fractionScrolledPast(minY: 10, maxY: 80, viewportTop: 44))
    }

    func testSyncFailureClassification() {
        XCTAssertNil(SyncErrorClassifier.failure(for: KOSyncError.offline))
        XCTAssertNil(SyncErrorClassifier.failure(for: URLError(.notConnectedToInternet)))
        XCTAssertEqual(SyncErrorClassifier.failure(for: KOSyncError.unauthorized), .unauthorized)
        XCTAssertEqual(SyncErrorClassifier.failure(for: URLError(.badServerResponse)), .server)
    }

    func testSyncExplanation() {
        XCTAssertNil(WatchMessages.syncExplanation(.idle, failure: nil))
        XCTAssertNil(WatchMessages.syncExplanation(.syncing, failure: nil))
        XCTAssertEqual(WatchMessages.syncExplanation(.offline, failure: nil), WatchMessages.syncStatus(.offline))
        let unauthorized = WatchMessages.syncExplanation(.error, failure: .unauthorized)
        let server = WatchMessages.syncExplanation(.error, failure: .server)
        XCTAssertNotNil(unauthorized)
        XCTAssertNotNil(server)
        XCTAssertNotEqual(unauthorized, server)
        XCTAssertEqual(WatchMessages.syncExplanation(.error, failure: nil), server)
    }
}
