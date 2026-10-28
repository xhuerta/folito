import Foundation
import ReaderCore

/// Locale-aware formatting of the values shown in the iPhone UI. Pure, so it is unit-tested with a fixed
/// locale; views call it with the user's locale.
enum DisplayFormat {
    /// Typographic points, e.g. "18 pt".
    static func points(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0)).locale(locale))
        return String(localized: "\(number) pt", locale: locale,
                      comment: "A length in typographic points, e.g. 18 pt. The placeholder is the formatted number")
    }

    /// Signed points with two decimals, used for letter spacing, e.g. "+0.25 pt".
    static func signedPoints(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let number = value.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always()).locale(locale))
        return String(localized: "\(number) pt", locale: locale,
                      comment: "A length in typographic points, e.g. 18 pt. The placeholder is the formatted number")
    }

    /// A scale factor as a whole percentage, e.g. 1.25 -> "125%".
    static func percent(_ fraction: Double, locale: Locale = .autoupdatingCurrent) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// Size of a book payload, e.g. "1.2 MB".
    static func fileSize(_ bytes: Int, locale: Locale = .autoupdatingCurrent) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(locale))
    }
}

/// Localizable display names for the reader typography options. ReaderCore's own `title` strings are
/// English-only (the package has no resources), so the iPhone UI uses these instead.
enum ReadingSettingsText {
    static func name(_ family: ReaderTypography.FontFamily) -> String {
        switch family {
        case .system: return String(localized: "System", comment: "Reader font: San Francisco")
        case .serif: return String(localized: "Serif", comment: "Reader font: New York")
        case .rounded: return String(localized: "Rounded", comment: "Reader font: SF Rounded")
        case .monospaced: return String(localized: "Mono", comment: "Reader font: SF Mono (short, fits a segmented control)")
        }
    }

    static func name(_ alignment: ReaderTypography.Alignment) -> String {
        switch alignment {
        case .leading: return String(localized: "Left", comment: "Text alignment")
        case .center: return String(localized: "Center", comment: "Text alignment")
        }
    }

    static func name(_ theme: ReaderTypography.Theme) -> String {
        switch theme {
        case .dark: return String(localized: "Dark", comment: "Reader colour theme")
        case .dim: return String(localized: "Dim", comment: "Reader colour theme")
        case .sepia: return String(localized: "Sepia", comment: "Reader colour theme")
        case .highContrast: return String(localized: "High Contrast", comment: "Reader colour theme")
        }
    }

    static func name(_ preset: ReaderTypography.Preset) -> String {
        switch preset {
        case .standard: return String(localized: "Standard", comment: "Reading style preset")
        case .compact: return String(localized: "Compact", comment: "Reading style preset")
        case .comfortable: return String(localized: "Comfortable", comment: "Reading style preset")
        case .largePrint: return String(localized: "Large Print", comment: "Reading style preset")
        case .night: return String(localized: "Night", comment: "Reading style preset")
        }
    }

    /// Spoken summary of the preview, e.g. "Serif, 18 pt, Sepia".
    static func previewSummary(_ t: ReaderTypography, locale: Locale = .autoupdatingCurrent) -> String {
        let font = name(t.fontFamily)
        let size = DisplayFormat.points(t.fontSize, locale: locale)
        let theme = name(t.theme)
        return String(localized: "\(font), \(size), \(theme)", locale: locale,
                      comment: "Accessibility value of the reading preview: font, size, colour theme")
    }
}
