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
    static func topIndex(frames: [Int: BlockFrame], threshold: CGFloat = 4) -> Int? {
        frames.filter { $0.value.maxY > threshold }.keys.min()
    }
}
