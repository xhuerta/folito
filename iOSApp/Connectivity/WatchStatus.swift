import Foundation
import WatchConnectivity

/// What the Library screen tells the user about the Apple Watch. Derived from the WCSession flags by a
/// pure function so the mapping is unit-tested.
enum WatchStatus: Equatable {
    /// WatchConnectivity is not available on this device (e.g. iPad). Nothing is shown.
    case unsupported
    /// The session has not finished activating yet. Nothing is shown, to avoid a flash of "no watch".
    case activating
    case notPaired
    case appNotInstalled
    /// The watch app can receive books; `reachable` is true while it is running in the foreground.
    case ready(reachable: Bool)

    init(supported: Bool, activation: WCSessionActivationState, paired: Bool, appInstalled: Bool, reachable: Bool) {
        guard supported else { self = .unsupported; return }
        guard activation == .activated else { self = .activating; return }
        guard paired else { self = .notPaired; return }
        guard appInstalled else { self = .appNotInstalled; return }
        self = .ready(reachable: reachable)
    }

    /// True when book transfers can be started now.
    var canSend: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Per-book state shown in a library row.
enum BookWatchState: Equatable {
    case onWatch
    case sending
    /// Not on the watch yet; it is sent automatically as soon as the watch app can receive it.
    case waiting

    init(sentToWatch: Bool, inFlight: Bool) {
        if inFlight { self = .sending } else if sentToWatch { self = .onWatch } else { self = .waiting }
    }

    var text: String {
        switch self {
        case .onWatch: return String(localized: "On Apple Watch", comment: "Library row: the book is stored on the watch")
        case .sending: return String(localized: "Sending to Apple Watch…", comment: "Library row: transfer in progress")
        case .waiting: return String(localized: "Waiting for Apple Watch", comment: "Library row: the book will be sent when the watch is available")
        }
    }

    var systemImage: String {
        switch self {
        case .onWatch: return "checkmark.circle.fill"
        case .sending: return "arrow.up.circle"
        case .waiting: return "clock"
        }
    }
}
