import WatchKit

/// Haptic moments of the watch app, mapped to the system's `WKHapticType`s.
enum HapticEvent: Equatable {
    /// The dictionary word cursor moved by a button or a VoiceOver adjust (the Digital Crown already
    /// plays its own detent haptics, so crown turns do not use this).
    case cursorMoved
    case lookupSucceeded
    case lookupFailed

    var hapticType: WKHapticType {
        switch self {
        case .cursorMoved: return .click
        case .lookupSucceeded: return .success
        case .lookupFailed: return .failure
        }
    }
}

protocol HapticPlaying {
    func play(_ event: HapticEvent)
}

/// Plays through `WKInterfaceDevice`. The system skips haptics when the user turned them off.
struct WatchHaptics: HapticPlaying {
    func play(_ event: HapticEvent) {
        WKInterfaceDevice.current().play(event.hapticType)
    }
}

/// Silent player for previews and tests.
struct NoHaptics: HapticPlaying {
    func play(_ event: HapticEvent) {}
}
