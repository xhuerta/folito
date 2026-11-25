import Foundation
#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

// Images inside the text (#71): which `<img>`s become image blocks, and how their pictures are resized and capped
// for the watch. See docs/WATCH_CONNECTIVITY.md ("Images") for the numbers.

/// A pixel size.
public struct PixelSize: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var longerSide: Int { max(width, height) }
    public var shorterSide: Int { min(width, height) }
}

/// How large the pictures sent to the watch may be.
public struct ImageLimits: Sendable, Equatable {
    /// Longer side of a picture, in pixels: three times the widest watch screen (416 px, 46 mm Series 10), so the
    /// full-screen viewer can zoom about 3x before it runs out of pixels.
    public var maxPixels: Int
    /// Longer side once half of `maxTotalBytes` is used, or when a picture is too heavy at `maxPixels` (2x zoom).
    public var reducedMaxPixels: Int
    /// One picture, after resizing. Heavier ones are tried at `reducedMaxPixels`, then left out.
    public var maxImageBytes: Int
    /// All the pictures of one book. Pictures past it are left out: their blocks show the alt text.
    public var maxTotalBytes: Int

    public init(maxPixels: Int = 1248, reducedMaxPixels: Int = 832, maxImageBytes: Int = 350 * 1024,
                maxTotalBytes: Int = 8 * 1024 * 1024) {
        self.maxPixels = maxPixels
        self.reducedMaxPixels = min(reducedMaxPixels, maxPixels)
        self.maxImageBytes = maxImageBytes
        self.maxTotalBytes = maxTotalBytes
    }

    public static let watch = ImageLimits()
}

/// A picture re-encoded for the watch.
public struct PreparedImage: Sendable, Equatable {
    public var data: Data
    public var mediaType: String
    public var width: Int
    public var height: Int

    public init(data: Data, mediaType: String, width: Int, height: Int) {
        self.data = data
        self.mediaType = mediaType
        self.width = width
        self.height = height
    }
}

/// Resizes a picture of the book for the watch. The iPhone uses `ImageIOImagePreparer`.
public protocol ImagePreparing: Sendable {
    /// `data` with its longer side at most `maxPixels` (never enlarged), or nil when it cannot be decoded.
    func prepare(_ data: Data, mediaType: String, maxPixels: Int) -> PreparedImage?
}

/// Keeps JPEG, PNG and GIF files that are already small enough, unchanged; refuses everything else. For platforms
/// without ImageIO (the Linux tests): it never decodes anything.
public struct PassthroughImagePreparer: ImagePreparing {
    public init() {}

    public func prepare(_ data: Data, mediaType: String, maxPixels: Int) -> PreparedImage? {
        guard ["image/jpeg", "image/png", "image/gif"].contains(mediaType),
              let size = ImageHeader.pixelSize(of: data), size.longerSide <= maxPixels else { return nil }
        return PreparedImage(data: data, mediaType: mediaType, width: size.width, height: size.height)
    }
}

#if canImport(ImageIO) && canImport(CoreGraphics)
/// Decodes with ImageIO at the target size (a thumbnail, never the full bitmap), flattens transparency onto white
/// (book illustrations are drawn for a white page; the watch viewer is black) and encodes a JPEG.
public struct ImageIOImagePreparer: ImagePreparing {
    public var quality: Double

    public init(quality: Double = 0.7) {
        self.quality = quality
    }

    public func prepare(_ data: Data, mediaType: String, maxPixels: Int) -> PreparedImage? {
        guard mediaType != "image/svg+xml", maxPixels > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0 else { return nil }
        let width = image.width
        let height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flat = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, flat,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), out.length > 0 else { return nil }
        return PreparedImage(data: out as Data, mediaType: "image/jpeg", width: width, height: height)
    }
}
#endif

