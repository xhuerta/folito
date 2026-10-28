import Foundation

/// User-configurable reader typography. Pure value type shared by the watch (renders and stores it) and
/// the iPhone (edits it and mirrors it to the watch). Every field is clamped by `clamped()` and decoding
/// is tolerant: unknown / missing / out-of-range values fall back to defaults instead of failing.
public struct ReaderTypography: Codable, Equatable, Sendable {
    /// 1: original fields. 2: `matchSystemTextSize` (missing in v1 data -> false).
    public static let currentVersion = 2

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
    /// Body size range once the system text size (Dynamic Type) is applied with `matchSystemTextSize`.
    /// Wider than `fontSizeRange` so accessibility sizes can go beyond what the size stepper offers.
    public static let systemScaledFontSizeRange: ClosedRange<Double> = 10...40

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
    /// Scale the reader's body size with the device's system text size (Dynamic Type). `fontSize` stays
    /// the user's size at the default system text size. Added in version 2.
    public var matchSystemTextSize: Bool
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
                matchSystemTextSize: Bool = false,
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
        self.matchSystemTextSize = matchSystemTextSize
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
        case alignment, boldText, headingScale, tracking, theme, matchSystemTextSize, stamp
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
        matchSystemTextSize = (try? c.decodeIfPresent(Bool.self, forKey: .matchSystemTextSize)).flatMap { $0 }
            ?? d.matchSystemTextSize
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
        // A preset is a look; whether text follows the system size is an accessibility choice, so keep it.
        t.matchSystemTextSize = matchSystemTextSize
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
        spec(for: style, accessibility: .none)
    }

    /// Body size after the system text size: `fontSize` unless `matchSystemTextSize` is on, in which case
    /// it is scaled by `textScale` (system body size / default body size) within
    /// `systemScaledFontSizeRange`. Rounded to 0.5 pt so tiny metric changes do not re-lay out the book.
    public func effectiveFontSize(textScale: Double) -> Double {
        let t = clamped()
        guard t.matchSystemTextSize, textScale.isFinite, textScale > 0 else { return t.fontSize }
        let scaled = Self.clamp(t.fontSize * textScale, Self.systemScaledFontSizeRange, fallback: t.fontSize)
        return (scaled * 2).rounded() / 2
    }

    /// Style of a block under these settings and the device's accessibility settings. Pure; unit-tested.
    public func spec(for style: BlockStyle, accessibility: ReaderAccessibility) -> BlockStyleSpec {
        let t = clamped()
        let heading = style.isHeading
        // headingScale stretches the *excess* over body size, so 0 flattens headings and 1 is the original.
        let scale = heading ? 1 + (style.baseScale - 1) * t.headingScale : 1
        let body = t.effectiveFontSize(textScale: accessibility.textScale)
        return BlockStyleSpec(
            pointSize: (body * scale * 10).rounded() / 10,
            bold: heading || t.boldText || t.theme == .highContrast || accessibility.boldText,
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
                "\(t.tracking)", t.theme.rawValue, "\(t.matchSystemTextSize)"].joined(separator: "|")
    }
}

// MARK: - Accessibility inputs

/// Device accessibility state that changes how the reader draws text. Platform-neutral so the mapping is
/// unit-tested here; the apps fill it from the SwiftUI environment (Dynamic Type, Bold Text, Increase
/// Contrast, Always On).
public struct ReaderAccessibility: Equatable, Sendable {
    /// System body text size divided by the default body size (1 = default Dynamic Type size). Only used
    /// when `ReaderTypography.matchSystemTextSize` is on.
    public var textScale: Double
    /// System Bold Text setting.
    public var boldText: Bool
    /// System Increase Contrast setting: use the theme's high-contrast colours.
    public var increaseContrast: Bool
    /// Always On display with the wrist down (reduced luminance): dim, simplified colours.
    public var luminanceReduced: Bool

    public init(textScale: Double = 1, boldText: Bool = false, increaseContrast: Bool = false,
                luminanceReduced: Bool = false) {
        self.textScale = textScale
        self.boldText = boldText
        self.increaseContrast = increaseContrast
        self.luminanceReduced = luminanceReduced
    }

    public static let none = ReaderAccessibility()
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

        /// WCAG 2.x contrast ratio between two colours (1...21, symmetric).
        public static func contrast(_ x: RGB, _ y: RGB) -> Double {
            let a = x.luminance, b = y.luminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }
    public var background: RGB
    public var text: RGB
    /// Quotes and other de-emphasised text.
    public var secondaryText: RGB
    /// Tint for links and controls drawn over the reader background (e.g. the sync status glyph).
    public var accent: RGB

    /// WCAG contrast ratio of text over background.
    public var contrastRatio: Double { RGB.contrast(text, background) }
    public var secondaryContrastRatio: Double { RGB.contrast(secondaryText, background) }
    public var accentContrastRatio: Double { RGB.contrast(accent, background) }

    /// The dimmed palette used while the Always On display has reduced luminance: black background and
    /// grey text whatever the theme (a light sepia page would light up the whole screen).
    public static let alwaysOn = ThemePalette(background: .init(0, 0, 0), text: .init(hex: 0xA6A6A6),
                                              secondaryText: .init(hex: 0x8C8C8C), accent: .init(hex: 0x6E9FCF))
}

extension ReaderTypography.Theme {
    /// Watch accent colour (AccentColor asset, #4DA6FF): 8.2:1 on black.
    private static let accentOnBlack = ThemePalette.RGB(hex: 0x4DA6FF)

    public var palette: ThemePalette {
        switch self {
        case .dark:
            return ThemePalette(background: .init(0, 0, 0), text: .init(1, 1, 1),
                                secondaryText: .init(0.85, 0.85, 0.85), accent: Self.accentOnBlack)
        case .dim:
            return ThemePalette(background: .init(0, 0, 0), text: .init(hex: 0xB8B8B8),
                                secondaryText: .init(hex: 0x9A9A9A), accent: .init(hex: 0x5A9BD8))
        case .sepia:
            return ThemePalette(background: .init(hex: 0xF4ECD8), text: .init(hex: 0x3B2A1A),
                                secondaryText: .init(hex: 0x5B4636), accent: .init(hex: 0x0B4F8A))
        case .highContrast:
            return ThemePalette(background: .init(0, 0, 0), text: .init(1, 1, 1),
                                secondaryText: .init(1, 1, 1), accent: .init(hex: 0x8CC8FF))
        }
    }

    /// Variant used when the system Increase Contrast setting is on: same character (dark stays dark,
    /// sepia stays sepia) with stronger text and accent colours.
    public var increasedContrastPalette: ThemePalette {
        switch self {
        case .dark, .highContrast:
            return ReaderTypography.Theme.highContrast.palette
        case .dim:
            return ThemePalette(background: .init(0, 0, 0), text: .init(hex: 0xE0E0E0),
                                secondaryText: .init(hex: 0xCCCCCC), accent: .init(hex: 0x8CC8FF))
        case .sepia:
            return ThemePalette(background: .init(hex: 0xF4ECD8), text: .init(hex: 0x1C1209),
                                secondaryText: .init(hex: 0x3B2A1A), accent: .init(hex: 0x063761))
        }
    }

    /// Palette for the current accessibility state. Always On wins over Increase Contrast.
    public func palette(for accessibility: ReaderAccessibility) -> ThemePalette {
        if accessibility.luminanceReduced { return .alwaysOn }
        return accessibility.increaseContrast ? increasedContrastPalette : palette
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
