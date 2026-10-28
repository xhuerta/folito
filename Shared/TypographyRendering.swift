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

/// Everything the block views need, derived once per typography change (fonts are built here, not per
/// block per render). Equality is by `ReaderTypography.renderKey`, so unrelated state changes do not
/// invalidate block views.
struct ReaderRenderStyle: Equatable {
    let key: String
    let typography: ReaderTypography
    let background: Color
    let textColor: Color
    let secondaryColor: Color
    let alignment: TextAlignment
    let frameAlignment: Alignment
    private let fonts: [BlockStyle: Font]
    private let specs: [BlockStyle: BlockStyleSpec]

    static let allStyles: [BlockStyle] = [.paragraph, .heading1, .heading2, .heading3, .heading4, .heading5,
                                          .heading6, .quote, .listItem]

    init(_ typography: ReaderTypography) {
        let t = typography.clamped()
        self.typography = t
        key = t.renderKey
        let palette = t.theme.palette
        background = palette.background.color
        textColor = palette.text.color
        secondaryColor = palette.secondaryText.color
        alignment = t.alignment == .center ? .center : .leading
        frameAlignment = t.alignment == .center ? .center : .leading
        var fonts: [BlockStyle: Font] = [:]
        var specs: [BlockStyle: BlockStyleSpec] = [:]
        for style in Self.allStyles {
            let spec = t.spec(for: style)
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
                    Text("\u{2022}")
                    base
                }
            } else {
                base
            }
        }
        content
            .font(font)
            .lineSpacing(style.typography.lineSpacing)
            .multilineTextAlignment(style.alignment)
            .foregroundStyle(spec.dimmed ? style.secondaryColor : style.textColor)
            .padding(.leading, spec.indent)
            .padding(.top, spec.topPadding)
            .frame(maxWidth: .infinity, alignment: style.frameAlignment)
    }
}

/// Small sample page used for live previews (iPhone settings and watch editor).
struct TypographyPreview: View {
    let typography: ReaderTypography

    private static let sample: [Block] = [
        Block(text: "Chapter One", style: .heading1, xpointer: "", globalOffset: -1),
        Block(text: "It was a bright cold day in April, and the clocks were striking thirteen.",
              spans: [StyleSpan(location: 9, length: 6, bold: true, italic: false),
                      StyleSpan(location: 16, length: 4, bold: false, italic: true)],
              xpointer: "", globalOffset: -2),
        Block(text: "\u{201C}Words on the wrist,\u{201D} he said.", style: .quote, xpointer: "", globalOffset: -3),
    ]

    var body: some View {
        let style = ReaderRenderStyle(typography)
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
