import Foundation
import ReaderCore

/// Launch arguments used by the UI test target (FolitoUITests). Compiled into Debug builds only, so
/// a Release / App Store build has no test hooks at all.
///
/// - `-UITesting`: the library lives in a fresh temporary directory, so every launch starts empty and the
///   user's real library is never touched.
/// - `-UITestingSeedSampleBook` (implies `-UITesting`): also adds one small built-in sample book, so the
///   non-empty library can be audited.
enum UITesting {
    static let isolateArgument = "-UITesting"
    static let seedSampleBookArgument = "-UITestingSeedSampleBook"

    #if DEBUG
    static var isActive: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains(isolateArgument) || args.contains(seedSampleBookArgument)
    }

    /// Root directory for `LibraryStore`; nil means the normal Application Support location.
    static var libraryRoot: URL? {
        guard isActive else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("UITesting-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    static func makeLibrary() -> LibraryStore {
        let store = LibraryStore(rootDirectory: libraryRoot)
        if ProcessInfo.processInfo.arguments.contains(seedSampleBookArgument) {
            try? store.addForUITesting(sampleBook, fileName: "sample.epub")
        }
        return store
    }

    /// A tiny public-domain text (Lewis Carroll, 1865), built in code: no EPUB file ships in the app.
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
    @MainActor
    static func makeLibrary() -> LibraryStore { LibraryStore() }
    #endif
}
