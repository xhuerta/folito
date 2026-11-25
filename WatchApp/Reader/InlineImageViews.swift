import SwiftUI
import WatchKit
import ReaderCore

/// One row of the reader: a text block, or an image block (#71). Used by the scroll view and by auto-scroll's own
/// column alike, so both lay every row out the same.
struct ReaderBlockView: View, Equatable {
    let block: Block
    let style: ReaderRenderStyle
    /// Where the book's pictures are; nil in previews and books without any.
    let files: BookImageFiles?
    /// Decode the picture now: the block is near the reading position (`ImageResidency`).
    let loadsImage: Bool

    var body: some View {
        if let image = block.image {
            InlineImageBlock(image: image, style: style, files: files, loads: loadsImage)
        } else {
            BlockStyledText(block: block, style: style)
                .equatable()
        }
    }
}

/// The screen, for decode sizes.
enum WatchScreen {
    static var size: CGSize { WKInterfaceDevice.current().screenBounds.size }
    static var scale: CGFloat { WKInterfaceDevice.current().screenScale }
}

/// Decoded inline pictures, a few at a time (`ImageResidency.cacheCapacity`). Emptied when the reader closes.
@MainActor
final class InlineImageCache {
    static let shared = InlineImageCache()
    private let cache = LRUCache<String, CGImage>(capacity: ImageResidency.cacheCapacity)

    func image(at url: URL, maxPixels: Int) async -> CGImage? {
        let key = "\(url.path)|\(maxPixels)"
        if let hit = cache.value(for: key) { return hit }
        let decoded = await Task.detached(priority: .userInitiated) {
            DecodedPicture(image: ImageDecoding.thumbnail(at: url, maxPixels: maxPixels))
        }.value
        if let image = decoded.image { cache.set(image, for: key) }
        return decoded.image
    }

    func removeAll() { cache.removeAll() }
}

/// Moves a decoded picture out of the decoding task.
struct DecodedPicture: @unchecked Sendable {
    let image: CGImage?
}

/// An image block in the text: the picture fitted to the column with a small "opens" badge, or, when it has no
/// picture (SVG, damaged, over the transfer cap), its alt text in a frame. VoiceOver reads the alt text, or
/// "Image" without one.
struct InlineImageBlock: View {
    let image: BlockImage
    let style: ReaderRenderStyle
    let files: BookImageFiles?
    let loads: Bool
    @State private var picture: CGImage?

    private struct LoadKey: Equatable {
        let url: URL
        let loads: Bool
    }

    /// The file to show, when there is one.
    private var url: URL? {
        guard let id = image.id, image.aspectRatio != nil else { return nil }
        return files?.url(for: id)
    }

    var body: some View {
        if let url, let width = image.width, let height = image.height {
            FittedImageFrame(pixelWidth: width, pixelHeight: height,
                             maxHeight: WatchScreen.size.height * InlineImageLayout.maxHeightFraction) {
                ZStack(alignment: .bottomTrailing) {
                    if let picture {
                        Image(decorative: picture, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(style.secondaryColor.opacity(0.15))
                    }
                    OpensBadge()
                        .padding(3)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.label(for: image))
            .modifier(ImageTraitWhenDescribed(described: image.alt != nil))
            .accessibilityHint(Text("Opens the image full screen.",
                                    comment: "VoiceOver hint of a picture in the book's text"))
            .task(id: LoadKey(url: url, loads: loads)) {
                guard loads else {
                    picture = nil
                    return
                }
                let fitted = InlineImageLayout.fittedSize(pixelWidth: width, pixelHeight: height,
                                                          columnWidth: WatchScreen.size.width,
                                                          maxHeight: WatchScreen.size.height * InlineImageLayout.maxHeightFraction)
                picture = await InlineImageCache.shared.image(
                    at: url, maxPixels: InlineImageLayout.decodePixels(for: fitted, scale: WatchScreen.scale))
            }
        } else {
            UnavailableImage(alt: image.alt, style: style)
        }
    }

    /// The alt text, or "Image".
    static func label(for image: BlockImage) -> Text {
        if let alt = image.alt { return Text(alt) }
        return Text("Image", comment: "VoiceOver label (and placeholder) of a picture in the book that has no description")
    }
}

/// The image trait, only for a picture with a description: one without is already called "Image".
private struct ImageTraitWhenDescribed: ViewModifier {
    let described: Bool

    func body(content: Content) -> some View {
        if described { content.accessibilityAddTraits(.isImage) } else { content }
    }
}

/// The hint that a picture opens: two small arrows on a dark disc in its corner.
private struct OpensBadge: View {
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(Circle().fill(Color.black.opacity(0.6)))
            .accessibilityHidden(true)
    }
}

/// A picture that cannot be shown: its alt text (or "Image") next to a picture symbol, in a frame.
private struct UnavailableImage: View {
    let alt: String?
    let style: ReaderRenderStyle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "photo")
                .accessibilityHidden(true)
            Group {
                if let alt { Text(alt) } else { InlineImageBlock.label(for: BlockImage(id: nil)) }
            }
            .italic()
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(style.font(for: .paragraph))
        .foregroundStyle(style.secondaryColor)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(style.secondaryColor.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .modifier(ImageTraitWhenDescribed(described: alt != nil))
    }
}

