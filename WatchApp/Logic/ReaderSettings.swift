import Foundation
import ReaderCore

/// User-facing reader preferences. Views bind to the keys via `@AppStorage`.
enum ReaderSettings {
    /// Legacy font size key; the value now lives in `ReaderTypography` (migrated by `TypographyStore`).
    static let fontSizeKey = TypographyStore.legacyFontSizeKey
    static let showSyncInfoKey = "settings.showSyncInfo"
    static let tapToLookUpKey = "settings.tapToLookUp"
    /// Estimated reading time left at the top of Reading Options (on by default).
    static let showTimeRemainingKey = "settings.showTimeRemaining"
    /// Book covers next to the titles in the Library (on by default while covers are an experiment).
    static let showCoversKey = "settings.showCovers"

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
        defaults.removeObject(forKey: tapToLookUpKey)
        defaults.removeObject(forKey: showTimeRemainingKey)
        defaults.removeObject(forKey: showCoversKey)
    }
}
