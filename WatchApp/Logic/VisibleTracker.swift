import Foundation

/// Tracks which block indices are currently on screen, using `onAppear`/`onDisappear`
/// callbacks of a `LazyVStack`. The reading position is the top-most visible block.
struct VisibleTracker: Equatable {
    private(set) var visible: Set<Int> = []

    mutating func appeared(_ index: Int) { visible.insert(index) }
    mutating func disappeared(_ index: Int) { visible.remove(index) }
    mutating func reset() { visible.removeAll() }

    /// Top-most visible block, or nil when nothing is visible.
    var top: Int? { visible.min() }
}
