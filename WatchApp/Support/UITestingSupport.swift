import Foundation
import ReaderCore
import UIKit

/// Launch arguments used by the watch UI test target (FolitoWatchUITests). The hooks are compiled into
/// Debug builds only: in Release every factory below returns the normal service and nothing is read from the
/// launch arguments, so an App Store build has no test hooks at all.
///
/// - `-UITesting`: books live in a fresh temporary directory and positions / typography in a private,
///   emptied `UserDefaults` suite, so every launch starts with an empty library and default settings and the
///   real library is never touched. WatchConnectivity is not started, so the iPhone cannot add books or
///   change settings during a test.
/// - `-UITestingSeedSampleBook` (implies `-UITesting`): also stores one small built-in sample book, so the
///   non-empty library and the reader can be tested without an iPhone.
enum UITesting {
    static let isolateArgument = "-UITesting"
    static let seedSampleBookArgument = "-UITestingSeedSampleBook"
    /// `-UITestingSeedCovers` (implies `-UITesting`): the sample book (no cover) and three books with generated
    /// covers, for the covers screenshots. `-UITestingCoversOff` starts with Settings > Show Covers off.
    static let seedCoversArgument = "-UITestingSeedCovers"
    static let coversOffArgument = "-UITestingCoversOff"

    #if DEBUG
    static let isActive: Bool = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains(isolateArgument) || args.contains(seedSampleBookArgument) || args.contains(seedCoversArgument)
    }()

    private static let defaultsSuite = "Folito.UITesting"

    /// Private settings store, emptied on every launch. `.standard` when not UI testing.
    static let defaults: UserDefaults = {
        guard isActive, let suite = UserDefaults(suiteName: defaultsSuite) else { return .standard }
        suite.removePersistentDomain(forName: defaultsSuite)
        return suite
    }()

    static func makeBookStorage() -> BookStorage {
        guard isActive else { return BookStorage() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UITesting-\(UUID().uuidString)", isDirectory: true)
        let storage = BookStorage(root: root)
        if ProcessInfo.processInfo.arguments.contains(seedSampleBookArgument) {
            seed(sampleBook, into: storage, scratch: root)
        }
        // The toggle is an @AppStorage in the standard defaults: set it for this launch either way.
        if ProcessInfo.processInfo.arguments.contains(coversOffArgument) {
            UserDefaults.standard.set(false, forKey: ReaderSettings.showCoversKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ReaderSettings.showCoversKey)
        }
        if ProcessInfo.processInfo.arguments.contains(seedCoversArgument) {
            seedCovers(into: storage, scratch: root)
        }
        return storage
    }

    /// Public-domain books; covers are generated (no cover art ships in the app).
    private static func seedCovers(into storage: BookStorage, scratch: URL) {
        let books: [(String, String, String, UInt32?)] = [
            ("00000000000000000000000000e00a02", "The Gods of Mars", "Edgar Rice Burroughs", 0xE8833A), // i18n-ignore: UI-test fixture
            ("00000000000000000000000000e00a01", "Emma", "Jane Austen", 0x30B0C7), // i18n-ignore: UI-test fixture
            ("00000000000000000000000000e00a03", "Twenty Thousand Leagues Under the Seas", "Jules Verne", 0x5856D6), // i18n-ignore: UI-test fixture
        ]
        var entries: [LibraryEntry] = []
        if var alice = seedEntry(sampleBook, into: storage, scratch: scratch) {
            alice.addedAt = Date(timeIntervalSince1970: 0)
            entries.append(alice)
        }
        for (i, (hash, title, author, color)) in books.enumerated() {
            let text = "Chapter one." // i18n-ignore: UI-test fixture (Debug only)
            let book = ProcessedBook(metadata: BookMetadata(title: title, authors: [author]), documentHash: hash,
                                     metaHash: hash + "m",
                                     chapters: [Chapter(spineIndex: 1, title: nil, blocks: [
                                         Block(text: text, xpointer: "/body/DocFragment[1]/body/p", globalOffset: 0)])],
                                     totalCharacters: text.count)
            guard var entry = seedEntry(book, into: storage, scratch: scratch) else { continue }
            entry.addedAt = Date(timeIntervalSince1970: TimeInterval(100 - i))
            if let color, let jpeg = generatedCover(color) {
                entry.hasCover = storage.saveCover(jpeg, documentHash: hash)
            }
            entries.append(entry)
        }
        storage.saveIndex(entries)
    }

    /// A 72 × 108 px JPEG (the size the iPhone sends): a colour field, two "title" bars and a disc.
    static func generatedCover(_ rgb: UInt32) -> Data? {
        let w = 72, h = 108
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                         blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.25)
        ctx.fillEllipse(in: CGRect(x: 14, y: 14, width: 44, height: 44))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.9)
        ctx.fill(CGRect(x: 9, y: 82, width: 54, height: 7))
        ctx.fill(CGRect(x: 9, y: 70, width: 36, height: 5))
        guard let image = ctx.makeImage() else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.6)
    }

    /// UI tests start with no dictionaries in a throwaway directory; nil = the normal location.
    static let dictionaryDirectory: URL? = isActive
        ? FileManager.default.temporaryDirectory.appendingPathComponent("UITesting-dict-\(UUID().uuidString)", isDirectory: true)
        : nil

    /// Stores `book` exactly as a transfer from the iPhone would (LZFSE-compressed JSON) and indexes it.
    private static func seed(_ book: ProcessedBook, into storage: BookStorage, scratch: URL) {
        guard let entry = seedEntry(book, into: storage, scratch: scratch) else { return }
        storage.saveIndex([entry])
    }

    private static func seedEntry(_ book: ProcessedBook, into storage: BookStorage, scratch: URL) -> LibraryEntry? {
        let file = scratch.appendingPathComponent("seed.book")
        guard let json = try? JSONEncoder().encode(book),
              let compressed = try? (json as NSData).compressed(using: .lzfse) as Data,
              (try? compressed.write(to: file, options: .atomic)) != nil,
              let entry = try? storage.importBook(from: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return entry
    }

    /// A tiny public-domain text (Lewis Carroll, 1865), built in code: no book file ships in the app.
    /// Same content as the iPhone's UI-testing sample.
    static let sampleBook: ProcessedBook = {
        let text = "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do." // i18n-ignore: UI-test fixture (Debug only)
        let blocks = [
            Block(text: "Down the Rabbit-Hole", style: .heading1, xpointer: "/body/DocFragment[1]/body/h1", globalOffset: 0),
            Block(text: text, xpointer: "/body/DocFragment[1]/body/p", globalOffset: 20),
        ]
        return ProcessedBook(metadata: BookMetadata(title: "Alice’s Adventures in Wonderland", authors: ["Lewis Carroll"]),
                             documentHash: "00000000000000000000000000a11ce0",
                             metaHash: "00000000000000000000000000a11ce1",
                             chapters: [Chapter(spineIndex: 0, title: "Down the Rabbit-Hole", blocks: blocks)],
                             totalCharacters: 20 + text.count)
    }()
    #else
    static let isActive = false
    static var defaults: UserDefaults { .standard }
    static func makeBookStorage() -> BookStorage { BookStorage() }
    static let dictionaryDirectory: URL? = nil
    #endif
}
