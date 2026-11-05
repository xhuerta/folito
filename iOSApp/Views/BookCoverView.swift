import SwiftUI
import UIKit

/// A book cover at a fixed size: the book's own cover, or the generated placeholder (title and author on a
/// colour picked from the title). Used by local and Readest rows alike, and large in the book detail view.
///
/// Decorative for VoiceOver: the title and author are always next to it as text. The size is fixed at every text
/// size, like Apple Books' covers; a layout that switches at `isAccessibilitySize` is replaced under the Dynamic
/// Type audits (docs/ACCESSIBILITY.md). The placeholder is a bitmap, not text on screen, so it is not audited as
/// text either.
struct CoverThumbnail: View {
    let image: UIImage?
    let title: String
    let author: String
    var width: CGFloat = 40

    private var size: CGSize { CGSize(width: width, height: (width * 1.5).rounded()) }

    var body: some View {
        Image(uiImage: image ?? CoverImages.shared.placeholder(title: title, author: author, size: size))
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: width > 80 ? 8 : 4))
            .overlay {
                // A hairline so light covers keep their edge on a white background.
                RoundedRectangle(cornerRadius: width > 80 ? 8 : 4).strokeBorder(.quaternary, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(width > 80 ? 0.2 : 0), radius: 8, y: 4)
            .accessibilityHidden(true)
    }
}
