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
}
