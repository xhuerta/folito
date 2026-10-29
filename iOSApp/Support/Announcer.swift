import UIKit

/// Speaks short status updates with VoiceOver (no effect when VoiceOver is off).
enum Announcer {
    @MainActor
    static func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning, !text.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