/// Reads the pixel size from the header of a PNG, GIF, JPEG, WebP or BMP file, without decoding it.
public enum ImageHeader {
    public static func pixelSize(of data: Data) -> PixelSize? {
        let b = [UInt8](data)
        let size: PixelSize?
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            size = b.count >= 24 ? PixelSize(width: be32(b, 16), height: be32(b, 20)) : nil
        } else if b.starts(with: Array("GIF8".utf8)) {
            size = b.count >= 10 ? PixelSize(width: le16(b, 6), height: le16(b, 8)) : nil
        } else if b.starts(with: [0xFF, 0xD8]) {
            size = jpeg(b)
        } else if b.count >= 30, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) {
            size = webp(b)
        } else if b.count >= 26, b.starts(with: Array("BM".utf8)) {
            size = PixelSize(width: abs(Int(Int32(bitPattern: UInt32(le32(b, 18))))),
                             height: abs(Int(Int32(bitPattern: UInt32(le32(b, 22))))))
        } else {
            size = nil
        }
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return size
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int { be16(b, i) << 16 | be16(b, i + 2) }
    private static func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private static func le24(_ b: [UInt8], _ i: Int) -> Int { le16(b, i) | Int(b[i + 2]) << 16 }
    private static func le32(_ b: [UInt8], _ i: Int) -> Int { le16(b, i) | le16(b, i + 2) << 16 }

    /// The first start-of-frame marker (SOF0...SOF15, except DHT, JPG and DAC).
    private static func jpeg(_ b: [UInt8]) -> PixelSize? {
        var i = 2
        while i + 3 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }  // fill byte
            if marker == 0x01 || (0xD0...0xD9).contains(marker) { i += 2; continue }  // no length
            let length = be16(b, i + 2)
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard i + 8 < b.count else { return nil }
                return PixelSize(width: be16(b, i + 7), height: be16(b, i + 5))
            }
            guard length >= 2 else { return nil }
            i += 2 + length
        }
        return nil
    }

    private static func webp(_ b: [UInt8]) -> PixelSize? {
        switch String(decoding: b[12..<16], as: UTF8.self) {
        case "VP8 ":
            return PixelSize(width: le16(b, 26) & 0x3FFF, height: le16(b, 28) & 0x3FFF)
        case "VP8L":
            guard b[20] == 0x2F else { return nil }
            let bits = le32(b, 21)
            return PixelSize(width: (bits & 0x3FFF) + 1, height: ((bits >> 14) & 0x3FFF) + 1)
        case "VP8X":
            return PixelSize(width: le24(b, 24) + 1, height: le24(b, 27) + 1)
        default:
            return nil
        }
    }
}

/// Which images of the text are decoration rather than content (#71): ornaments, separators and spacers.
public enum ImageFilter {
    /// Smaller on its longer side: an ornament, a bullet, a spacer.
    public static let ornamentMaxPixels = 48
    /// A rule: at most this thick, and `separatorMinRatio` times longer than thick.
    public static let separatorMaxThickness = 24
    public static let separatorMinRatio = 6
    /// An image with an empty `alt` outside a link (the HTML way of marking decoration) is decoration up to this
    /// longer side. A larger one is kept: many converters write `alt=""` on every picture, illustrations included.
    public static let emptyAltMaxPixels = 320

    /// - Parameters:
    ///   - size: the picture's pixel size (the declared `width` / `height` when both are given), nil when unknown.
    ///   - alt: the `alt` attribute as written: nil when absent, "" when empty.
    ///   - inLink: the image is inside an `<a href>`.
    ///   - presentational: `role="presentation"` / `"none"` or `aria-hidden="true"`.
    public static func isDecorative(size: PixelSize?, alt: String?, inLink: Bool, presentational: Bool) -> Bool {
        if presentational { return true }
        if let size {
            if size.longerSide < ornamentMaxPixels { return true }
            if size.shorterSide <= separatorMaxThickness, size.longerSide >= separatorMinRatio * size.shorterSide {
                return true
            }
        }
        let emptyAlt = alt.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        if emptyAlt, !inLink {
            // Without a known size an image with an empty alt can neither be shown nor described.
            guard let size else { return true }
            return size.longerSide <= emptyAltMaxPixels
        }
        return false
    }

    /// `width` / `height` attribute values in pixels ("120", "120px"); nil for percentages and other units.
    static func declaredPixels(_ value: String?) -> Int? {
        guard var v = value?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return nil }
        if v.hasSuffix("px") { v.removeLast(2) }
        guard let n = Double(v), n.isFinite, n > 0 else { return nil }
        return Int(n.rounded())
    }
}

/// Resizes the pictures of one book and keeps them within `ImageLimits` (#71), in reading order: the first
/// pictures of the book are the ones kept when it is very heavily illustrated.
struct ImageEmbedder {
    let preparer: ImagePreparing
    let limits: ImageLimits
    private(set) var images: [BookImage] = []
    private(set) var totalBytes = 0
    private var byPath: [String: Int] = [:]
    private var refused: Set<String> = []

    init(preparer: ImagePreparing, limits: ImageLimits) {
        self.preparer = preparer
        self.limits = limits
    }

    /// The picture already kept for `path`.
    func image(forPath path: String) -> BookImage? {
        byPath[path].map { images[$0] }
    }

    /// Whether `path` was tried and could not be kept.
    func wasRefused(_ path: String) -> Bool { refused.contains(path) }

    /// Keeps the picture at `path` (once per path) and returns it, or nil when it cannot be decoded or does not fit.
    mutating func embed(path: String, data: Data, mediaType: String) -> BookImage? {
        if let kept = image(forPath: path) { return kept }
        guard !refused.contains(path) else { return nil }
        guard let prepared = fit(data, mediaType: mediaType) else {
            refused.insert(path)
            return nil
        }
        let image = BookImage(id: "i\(images.count + 1)", mediaType: prepared.mediaType, width: prepared.width,
                              height: prepared.height, data: prepared.data)
        byPath[path] = images.count
        images.append(image)
        totalBytes += prepared.data.count
        return image
    }

