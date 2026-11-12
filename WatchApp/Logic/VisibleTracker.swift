import Foundation
import CoreGraphics

/// Vertical extent of a block in the scroll view's coordinate space (0 = top edge of the viewport).
struct BlockFrame: Equatable {
    var minY: CGFloat
    var maxY: CGFloat
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
}

/// When a programmatic jump (restore, chapter, remote position) has to be re-issued.
enum RestoreCheck {
    static let maxRetries = 3

    /// The block at the top is not the target (or nothing is laid out yet) and retries remain. Near the
    /// end of a book the target may be unable to reach the top; the retries then run out harmlessly.
    static func needsRetry(top: Int?, target: Int, attempts: Int) -> Bool {
        attempts < maxRetries && top != target
    }
}
