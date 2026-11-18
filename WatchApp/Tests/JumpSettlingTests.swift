import XCTest
import SwiftUI
import ReaderCore
@testable import FolitoWatch

/// Far jumps settle under a cover (#174, `JumpSettling`): the text is hidden from the jump until the target is at
/// the top edge, the corrections in between are never seen, the saved position is the target from the start,
/// and VoiceOver gets one arrival announcement.
final class JumpSettlingTests: XCTestCase {
    /// Three chapters ("One", "Two", "Three") of `blocksPerChapter` blocks each.
    private static let blocksPerChapter = 20

    private func book() -> ProcessedBook {
        var offset = 0
        var chapters: [Chapter] = []
        for (c, title) in ["One", "Two", "Three"].enumerated() {
            var blocks: [Block] = []
            for b in 0..<Self.blocksPerChapter {
                let text = "Block \(b) of chapter \(title) with a few words."
                blocks.append(Block(text: text, xpointer: "/body/DocFragment[\(c + 1)]/body/p[\(b + 1)]",
                                    globalOffset: offset))
                offset += text.count
            }
            chapters.append(Chapter(spineIndex: c + 1, title: title, blocks: blocks))
        }
        return ProcessedBook(metadata: BookMetadata(title: "Jumps", authors: ["A"]), documentHash: "jumps",
                             metaHash: "jumpsm", chapters: chapters, totalCharacters: offset)
    }

    private func f(_ minY: CGFloat, _ maxY: CGFloat) -> BlockFrame { BlockFrame(minY: minY, maxY: maxY) }

    private struct Fixture {
        let model: ReaderViewModel
        let positions: PositionStore
        let sync: SyncCoordinator
        let defaults: UserDefaults
    }

