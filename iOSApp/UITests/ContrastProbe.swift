import UIKit
import XCTest

/// Diagnostic only (never decides pass/fail): estimates the WCAG contrast of an element from a screenshot.
/// The most frequent colour is taken as the background and, among the colours covering at least 1% of the
/// element, the one furthest from it as the text colour.
enum ContrastProbe {
    @MainActor
    static func measure(_ element: XCUIElement) -> String? {
        guard let cgImage = element.screenshot().image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var counts: [Int: Int] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = Int(pixels[i]) << 16 | Int(pixels[i + 1]) << 8 | Int(pixels[i + 2])
            counts[rgb, default: 0] += 1
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let minimum = max(1, width * height / 100)
        let candidates = counts.filter { $0.value >= minimum && $0.key != background }.map(\.key)
        guard let text = candidates.max(by: { ratio($0, background) < ratio($1, background) }) else {
            return String(format: "uniform #%06X", background)
        }
        return String(format: "%.2f:1 (#%06X on #%06X)", ratio(text, background), text, background)
    }

    static func ratio(_ a: Int, _ b: Int) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ rgb: Int) -> Double {
        func lin(_ v: Int) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin((rgb >> 16) & 0xFF) + 0.7152 * lin((rgb >> 8) & 0xFF) + 0.0722 * lin(rgb & 0xFF)
    }
}
