import SwiftUI
import UIKit

extension UIColor {
    /// Colour for supporting text the app styles itself (author line, file size, watch state, slider values,
    /// sync explanations).
    ///
    /// The system's `secondaryLabel` (60% gray) is only about 3.5:1 on white and 3.2:1 on the grouped
    /// background, below the WCAG AA minimum of 4.5:1 for text at footnote/subheadline sizes. This colour uses
    /// opaque system grays that keep at least 4.5:1 on every system background (plain, grouped, elevated) in
    /// light and dark mode, and moves further from the background with Increase Contrast.
    /// `SecondaryTextContrastTests` checks the ratios.
    static let secondaryText = UIColor { traits in
        let increased = traits.accessibilityContrast == .high
        if traits.userInterfaceStyle == .dark {
            return increased ? UIColor(rgb: 0xD1D1D6) : UIColor(rgb: 0xAEAEB2)
        } else {
            return increased ? UIColor(rgb: 0x48484A) : UIColor(rgb: 0x636366)
        }
    }

    convenience init(rgb: Int) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension ShapeStyle where Self == Color {
    /// Secondary text with at least 4.5:1 contrast; see `UIColor.secondaryText`. Use it instead of `.secondary`
    /// for any text the app colours itself.
    static var secondaryText: Color { Color(uiColor: .secondaryText) }
}

extension View {
    /// Marks text whose colour is chosen by a system component, not by the app: section headers and footers,
    /// `LabeledContent` values and `ContentUnavailableView` descriptions, all drawn in the system's
    /// `secondaryLabel`. It only sets an accessibility identifier, which the UI-test accessibility audit uses to
    /// accept its "Contrast nearly passed" finding on exactly these elements (see docs/ACCESSIBILITY.md).
    func systemSecondaryText() -> some View {
        accessibilityIdentifier(SystemSecondaryText.identifier)
    }
}

enum SystemSecondaryText {
    /// Keep in sync with `AccessibilityAuditTests.systemSecondaryTextID`.
    static let identifier = "systemSecondaryText"
}
