import SwiftUI
import ReaderCore

// SwiftUI mapping of `ReaderTypography`. Compiled into both the watch and the iPhone app so the iPhone's
// live preview renders exactly what the watch reader renders. The numeric decisions live in ReaderCore
// (`ReaderTypography.spec(for:)`, `ThemePalette`) where they are unit-tested on Linux.

extension ReaderTypography.FontFamily {
    var design: Font.Design {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        }
    }
}

extension ThemePalette.RGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}

/// Everything the block views need, derived once per typography / accessibility change (fonts are built
/// here, not per block per render). Equality is by `key` (`ReaderTypography.renderKey` plus the
/// accessibility state), so unrelated state changes do not invalidate block views.
struct ReaderRenderStyle: Equatable {
    let key: String
    /// Part of `key` that changes line breaks (sizes, weights, spacing). Colour-only changes such as Always
    /// On or Increase Contrast keep it, so the reader does not need to re-anchor its scroll position.
    let layoutKey: String
    let typography: ReaderTypography
    let accessibility: ReaderAccessibility
    let background: Color
    let textColor: Color
    let secondaryColor: Color
    /// Links and glyphs drawn over the page (meets 4.5:1 against `background` in every theme).
    let accentColor: Color
    let alignment: TextAlignment
    let frameAlignment: Alignment
    private let fonts: [BlockStyle: Font]
    private let specs: [BlockStyle: BlockStyleSpec]

    static let allStyles: [BlockStyle] = [.paragraph, .heading1, .heading2, .heading3, .heading4, .heading5,
                                          .heading6, .quote, .listItem]

    init(_ typography: ReaderTypography, accessibility: ReaderAccessibility = .none) {
        let t = typography.clamped()
        self.typography = t
        self.accessibility = accessibility
        layoutKey = t.renderKey + "|\(t.effectiveFontSize(textScale: accessibility.textScale))|\(accessibility.boldText)"
        key = layoutKey + "|\(accessibility.increaseContrast)|\(accessibility.luminanceReduced)"
        let palette = t.theme.palette(for: accessibility)
        background = palette.background.color
        textColor = palette.text.color
        secondaryColor = palette.secondaryText.color
        accentColor = palette.accent.color
        alignment = t.alignment == .center ? .center : .leading
        frameAlignment = t.alignment == .center ? .center : .leading
        var fonts: [BlockStyle: Font] = [:]
        var specs: [BlockStyle: BlockStyleSpec] = [:]
        for style in Self.allStyles {
            let spec = t.spec(for: style, accessibility: accessibility)
            let weight: Font.Weight = spec.isHeading ? .bold : (spec.bold ? .semibold : .regular)
            var font = Font.system(size: spec.pointSize, weight: weight, design: t.fontFamily.design)
            if spec.italic { font = font.italic() }
            fonts[style] = font
            specs[style] = spec
        }
        self.fonts = fonts
        self.specs = specs
    }

    static func == (a: ReaderRenderStyle, b: ReaderRenderStyle) -> Bool { a.key == b.key }

    func font(for style: BlockStyle) -> Font { fonts[style] ?? .body }
    func spec(for style: BlockStyle) -> BlockStyleSpec { specs[style] ?? ReaderTypography.default.spec(for: style) }

    /// Light page (sepia) or dark page: drives `preferredColorScheme` so system chrome over the page
    /// (toolbar glyphs, `.secondary`) adapts. Always On is always dark.
    var isLightPage: Bool { typography.theme.palette(for: accessibility).background.luminance > 0.5 }

    /// VoiceOver heading level of a block (nil for non-headings), so the rotor can jump between headings.
    static func headingLevel(for style: BlockStyle) -> AccessibilityHeadingLevel? {
        switch style {
        case .heading1: return .h1
        case .heading2: return .h2
        case .heading3: return .h3
        case .heading4: return .h4
        case .heading5: return .h5
        case .heading6: return .h6
        case .paragraph, .quote, .listItem: return nil
        }
    }
}

/// Reads the accessibility settings that change how reader text is drawn from the SwiftUI environment:
/// Dynamic Type (as a body-text scale), Bold Text, Increase Contrast and reduced luminance (Always On).
/// Declare it as a stored property of a view (`private var readerAccessibility = ReaderAccessibilityReader()`)
/// so SwiftUI installs its environment values, then read `readerAccessibility.value` in `body`.
struct ReaderAccessibilityReader: DynamicProperty {
    /// 100 at the default text size; scales with the system text size like body text does.
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 100
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var value: ReaderAccessibility {
        ReaderAccessibility(textScale: Double(bodyScale) / 100,
                            boldText: legibilityWeight == .bold,
                            increaseContrast: colorSchemeContrast == .increased,
                            luminanceReduced: isLuminanceReduced)
    }
}

