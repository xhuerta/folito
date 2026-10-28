import Foundation
import ReaderCore

// User-facing names and formatted values of the watch app. ReaderCore's `title`
// properties are plain English for logs and tests; the UI uses these localizable versions instead.

extension ReaderTypography.Theme {
    var localizedName: String {
        switch self {
        case .dark: return String(localized: "Dark", comment: "Reader theme: white text on black")
        case .dim: return String(localized: "Dim", comment: "Reader theme: grey text on black")
        case .sepia: return String(localized: "Sepia", comment: "Reader theme: dark brown text on cream")
        case .highContrast: return String(localized: "High Contrast", comment: "Reader theme: bold white text on black")
        }
    }
}

extension ReaderTypography.FontFamily {
    var localizedName: String {
        switch self {
        case .system: return String(localized: "System", comment: "Reader font: San Francisco")
        case .serif: return String(localized: "Serif", comment: "Reader font: New York")
        case .rounded: return String(localized: "Rounded", comment: "Reader font: SF Rounded")
        case .monospaced: return String(localized: "Monospaced", comment: "Reader font: SF Mono")
        }
    }
}

extension ReaderTypography.Alignment {
    var localizedName: String {
        switch self {
        case .leading: return String(localized: "Left", comment: "Reader text alignment")
        case .center: return String(localized: "Centered", comment: "Reader text alignment")
        }
    }
}

extension ReaderTypography.Preset {
    var localizedName: String {
        switch self {
        case .standard: return String(localized: "Standard", comment: "Typography preset")
        case .compact: return String(localized: "Compact", comment: "Typography preset")
        case .comfortable: return String(localized: "Comfortable", comment: "Typography preset")
        case .largePrint: return String(localized: "Large Print", comment: "Typography preset")
        case .night: return String(localized: "Night", comment: "Typography preset")
        }
    }
}

/// Reading progress as text, formatted for the user's locale ("43 %" in French, "٤٣٪" in Arabic...).
enum ReadingProgressFormat {
    /// Whole percent, rounded down so an unfinished book never shows 100%.
    static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        let f = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        // The epsilon keeps binary rounding (0.29 * 100 = 28.999…) from dropping a whole percent.
        let whole = min((f * 100 + 1e-9).rounded(.down), 100) / 100
        return whole.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "43% read" (library rows).
    static func read(_ fraction: Double, locale: Locale = .current) -> String {
        let p = percent(fraction, locale: locale)
        return String(localized: "\(p) read", locale: locale,
                      comment: "Reading progress of a book, e.g. '43% read'. The argument is a formatted percentage.")
    }

    /// "43% read on iPad" (the remote-position offer).
    static func readOnDevice(_ fraction: Double, device: String, locale: Locale = .current) -> String {
        let p = percent(fraction, locale: locale)
        return String(localized: "\(p) read on \(device)", locale: locale,
                      comment: "Reading progress saved by another device. Arguments: formatted percentage, device name.")
    }
}
