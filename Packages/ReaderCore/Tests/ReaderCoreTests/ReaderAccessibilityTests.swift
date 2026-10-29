import XCTest
@testable import ReaderCore

/// WCAG contrast of every reader theme, the Increase Contrast / Always On variants, and the typography
/// fields that follow the system's accessibility settings.
final class ReaderAccessibilityTests: XCTestCase {
    private typealias RGB = ThemePalette.RGB

    // MARK: Contrast

    func testContrastFormulaReferenceValues() {
        XCTAssertEqual(RGB.contrast(RGB(0, 0, 0), RGB(1, 1, 1)), 21, accuracy: 0.001)
        XCTAssertEqual(RGB.contrast(RGB(1, 1, 1), RGB(1, 1, 1)), 1, accuracy: 0.001)
        // Symmetric.
        XCTAssertEqual(RGB.contrast(RGB(hex: 0x3B2A1A), RGB(hex: 0xF4ECD8)),
                       RGB.contrast(RGB(hex: 0xF4ECD8), RGB(hex: 0x3B2A1A)), accuracy: 1e-12)
        // #767676 on white is the well-known 4.54:1 AA boundary grey.
        XCTAssertEqual(RGB.contrast(RGB(hex: 0x767676), RGB(1, 1, 1)), 4.54, accuracy: 0.01)
    }

    /// Body text, secondary text (quotes) and accent (links / glyphs on the page) all reach WCAG AA
    /// (4.5:1) in every theme; body text in the standard palettes reaches AAA (7:1).
    func testEveryThemeMeetsAA() {
        for theme in ReaderTypography.Theme.allCases {
            let p = theme.palette
            XCTAssertGreaterThanOrEqual(p.contrastRatio, 7.0, "\(theme) body text")
            XCTAssertGreaterThanOrEqual(p.secondaryContrastRatio, 4.5, "\(theme) secondary text")
            XCTAssertGreaterThanOrEqual(p.accentContrastRatio, 4.5, "\(theme) accent")
        }
    }

    func testIncreasedContrastVariantsAreAtLeastAsStrong() {
        for theme in ReaderTypography.Theme.allCases {
            let base = theme.palette, high = theme.increasedContrastPalette
            XCTAssertEqual(high.background, base.background, "\(theme) keeps its background")
            XCTAssertGreaterThanOrEqual(high.contrastRatio, base.contrastRatio, "\(theme) body")
            XCTAssertGreaterThanOrEqual(high.secondaryContrastRatio, base.secondaryContrastRatio, "\(theme) secondary")
            XCTAssertGreaterThanOrEqual(high.accentContrastRatio, base.accentContrastRatio, "\(theme) accent")
            XCTAssertGreaterThanOrEqual(high.contrastRatio, 7.0, "\(theme) body AAA")
            XCTAssertGreaterThanOrEqual(high.secondaryContrastRatio, 7.0, "\(theme) secondary AAA")
            XCTAssertGreaterThanOrEqual(high.accentContrastRatio, 7.0, "\(theme) accent AAA")
        }
        XCTAssertEqual(ReaderTypography.Theme.dark.increasedContrastPalette.contrastRatio, 21, accuracy: 0.01)
    }

    func testAlwaysOnPaletteIsDarkButStillReadable() {
        let p = ThemePalette.alwaysOn
        XCTAssertEqual(p.background, RGB(0, 0, 0))
        XCTAssertGreaterThanOrEqual(p.contrastRatio, 4.5)
        XCTAssertGreaterThanOrEqual(p.secondaryContrastRatio, 4.5)
        XCTAssertGreaterThanOrEqual(p.accentContrastRatio, 4.5)
        // Dimmer than the normal dark theme.
        XCTAssertLessThan(p.text.luminance, ReaderTypography.Theme.dark.palette.text.luminance)
    }

    func testPaletteSelection() {
        let sepia = ReaderTypography.Theme.sepia
        XCTAssertEqual(sepia.palette(for: .none), sepia.palette)
        XCTAssertEqual(sepia.palette(for: ReaderAccessibility(increaseContrast: true)), sepia.increasedContrastPalette)
        XCTAssertEqual(sepia.palette(for: ReaderAccessibility(luminanceReduced: true)), .alwaysOn)
        XCTAssertEqual(sepia.palette(for: ReaderAccessibility(increaseContrast: true, luminanceReduced: true)), .alwaysOn)
    }

    /// Prints the table used in docs/ACCESSIBILITY.md (visible with `swift test -v`).
    func testPrintContrastTable() {
        func f(_ x: Double) -> String { String(format: "%.1f", x) }
        for theme in ReaderTypography.Theme.allCases {
            for (name, p) in [("standard", theme.palette), ("increased", theme.increasedContrastPalette)] {
                print("contrast \(theme.rawValue) \(name): text \(f(p.contrastRatio)) secondary \(f(p.secondaryContrastRatio)) accent \(f(p.accentContrastRatio))")
            }
        }
        let a = ThemePalette.alwaysOn
        print("contrast alwaysOn: text \(f(a.contrastRatio)) secondary \(f(a.secondaryContrastRatio)) accent \(f(a.accentContrastRatio))")
    }

