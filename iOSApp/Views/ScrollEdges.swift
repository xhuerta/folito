import SwiftUI

extension View {
    /// Hard scroll edges under the navigation and tab bars (iOS 26).
    ///
    /// The default soft edge effect fades text as it scrolls towards a bar, so rows resting just above the tab bar
    /// (for example the last footer of a form) and rows under the navigation bar are drawn below 4.5:1; the
    /// accessibility audit measured 1.1:1 to 1.7:1 there. With the hard style text stays at full contrast up to a
    /// clear dividing line. Earlier iOS versions draw opaque bars anyway.
    @ViewBuilder
    func readableScrollEdges() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .vertical)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
