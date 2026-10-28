import Foundation
import ReaderCore

/// Launch arguments used by the watch UI test target (WristReaderWatchUITests). The hooks are compiled into
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

    #if DEBUG
    static let isActive: Bool = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains(isolateArgument) || args.contains(seedSampleBookArgument)
    }()

    private static let defaultsSuite = "WristReader.UITesting"

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
        return storage
    }

    /// Stores `book` exactly as a transfer from the iPhone would (LZFSE-compressed JSON) and indexes it.
    private static func seed(_ book: ProcessedBook, into storage: BookStorage, scratch: URL) {
        let file = scratch.appendingPathComponent("seed.book")
        guard let json = try? JSONEncoder().encode(book),
              let compressed = try? (json as NSData).compressed(using: .lzfse) as Data,
              (try? compressed.write(to: file, options: .atomic)) != nil,
              let entry = try? storage.importBook(from: file) else { return }
        try? FileManager.default.removeItem(at: file)
        storage.saveIndex([entry])
    }

    /// A tiny public-domain text (Lewis Carroll, 1865), built in code: no book file ships in the app.
    /// Same content as the iPhone's UI-testing sample.
    static let sampleBook: ProcessedBook = {
        let text = "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do."
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
    #endif
}