/// Bounded cache of the styled `AttributedString` of each block. It depends only on the block's text and
/// spans (fonts are applied by modifiers), so changing typography never rebuilds it.
final class AttributedBlockCache: @unchecked Sendable {
    static let shared = AttributedBlockCache()

    private final class Box { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    private let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 400
        return c
    }()

    func attributed(for block: Block) -> AttributedString {
        let key = "\(block.globalOffset)|\(block.text.utf16.count)|\(block.spans.count)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = BlockText.attributed(text: block.text, spans: block.spans)
        cache.setObject(Box(value), forKey: key)
        return value
    }

    func removeAll() { cache.removeAllObjects() }
}

/// One block of the book, drawn with a `ReaderRenderStyle`. Equatable so `.equatable()` skips re-rendering
/// when only unrelated parent state changed.
struct BlockStyledText: View, Equatable {
    let block: Block
    let style: ReaderRenderStyle

    var body: some View {
        let spec = style.spec(for: block.style)
        let font = style.font(for: block.style)
        let base = Text(AttributedBlockCache.shared.attributed(for: block))
            .tracking(style.typography.tracking)
        let content = Group {
            if spec.showsBullet {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // Decorative: VoiceOver reads the item's text only.
                    Text(verbatim: "\u{2022}").accessibilityHidden(true)
                    base
                }
            } else {
                base
            }
        }
        content
            // One VoiceOver element per block (the bullet and the text are read together).
            .accessibilityElement(children: .combine)
            .modifier(HeadingAccessibility(level: ReaderRenderStyle.headingLevel(for: block.style)))
            .font(font)
            .lineSpacing(style.typography.lineSpacing)
            .multilineTextAlignment(style.alignment)
            .foregroundStyle(spec.dimmed ? style.secondaryColor : style.textColor)
            .padding(.leading, spec.indent)
            .padding(.top, spec.topPadding)
            .frame(maxWidth: .infinity, alignment: style.frameAlignment)
    }
}

/// Marks heading blocks with the header trait and their level (VoiceOver rotor "Headings").
private struct HeadingAccessibility: ViewModifier {
    let level: AccessibilityHeadingLevel?

    func body(content: Content) -> some View {
        if let level {
            content
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(level)
        } else {
            content
        }
    }
}

/// Small sample page used for live previews (iPhone settings and watch editor).
struct TypographyPreview: View {
    let typography: ReaderTypography
    /// The watch passes its own accessibility state so the preview matches its reader; the iPhone keeps
    /// `.none` (its settings are not the watch's).
    var accessibility: ReaderAccessibility = .none

    /// Localized sample text. The emphasized words are looked up in the translated sentence, so a
    /// translation only has to contain them verbatim (otherwise the sentence is shown without emphasis).
    private static let sample: [Block] = {
        let heading = String(localized: "Chapter One",
                             comment: "Typography preview: sample chapter heading")
        let sentence = String(localized: "It was a bright cold day in April, and the clocks were striking thirteen.",
                              comment: "Typography preview: sample paragraph (opening line of Orwell's 1984; use the published translation if there is one). Must contain the words translated for 'bright' and 'cold' exactly as written there.")
        let boldWord = String(localized: "bright",
                              comment: "Typography preview: the word of the sample paragraph shown in bold. Must appear exactly like this in the translated sample paragraph.")
        let italicWord = String(localized: "cold",
                                comment: "Typography preview: the word of the sample paragraph shown in italics. Must appear exactly like this in the translated sample paragraph.")
        let quote = String(localized: "\u{201C}Words on the wrist,\u{201D} he said.",
                           comment: "Typography preview: sample quotation; use the quotation marks of your language")
        let spans = [span(of: boldWord, in: sentence, bold: true, italic: false),
                     span(of: italicWord, in: sentence, bold: false, italic: true)].compactMap { $0 }
        return [
            Block(text: heading, style: .heading1, xpointer: "", globalOffset: -1),
            Block(text: sentence, spans: spans, xpointer: "", globalOffset: -2),
            Block(text: quote, style: .quote, xpointer: "", globalOffset: -3),
        ]
    }()

    /// UTF-16 range of `word` in `text` as a style span (nil when the translation does not contain it).
    private static func span(of word: String, in text: String, bold: Bool, italic: Bool) -> StyleSpan? {
        let range = (text as NSString).range(of: word)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return StyleSpan(location: range.location, length: range.length, bold: bold, italic: italic)
    }

    var body: some View {
        let style = ReaderRenderStyle(typography, accessibility: accessibility)
        VStack(alignment: .leading, spacing: style.typography.paragraphSpacing) {
            ForEach(Array(Self.sample.enumerated()), id: \.offset) { _, block in
                BlockStyledText(block: block, style: style)
            }
        }
        .padding(.horizontal, style.typography.horizontalMargin)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.background)
    }
}
