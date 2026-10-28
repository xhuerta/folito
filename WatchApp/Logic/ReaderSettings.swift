import Foundation

/// User-facing reader preferences. Views bind to the keys via `@AppStorage`.
enum ReaderSettings {
    static let fontSizeKey = "settings.fontSize"
    static let showSyncInfoKey = "settings.showSyncInfo"

    static let minFontSize = 12.0
    static let maxFontSize = 28.0
    static let defaultFontSize = 16.0

    static func clampFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultFontSize }
        return min(max(value, minFontSize), maxFontSize)
    }

    static func resetPreferences(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: fontSizeKey)
        defaults.removeObject(forKey: showSyncInfoKey)
    }
}
