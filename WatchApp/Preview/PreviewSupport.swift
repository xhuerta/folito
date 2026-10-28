import SwiftUI
import ReaderCore

/// Sample data and mocks for SwiftUI previews only.
enum PreviewSupport {
    struct MockClient: KOSyncClientProtocol {
        var remote: KOSyncProgress?
        func authorize() async throws {}
        func createUser() async throws {}
        func pushProgress(_ progress: KOSyncProgress) async throws {}
        func fetchProgress(document: String) async throws -> KOSyncProgress? { remote }
    }

    static var sampleBook: ProcessedBook {
        var offset = 0
        func block(_ text: String, _ style: BlockStyle = .paragraph, spans: [StyleSpan] = [], n: Int) -> Block {
            defer { offset += text.count }
            return Block(text: text, style: style, spans: spans,
                         xpointer: "/body/DocFragment[1]/body/p[\(n)]/text().0", globalOffset: offset)
        }
        let blocks = [
            block("Chapter One", .heading1, n: 1),
            block("It was a bright cold day in April, and the clocks were striking thirteen.",
                  spans: [StyleSpan(location: 9, length: 6, bold: true, italic: false),
                          StyleSpan(location: 16, length: 4, bold: false, italic: true)], n: 2),
            block("Second paragraph with more text to scroll through.", n: 3),
        ]
        return ProcessedBook(metadata: BookMetadata(title: "Sample", authors: ["A. Author"]),
                             documentHash: "preview", metaHash: "preview",
                             chapters: [Chapter(spineIndex: 1, title: "Chapter One", blocks: blocks)],
                             totalCharacters: offset)
    }
}

#Preview {
    let positions = PositionStore(defaults: UserDefaults(suiteName: "preview") ?? .standard)
    let sync = SyncCoordinator(credentials: { nil })
    return NavigationStack {
        ReaderView(model: ReaderViewModel(book: PreviewSupport.sampleBook, positions: positions, sync: sync))
    }
    .environmentObject(sync)
    .environmentObject(TypographyModel(store: TypographyStore(defaults: UserDefaults(suiteName: "preview") ?? .standard)))
    .preferredColorScheme(.dark)
}
