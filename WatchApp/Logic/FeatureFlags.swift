import Foundation

/// Features that are built but not shipped yet. Each flag is a plain constant: flip it to ship the feature.
enum FeatureFlags {
    /// Auto-scroll in the reader (#67). Off until the owner is happy with it on a real watch: with the flag off,
    /// Reading Options has no Auto-Scroll row, so auto-scroll cannot start and nothing else in the reader changes.
    static let autoScrollEnabled = false

    /// `-UITestingEnableAutoScroll` turns auto-scroll on for the UI tests (Debug builds only, like every UI
    /// testing hook in `UITesting`).
    static let enableAutoScrollArgument = "-UITestingEnableAutoScroll"

    /// Whether the reader offers auto-scroll.
    static let autoScroll: Bool = {
        if autoScrollEnabled { return true }
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(enableAutoScrollArgument)
        #else
        return false
        #endif
    }()
}