    /// A reader opened at the start of the book, positioned and showing its text, with fast checks.
    @MainActor
    private func openedReader() async throws -> Fixture {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "JumpSettlingTests.\(UUID().uuidString)"))
        let positions = PositionStore(defaults: defaults)
        let sync = SyncCoordinator(defaults: defaults, credentials: { nil })
        let model = ReaderViewModel(book: book(), positions: positions, sync: sync, settings: defaults)
        model.settleDelay = 20_000_000
        model.openSettleDelay = 20_000_000
        model.settlingIndicatorDelay = 5_000_000_000
        model.viewportHeight = 200
        XCTAssertTrue(model.coversText, "the text is hidden while the book opens")
        model.restoreInitialPosition()
        model.blockFramesChanged([0: f(0, 100), 1: f(110, 210)])
        try await waitUntil { model.isPositioned }
        XCTAssertFalse(model.coversText)
        XCTAssertNil(model.arrival, "opening a book announces nothing")
        return Fixture(model: model, positions: positions, sync: sync, defaults: defaults)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out")
    }

    func testCoverOnlyForFarJumpsOfAPositionedReader() {
        XCTAssertTrue(JumpSettling.covers(isPositioned: true, targetLaidOut: false))
        XCTAssertFalse(JumpSettling.covers(isPositioned: true, targetLaidOut: true), "a laid-out target lands in one scroll")
        XCTAssertFalse(JumpSettling.covers(isPositioned: false, targetLaidOut: false), "the opening hides the text already")
    }

    func testChecksRunAtTheShortPaceUnderACover() {
        XCTAssertEqual(JumpSettling.checkDelay(isPositioned: false, isSettling: false, settleDelay: 700, openSettleDelay: 200), 200)
        XCTAssertEqual(JumpSettling.checkDelay(isPositioned: true, isSettling: true, settleDelay: 700, openSettleDelay: 200), 200)
        XCTAssertEqual(JumpSettling.checkDelay(isPositioned: true, isSettling: true, settleDelay: 10, openSettleDelay: 200), 10)
        XCTAssertEqual(JumpSettling.checkDelay(isPositioned: true, isSettling: false, settleDelay: 700, openSettleDelay: 200), 700)
    }

    /// A far jump covers the text, keeps it covered through a landing that is off (the jump is re-issued, the
    /// wrong block never becomes the position), and reveals it once the target is at the top, announcing the
    /// chapter once.
    @MainActor
    func testFarJumpIsCoveredUntilTheTargetIsAtTheTop() async throws {
        let fixture = try await openedReader()
        let model = fixture.model
        // Slow enough checks that the test reports each landing before the next check (and before the
        // retries run out).
        model.settleDelay = 150_000_000
        model.openSettleDelay = 150_000_000
        let target = 2 * Self.blocksPerChapter // chapter "Three"
        model.jump(to: target)
        XCTAssertTrue(model.isSettling)
        XCTAssertTrue(model.coversText)
        XCTAssertTrue(model.isRestoring)
        XCTAssertEqual(model.currentIndex, target, "the jump's target is the position from the start")
        XCTAssertEqual(ReaderViewModel(book: book(), positions: fixture.positions, sync: fixture.sync,
                                       settings: fixture.defaults).startIndex, target,
                       "the target is saved at once: leaving mid-jump reopens there")
        let firstJump = try XCTUnwrap(model.jumpRequest)

        // The lazy stack's estimate lands a few blocks short.
        model.blockFramesChanged([target - 3: f(0, 100), target - 2: f(110, 210)])
        try await waitUntil { model.jumpRequest != firstJump }
        XCTAssertEqual(model.jumpRequest?.index, target, "the jump is re-issued")
        XCTAssertTrue(model.isSettling, "still covered while it corrects")
        XCTAssertEqual(model.currentIndex, target, "a landing that is off never becomes the position")
        XCTAssertNil(model.arrival)

        model.blockFramesChanged([target: f(0, 100), target + 1: f(110, 210)])
        try await waitUntil { !model.isSettling }
        XCTAssertFalse(model.coversText)
        XCTAssertFalse(model.isRestoring)
        XCTAssertFalse(model.showsSettlingIndicator)
        let arrival = try XCTUnwrap(model.arrival)
        XCTAssertEqual(arrival.announcement, "Three", "VoiceOver hears the chapter arrived at")

        // Reading by hand afterwards moves the position again, and announces nothing more.
        model.blockFramesChanged([target + 1: f(0, 100), target + 2: f(110, 210)])
        XCTAssertEqual(model.currentIndex, target + 1)
        XCTAssertEqual(model.arrival, arrival)
    }

    /// A jump to a block that is already laid out lands in one scroll: no cover, no announcement.
    @MainActor
    func testNearJumpIsNotCovered() async throws {
        let model = try await openedReader().model
        model.jump(to: 1)
        XCTAssertFalse(model.isSettling)
        XCTAssertFalse(model.coversText)
        model.blockFramesChanged([1: f(0, 100), 2: f(110, 210)])
        try await waitUntil { !model.isRestoring }
        XCTAssertNil(model.arrival)
    }

    /// The small progress indicator shows only once the cover has lasted `settlingIndicatorDelay`, and goes with it.
    @MainActor
    func testIndicatorShowsAfterADelayAndGoesWithTheCover() async throws {
        let model = try await openedReader().model
        model.settlingIndicatorDelay = 30_000_000
        model.settleDelay = 400_000_000
        model.openSettleDelay = 400_000_000
        model.jump(to: 2 * Self.blocksPerChapter)
        XCTAssertFalse(model.showsSettlingIndicator, "not at once: most jumps land before it is needed")
        try await waitUntil { model.showsSettlingIndicator }
        XCTAssertTrue(model.isSettling)

        let target = 2 * Self.blocksPerChapter
        model.blockFramesChanged([target: f(0, 100)])
        try await waitUntil { !model.isSettling }
        XCTAssertFalse(model.showsSettlingIndicator)
    }

    /// Closing the menu re-anchors the reader (`reanchor`): during a far jump that keeps the cover, which lifts
    /// once the target has landed.
    @MainActor
    func testReanchorDuringAJumpKeepsTheCover() async throws {
        let model = try await openedReader().model
        let target = Self.blocksPerChapter // chapter "Two"
        model.jump(to: target)
        model.reanchor()
        XCTAssertTrue(model.isSettling)
        XCTAssertEqual(model.jumpRequest?.index, target)
        model.blockFramesChanged([target: f(0, 100), target + 1: f(110, 210)])
        try await waitUntil { !model.isSettling }
        XCTAssertEqual(model.arrival?.announcement, "Two")
        XCTAssertEqual(model.currentIndex, target)
    }

    // MARK: Chapter starts (build 48 feedback)

    func testOnlyAMeasuredBlockNearTheScreenCountsAsLaidOut() {
        XCTAssertTrue(JumpSettling.isNear(f(250, 300), viewportHeight: 200), "just below the screen")
        XCTAssertTrue(JumpSettling.isNear(f(-150, -100), viewportHeight: 200), "just above the screen")
        XCTAssertFalse(JumpSettling.isNear(f(2_000, 2_050), viewportHeight: 200), "kept by the lazy stack, far below")
        XCTAssertFalse(JumpSettling.isNear(f(-3_000, -2_950), viewportHeight: 200), "read earlier, far above")
        XCTAssertTrue(JumpSettling.isNear(f(2_000, 2_050), viewportHeight: 0), "no viewport yet: the frame is all there is")
    }

    /// The previous chapter's heading can still be measured (the lazy stack keeps it) far above the screen, with
    /// estimated heights in between: the jump is covered like any far jump.
    @MainActor
    func testJumpToAFarBlockThatIsStillMeasuredIsCovered() async throws {
        let model = try await openedReader().model
        model.blockFramesChanged([0: f(-3_000, -2_950), 30: f(0, 100), 31: f(110, 210)])
        model.jump(to: 0)
        XCTAssertTrue(model.isSettling, "a block measured far from the screen does not land exactly")
    }

    /// A jump to a chapter's start (offset 0) is over only once the heading's top is at the reading line: the
    /// heading being the top block is not enough when it landed half under the bar.
    @MainActor
    func testChapterJumpCorrectsALandingOffTheReadingLine() async throws {
        let model = try await openedReader().model
        model.settleDelay = 150_000_000
        model.openSettleDelay = 150_000_000
        model.viewportTop = 30
        let target = Self.blocksPerChapter // chapter "Two"
        model.jump(to: target)
        let firstJump = try XCTUnwrap(model.jumpRequest)
        XCTAssertNil(firstJump.anchorY, "a chapter start goes to the block's top")

        // The heading is the top block, but 20 pt above the reading line (under the bar).
        model.blockFramesChanged([target: f(10, 60), target + 1: f(70, 170)])
        try await waitUntil { model.jumpRequest != firstJump }
        let correction = try XCTUnwrap(model.jumpRequest)
        XCTAssertEqual(correction.index, target)
        XCTAssertEqual(try XCTUnwrap(correction.anchorY), 0, accuracy: 1e-9,
                       "the same `.top` scroll again, now on measured heights: no anchor computed from the reading line")
        XCTAssertTrue(model.isSettling, "still covered while it corrects")

        model.blockFramesChanged([target: f(30, 80), target + 1: f(90, 190)])
        try await waitUntil { !model.isSettling }
        XCTAssertFalse(model.isRestoring)
        XCTAssertEqual(model.currentIndex, target)
        XCTAssertEqual(model.currentOffset, 0, "the chapter's first line is the position")
        XCTAssertEqual(model.arrival?.announcement, "Two")
    }

    /// `.top` puts a block's top at the reading line: a near jump to a chapter's start uses it as is, with no
    /// anchor derived from the reading line (one derived from it put headings at y 95 of 197 in build 48's PR).
    @MainActor
    func testNearChapterJumpScrollsToTheBlockTop() async throws {
        let model = try await openedReader().model
        model.viewportTop = 30
        model.jump(to: 1) // laid out at 110...210 in a 200 pt viewport
        XCTAssertFalse(model.isSettling)
        XCTAssertNil(model.jumpRequest?.anchorY)
    }

    // MARK: Text size changes (build 48 feedback)

    /// A new layout freezes the position at once, covers the text, brings the same line back to the top and reveals
    /// it: the saved block and character offset never change, and nothing is announced.
    @MainActor
    func testLayoutChangeKeepsTheLineAndRevealsItOnceItIsBack() async throws {
        let fixture = try await openedReader()
        let model = fixture.model
        model.settleDelay = 150_000_000
        model.openSettleDelay = 150_000_000
        // Reading block 5, a quarter of it scrolled past.
        model.blockFramesChanged([5: f(-50, 150), 6: f(160, 260)], layoutKey: "16pt")
        XCTAssertEqual(model.currentIndex, 5)
        let offset = model.currentOffset
        XCTAssertGreaterThan(offset, 0)
        XCTAssertFalse(model.isRestoring, "the first layout key is only remembered")

        // The first frames of the larger text arrive (before the view's onChange): block 7 is now at the top.
        model.blockFramesChanged([7: f(0, 300), 8: f(310, 610)], layoutKey: "17pt")
        XCTAssertEqual(model.currentIndex, 5, "the new layout is not read as scrolling")
        XCTAssertEqual(model.currentOffset, offset)
        XCTAssertTrue(model.isRestoring)
        XCTAssertTrue(model.isSettling, "covered while the line is brought back")
        let firstJump = try XCTUnwrap(model.jumpRequest)
        XCTAssertEqual(firstJump.index, 5)
        // The view's onChange for the same key changes nothing more.
        model.layoutChanged(to: "17pt")
        XCTAssertEqual(model.jumpRequest, firstJump)

        // The block is at the top; the line inside it not yet.
        model.blockFramesChanged([5: f(0, 300), 6: f(310, 610)], layoutKey: "17pt")
        try await waitUntil { model.jumpRequest != firstJump }
        XCTAssertNotNil(model.jumpRequest?.anchorY, "the second scroll brings the line to the top edge")
        XCTAssertTrue(model.isSettling)

        let fraction = InBlockPosition.fraction(forCharacterOffset: offset, in: model.flat.blocks[5].text)
        let wanted = CGFloat(InBlockPosition.wantedMinY(fraction: fraction, blockHeight: 300, viewportTop: 0))
        model.blockFramesChanged([5: f(wanted, wanted + 300), 6: f(wanted + 310, wanted + 610)], layoutKey: "17pt")
        try await waitUntil { !model.isSettling }
        XCTAssertFalse(model.isRestoring)
        XCTAssertEqual(model.currentIndex, 5)
        XCTAssertEqual(model.currentOffset, offset, "the same line, to the character")
        XCTAssertNil(model.arrival, "a text size change goes nowhere: nothing to announce")
        let reopened = ReaderViewModel(book: book(), positions: fixture.positions, sync: fixture.sync,
                                       settings: fixture.defaults)
        XCTAssertEqual(reopened.startIndex, 5)
        XCTAssertEqual(reopened.startOffset, offset, "the saved position never moved")
    }

    /// The view's onChange can come first, with the old frames still reported: the same freeze.
    @MainActor
    func testLayoutChangeFromTheViewFreezesThePositionBeforeNewFrames() async throws {
        let model = try await openedReader().model
        model.blockFramesChanged([3: f(0, 100), 4: f(110, 210)], layoutKey: "a")
        XCTAssertEqual(model.currentIndex, 3)
        model.layoutChanged(to: "b")
        XCTAssertTrue(model.isSettling)
        XCTAssertNil(model.jumpRequest?.anchorY, "old heights are not used for the anchor")
        model.blockFramesChanged([6: f(0, 100)], layoutKey: "b")
        XCTAssertEqual(model.currentIndex, 3, "frames during the re-layout never become the position")
        model.blockFramesChanged([3: f(0, 140), 4: f(150, 290)], layoutKey: "b")
        try await waitUntil { !model.isSettling }
        XCTAssertEqual(model.currentIndex, 3)
        XCTAssertEqual(model.currentOffset, 0)
    }

    /// Closing the menu re-anchors; with the line already at the top nothing scrolls (no hop).
    @MainActor
    func testReanchorWithTheLineInPlaceDoesNotScroll() async throws {
        let model = try await openedReader().model
        let before = model.jumpRequest
        model.reanchor()
        XCTAssertEqual(model.jumpRequest, before)
        XCTAssertFalse(model.isRestoring)
        XCTAssertFalse(model.coversText)
    }

    // MARK: Settling on real books (build 49 feedback)

    /// After the `.top` scroll the lazy stack measures the blocks above the target, which moves it: a landing that
    /// was in place at one check and has moved at the next is brought back, and the cover lifts only once it has
    /// stayed in place.
    @MainActor
    func testFarJumpIsRevealedOnlyOnceTheTargetStaysInPlace() async throws {
        let model = try await openedReader().model
        model.settleDelay = 120_000_000
        model.openSettleDelay = 120_000_000
        let target = Self.blocksPerChapter // chapter "Two"
        model.jump(to: target)
        model.blockFramesChanged([target: f(0, 40), target + 1: f(50, 150)])
        let firstJump = try XCTUnwrap(model.jumpRequest)
        // In place at the first check: not revealed yet.
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertTrue(model.isSettling, "one check in place is not enough")
        XCTAssertEqual(model.jumpRequest, firstJump, "nothing to correct yet")

        // The blocks above were measured taller than estimated: the target moved down, the previous chapter's last
        // paragraph is at the top.
        model.blockFramesChanged([target - 1: f(-30, 30), target: f(40, 80), target + 1: f(90, 190)])
        try await waitUntil { model.jumpRequest != firstJump }
        XCTAssertEqual(model.jumpRequest?.index, target, "the jump is re-issued")
        XCTAssertTrue(model.isSettling)

        model.blockFramesChanged([target: f(0, 40), target + 1: f(50, 150)])
        try await waitUntil { !model.isSettling }
        XCTAssertEqual(model.currentIndex, target)
        XCTAssertEqual(model.currentOffset, 0)
    }

    /// Under the cover a landing that is still off after three re-issues is not revealed: the restore keeps going
    /// (up to `RestoreCheck.coveredRetries`).
    @MainActor
    func testCoveredJumpKeepsCorrectingPastThreeRetries() async throws {
        let model = try await openedReader().model
        model.settleDelay = 60_000_000
        model.openSettleDelay = 60_000_000
        let target = 2 * Self.blocksPerChapter + 5
        model.jump(to: target)
        model.blockFramesChanged([target + 4: f(0, 100), target + 5: f(110, 210)]) // landed past the target
        var requests = 0
        var last = model.jumpRequest
        while requests < RestoreCheck.maxRetries + 2 {
            try await waitUntil { model.jumpRequest != last }
            last = model.jumpRequest
            requests += 1
        }
        XCTAssertTrue(model.isSettling, "still covered after \(requests) re-issues")
        XCTAssertEqual(model.currentIndex, target, "the landing past the target never became the position")
        model.blockFramesChanged([target: f(0, 100), target + 1: f(110, 210)])
        try await waitUntil { !model.isSettling }
        XCTAssertEqual(model.currentIndex, target)
    }

    /// A re-layout whose frames do not come (the reader behind the Reading Options sheet) waits for them instead of
    /// ending the restore: the first frames of the new layout are then checked, not saved as the position.
    @MainActor
    func testLayoutChangeWaitsForTheNewFrames() async throws {
        let model = try await openedReader().model
        let heading = Self.blocksPerChapter
        model.jump(to: heading)
        model.blockFramesChanged([heading: f(0, 40), heading + 1: f(50, 150)], layoutKey: "15pt")
        try await waitUntil { !model.isRestoring }
        model.layoutChanged(to: "16pt")
        // Many checks' worth of time with no frames at all.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(model.isRestoring, "no frames yet: the restore waits")
        XCTAssertTrue(model.isSettling)
        // The sheet goes; the new layout arrives with the scroll offset kept: the previous chapter's end at the top.
        model.blockFramesChanged([heading - 1: f(-20, 60), heading: f(70, 120)], layoutKey: "16pt")
        XCTAssertEqual(model.currentIndex, heading, "the new layout is not read as scrolling")
        try await waitUntil { model.jumpRequest?.index == heading && model.isRestoring }
        model.blockFramesChanged([heading: f(0, 50), heading + 1: f(60, 200)], layoutKey: "16pt")
        try await waitUntil { !model.isSettling }
        XCTAssertEqual(model.currentIndex, heading)
        XCTAssertEqual(model.currentOffset, 0)
    }

    /// Near the end of the book the target cannot reach the reading line: on screen below it, with the end of the
    /// book in view, is its place, and the restore ends without using up its retries.
    @MainActor
    func testTargetHeldBelowTheLineByTheEndOfTheBookSettles() async throws {
        let model = try await openedReader().model
        let last = 3 * Self.blocksPerChapter - 1
        model.jump(to: last - 1)
        model.blockFramesChanged([last - 2: f(-40, 20), last - 1: f(30, 90), last: f(100, 180)])
        try await waitUntil(timeout: 1.5) { !model.isSettling }
        XCTAssertEqual(model.currentIndex, last - 1)
    }
}
