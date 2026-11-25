import CoreGraphics
import Foundation
import ImageIO
import ReaderCore

// Images inside the text (#71): where their files are, how big they are drawn, which ones are kept in memory and
// how the full-screen viewer zooms. Pure logic, unit-tested in InlineImageTests; the views are in
// Reader/InlineImageViews.swift.

/// Where a book's pictures are stored on the watch (`BookStorage.imageDirectory`), one file per `BookImage.id`.
struct BookImageFiles: Equatable, Sendable {
    let directory: URL

    /// The file of picture `id`; nil for an id that is not a plain ASCII letters-and-digits name (never a path).
    func url(for id: String) -> URL? {
        guard !id.isEmpty, id.count <= 64,
              id.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return directory.appendingPathComponent(id).appendingPathExtension("img")
    }
}

/// The size of an image block in the text.
enum InlineImageLayout {
    /// A picture is never drawn taller than this share of the screen: the rest of the page stays in sight, and
    /// the full-screen viewer shows it whole.
    static let maxHeightFraction: CGFloat = 0.8

    /// The picture fitted to the column: as wide as the column, but never enlarged past one point per pixel (a
    /// small drawing stays small and sharp), and no taller than `maxHeight`.
    static func fittedSize(pixelWidth: Int, pixelHeight: Int, columnWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0, columnWidth.isFinite, columnWidth > 0 else { return .zero }
        let ratio = CGFloat(pixelWidth) / CGFloat(pixelHeight)
        var width = min(columnWidth, CGFloat(pixelWidth))
        var height = width / ratio
        if maxHeight.isFinite, maxHeight > 0, height > maxHeight {
            height = maxHeight
            width = height * ratio
        }
        return CGSize(width: width.rounded(.down), height: height.rounded(.down))
    }

    /// Pixels to decode for a picture drawn at `size` points on a screen of `scale`: the longer side, never the
    /// full bitmap.
    static func decodePixels(for size: CGSize, scale: CGFloat) -> Int {
        max(1, Int((max(size.width, size.height) * max(scale, 1)).rounded(.up)))
    }
}

/// Which pictures the reader keeps decoded: only those of the image blocks near the reading position. The others
/// keep their place (the block has its full size from the stored pixel size) and show an empty frame.
enum ImageResidency {
    /// Blocks before and after the current one whose pictures are decoded.
    static let radius = 8
    /// Decoded pictures kept in the cache beyond the ones on screen.
    static let cacheCapacity = 6

    static func isNear(_ index: Int, current: Int) -> Bool {
        abs(index - current) <= radius
    }
}

/// A small least-recently-used cache.
final class LRUCache<Key: Hashable, Value> {
    let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { values.count }
    var keys: [Key] { order }

    func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    func set(_ value: Value, for key: Key) {
        values[key] = value
        touch(key)
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
    }

    func removeAll() {
        values = [:]
        order = []
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// Decodes a stored picture at a given size with ImageIO (a thumbnail: the full bitmap is never decoded).
enum ImageDecoding {
    static func thumbnail(at url: URL, maxPixels: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Zoom and pan of the full-screen viewer, like Photos on the watch: the crown zooms between fit (1x) and
/// `maxScale`, a drag pans a zoomed picture (never past its edges), a double tap switches between fit and
/// `doubleTapScale`.
struct ImageZoom: Equatable {
    static let minScale: Double = 1
    static let maxScale: Double = 3
    static let doubleTapScale: Double = 2.5
    /// One crown detent.
    static let crownStep: Double = 0.1

    private(set) var scale: Double = 1
    private(set) var offset: CGSize = .zero

    var isZoomed: Bool { scale > Self.minScale + 0.001 }

    /// The picture fitted inside `viewport` at 1x.
    static func fitted(aspectRatio: Double, in viewport: CGSize) -> CGSize {
        guard aspectRatio.isFinite, aspectRatio > 0, viewport.width > 0, viewport.height > 0 else { return viewport }
        let ratio = CGFloat(aspectRatio)
        if viewport.width / viewport.height > ratio {
            return CGSize(width: viewport.height * ratio, height: viewport.height)
        }
        return CGSize(width: viewport.width, height: viewport.width / ratio)
    }

    static func clampedScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return minScale }
        return min(max(scale, minScale), maxScale)
    }

    /// `offset` kept so the zoomed picture still covers the viewport where it is larger than it (centred where not).
    static func clampedOffset(_ offset: CGSize, scale: Double, fitted: CGSize, viewport: CGSize) -> CGSize {
        let maxX = max(0, (fitted.width * CGFloat(scale) - viewport.width) / 2)
        let maxY = max(0, (fitted.height * CGFloat(scale) - viewport.height) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }

    /// Zooms to `newScale` around the centre of the screen, keeping the point there in place.
    mutating func setScale(_ newScale: Double, fitted: CGSize, viewport: CGSize) {
        let s = Self.clampedScale(newScale)
        let factor = CGFloat(s / scale)
        scale = s
        offset = Self.clampedOffset(CGSize(width: offset.width * factor, height: offset.height * factor),
                                    scale: s, fitted: fitted, viewport: viewport)
    }

    /// Pans from `base` (the offset when the drag began) by `translation`.
    mutating func pan(from base: CGSize, by translation: CGSize, fitted: CGSize, viewport: CGSize) {
        guard isZoomed else { offset = .zero; return }
        offset = Self.clampedOffset(CGSize(width: base.width + translation.width, height: base.height + translation.height),
                                    scale: scale, fitted: fitted, viewport: viewport)
    }

    /// Double tap: back to fit when zoomed, else to `doubleTapScale`.
    mutating func toggle(fitted: CGSize, viewport: CGSize) {
        if isZoomed {
            scale = Self.minScale
            offset = .zero
        } else {
            setScale(Self.doubleTapScale, fitted: fitted, viewport: viewport)
        }
    }

    /// VoiceOver's adjustable action: one step in or out.
    mutating func step(up: Bool, fitted: CGSize, viewport: CGSize) {
        setScale(scale + (up ? 0.5 : -0.5), fitted: fitted, viewport: viewport)
    }

    /// Pixels to decode for the viewer: enough for `maxScale` on this screen, never more than the picture has.
    static func decodePixels(screen: CGSize, scale: CGFloat, pixelWidth: Int?, pixelHeight: Int?) -> Int {
        let wanted = Int((max(screen.width, screen.height) * max(scale, 1) * CGFloat(maxScale)).rounded(.up))
        guard let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 else { return max(1, wanted) }
        return max(1, min(wanted, max(w, h)))
    }
}
