import Foundation

/// User-configurable reader typography. Pure value type shared by the watch (renders and stores it) and
/// the iPhone (edits it and mirrors it to the watch). Every field is clamped by `clamped()` and decoding
/// is tolerant: unknown / missing / out-of-range values fall back to defaults instead of failing.
public struct ReaderTypography: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public enum FontFamily: String, Codable, CaseIterable, Sendable {
        /// SF Pro.
        case system
        /// New York (`.serif` design).
        case serif
        case rounded
        case monospaced
    }

    public enum Alignment: String, Codable, CaseIterable, Sendable {
        case leading
        case center
    }

    public enum Theme: String, Codable, CaseIterable, Sendable {
        /// White text on black (the original look).
        case dark
        /// Soft grey text on black, less glare at night.
        case dim
        case sepia
        /// Pure white, forced bold, on black.
        case highContrast
    }

    // MARK: Ranges

    public static let fontSizeRange: ClosedRange<Double> = 12...28
    public static let lineSpacingRange: ClosedRange<Double> = 0...10
    public static let horizontalMarginRange: ClosedRange<Double> = 0...16
    public static let paragraphSpacingRange: ClosedRange<Double> = 2...28
    public static let headingScaleRange: ClosedRange<Double> = 0...2
    public static let trackingRange: ClosedRange<Double> = -1...2

    // MARK: Defaults (reproduce the pre-typography look exactly)

    public static let defaultFontSize = 16.0

    // MARK: Stored properties

    public var version: Int
    public var fontFamily: FontFamily
    public var fontSize: Double
    /// Extra points between lines.
    public var lineSpacing: Double
    /// Horizontal padding of the text column, in points.
    public var horizontalMargin: Double
    /// Vertical gap between blocks, in points.
    public var paragraphSpacing: Double
    public var alignment: Alignment
    /// Body text in semibold instead of regular.
    public var boldText: Bool
    /// 0 = headings as large as body text, 1 = default sizes, 2 = exaggerated.
    public var headingScale: Double
    /// Letter spacing in points (negative = tighter). SwiftUI on watchOS has no hyphenation control.
    public var tracking: Double
    public var theme: Theme
    /// Unix time of the last user change. Last writer wins when the phone and the watch disagree.
    public var stamp: Int

    public init(fontFamily: FontFamily = .system,
                fontSize: Double = ReaderTypography.defaultFontSize,
                lineSpacing: Double = 0,
                horizontalMargin: Double = 4,
                paragraphSpacing: Double = 10,
                alignment: Alignment = .leading,
                boldText: Bool = false,
                headingScale: Double = 1,
                tracking: Double = 0,
                theme: Theme = .dark,
                stamp: Int = 0) {
        self.version = Self.currentVersion
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.horizontalMargin = horizontalMargin
        self.paragraphSpacing = paragraphSpacing
        self.alignment = alignment
        self.boldText = boldText
        self.headingScale = headingScale
        self.tracking = tracking
        self.theme = theme
        self.stamp = stamp
        self = clamped()
    }

    public static let `default` = ReaderTypography()

    // MARK: Clamping

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>, fallback: Double) -> Double {
        guard v.isFinite else { return fallback }
        return min(max(v, r.lowerBound), r.upperBound)
    }

    /// Copy with every numeric field forced into its range (NaN/inf -> default).
    public func clamped() -> ReaderTypography {
        var c = self
        c.version = Self.currentVersion
        c.fontSize = Self.clamp(fontSize, Self.fontSizeRange, fallback: Self.defaultFontSize)
        c.lineSpacing = Self.clamp(lineSpacing, Self.lineSpacingRange, fallback: 0)
        c.horizontalMargin = Self.clamp(horizontalMargin, Self.horizontalMarginRange, fallback: 4)
        c.paragraphSpacing = Self.clamp(paragraphSpacing, Self.paragraphSpacingRange, fallback: 10)
        c.headingScale = Self.clamp(headingScale, Self.headingScaleRange, fallback: 1)
        c.tracking = Self.clamp(tracking, Self.trackingRange, fallback: 0)
        c.stamp = max(0, stamp)
        return c
    }

    // MARK: Tolerant decoding

    private enum CodingKeys: String, CodingKey {
        case version, fontFamily, fontSize, lineSpacing, horizontalMargin, paragraphSpacing
        case alignment, boldText, headingScale, tracking, theme, stamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReaderTypography.default
        // Enums: an unknown raw value (newer app version) falls back to the default.
        func value<T: RawRepresentable>(_ key: CodingKeys, _ fallback: T) -> T where T.RawValue == String {
            (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.flatMap(T.init(rawValue:)) ?? fallback
        }
        func number(_ key: CodingKeys, _ fallback: Double) -> Double {
            (try? c.decodeIfPresent(Double.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        version = Self.currentVersion
        fontFamily = value(.fontFamily, d.fontFamily)
        fontSize = number(.fontSize, d.fontSize)
        lineSpacing = number(.lineSpacing, d.lineSpacing)
        horizontalMargin = number(.horizontalMargin, d.horizontalMargin)
        paragraphSpacing = number(.paragraphSpacing, d.paragraphSpacing)
        alignment = value(.alignment, d.alignment)
        boldText = (try? c.decodeIfPresent(Bool.self, forKey: .boldText)).flatMap { $0 } ?? d.boldText
        headingScale = number(.headingScale, d.headingScale)
        tracking = number(.tracking, d.tracking)
        theme = value(.theme, d.theme)
        stamp = (try? c.decodeIfPresent(Int.self, forKey: .stamp)).flatMap { $0 } ?? 0
        self = clamped()
    }

    // MARK: Serialisation

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self.clamped())
    }

    public static func decode(_ data: Data) -> ReaderTypography? {
        try? JSONDecoder().decode(ReaderTypography.self, from: data)
    }

    public static func decode(json: String) -> ReaderTypography? {
        decode(Data(json.utf8))
    }

    public func jsonString() -> String? {
        encoded().flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Equality ignoring `stamp`: "does this look different?".
    public func sameLook(as other: ReaderTypography) -> Bool {
        var a = self, b = other
        a.stamp = 0; b.stamp = 0
        return a == b
    }
}

// MARK: - Presets

extension ReaderTypography {
    public enum Preset: String, CaseIterable, Sendable {
        case standard, compact, comfortable, largePrint, night

        public var title: String {
            switch self {
            case .standard: return "Standard"
            case .compact: return "Compact"
            case .comfortable: return "Comfortable"
            case .largePrint: return "Large print"
            case .night: return "Night"
            }
        }
    }

    /// The preset's look. Keeps the user's font size for presets that do not define one, and the `stamp`
    /// is left for the caller to set.
    public func applying(_ preset: Preset) -> ReaderTypography {
        var t = self
        switch preset {
        case .standard:
            t = ReaderTypography(fontFamily: .system, fontSize: fontSize)
        case .compact:
            t = ReaderTypography(fontFamily: .system, fontSize: max(Self.fontSizeRange.lowerBound, fontSize - 2),
                                 lineSpacing: 0, horizontalMargin: 2, paragraphSpacing: 6, headingScale: 0.8)
        case .comfortable:
            t = ReaderTypography(fontFamily: .serif, fontSize: fontSize, lineSpacing: 3,
                                 horizontalMargin: 6, paragraphSpacing: 14, headingScale: 1.1)
        case .largePrint:
            t = ReaderTypography(fontFamily: .system, fontSize: 22, lineSpacing: 2, horizontalMargin: 4,
                                 paragraphSpacing: 14, boldText: true, headingScale: 1, theme: .highContrast)
        case .night:
            t = ReaderTypography(fontFamily: .serif, fontSize: fontSize, lineSpacing: 2,
                                 horizontalMargin: 6, paragraphSpacing: 12, theme: .dim)
        }
        t.stamp = stamp
        return t.clamped()
    }
}

// MARK: - Style mapping

/// Resolved, platform-neutral style of one block. The UI maps it to SwiftUI `Font` etc.
public struct BlockStyleSpec: Equatable, Sendable {
    public var pointSize: Double
    public var bold: Bool
    public var italic: Bool
    /// Leading indent in points (quotes).
    public var indent: Double
    public var topPadding: Double
    public var isHeading: Bool
    public var showsBullet: Bool
    /// Quotes use a slightly dimmer foreground.
    public var dimmed: Bool
}

extension BlockStyle {
    /// Size multiplier of a style relative to body text at `headingScale == 1`.
    public var baseScale: Double {
        switch self {
        case .heading1: return 1.35
        case .heading2: return 1.25
        case .heading3: return 1.15
        case .heading4, .heading5, .heading6: return 1.05
        case .paragraph, .quote, .listItem: return 1.0
        }
    }

    public var isHeading: Bool {
        switch self {
        case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6: return true
        default: return false
        }
    }
}

extension ReaderTypography {
    /// Style of a block under these settings. Pure; unit-tested.
    public func spec(for style: BlockStyle) -> BlockStyleSpec {
        let t = clamped()
        let heading = style.isHeading
        // headingScale stretches the *excess* over body size, so 0 flattens headings and 1 is the original.
        let scale = heading ? 1 + (style.baseScale - 1) * t.headingScale : 1
        return BlockStyleSpec(
            pointSize: (t.fontSize * scale * 10).rounded() / 10,
            bold: heading || t.boldText || t.theme == .highContrast,
            italic: style == .quote,
            indent: style == .quote ? 8 : 0,
            topPadding: heading ? 6 : 0,
            isHeading: heading,
            showsBullet: style == .listItem,
            dimmed: style == .quote)
    }

    /// Identity of everything that changes how a block is *drawn* (not its text); `stamp` excluded.
    /// Views use it as the cache/equality key.
    public var renderKey: String {
        let t = clamped()
        return [t.fontFamily.rawValue, "\(t.fontSize)", "\(t.lineSpacing)", "\(t.horizontalMargin)",
                "\(t.paragraphSpacing)", t.alignment.rawValue, "\(t.boldText)", "\(t.headingScale)",
                "\(t.tracking)", t.theme.rawValue].joined(separator: "|")
    }
}

// MARK: - Theme colours

public struct ThemePalette: Equatable, Sendable {
    /// sRGB components 0...1.
    public struct RGB: Equatable, Sendable {
        public var r: Double, g: Double, b: Double
        public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        public init(hex: Int) {
            self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
        /// WCAG relative luminance.
        public var luminance: Double {
            func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
    }
    public var background: RGB
    public var text: RGB
    public var secondaryText: RGB

    /// WCAG contrast ratio of text over background.
    public var contrastRatio: Double {
        let a = text.luminance, b = background.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension ReaderTypography.Theme {
    public var palette: ThemePalette {
        switch self {
        case .dark:
            return ThemePalette(background: .init(0, 0, 0), text: .init(1, 1, 1), secondaryText: .init(0.85, 0.85, 0.85))
        case .dim:
            return ThemePalette(background: .init(0, 0, 0), text: .init(hex: 0xB8B8B8), secondaryText: .init(hex: 0x9A9A9A))
        case .sepia:
            return ThemePalette(background: .init(hex: 0xF4ECD8), text: .init(hex: 0x3B2A1A), secondaryText: .init(hex: 0x5B4636))
        case .highContrast:
            return ThemePalette(background: .init(0, 0, 0), text: .init(1, 1, 1), secondaryText: .init(1, 1, 1))
        }
    }

    public var title: String {
        switch self {
        case .dark: return "Dark"
        case .dim: return "Dim"
        case .sepia: return "Sepia"
        case .highContrast: return "High contrast"
        }
    }
}

extension ReaderTypography.FontFamily {
    public var title: String {
        switch self {
        case .system: return "SF"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .monospaced: return "Mono"
        }
    }
}

extension ReaderTypography.Alignment {
    public var title: String { self == .leading ? "Left" : "Center" }
}