    private func fit(_ data: Data, mediaType: String) -> PreparedImage? {
        let remaining = limits.maxTotalBytes - totalBytes
        guard remaining > 0 else { return nil }
        let budget = min(limits.maxImageBytes, remaining)
        // Past half the budget, the rest of the book's pictures are sent smaller (2x zoom instead of 3x).
        let full = totalBytes * 2 < limits.maxTotalBytes
        if full, let p = preparer.prepare(data, mediaType: mediaType, maxPixels: limits.maxPixels), p.data.count <= budget {
            return p
        }
        guard let p = preparer.prepare(data, mediaType: mediaType, maxPixels: limits.reducedMaxPixels),
              p.data.count <= budget else { return nil }
        return p
    }
}

/// An `<img>` (or SVG `<image>`) as the extractor saw it.
struct RawImage: Equatable {
    /// `src` / `href` as written.
    var source: String
    /// The `alt` attribute: nil when absent, "" when empty.
    var alt: String?
    var inLink: Bool
    var presentational: Bool
    /// `width` / `height` attributes in pixels, when both are given in pixels.
    var declaredSize: PixelSize?
}

/// Decides, per image of the text, whether it becomes an image block and with which picture (#71).
struct ImagePlacer {
    var embedder: ImageEmbedder
    /// Archive path of the book's cover, and whether it was only guessed from the first page (then it is skipped only
    /// at the very start of the book, before any text).
    let coverPath: String?
    let coverIsGuessed: Bool
    /// Media types from the manifest, by archive path.
    let mediaTypes: [String: String]
    /// Reads an archive entry; nil when missing or unreadable.
    let load: (String) -> Data?
    private var sizes: [String: PixelSize?] = [:]
    private var missing: Set<String> = []

    init(embedder: ImageEmbedder, coverPath: String?, coverIsGuessed: Bool, mediaTypes: [String: String] = [:],
         load: @escaping (String) -> Data?) {
        self.embedder = embedder
        self.coverPath = coverPath
        self.coverIsGuessed = coverIsGuessed
        self.mediaTypes = mediaTypes
        self.load = load
    }

    static func collapsed(_ alt: String?) -> String? {
        guard let alt else { return nil }
        let words = alt.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    /// The image block for `raw` in the document at `documentPath`, or nil when it leaves the text (decoration,
    /// the repeated cover). `atBookStart`: no text comes before it in the book.
    mutating func place(_ raw: RawImage, documentPath: String, atBookStart: Bool) -> BlockImage? {
        let alt = Self.collapsed(raw.alt)
        guard let path = EPUBParser.resolve(raw.source, relativeTo: documentPath) else {
            // External or inline (data:) pictures are never fetched or decoded: only their description remains.
            if ImageFilter.isDecorative(size: raw.declaredSize, alt: raw.alt, inLink: raw.inLink,
                                        presentational: raw.presentational) { return nil }
            return BlockImage(id: nil, alt: alt)
        }
        if path == coverPath, !coverIsGuessed || atBookStart { return nil }
        if raw.presentational { return nil }
        var data: Data?
        if sizes[path] == nil {
            data = load(path)
            if data == nil { missing.insert(path) }
            sizes[path] = data.flatMap(ImageHeader.pixelSize(of:))
        }
        // A reference to a file the book does not hold shows nothing; only its description, if any, remains.
        if missing.contains(path) { return alt.map { BlockImage(id: nil, alt: $0) } }
        let size = raw.declaredSize ?? sizes[path] ?? nil
        if ImageFilter.isDecorative(size: size, alt: raw.alt, inLink: raw.inLink, presentational: false) { return nil }
        if let kept = embedder.image(forPath: path) {
            return BlockImage(id: kept.id, width: kept.width, height: kept.height, alt: alt)
        }
        if !embedder.wasRefused(path), let bytes = data ?? load(path),
           let kept = embedder.embed(path: path, data: bytes, mediaType: mediaType(of: path)) {
            return BlockImage(id: kept.id, width: kept.width, height: kept.height, alt: alt)
        }
        // SVG, damaged, missing or over the cap: the block shows the alt text (or "Image") in its place.
        return BlockImage(id: nil, alt: alt)
    }

    func mediaType(of path: String) -> String {
        if let declared = mediaTypes[path], declared.hasPrefix("image/") {
            return declared == "image/jpg" ? "image/jpeg" : declared
        }
        return EPUBMetadataReader.imageExtensions[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }
}