/// Lays the picture out at its fitted size (`InlineImageLayout.fittedSize`), centred in the full column width, so
/// the block's height comes from the stored pixel size whether or not the picture is decoded yet.
struct FittedImageFrame: Layout {
    let pixelWidth: Int
    let pixelHeight: Int
    let maxHeight: CGFloat

    private func fitted(_ column: CGFloat) -> CGSize {
        InlineImageLayout.fittedSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight, columnWidth: column,
                                     maxHeight: maxHeight)
    }

    private func column(_ proposal: ProposedViewSize) -> CGFloat {
        if let width = proposal.width, width.isFinite, width > 0 { return width }
        return WatchScreen.size.width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = column(proposal)
        return CGSize(width: width, height: fitted(width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = fitted(bounds.width)
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(size))
        }
    }
}

// MARK: - Full screen

/// A picture full screen on black (#71). The Digital Crown zooms (1x to 3x, with detents), a drag pans the zoomed
/// picture, a double tap switches between fit and zoomed, like Photos on the watch. The reader stays where it was
/// underneath, so closing returns to the same line. VoiceOver: the picture is one element with its alt text,
/// swipe up or down zooms (adjustable), the close button is labelled, and the two-finger scrub closes.
struct ImageViewer: View {
    let image: BlockImage
    let url: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var picture: CGImage?
    @State private var failed = false
    @State private var zoom = ImageZoom()
    @State private var crown = ImageZoom.minScale
    @State private var dragBase: CGSize?
    @FocusState private var crownFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size
            let fitted = ImageZoom.fitted(aspectRatio: image.aspectRatio ?? 1, in: viewport)
            ZStack {
                Color.black
                if let picture {
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .scaleEffect(CGFloat(zoom.scale))
                        .offset(zoom.offset)
                } else if failed || url == nil {
                    InlineImageBlock.label(for: image)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    ProgressView()
                }
            }
            .frame(width: viewport.width, height: viewport.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let base = dragBase ?? zoom.offset
                    dragBase = base
                    zoom.pan(from: base, by: value.translation, fitted: fitted, viewport: viewport)
                }
                .onEnded { _ in dragBase = nil })
            .onTapGesture(count: 2) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    zoom.toggle(fitted: fitted, viewport: viewport)
                }
                crown = zoom.scale
            }
            .focusable()
            .focused($crownFocused)
            .focusEffectDisabled()
            .digitalCrownRotation($crown, from: ImageZoom.minScale, through: ImageZoom.maxScale, by: ImageZoom.crownStep,
                                  sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
            .onChange(of: crown) { value in
                guard abs(value - zoom.scale) > 0.001 else { return }
                zoom.setScale(value, fitted: fitted, viewport: viewport)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(InlineImageBlock.label(for: image))
            .accessibilityAddTraits(.isImage)
            .accessibilityValue(Text(zoom.scale.formatted(.percent.precision(.fractionLength(0)))))
            .accessibilityHint(Text("Swipe up or down to zoom.",
                                    comment: "VoiceOver hint of the full-screen picture viewer"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: zoom.step(up: true, fitted: fitted, viewport: viewport)
                case .decrement: zoom.step(up: false, fitted: fitted, viewport: viewport)
                @unknown default: break
                }
                crown = zoom.scale
            }
            .accessibilityAction(.escape) { dismiss() }
            .accessibilityIdentifier("imageViewerPicture")
        }
        .background(Color.black)
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 40, minHeight: 40)
                    .background(Circle().fill(Color(white: 0.25)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close", comment: "Button that closes the full-screen picture viewer"))
            .accessibilityIdentifier("imageViewerClose")
            .padding(.leading, 4)
        }
        .task {
            guard let url else { return }
            let pixels = ImageZoom.decodePixels(screen: WatchScreen.size, scale: WatchScreen.scale,
                                                pixelWidth: image.width, pixelHeight: image.height)
            let decoded = await Task.detached(priority: .userInitiated) {
                DecodedPicture(image: ImageDecoding.thumbnail(at: url, maxPixels: pixels))
            }.value
            picture = decoded.image
            failed = decoded.image == nil
        }
        .onAppear {
            DispatchQueue.main.async { crownFocused = true }
        }
    }
}
