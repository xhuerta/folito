import UIKit
import XCTest
import ReaderCore
@testable import Folito

/// The app's own text colours (`UIColor.secondaryText`, `UIColor.destructiveText`) must reach WCAG AA 4.5:1 on
/// every system background they can appear on, in light and dark mode, with and without Increase Contrast.
final class SecondaryTextContrastTests: XCTestCase {
    private typealias RGB = ThemePalette.RGB

    private static let backgrounds: [(String, UIColor)] = [
        ("systemBackground", .systemBackground),
        ("secondarySystemBackground", .secondarySystemBackground),
        ("systemGroupedBackground", .systemGroupedBackground),
        ("secondarySystemGroupedBackground", .secondarySystemGroupedBackground),
        ("tertiarySystemGroupedBackground", .tertiarySystemGroupedBackground),
    ]

    private static let traitSets: [(String, UITraitCollection)] = {
        var result: [(String, UITraitCollection)] = []
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                for level in [UIUserInterfaceLevel.base, .elevated] {
                    let traits = UITraitCollection(mutations: { mutable in
                        mutable.userInterfaceStyle = style
                        mutable.accessibilityContrast = contrast
                        mutable.userInterfaceLevel = level
                    })
                    let name = "\(style == .dark ? "dark" : "light")\(contrast == .high ? "+increased" : "")"
                        + "\(level == .elevated ? "+elevated" : "")"
                    result.append((name, traits))
                }
            }
        }
        return result
    }()

    private static let appTextColors: [(String, UIColor)] = [("secondaryText", .secondaryText),
                                                             ("destructiveText", .destructiveText)]

    func testAppTextColorsMeetAAOnEverySystemBackground() {
        for (colorName, color) in Self.appTextColors {
            for (traitName, traits) in Self.traitSets {
                let text = Self.rgb(color, traits, over: RGB(1, 1, 1))
                for (name, background) in Self.backgrounds {
                    let bg = Self.rgb(background, traits, over: RGB(0, 0, 0))
                    let ratio = RGB.contrast(text, bg)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(colorName) on \(name), \(traitName): \(ratio)")
                }
            }
        }
    }

    func testIncreaseContrastMovesFurtherFromTheBackground() {
        for (colorName, color) in Self.appTextColors {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let normal = UITraitCollection(mutations: { $0.userInterfaceStyle = style; $0.accessibilityContrast = .normal })
                let high = UITraitCollection(mutations: { $0.userInterfaceStyle = style; $0.accessibilityContrast = .high })
                let bg = Self.rgb(.systemBackground, normal, over: RGB(0, 0, 0))
                XCTAssertGreaterThan(RGB.contrast(Self.rgb(color, high, over: bg), bg),
                                     RGB.contrast(Self.rgb(color, normal, over: bg), bg), colorName)
            }
        }
    }

    /// The reason the app does not colour its own text with the system's `secondaryLabel`: it is below 4.5:1
    /// on the light grouped background (documented in docs/ACCESSIBILITY.md).
    func testSystemSecondaryLabelIsBelowAAOnLightGroupedBackground() {
        let light = UITraitCollection(mutations: { $0.userInterfaceStyle = .light; $0.accessibilityContrast = .normal })
        let bg = Self.rgb(.systemGroupedBackground, light, over: RGB(1, 1, 1))
        let label = Self.rgb(.secondaryLabel, light, over: bg)
        XCTAssertLessThan(RGB.contrast(label, bg), 4.5)
    }

    /// Resolves a (possibly translucent) colour for `traits` and composites it over `base`.
    private static func rgb(_ color: UIColor, _ traits: UITraitCollection, over base: RGB) -> RGB {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        func mix(_ c: CGFloat, _ under: Double) -> Double { Double(c) * Double(a) + under * (1 - Double(a)) }
        return RGB(mix(r, base.r), mix(g, base.g), mix(b, base.b))
    }
}
