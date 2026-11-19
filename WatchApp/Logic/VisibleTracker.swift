import Foundation
import CoreGraphics
import ReaderCore

/// Vertical extent of a block in the scroll view's coordinate space (0 = top edge of the viewport).
struct BlockFrame: Equatable {
    var minY: CGFloat
    var maxY: CGFloat
    /// Width of the block (used to place a tap within a line for the word lookup).
    var width: CGFloat = 0
    /// Left edge of the block (auto-scroll lines its own copy of the text up with it).
    var minX: CGFloat = 0
    /// The block's top on screen (global coordinates), measured with the frame above. The difference to `minY` is
    /// where the scroll view's space starts on screen, which is not always the same (below the bar or at the top of
    /// the screen, with the same reported inset and origin). Nil where not measured (tests).
    var screenMinY: CGFloat? = nil
}

/// Decides the reading position from block frames measured with a named coordinate space.
///
/// `onAppear`/`onDisappear` of a `LazyVStack` row fire when the row is instantiated/discarded, which
/// includes an off-screen prefetch buffer, so "smallest appeared index" can be a block that is not on
/// screen. Geometry in the scroll view's own space is exact: the position is the first block whose
/// bottom edge is still below the top of the viewport.
enum VisibleBlockResolver {
    /// Blocks whose bottom edge is within `threshold` points of the viewport top count as scrolled off.
    /// `viewportTop` is where the visible area starts in that space: non-zero when the scroll view
    /// extends under the navigation bar, whose height is then a top safe-area inset of the scroll view.
    /// A block hidden under the bar is not the one being read.
    static func topIndex(frames: [Int: BlockFrame], viewportTop: CGFloat = 0, threshold: CGFloat = 4) -> Int? {
        frames.filter { $0.value.maxY > viewportTop + threshold }.keys.min()
    }

    /// How far below the reading line the top block's top may be and still be the block being read: the gap
    /// between two paragraphs (the line falls between them) with room to spare.
    static let lineSlack: CGFloat = 24

    /// The block at the reading line, only if one is there: `topIndex`, provided that block's top is not more than
    /// `lineSlack` below the line. A frame report can hold only some rows (while they are laid out again), and the
    /// first one "below the line" is then a block far down the screen or off it. Such a report says nothing about the
    /// position: nil.
    static func lineIndex(frames: [Int: BlockFrame], viewportTop: CGFloat = 0, threshold: CGFloat = 4) -> Int? {
        guard let top = topIndex(frames: frames, viewportTop: viewportTop, threshold: threshold),
              let frame = frames[top], frame.minY <= viewportTop + lineSlack else { return nil }
        return top
    }
}

/// When a programmatic jump (restore, chapter, remote position) has to be re-issued.
enum RestoreCheck {
    /// Re-issues (and in-block corrections) for a restore the reader can see.
    static let maxRetries = 3
    /// The same under a cover (opening, far jump, re-layout), where nobody sees them: a landing that is still being
    /// laid out gets more checks before the cover lifts. About 2.4 s at the covered pace; most jumps settle in two or
    /// three checks, and `JumpSettling.maxSettleDuration` caps the cover anyway.
    static let coveredRetries = 12

    /// The block at the top is not the target (or nothing is laid out yet) and retries remain. Near the
    /// end of a book the target may be unable to reach the top; the retries then run out harmlessly.
    static func needsRetry(top: Int?, target: Int, attempts: Int, limit: Int = maxRetries) -> Bool {
        attempts < limit && top != target
    }

    /// The target block is at the top but the saved line inside it is more than `tolerance` points away
    /// from the top edge, and corrections remain.
    static func needsInBlockRetry(landedMinY: Double, wantedMinY: Double, attempts: Int,
                                  tolerance: Double = InBlockPosition.tolerance, limit: Int = maxRetries) -> Bool {
        attempts < limit && abs(landedMinY - wantedMinY) > tolerance
    }

