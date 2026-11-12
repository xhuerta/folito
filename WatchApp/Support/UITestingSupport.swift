import CoreText
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
    /// sample book and three more public-domain titles, each with a title-and-author cover drawn in code and
    /// three of them part-read, and a small sample dictionary.
    static let seedAppStoreArgument = "-UITestingSeedAppStore"
    /// `-UITestingAppStoreSepia` (with `-UITestingSeedAppStore`): the reader in the "Comfortable" preset with the
    /// sepia theme, and the sample book opened further on (`AppStoreSeed.sepia`), for the sepia screenshot.
    static let appStoreSepiaArgument = "-UITestingAppStoreSepia"
    /// `-UITestingSimulateSync`: a progress sync service counts as set up (an in-memory client that has no
    /// position for any book; nothing leaves the simulator), so the reader menu offers "Go to Synced Position".
    static let simulateSyncArgument = "-UITestingSimulateSync"

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

    /// The sync coordinator; with `-UITestingSimulateSync` one whose service is an offline stand-in.
    @MainActor
    static func makeSync() -> SyncCoordinator {
        guard isActive, ProcessInfo.processInfo.arguments.contains(simulateSyncArgument) else { return SyncCoordinator() }
        let credentials = KOSyncCredentials(serverURL: URL(string: "https://sync.example.invalid")!, // i18n-ignore: UI-test fixture
                                            username: "reader", authKey: String(repeating: "0", count: 32)) // i18n-ignore: UI-test fixture
        return SyncCoordinator(defaults: defaults, credentials: { credentials }, makeClient: { _ in OfflineSyncClient() })
    }

    /// A sync service with no stored positions that accepts every push.
    private struct OfflineSyncClient: KOSyncClientProtocol {
        func authorize() async throws {}
        func createUser() async throws {}
        func pushProgress(_ progress: KOSyncProgress) async throws {}
        func fetchProgress(document: String) async throws -> KOSyncProgress? { nil }
    }

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
            if let seed = AppStoreSeed.current {
                seedAppStore(seed, into: storage, scratch: root)
            } else {
                seedAppStore(into: storage, scratch: root)
            }
        } else if ProcessInfo.processInfo.arguments.contains(seedCoversArgument) {
            seedCovers(into: storage, scratch: root)
        }
        return storage
    }

    /// The three public-domain titles of the covers and App Store libraries, with their cover colours.
    private static let coverBooks: [(hash: String, title: String, author: String, color: UInt32)] = [
        ("00000000000000000000000000e00a02", "The Gods of Mars", "Edgar Rice Burroughs", 0xE8833A), // i18n-ignore: UI-test fixture
        ("00000000000000000000000000e00a01", "Emma", "Jane Austen", 0x30B0C7), // i18n-ignore: UI-test fixture
        ("00000000000000000000000000e00a03", "Twenty Thousand Leagues Under the Seas", "Jules Verne", 0x5856D6), // i18n-ignore: UI-test fixture
    ]

    /// A one-paragraph book with the given title and author.
    private static func placeholderBook(hash: String, title: String, author: String) -> ProcessedBook {
        let text = "Chapter one." // i18n-ignore: UI-test fixture (Debug only)
        return ProcessedBook(metadata: BookMetadata(title: title, authors: [author]), documentHash: hash,
                             metaHash: hash + "m",
                             chapters: [Chapter(spineIndex: 1, title: nil, blocks: [
                                 Block(text: text, xpointer: "/body/DocFragment[1]/body/p", globalOffset: 0)])],
                             totalCharacters: text.count)
    }

    /// Public-domain books; covers are generated (no cover art ships in the app). The sample book has no cover
    /// and is the oldest book of the library.
    private static func seedCovers(into storage: BookStorage, scratch: URL) {
        var entries: [LibraryEntry] = []
        if var lead = seedEntry(sampleBook, into: storage, scratch: scratch) {
            lead.addedAt = Date(timeIntervalSince1970: 0)
            entries.append(lead)
        }
        for (i, b) in coverBooks.enumerated() {
            guard var entry = seedEntry(placeholderBook(hash: b.hash, title: b.title, author: b.author),
                                        into: storage, scratch: scratch) else { continue }
            entry.addedAt = Date(timeIntervalSince1970: TimeInterval(100 - i))
            if let jpeg = generatedCover(b.color) {
                entry.hasCover = storage.saveCover(jpeg, documentHash: b.hash)
            }
            entries.append(entry)
        }
        storage.saveIndex(entries)
    }

    /// The App Store Library: *Pride and Prejudice* (the reader screenshot's book, newest, at its opening) and
    /// the three other titles, every one with a cover showing its title and author (drawn here: no cover art
    /// ships in the app) and the others part-read, as a library in use looks.
    private static func seedAppStore(into storage: BookStorage, scratch: URL) {
        let positions = PositionStore(defaults: defaults)
        let read: [Double] = [0.43, 0.78, 0.12]
        var books: [(book: ProcessedBook, color: UInt32, read: Double)] = [(appStoreBook, 0x7A2E3A, 0)]
        for (i, b) in coverBooks.enumerated() {
            books.append((placeholderBook(hash: b.hash, title: b.title, author: b.author), b.color, read[i]))
        }
        var entries: [LibraryEntry] = []
        for (i, b) in books.enumerated() {
            guard var entry = seedEntry(b.book, into: storage, scratch: scratch) else { continue }
            entry.addedAt = Date(timeIntervalSince1970: TimeInterval(1_000 - i))
            if let jpeg = titleCover(title: b.book.metadata.title, author: b.book.metadata.authors.first ?? "",
                                     rgb: b.color) {
                entry.hasCover = storage.saveCover(jpeg, documentHash: b.book.documentHash)
            }
            if b.read > 0 {
                positions.save(StoredPosition(position: BookPosition(chapterIndex: 0, blockIndex: 0), percentage: b.read),
                               for: b.book.documentHash)
            }
            entries.append(entry)
        }
        storage.saveIndex(entries)
    }

    /// The App Store Library of one language (`UITESTING_APPSTORE_SEED`): its sample book (newest, at its opening;
    /// with `-UITestingAppStoreSepia` further on, in the sepia "Comfortable" look) and three more public-domain
    /// titles with title covers, part-read. The other titles hold a placeholder paragraph: only their rows show.
    private static func seedAppStore(_ seed: AppStoreSeed, into storage: BookStorage, scratch: URL) {
        let positions = PositionStore(defaults: defaults)
        var books: [(book: ProcessedBook, color: UInt32, read: Double)] = [(seed.sampleBook(), seed.sample.color, 0)]
        for b in seed.library {
            books.append((placeholderBook(hash: b.hash, title: b.title, author: b.author), b.color, b.read))
        }
        var entries: [LibraryEntry] = []
        for (i, b) in books.enumerated() {
            guard var entry = seedEntry(b.book, into: storage, scratch: scratch) else { continue }
            entry.addedAt = Date(timeIntervalSince1970: TimeInterval(1_000 - i))
            if let jpeg = titleCover(title: b.book.metadata.title, author: b.book.metadata.authors.first ?? "",
                                     rgb: b.color) {
                entry.hasCover = storage.saveCover(jpeg, documentHash: b.book.documentHash)
            }
            if b.read > 0 {
                positions.save(StoredPosition(position: BookPosition(chapterIndex: 0, blockIndex: 0), percentage: b.read),
                               for: b.book.documentHash)
            }
            entries.append(entry)
        }
        storage.saveIndex(entries)
        if ProcessInfo.processInfo.arguments.contains(appStoreSepiaArgument) {
            let book = books[0].book
            let chapter = min(seed.sepia.chapter, book.chapters.count - 1)
            let block = min(seed.sepia.block, book.chapters[chapter].blocks.count - 1)
            let offset = book.chapters[chapter].blocks[block].globalOffset
            positions.save(StoredPosition(position: BookPosition(chapterIndex: chapter, blockIndex: block),
                                          percentage: Double(offset) / Double(max(book.totalCharacters, 1))),
                           for: book.documentHash)
            var look = ReaderTypography().applying(.comfortable)
            look.theme = .sepia
            TypographyStore(defaults: defaults).save(look)
        }
    }

    /// A 72 × 108 px JPEG (the size the iPhone sends) laid out like a printed cover: a colour field, a thin
    /// frame, the title in a bold serif at the top and the author at the bottom.
    static func titleCover(title: String, author: String, rgb: UInt32) -> Data? {
        let w = 72, h = 108
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255, g = CGFloat((rgb >> 8) & 0xFF) / 255, b = CGFloat(rgb & 0xFF) / 255
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let isLight = 0.299 * r + 0.587 * g + 0.114 * b > 0.6
        let ink = isLight ? CGColor(gray: 0.1, alpha: 1) : CGColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(ink.copy(alpha: 0.55) ?? ink)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 3.5, y: 3.5, width: CGFloat(w) - 7, height: CGFloat(h) - 7))
        ctx.textMatrix = .identity
        // CoreText's origin is the bottom left, as the context's: the title box is the upper part.
        drawCentered(title, maxSize: 12, minSize: 7, weight: .bold, color: ink, in: CGRect(x: 7, y: 34, width: 58, height: 66), ctx)
        drawCentered(author, maxSize: 7, minSize: 5, weight: .regular, color: ink, in: CGRect(x: 7, y: 8, width: 58, height: 20), ctx)
        guard let image = ctx.makeImage() else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }

    /// Draws `text` centred in `rect`, top-aligned, at the largest size from `maxSize` down at which it fits
    /// without breaking a word.
    private static func drawCentered(_ text: String, maxSize: CGFloat, minSize: CGFloat, weight: UIFont.Weight,
                                     color: CGColor, in rect: CGRect, _ ctx: CGContext) {
        var alignment = CTTextAlignment.center
        let paragraph: CTParagraphStyle = withUnsafePointer(to: &alignment) { pointer in
            var settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                    value: pointer)]
            return CTParagraphStyleCreate(&settings, settings.count)
        }
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        func font(_ size: CGFloat) -> UIFont {
            let system = UIFont.systemFont(ofSize: size, weight: weight)
            return system.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? system
        }
        func setter(_ size: CGFloat) -> CTFramesetter {
            CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                fontKey: font(size),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ]))
        }
        func fits(_ size: CGFloat) -> Bool {
            let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter(size), CFRange(location: 0, length: 0), nil,
                                                                      CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
            guard needed.height <= rect.height else { return false }
            let wordFont = font(size)
            return text.split(separator: " ").allSatisfy { word in
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(word),
                                                                               attributes: [fontKey: wordFont]))
                return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) <= rect.width
            }
        }
        var size = maxSize
        while size > minSize && !fits(size) { size -= 0.5 }
        let frame = CTFramesetterCreateFrame(setter(size), CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
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
            if let seed = AppStoreSeed.current {
                seedSampleDictionary(seed.dictionary, into: directory)
            } else {
                seedSampleDictionary(into: directory)
            }
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

    /// The sample dictionary of one language (`AppStoreSeed.dictionary`), written like the English one.
    private static func seedSampleDictionary(_ dictionary: AppStoreSeed.SampleDictionary, into directory: URL) {
        let source = "Sample dictionary" // i18n-ignore: UI-test fixture (Debug only)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let writer = try CompactDictionaryWriter(url: directory.appendingPathComponent(InstalledDictionaries.fileName(for: dictionary.id)))
            for e in dictionary.entries {
                let senses = e.senses.map { DictionarySense(definition: $0.definition, examples: $0.examples ?? []) }
                let entry = DictionaryEntry(word: e.word, language: dictionary.language, pronunciation: e.pronunciation,
                                            meanings: [DictionaryMeaning(partOfSpeech: e.partOfSpeech, senses: senses)],
                                            source: source)
                let ref = try writer.add(entry)
                writer.addKey(entry.word, ref: ref)
                for form in e.forms { writer.addKey(form, ref: ref, isHeadword: false) }
            }
            _ = try writer.finish(info: CompactDictionaryInfo(id: dictionary.id, name: source, language: dictionary.language,
                                                              source: source, license: "", licenseURL: "",
                                                              attribution: source, sourceURL: "", sourceVersion: ""))
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
    @MainActor static func makeSync() -> SyncCoordinator { SyncCoordinator() }
    #endif
}
