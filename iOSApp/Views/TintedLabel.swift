import SwiftUI

/// A label whose symbol carries the colour while the text keeps the primary colour, so text contrast
/// stays at the system level (coloured text such as green on white is below 4.5:1).
struct TintedLabel<Tint: ShapeStyle>: View {
    private let title: Text
    private let systemImage: String
    private let tint: Tint

    init(_ titleKey: LocalizedStringKey, systemImage: String, tint: Tint) {
        title = Text(titleKey); self.systemImage = systemImage; self.tint = tint
    }

    init(verbatim title: String, systemImage: String, tint: Tint) {
        self.title = Text(verbatim: title); self.systemImage = systemImage; self.tint = tint
    }

    var body: some View {
        Label {
            title
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }
}