    /// A covered restore ends only once the target has been in place at two checks in a row, at the same point
    /// (within `tolerance`): a landing that still moves (blocks above it being measured) is not settled yet.
    static func isStable(previousMinY: Double?, minY: Double, tolerance: Double = 0.5) -> Bool {
        guard let previousMinY else { return false }
        return abs(previousMinY - minY) <= tolerance
    }

    /// The end of the book is on screen (the last block's bottom within the viewport): a target near the end
    /// cannot scroll up to the reading line, so its landing below the line is the right one.
    static func endOfBookOnScreen(lastBlockMaxY: Double?, viewportHeight: Double) -> Bool {
        guard let lastBlockMaxY, viewportHeight > 0 else { return false }
        return lastBlockMaxY <= viewportHeight + 1
    }
}

/// The cover over the text while a far jump or a re-layout settles (#174).
///
/// A `LazyVStack` places far-away blocks with estimated heights, so `scrollTo` to a block that is not laid out
/// lands a little off and the restore loop (`RestoreCheck`) corrects it once the real blocks are measured.
/// Each correction would be a visible hop. Instead the text is covered from the jump until the target is at the
/// top edge, then revealed at once (a short cross-fade, none with Reduce Motion): the reader sees the old place,
/// then the new one. A jump to a block that is already laid out lands exactly in one scroll (its in-block anchor
/// is known up front) and is not covered.
///
/// A text-size (or any typography layout) change is covered the same way: every block changes height, so the
/// passage at the top has to be brought back by a scroll that lands on estimated heights first. The position is
/// frozen from the moment the layout key changes (`ReaderViewModel.layoutChanged(to:)`), so the corrections can
/// never be saved as the reading position, and the text is revealed once that passage is back at the top.
enum JumpSettling {
    /// After this long under the cover, a small progress indicator shows (most far jumps land before it).
    static let indicatorDelay: UInt64 = 150_000_000

    /// The longest a restore keeps the text covered (seconds): it is then revealed wherever it stands, so the
    /// cover always lifts, whatever the checks find (or fail to find).
    static let maxSettleDuration: TimeInterval = 3

    /// How long the checks after a re-layout wait for the first frame of the new layout (seconds) before they go
    /// on with the frames they have.
    static let newLayoutWait: TimeInterval = 1

    /// Whether a jump to a block must be covered: the reader is already showing text (while the book opens it
    /// is hidden anyway) and the target block is not laid out, so the first scroll cannot land exactly.
    static func covers(isPositioned: Bool, targetLaidOut: Bool) -> Bool {
        isPositioned && !targetLaidOut
    }

    /// Whether a measured block is close enough to the screen for `scrollTo` to land on it exactly: within
    /// `nearScreens` viewport heights above or below the visible area. The lazy stack can keep a block measured
    /// long after it scrolled away (the previous chapter's heading, read earlier), while the blocks between it and
    /// the screen are placed on estimated heights; a jump to such a block lands off just like a far one, so it
    /// is covered too. An unknown viewport height counts as near (the frame is all there is to go on).
    static func isNear(_ frame: BlockFrame, viewportHeight: CGFloat, nearScreens: CGFloat = 2) -> Bool {
        guard viewportHeight > 0 else { return true }
        return frame.maxY > -nearScreens * viewportHeight && frame.minY < (1 + nearScreens) * viewportHeight
    }

    /// How close (points) a jump to the start of a block (a chapter, a block-only bookmark) must bring the block's
    /// top to the reading line. Tighter than `InBlockPosition.tolerance`, which is about a saved line inside a
    /// block: a chapter heading half under the bar is not "the start of the chapter".
    static let startTolerance = 1.0

    /// Pause before checking where a scroll landed. Under a cover (opening or a far jump) nobody sees a
    /// re-issued scroll, so checks come at the short opening pace and the cover lifts sooner; uncovered
    /// corrections wait for the lazy layout to settle (`settleDelay`).
    static func checkDelay(isPositioned: Bool, isSettling: Bool, settleDelay: UInt64, openSettleDelay: UInt64) -> UInt64 {
        if !isPositioned { return openSettleDelay }
        return isSettling ? min(settleDelay, openSettleDelay) : settleDelay
    }
}
