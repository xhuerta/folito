import XCTest
import Foundation
@testable import ReaderCore

/// Issue #105: the watch offered its own Readest progress back as "1% read on another device".
final class OwnProgressTests: XCTestCase {
    private let policy = DefaultSyncConflictPolicy()
    private let book = BookIdentity(partialMD5: "hash", metaHash: "meta")
    private let me = "watch-1"

    /// The position Folito reports for the first block of a 100-block book: 0 % of the characters, but
    /// page 1 of 100, which Readest reads back as 1 %.
    private func local(block: Int = 0, pct: Double = 0) -> ReadingPosition {
        ReadingPosition(xpointer: "/body/DocFragment[1]/body/p[\(block + 1)]", percentage: pct,
                        page: block + 1, pageCount: 100, timestamp: Date(timeIntervalSince1970: 1000),
                        deviceID: me, deviceName: "Folito")
    }

    /// What `ReadestConnector.fetchProgress` returns after `position` was pushed.
    private func roundTrip(_ position: ReadingPosition) -> ReadingPosition? {
        let row = ReadestProgressMapper.config(for: position, book: book, now: Date())
        return ReadestProgressMapper.position(from: [row], book: book)
    }

    func testOwnProgressRoundTripsWithoutAPrompt() throws {
        let pushed = local()
        let remote = try XCTUnwrap(roundTrip(pushed))
        // The service lost the device id and turned 0 % into page/pageCount = 1 %.
        XCTAssertEqual(remote.deviceID, "")
        XCTAssertEqual(remote.percentage, 0.01, accuracy: 1e-9)
        // The old percentage-only rule offered it: this is the bug.
        XCTAssertEqual(policy.decide(localPercentage: pushed.percentage, remote: remote, ownDeviceID: me),
                       .offerRemote(remote))
        // Reopening at the same spot: no prompt.
        XCTAssertEqual(policy.decide(local: pushed, remote: remote, ownDeviceID: me), .keepLocal)
    }

    func testOwnLastPushedPositionDoesNotPromptAfterMovingBack() throws {
        // Pushed block 50, then went back to block 10 without the later push reaching the service.
        let pushed = local(block: 50, pct: 0.48)
        let remote = try XCTUnwrap(roundTrip(pushed))
        let now = local(block: 10, pct: 0.09)
        XCTAssertEqual(policy.decide(local: now, remote: remote, ownDeviceID: me, lastPushed: pushed), .keepLocal)
        // Without the record it looks like another device ahead.
        XCTAssertEqual(policy.decide(local: now, remote: remote, ownDeviceID: me), .offerRemote(remote))
    }

    func testADifferentDevicesPositionStillPrompts() throws {
        let pushed = local()
        // The Kobo (or Readest) later wrote block 40 of the same file.
        let other = ReadestBookConfig(bookHash: book.partialMD5, metaHash: "meta",
                                      xpointer: "/body/DocFragment[3]/body/p[7]", progress: [120, 300],
                                      updatedAt: Date(timeIntervalSince1970: 2000))
        let remote = try XCTUnwrap(ReadestProgressMapper.position(from: [other], book: book))
        XCTAssertEqual(policy.decide(local: pushed, remote: remote, ownDeviceID: me, lastPushed: pushed),
                       .offerRemote(remote))
    }

    func testKOSyncOwnDeviceIdAndOtherDevice() {
        let pos = local(block: 30, pct: 0.3)
        var mine = local(block: 60, pct: 0.6)
        XCTAssertEqual(policy.decide(local: pos, remote: mine, ownDeviceID: me), .keepLocal)
        mine.deviceID = "kobo"
        XCTAssertEqual(policy.decide(local: pos, remote: mine, ownDeviceID: me), .offerRemote(mine))
        // A remote position behind the local one is never offered.
        XCTAssertEqual(policy.decide(local: local(block: 70, pct: 0.7), remote: mine, ownDeviceID: me), .keepLocal)
    }

    /// Issue #112: forward only, like Readest and KOReader. Ahead prompts; behind (or within the
    /// tolerance) stays silent, from another device as from a Readest row without a device id.
    func testOnlyARemotePositionAheadIsOffered() throws {
        let here = local(block: 50, pct: 0.5)
        var ahead = local(block: 80, pct: 0.8); ahead.deviceID = ""
        var behind = local(block: 20, pct: 0.2); behind.deviceID = ""
        var close = local(block: 51, pct: 0.503); close.deviceID = "kobo"
        XCTAssertEqual(policy.decide(local: here, remote: ahead, ownDeviceID: me), .offerRemote(ahead))
        XCTAssertEqual(policy.decide(local: here, remote: behind, ownDeviceID: me), .keepLocal)
        XCTAssertEqual(policy.decide(local: here, remote: close, ownDeviceID: me), .keepLocal)
        behind.deviceID = "kobo"
        XCTAssertEqual(policy.decide(local: here, remote: behind, ownDeviceID: me), .keepLocal)
        // Through a Readest round trip (percentage rebuilt from page / pageCount) the direction holds.
        let readestAhead = try XCTUnwrap(roundTrip(local(block: 80, pct: 0.8)))
        let readestBehind = roundTrip(local(block: 20, pct: 0.2))
        XCTAssertEqual(policy.decide(local: here, remote: readestAhead, ownDeviceID: me), .offerRemote(readestAhead))
        XCTAssertEqual(policy.decide(local: here, remote: readestBehind, ownDeviceID: me), .keepLocal)
    }

    func testSameSpot() {
        XCTAssertTrue(local(block: 3).isSameSpot(as: local(block: 3, pct: 0.5)))
        XCTAssertFalse(local(block: 3).isSameSpot(as: local(block: 4)))
        let pageOnly = ReadingPosition(xpointer: "", percentage: 0.04, page: 4, pageCount: 100)
        XCTAssertTrue(pageOnly.isSameSpot(as: local(block: 3)))
        XCTAssertFalse(ReadingPosition(xpointer: "", percentage: 0.04).isSameSpot(as: local(block: 3)))
    }

    func testOwnProgressLogPersistsPerConnectorAndBook() throws {
        let suite = "OwnProgressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = OwnProgressLog(defaults: defaults)
        XCTAssertNil(log.lastPushed(connectorID: "readest", bookKey: "a"))
        log.record(local(block: 5), connectorID: "readest", bookKey: "a")
        // A fresh instance (next launch) reads the same value.
        XCTAssertEqual(OwnProgressLog(defaults: defaults).lastPushed(connectorID: "readest", bookKey: "a"), local(block: 5))
        XCTAssertNil(log.lastPushed(connectorID: "kosync", bookKey: "a"))
        XCTAssertNil(log.lastPushed(connectorID: "readest", bookKey: "b"))
        log.remove(bookKey: "a")
        XCTAssertNil(log.lastPushed(connectorID: "readest", bookKey: "a"))
    }

    func testOwnProgressLogIsBounded() throws {
        let suite = "OwnProgressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = OwnProgressLog(defaults: defaults)
        let start = Date(timeIntervalSince1970: 0)
        for i in 0...OwnProgressLog.capacity {
            log.record(local(), connectorID: "readest", bookKey: "b\(i)", now: start.addingTimeInterval(Double(i)))
        }
        XCTAssertNil(log.lastPushed(connectorID: "readest", bookKey: "b0"))
        XCTAssertNotNil(log.lastPushed(connectorID: "readest", bookKey: "b\(OwnProgressLog.capacity)"))
    }
}
