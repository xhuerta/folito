import Foundation
import ImageIO
import ReaderCore
import UIKit
import UniformTypeIdentifiers

/// Cover images of local books. Everything comes from the EPUB itself; nothing is looked up online.
///
/// Files, next to the book payloads in the books directory:
/// - `<hash>.cover.jpg`: the cover, downscaled to at most `libraryPixels` on its longer side (rows and the detail view);
/// - `<hash>.watch.jpg`: a small JPEG for the watch's library row (`watchPixels`, about 2–6 KB).
/// A book without a usable cover (none, or SVG) has neither file and is drawn with a generated placeholder.
enum CoverStore {
    static let libraryPixels = 600
    /// Longer side of the watch thumbnail: 2x of a 36 × 54 pt row cover.
    static let watchPixels = 108
    static let watchMaxBytes = 6 * 1024

    static func coverFileName(forHash hash: String) -> String { "\(hash).cover.jpg" }
    static func watchFileName(forHash hash: String) -> String { "\(hash).watch.jpg" }

    /// Reads the cover from the EPUB and writes both thumbnails into `dir`. Returns true when the book has a
    /// usable (raster) cover. Runs off the main thread.
    @discardableResult
    static func storeCover(_ cover: EPUBCover?, hash: String, in dir: URL) -> Bool {
        let large = dir.appendingPathComponent(coverFileName(forHash: hash))
        let small = dir.appendingPathComponent(watchFileName(forHash: hash))
        try? FileManager.default.removeItem(at: large)
        try? FileManager.default.removeItem(at: small)
        guard let cover, cover.isRaster,
              let big = thumbnail(cover.data, maxPixels: libraryPixels),
              let bigJPEG = UIImage(cgImage: big).jpegData(compressionQuality: 0.8) else { return false }
        do { try bigJPEG.write(to: large, options: .atomic) } catch { return false }
        if let watch = watchJPEG(from: cover.data) { try? watch.write(to: small, options: .atomic) }
        return true
    }

    /// Removes the cover files of a book.
    static func removeCovers(hash: String, in dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(coverFileName(forHash: hash)))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(watchFileName(forHash: hash)))
    }

    /// Decodes and downscales any format ImageIO reads (JPEG, PNG, GIF, WebP, HEIC), applying EXIF orientation.
    static func thumbnail(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A JPEG for the watch row, at most `watchMaxBytes` (quality lowered step by step).
    static func watchJPEG(from data: Data) -> Data? {
        guard let image = thumbnail(data, maxPixels: watchPixels) else { return nil }
        let ui = UIImage(cgImage: image)
        for quality in stride(from: 0.7, through: 0.2, by: -0.1) {
            if let jpeg = ui.jpegData(compressionQuality: quality), jpeg.count <= watchMaxBytes { return jpeg }
        }
        return nil
    }

    /// PNG of the book's cover for Readest (`cover.png`), at most 1024 px on its longer side; nil without one.
    static func readestPNG(epubAt url: URL) -> Data? {
        guard let cover = try? EPUBMetadataReader.cover(epubAt: url), cover.isRaster,
              let image = thumbnail(cover.data, maxPixels: 1024) else { return nil }
        return UIImage(cgImage: image).pngData()
    }
}

/// Covers for display, cached in memory: the stored thumbnail or a generated placeholder.
@MainActor
final class CoverImages {
    static let shared = CoverImages()
    private let cache = NSCache<NSString, UIImage>()

    /// The stored cover of `hash` in `dir`, or nil.
    func cover(hash: String, in dir: URL) -> UIImage? {
        let key = "cover|\(hash)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let image = UIImage(contentsOfFile: dir.appendingPathComponent(CoverStore.coverFileName(forHash: hash)).path)
        else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Forgets a cached cover (after the files changed).
    func invalidate(hash: String) {
        cache.removeObject(forKey: "cover|\(hash)" as NSString)
    }

    /// A placeholder like Apple Books': title and author on a colour picked from the title. Drawn as a bitmap,
    /// so it is artwork (hidden from VoiceOver) rather than text on screen.
    func placeholder(title: String, author: String, size: CGSize) -> UIImage {
        let key = "ph|\(title)|\(author)|\(Int(size.width))x\(Int(size.height))" as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = Self.drawPlaceholder(title: title, author: author, size: size)
        cache.setObject(image, forKey: key)
        return image
    }

    static func placeholderColor(for title: String) -> UIColor {
        let c = CoverPalette.rgb(for: title)
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    private static func drawPlaceholder(title: String, author: String, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            placeholderColor(for: title).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // A faint band at the top, like a printed cover's edge.
            UIColor.white.withAlphaComponent(0.12).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.06))
            let inset = size.width * 0.1
            let width = size.width - 2 * inset
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            let titleFont = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .headline)
                .withDesign(.serif) ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: .headline),
                                   size: max(5, size.width * 0.13))
            let authorFont = UIFont.systemFont(ofSize: max(4, size.width * 0.08), weight: .medium)
            let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.white,
                                                                  .paragraphStyle: paragraph]
            let authorAttributes: [NSAttributedString.Key: Any] = [
                .font: authorFont, .foregroundColor: UIColor.white.withAlphaComponent(0.85), .paragraphStyle: paragraph,
            ]
            let titleBox = CGRect(x: inset, y: size.height * 0.16, width: width, height: size.height * 0.5)
            (title as NSString).draw(with: titleBox, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: titleAttributes, context: nil)
            let authorBox = CGRect(x: inset, y: size.height * 0.72, width: width, height: size.height * 0.2)
            (author as NSString).draw(with: authorBox, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: authorAttributes, context: nil)
        }
    }
}
