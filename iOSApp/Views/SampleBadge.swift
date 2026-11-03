import SwiftUI

/// Small "Sample" tag on library rows of bundled sample books (see `SampleBooks`). Text in the secondary text
/// colour with an outline, so it keeps 4.5:1 contrast in light and dark mode; VoiceOver reads it as part of the row.
struct SampleBadge: View {
    var body: some View {
        Text("Sample", comment: "Library row badge: the book is one of the sample books bundled with the app")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color(uiColor: .secondaryText), lineWidth: 1))
            .accessibilityIdentifier("sampleBadge")
    }
}