    // MARK: Bold Text / Dynamic Type

    func testSystemBoldTextMakesBodyBold() {
        let t = ReaderTypography.default
        XCTAssertFalse(t.spec(for: .paragraph).bold)
        XCTAssertTrue(t.spec(for: .paragraph, accessibility: ReaderAccessibility(boldText: true)).bold)
        XCTAssertTrue(t.spec(for: .quote, accessibility: ReaderAccessibility(boldText: true)).bold)
    }

    func testTextScaleIgnoredUnlessMatchingSystemSize() {
        let t = ReaderTypography.default
        XCTAssertFalse(t.matchSystemTextSize)
        XCTAssertEqual(t.effectiveFontSize(textScale: 1.5), 16)
        XCTAssertEqual(t.spec(for: .paragraph, accessibility: ReaderAccessibility(textScale: 2)).pointSize, 16)
    }

    func testMatchingSystemSizeScalesAndClamps() {
        var t = ReaderTypography.default
        t.matchSystemTextSize = true
        XCTAssertEqual(t.effectiveFontSize(textScale: 1), 16)
        XCTAssertEqual(t.effectiveFontSize(textScale: 1.25), 20)
        XCTAssertEqual(t.effectiveFontSize(textScale: 1.13), 18) // 18.08 rounded to 0.5 pt
        XCTAssertEqual(t.effectiveFontSize(textScale: 10), ReaderTypography.systemScaledFontSizeRange.upperBound)
        XCTAssertEqual(t.effectiveFontSize(textScale: 0.1), ReaderTypography.systemScaledFontSizeRange.lowerBound)
        XCTAssertEqual(t.effectiveFontSize(textScale: .nan), 16)
        XCTAssertEqual(t.effectiveFontSize(textScale: 0), 16)
        let a = ReaderAccessibility(textScale: 1.25)
        XCTAssertEqual(t.spec(for: .paragraph, accessibility: a).pointSize, 20)
        XCTAssertEqual(t.spec(for: .heading1, accessibility: a).pointSize, 27)  // 20 * 1.35
        // The stored size is the user's own and stays within the stepper range.
        XCTAssertEqual(t.fontSize, 16)
    }

    func testSpecWithoutAccessibilityIsUnchanged() {
        for style in [BlockStyle.paragraph, .heading1, .heading4, .quote, .listItem] {
            XCTAssertEqual(ReaderTypography.default.spec(for: style),
                           ReaderTypography.default.spec(for: style, accessibility: .none))
        }
    }

    // MARK: Model migration (version 2: matchSystemTextSize)

    func testVersion1DataDecodesWithMatchOff() throws {
        let v1 = #"{"alignment":"leading","boldText":true,"fontFamily":"serif","fontSize":20,"headingScale":1,"horizontalMargin":4,"lineSpacing":0,"paragraphSpacing":10,"stamp":42,"theme":"sepia","tracking":0,"version":1}"#
        let t = try XCTUnwrap(ReaderTypography.decode(json: v1))
        XCTAssertFalse(t.matchSystemTextSize)
        XCTAssertEqual(t.version, 2)
        XCTAssertEqual(t.fontFamily, .serif)
        XCTAssertEqual(t.fontSize, 20)
        XCTAssertEqual(t.theme, .sepia)
        XCTAssertEqual(t.stamp, 42)
    }

    func testMatchSystemTextSizeRoundTripsAndToleratesBadValues() throws {
        var t = ReaderTypography.default
        t.matchSystemTextSize = true
        t.stamp = 7
        let json = try XCTUnwrap(t.jsonString())
        XCTAssertTrue(json.contains(#""matchSystemTextSize":true"#))
        XCTAssertTrue(json.contains(#""version":2"#))
        XCTAssertEqual(ReaderTypography.decode(json: json), t)
        XCTAssertEqual(ReaderTypography.decode(json: #"{"matchSystemTextSize":"yes"}"#)?.matchSystemTextSize, false)
        XCTAssertEqual(ReaderTypography.decode(json: #"{"matchSystemTextSize":true,"version":99}"#)?.matchSystemTextSize, true)
    }

    func testMatchSystemTextSizeIsPartOfTheLook() {
        var a = ReaderTypography.default
        var b = a
        b.matchSystemTextSize = true
        XCTAssertNotEqual(a.renderKey, b.renderKey)
        XCTAssertFalse(a.sameLook(as: b))
        a.matchSystemTextSize = true
        XCTAssertTrue(a.sameLook(as: b))
    }

    func testPresetsKeepMatchSystemTextSize() {
        var t = ReaderTypography.default
        t.matchSystemTextSize = true
        for preset in ReaderTypography.Preset.allCases {
            XCTAssertTrue(t.applying(preset).matchSystemTextSize, "\(preset)")
        }
    }

    func testWireFormatCarriesTheField() throws {
        var t = ReaderTypography.default
        t.matchSystemTextSize = true
        t.stamp = 100
        let back = try XCTUnwrap(TypographySync.decode(from: TypographySync.context(for: t)))
        XCTAssertTrue(back.matchSystemTextSize)
    }
}
