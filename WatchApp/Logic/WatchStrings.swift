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

    /// The remote-position offer's message: "43% read on iPad", or, when the service names no device,
    /// "43% read in Readest" for Readest Cloud and "43% read on another device" otherwise.
    static func remoteOffer(_ fraction: Double, deviceName: String, connectorID: String?,
                            locale: Locale = .current) -> String {
        if !deviceName.isEmpty { return readOnDevice(fraction, device: deviceName, locale: locale) }
        if connectorID == ReadestConnectorFactory.id {
            let p = percent(fraction, locale: locale)
            return String(localized: "\(p) read in Readest", locale: locale,
                          comment: "Reading progress saved in the Readest app (Readest Cloud sync). Argument: formatted percentage.")
        }
        return readOnDevice(fraction, device: String(localized: "another device", locale: locale,
                                                     comment: "Used in '43% read on another device' when the device name is unknown"),
                            locale: locale)
    }

    /// "43% read on iPad" (the remote-position offer).
    static func readOnDevice(_ fraction: Double, device: String, locale: Locale = .current) -> String {
        let p = percent(fraction, locale: locale)
        return String(localized: "\(p) read on \(device)", locale: locale,
                      comment: "Reading progress saved by another device. Arguments: formatted percentage, device name.")
    }
}

/// Estimated reading time left, as text (`ReadingTimeRemaining`). Durations come from `DateComponentsFormatter`
/// in the user's locale: abbreviated on screen ("12 min", "3 hr, 20 min"), spelled out for VoiceOver
/// ("12 minutes", "3 hours, 20 minutes").
enum TimeRemainingFormat {
    static func duration(_ seconds: TimeInterval, style: DateComponentsFormatter.UnitsStyle,
                         locale: Locale = .current) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = style
        formatter.allowedUnits = [.hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        let minutes = max(ReadingTimeEstimator.displayMinutes(seconds), 1)
        return formatter.string(from: TimeInterval(minutes * 60)) ?? ""
    }

    /// "12 min left in chapter"
    static func chapter(_ seconds: TimeInterval, style: DateComponentsFormatter.UnitsStyle = .short,
                        locale: Locale = .current) -> String {
        let d = duration(seconds, style: style, locale: locale)
        return String(localized: "\(d) left in chapter", locale: locale,
                      comment: "Estimated reading time to the end of the chapter, e.g. '12 min left in chapter'")
    }

    /// "3 hr, 20 min in book" (shown after the chapter time, separated by a middle dot)
    static func bookShort(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        let d = duration(seconds, style: .short, locale: locale)
        return String(localized: "\(d) in book", locale: locale,
                      comment: "Estimated reading time to the end of the book, shown after the chapter time: '12 min left in chapter · 3 hr in book'")
    }

    /// "3 hours, 20 minutes left in book"
    static func book(_ seconds: TimeInterval, style: DateComponentsFormatter.UnitsStyle = .full,
                     locale: Locale = .current) -> String {
        let d = duration(seconds, style: style, locale: locale)
        return String(localized: "\(d) left in book", locale: locale,
                      comment: "Estimated reading time to the end of the book, e.g. '3 hours, 20 minutes left in book'")
    }

    /// Visible line: "12 min left in chapter · 3 hr, 20 min in book".
    static func line(_ value: ReadingTimeRemaining, locale: Locale = .current) -> String {
        "\(chapter(value.chapterSeconds, locale: locale)) · \(bookShort(value.bookSeconds, locale: locale))" // i18n-ignore
    }

    /// VoiceOver sentence: "12 minutes left in chapter, 3 hours, 20 minutes left in book."
    static func spoken(_ value: ReadingTimeRemaining, locale: Locale = .current) -> String {
        let c = chapter(value.chapterSeconds, style: .full, locale: locale)
        let b = book(value.bookSeconds, style: .full, locale: locale)
        return String(localized: "\(c). \(b).", locale: locale,
                      comment: "VoiceOver: chapter and book reading time left, two sentences, e.g. '12 minutes left in chapter. 3 hours left in book.'")
    }
}
