import Foundation
import ReaderCore

#if DEBUG
/// One language's App Store screenshot seed (`AppStoreSeeds/<lang>.json`, built by
/// scripts/make_appstore_seeds.py; docs/appstore/SCREENSHOTS.md). Debug builds only: the localized screenshot
/// suites pass the file's path in `UITESTING_APPSTORE_SEED` (with `-UITestingSeedCovers` on the iPhone,
/// `-UITestingSeedAppStore` on the watch), and the apps seed their Library from it instead of the English fixtures.
struct AppStoreSeed: Decodable {
    struct SeedChapter: Decodable {
        let title: String?
        /// Table-of-contents label when it differs from the heading (a bare "一" reads as a dash in a list).
        let toc: String?
        let paragraphs: [String]
    }

    struct Sample: Decodable {
        let title: String
        let author: String
        let year: Int
        let language: String
        let color: UInt32
        let hash: String
        let chapters: [SeedChapter]
    }

    struct LibraryBook: Decodable {
        let title: String
        let author: String
        let color: UInt32
        /// Reading progress shown in the Library (0...1).
        let read: Double
        /// How many times the sample text is repeated as this book's text, so its size looks like a book's.
        let repeats: Int
        let hash: String
        /// Name of a full text in the iPhone UI test bundle's `AppStoreBooks` folder (English only).
        let text: String?
    }

    struct Lookup: Decodable {
        let word: String
        let chapter: Int
        let block: Int
        let probe: String
    }

    struct Sense: Decodable {
        let definition: String
        let examples: [String]?
    }

    struct Entry: Decodable {
        let word: String
        let pronunciation: String
        let partOfSpeech: String
        let senses: [Sense]
        let forms: [String]
    }

    struct SampleDictionary: Decodable {
        let id: String
        let language: String
        let entries: [Entry]
    }

    struct Position: Decodable {
        let chapter: Int
        let block: Int
    }

    let language: String
    let shortTitle: String
    let sample: Sample
    let library: [LibraryBook]
    let lookup: Lookup
    let dictionary: SampleDictionary
    let sepia: Position

    static let environmentKey = "UITESTING_APPSTORE_SEED"

    /// The seed named by `UITESTING_APPSTORE_SEED`, or nil (the English fixtures are used).
    static let current: AppStoreSeed? = {
        guard let path = ProcessInfo.processInfo.environment[environmentKey],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        do {
            return try JSONDecoder().decode(AppStoreSeed.self, from: data)
        } catch {
            assertionFailure("App Store seed \(path): \(error)")
            return nil
        }
    }()

    /// The sample book of the language, `times` times over (a Library book's stand-in text).
    func sampleBook(hash: String? = nil, title: String? = nil, author: String? = nil, times: Int = 1) -> ProcessedBook {
        var chapters: [Chapter] = []
        var toc: [TOCEntry] = []
        var offset = 0
        for _ in 0..<max(times, 1) {
            for chapter in sample.chapters {
                let n = chapters.count + 1
                var blocks: [Block] = []
                if let heading = chapter.title {
                    // Like an EPUB nav entry: one per chapter, at its heading, so the watch lists the TOC.
                    toc.append(TOCEntry(title: chapter.toc ?? heading, depth: 0,
                                        position: BookPosition(chapterIndex: chapters.count, blockIndex: 0)))
                    blocks.append(Block(text: heading, style: .heading1, xpointer: "/body/DocFragment[\(n)]/body/h1",
                                        globalOffset: offset))
                    offset += heading.count
                }
                for (i, paragraph) in chapter.paragraphs.enumerated() {
                    blocks.append(Block(text: paragraph, xpointer: "/body/DocFragment[\(n)]/body/p[\(i + 1)]",
                                        globalOffset: offset))
                    offset += paragraph.count
                }
                chapters.append(Chapter(spineIndex: n, title: chapter.title, blocks: blocks))
            }
        }
        let id = hash ?? sample.hash
        return ProcessedBook(metadata: BookMetadata(title: title ?? sample.title, authors: [author ?? sample.author],
                                                    language: sample.language),
                             documentHash: id, metaHash: id + "m",
                             chapters: chapters, totalCharacters: offset,
                             toc: toc.isEmpty ? nil : toc, tocSource: toc.isEmpty ? nil : .nav)
    }
}
#endif
