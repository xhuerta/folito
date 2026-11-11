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
    /// `-UITestingSeedAppStore` (implies `-UITesting`): the library, the reader and the word lookup as the App
    /// Store screenshots show them (docs/appstore/SCREENSHOTS.md): the opening of the iPhone app's English
    /// sample book, three more public-domain titles with generated covers, and a small sample dictionary.
    static let seedAppStoreArgument = "-UITestingSeedAppStore"

    #if DEBUG
    static let isActive: Bool = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains(isolateArgument) || args.contains(seedSampleBookArgument) || args.contains(seedCoversArgument)
            || args.contains(seedAppStoreArgument)
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
        if ProcessInfo.processInfo.arguments.contains(seedAppStoreArgument) {
            seedCovers(into: storage, scratch: root, first: appStoreBook, firstIsNewest: true)
        } else if ProcessInfo.processInfo.arguments.contains(seedCoversArgument) {
            seedCovers(into: storage, scratch: root)
        }
        return storage
    }

    /// Public-domain books; covers are generated (no cover art ships in the app). `first` has no cover; it is
    /// the oldest book of the library unless `firstIsNewest`.
    private static func seedCovers(into storage: BookStorage, scratch: URL, first: ProcessedBook = sampleBook,
                                   firstIsNewest: Bool = false) {
        let books: [(String, String, String, UInt32?)] = [
            ("00000000000000000000000000e00a02", "The Gods of Mars", "Edgar Rice Burroughs", 0xE8833A), // i18n-ignore: UI-test fixture
            ("00000000000000000000000000e00a01", "Emma", "Jane Austen", 0x30B0C7), // i18n-ignore: UI-test fixture
            ("00000000000000000000000000e00a03", "Twenty Thousand Leagues Under the Seas", "Jules Verne", 0x5856D6), // i18n-ignore: UI-test fixture
        ]
        var entries: [LibraryEntry] = []
        if var lead = seedEntry(first, into: storage, scratch: scratch) {
            lead.addedAt = Date(timeIntervalSince1970: firstIsNewest ? 1_000 : 0)
            entries.append(lead)
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

    /// UI tests start with no dictionaries in a throwaway directory (`-UITestingSeedAppStore`: with the sample
    /// dictionary); nil = the normal location.
    static let dictionaryDirectory: URL? = {
        guard isActive else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UITesting-dict-\(UUID().uuidString)", isDirectory: true)
        if ProcessInfo.processInfo.arguments.contains(seedAppStoreArgument) {
            seedSampleDictionary(into: directory)
        }
        return directory
    }()

    /// A compact dictionary with a few entries for words of the App Store sample text, written with the same
    /// writer the iPhone uses. The definitions are written for this fixture, so the source line names it as a
    /// sample instead of crediting a real dictionary.
    private static func seedSampleDictionary(into directory: URL) {
        let id = "sample-en"
        let source = "Sample dictionary" // i18n-ignore: UI-test fixture (Debug only)
        func make(_ word: String, _ pronunciation: String, _ partOfSpeech: String, _ senses: [DictionarySense]) -> DictionaryEntry {
            DictionaryEntry(word: word, language: "en", pronunciation: pronunciation,
                            meanings: [DictionaryMeaning(partOfSpeech: partOfSpeech, senses: senses)], source: source)
        }
        let entries: [(DictionaryEntry, [String])] = [
            (make("acknowledge", "/əkˈnɒl.ɪdʒ/", "Verb", [ // i18n-ignore: UI-test fixture
                DictionarySense(definition: "To accept or admit that something is true or exists.", // i18n-ignore: UI-test fixture
                                examples: ["She acknowledged her mistake."]), // i18n-ignore: UI-test fixture
                DictionarySense(definition: "To recognise the standing, rights or importance of someone or something."), // i18n-ignore: UI-test fixture
                DictionarySense(definition: "To let someone know that a letter or message has arrived."), // i18n-ignore: UI-test fixture
            ]), ["acknowledged", "acknowledges", "acknowledging"]),
            (make("truth", "/truːθ/", "Noun", [ // i18n-ignore: UI-test fixture
                DictionarySense(definition: "What is really the case; the facts, as opposed to what is imagined or invented."), // i18n-ignore: UI-test fixture
                DictionarySense(definition: "A statement or principle that is generally accepted as true."), // i18n-ignore: UI-test fixture
            ]), ["truths"]),
            (make("universally", "/ˌjuː.nɪˈvɜː.səl.i/", "Adverb", [ // i18n-ignore: UI-test fixture
                DictionarySense(definition: "By everyone, or in every case; without exception."), // i18n-ignore: UI-test fixture
            ]), []),
            (make("fortune", "/ˈfɔː.tʃuːn/", "Noun", [ // i18n-ignore: UI-test fixture
                DictionarySense(definition: "A large amount of money or property; wealth."), // i18n-ignore: UI-test fixture
                DictionarySense(definition: "Chance or luck, seen as a force that shapes what happens to people."), // i18n-ignore: UI-test fixture
            ]), ["fortunes"]),
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let writer = try CompactDictionaryWriter(url: directory.appendingPathComponent(InstalledDictionaries.fileName(for: id)))
            for (entry, forms) in entries {
                let ref = try writer.add(entry)
                writer.addKey(entry.word, ref: ref)
                for form in forms { writer.addKey(form, ref: ref, isHeadword: false) }
            }
            _ = try writer.finish(info: CompactDictionaryInfo(id: id, name: source, language: "en", source: source,
                                                              license: "", licenseURL: "", attribution: source,
                                                              sourceURL: "", sourceVersion: ""))
        } catch {
            assertionFailure("sample dictionary: \(error)")
        }
    }

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

    /// The opening of *Pride and Prejudice* (Jane Austen, 1813; public domain), the iPhone app's English sample
    /// book (docs/SAMPLE_BOOKS.md, text of docs/samples-src/en.txt), built in code: no book file ships in the
    /// watch app.
    static let appStoreBook: ProcessedBook = {
        let paragraphs = [
            "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.", // i18n-ignore: UI-test fixture (Debug only)
            "However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered as the rightful property of some one or other of their daughters.", // i18n-ignore: UI-test fixture
            "\"My dear Mr. Bennet,\" said his lady to him one day, \"have you heard that Netherfield Park is let at last?\"", // i18n-ignore: UI-test fixture
            "Mr. Bennet replied that he had not.", // i18n-ignore: UI-test fixture
            "\"But it is,\" returned she; \"for Mrs. Long has just been here, and she told me all about it.\"", // i18n-ignore: UI-test fixture
            "Mr. Bennet made no answer.", // i18n-ignore: UI-test fixture
            "\"Do not you want to know who has taken it?\" cried his wife impatiently.", // i18n-ignore: UI-test fixture
            "This was invitation enough.", // i18n-ignore: UI-test fixture
        ]
        let heading = "Chapter I" // i18n-ignore: UI-test fixture
        var blocks = [Block(text: heading, style: .heading1, xpointer: "/body/DocFragment[1]/body/h1", globalOffset: 0)]
        var offset = heading.count
        for (i, paragraph) in paragraphs.enumerated() {
            blocks.append(Block(text: paragraph, xpointer: "/body/DocFragment[1]/body/p[\(i + 1)]", globalOffset: offset))
            offset += paragraph.count
        }
        return ProcessedBook(metadata: BookMetadata(title: "Pride and Prejudice", authors: ["Jane Austen"], language: "en"), // i18n-ignore: UI-test fixture
                             documentHash: "000000000000000000000000000a0571",
                             metaHash: "000000000000000000000000000a0572",
                             chapters: [Chapter(spineIndex: 1, title: heading, blocks: blocks)],
                             totalCharacters: offset)
    }()
    #else
    static let isActive = false
    static var defaults: UserDefaults { .standard }
    static func makeBookStorage() -> BookStorage { BookStorage() }
    static let dictionaryDirectory: URL? = nil
    #endif
}
