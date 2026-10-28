import XCTest
@testable import ReaderCore

final class SyncQueueRemovalTests: XCTestCase {
    private func prog(_ doc: String) -> KOSyncProgress {
        KOSyncProgress(document: doc, progress: "p", percentage: 0.5, device_id: "me")
    }

    func testRemoveDocumentDropsOnlyThatEntryAndPersists() async {
        let client = FakeClient()
        let saved = Box()
        let q = SyncQueue(client: client, clock: FakeClock(), onChange: { saved.data = $0 })
        await q.enqueue(prog("a")); await q.enqueue(prog("b"))
        await q.remove(document: "a")
        let pending = await q.pending
        XCTAssertEqual(pending.map(\.progress.document), ["b"])
        let restored = try? JSONDecoder().decode([PendingProgress].self, from: saved.data ?? Data())
        XCTAssertEqual(restored?.map(\.progress.document), ["b"])
        let r = await q.flush()
        XCTAssertEqual(r.sent, ["b"])
        XCTAssertEqual(client.pushed.map(\.document), ["b"])
    }

    func testRemoveAllClearsQueue() async {
        let q = SyncQueue(client: FakeClient(), clock: FakeClock())
        await q.enqueue(prog("a")); await q.enqueue(prog("b"))
        await q.removeAll()
        let pending = await q.pending
        XCTAssertTrue(pending.isEmpty)
    }
}

private final class Box: @unchecked Sendable { var data: Data? }
