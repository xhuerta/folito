import Foundation

/// What a row shows about a file transfer to the watch that is still in flight (a book or a dictionary).
/// Pure value: built by `WatchTransferTracker` from `WCSessionFileTransfer.progress`, unit-tested.
///
/// Only the iPhone can show this: watchOS reports a received file to the watch app once it is complete, so the
/// watch has no incoming progress to show.
struct WatchTransferProgress: Equatable {
    /// Whole percentage done, 0...100.
    var percent: Int
    /// Queued, but not moving: the watch is asleep, out of range or low on battery. Not an error.
    var isWaiting: Bool

    /// VoiceOver speaks the percentage in steps of this size, so a focused row is not re-read on every change.
    static let accessibilityStep = 5

    init(percent: Int, isWaiting: Bool) {
        self.percent = min(max(percent, 0), 100)
        self.isWaiting = isWaiting
    }

    /// For the determinate progress bar.
    var fraction: Double { Double(percent) / 100 }

    /// The percentage VoiceOver speaks (rounded down to `accessibilityStep`).
    var spokenPercent: Int { percent / Self.accessibilityStep * Self.accessibilityStep }

    var systemImage: String { isWaiting ? "clock" : "arrow.up.circle" }

    /// Row text: "Sending… 45%" or "Waiting for Apple Watch".
    func text(locale: Locale = .autoupdatingCurrent) -> String {
        if isWaiting { return Self.waitingText }
        let value = DisplayFormat.percent(fraction, locale: locale)
        return String(localized: "Sending… \(value)",
                      comment: "Library row: a transfer to the watch that is moving; the placeholder is a percentage, e.g. 45%")
    }

    /// VoiceOver text: "Sending to Apple Watch, 45%" (read as "45 percent"), or the waiting text.
    func accessibilityText(locale: Locale = .autoupdatingCurrent) -> String {
        if isWaiting { return Self.waitingText }
        let value = DisplayFormat.percent(Double(spokenPercent) / 100, locale: locale)
        return String(localized: "Sending to Apple Watch, \(value)",
                      comment: "VoiceOver value of a transfer to the watch; the placeholder is a percentage")
    }

    static var waitingText: String {
        String(localized: "Waiting for Apple Watch", comment: "Library row: the book will be sent when the watch is available")
    }

    /// Shown under a waiting transfer.
    static var waitingHint: String {
        String(localized: "Keep your Apple Watch nearby and unlocked.",
               comment: "Hint under a transfer to the watch that is queued but not moving")
    }
}

/// Follows one transfer's `fractionCompleted` and decides between *Sending* and *Waiting for Apple Watch*.
/// Pure value type (time is passed in), so the transitions are unit-tested.
struct WatchTransferTracker: Equatable {
    /// A transfer still at 0 % counts as waiting after this long (at once while the watch is not reachable).
    static let startGrace: TimeInterval = 4
    /// A transfer that has not moved for this long counts as waiting.
    static let stallInterval: TimeInterval = 20

    private(set) var fraction: Double = 0
    /// When the fraction last grew (initially: when tracking started).
    private(set) var lastAdvance: Date

    init(startedAt start: Date) {
        lastAdvance = start
    }

    /// Records the transfer's current `fractionCompleted`. Only growth counts as movement; NaN and values
    /// outside 0...1 are clamped.
    mutating func record(_ value: Double, at now: Date) {
        let clamped = value.isFinite ? min(max(value, 0), 1) : 0
        if clamped > fraction {
            fraction = clamped
            lastAdvance = now
        }
    }

    func progress(at now: Date, watchReachable: Bool) -> WatchTransferProgress {
        let idle = now.timeIntervalSince(lastAdvance)
        let waiting: Bool
        if fraction == 0 {
            waiting = !watchReachable || idle >= Self.startGrace
        } else {
            waiting = idle >= Self.stallInterval
        }
        // The epsilon keeps e.g. 0.29 (28.999… × 100) at 29 %.
        return WatchTransferProgress(percent: Int((fraction * 100 + 1e-9).rounded(.down)), isWaiting: waiting)
    }
}
