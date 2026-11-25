import XCTest
import ReaderCore
@testable import FolitoWatch

private func book(_ id: String, _ title: String, author: String = "", added: TimeInterval,
                  finished: Bool = false) -> LibraryEntry {
    LibraryEntry(documentHash: id, title: title, author: author, totalCharacters: 100,
                 addedAt: Date(timeIntervalSince1970: added),
                 readStatus: finished ? ReadStatusMark(status: .finished, stamp: 1) : nil)
}

private func snapshot(_ id: String) -> ReadingSnapshot {
    ReadingSnapshot(bookID: id, title: "T", chapterTitle: nil, fraction: 0.3)
}

/// "Continue Reading" / "Open Book" (App Intents, #68).
final class ContinueReadingResolverTests: XCTestCase {
    private let library = [book("old", "Emma", added: 1), book("new", "Persuasion", added: 3),
                           book("mid", "Sanditon", added: 2)]

    func testSnapshotBookWins() {
        let progress: [String: Double] = ["new": 0.5, "mid": 0.2]
        let entry = ContinueReadingResolver.book(snapshot: snapshot("old"), entries: library,
                                                 progress: { progress[$0] })
        XCTAssertEqual(entry?.documentHash, "old")
    }

    func testFinishedSnapshotBookStillOpens() {
        let entries = [book("done", "Emma", added: 1, finished: true), book("b", "Persuasion", added: 2)]
        let entry = ContinueReadingResolver.book(snapshot: snapshot("done"), entries: entries, progress: { _ in 0.4 })
        XCTAssertEqual(entry?.documentHash, "done")
    }

    func testWithoutSnapshotNewestStartedUnfinishedBook() {
        let entries = library + [book("newest-finished", "Lady Susan", added: 9, finished: true),
                                 book("newest-unread", "Love and Freindship", added: 8)]
        let progress: [String: Double] = ["old": 0.1, "mid": 0.6, "newest-finished": 0.9]
        let entry = ContinueReadingResolver.book(snapshot: nil, entries: entries, progress: { progress[$0] })
        XCTAssertEqual(entry?.documentHash, "mid")
    }

    func testDeletedSnapshotBookFallsBack() {
        let progress: [String: Double] = ["old": 0.1]
        let entry = ContinueReadingResolver.book(snapshot: snapshot("gone"), entries: library,
                                                 progress: { progress[$0] })
        XCTAssertEqual(entry?.documentHash, "old")
    }

    func testNothingInProgress() {
        XCTAssertNil(ContinueReadingResolver.book(snapshot: nil, entries: library, progress: { _ in nil }))
        XCTAssertNil(ContinueReadingResolver.book(snapshot: nil, entries: library, progress: { _ in 0 }))
        XCTAssertNil(ContinueReadingResolver.book(snapshot: snapshot("x"), entries: [], progress: { _ in 1 }))
    }

    func testDeepLink() {
        XCTAssertEqual(ContinueReadingResolver.deepLink(for: library[0]), .book(id: "old"))
        XCTAssertEqual(ContinueReadingResolver.deepLink(for: nil), .library)
        XCTAssertEqual(ContinueReadingResolver.deepLink(for: book("not/a valid id", "X", added: 0)), .library)
        // The same URL a complication tap opens.
        XCTAssertEqual(ContinueReadingResolver.deepLink(for: library[0]).url.absoluteString, "folito://book/old")
    }

    func testStoredLocalSnapshotPrefersTheReadersOwn() throws {
        let suite = "ContinueReadingResolverTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sharedSuite = suite + ".shared"
        let sharedDefaults = try XCTUnwrap(UserDefaults(suiteName: sharedSuite))
        defer { sharedDefaults.removePersistentDomain(forName: sharedSuite) }
        let shared = ReadingSnapshotStore(defaults: sharedDefaults)

        XCTAssertNil(ComplicationPublisher.storedLocalSnapshot(defaults: defaults, shared: shared))
        shared.save(snapshot("shown"))
        XCTAssertEqual(ComplicationPublisher.storedLocalSnapshot(defaults: defaults, shared: shared)?.bookID, "shown")
        ReadingSnapshotStore(defaults: defaults, key: ComplicationPublisher.localSnapshotKey).save(snapshot("own"))
        XCTAssertEqual(ComplicationPublisher.storedLocalSnapshot(defaults: defaults, shared: shared)?.bookID, "own")
    }
}

final class BookEntityLookupTests: XCTestCase {
    private let library = [book("a", "Jane Eyre", author: "Charlotte Brontë", added: 1),
                           book("b", "Emma", author: "Jane Austen", added: 3, finished: true),
                           book("c", "Persuasion", author: "Jane Austen", added: 2)]

    func testSuggestedInLibraryOrder() {
        // Newest first, finished books last (as in the Library).
        XCTAssertEqual(BookEntityLookup.suggested(library).map(\.documentHash), ["c", "a", "b"])
    }

    func testEntitiesForIdentifiersKeepsOrderAndDropsUnknown() {
        XCTAssertEqual(BookEntityLookup.entries(for: ["b", "gone", "a"], in: library).map(\.documentHash), ["b", "a"])
        XCTAssertTrue(BookEntityLookup.entries(for: [], in: library).isEmpty)
    }

    func testMatchingTitleAndAuthorIgnoringCaseAndDiacritics() {
        XCTAssertEqual(BookEntityLookup.matching("bronte", in: library).map(\.documentHash), ["a"])
        XCTAssertEqual(BookEntityLookup.matching("JANE", in: library).map(\.documentHash), ["c", "a", "b"])
        XCTAssertEqual(BookEntityLookup.matching("austen emma", in: library).map(\.documentHash), ["b"])
        XCTAssertEqual(BookEntityLookup.matching("persuasion, austen", in: library).map(\.documentHash), ["c"])
        XCTAssertTrue(BookEntityLookup.matching("dickens", in: library).isEmpty)
    }

    func testEmptyQueryMatchesEveryBook() {
        XCTAssertEqual(BookEntityLookup.matching("  ", in: library).map(\.documentHash), ["c", "a", "b"])
    }

    func testBookEntity() {
        let entity = BookEntity(library[0])
        XCTAssertEqual(entity.id, "a")
        XCTAssertEqual(entity.title, "Jane Eyre")
        XCTAssertEqual(entity.author, "Charlotte Brontë")
    }
}

@MainActor
final class IntentRouterTests: XCTestCase {
    func testLinkBeforeAttachIsDeliveredOnAttach() {
        let router = IntentRouter()
        router.open(.library)
        router.open(.book(id: "abc"))
        XCTAssertEqual(router.pending, .book(id: "abc"))
        var received: [FolitoDeepLink] = []
        router.attach { received.append($0) }
        XCTAssertEqual(received, [.book(id: "abc")])
        XCTAssertNil(router.pending)
    }

    func testLinkAfterAttachGoesStraightThrough() {
        let router = IntentRouter()
        var received: [FolitoDeepLink] = []
        router.attach { received.append($0) }
        XCTAssertTrue(received.isEmpty)
        router.open(.book(id: "x"))
        router.open(.library)
        XCTAssertEqual(received, [.book(id: "x"), .library])
        XCTAssertNil(router.pending)
    }
}
