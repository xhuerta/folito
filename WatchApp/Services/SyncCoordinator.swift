import Foundation
import os
import SwiftUI
import ReaderCore

enum SyncStatus: Equatable {
    case idle, syncing, offline, error
}

/// What went wrong when the status is `.error` (anything that is not "offline"), so the reader can explain
/// the glyph when it is tapped.
enum SyncFailure: Equatable {
    /// The server rejected the account (wrong credentials, expired session).
    case unauthorized
    /// Any other failure: the server answered with an error or something unexpected.
    case server
}

/// Maps errors to the user-visible status. Pure, unit-tested.
enum SyncErrorClassifier {
    static func status(for error: Error) -> SyncStatus {
        SyncErrors.isOffline(error) ? .offline : .error
    }

    /// The failure behind an `.error` status; nil when the error only means "offline".
    static func failure(for error: Error) -> SyncFailure? {
        if SyncErrors.isOffline(error) { return nil }
        return SyncErrors.isUnauthorized(error) ? .unauthorized : .server
    }
}

/// Bridges `SyncQueue` (which owns one connector for its lifetime) to settings that can change at any
/// time: the active connector is resolved on every call. Without one every call fails with
/// `.notConfigured`, which `SyncQueue` keeps queued without counting an attempt.
struct ActiveSyncConnector: SyncConnector {
    let resolve: @Sendable () -> SyncConnector?
    /// Reports the outcome of each push (nil = success) so the UI status can follow the queue's worker.
    let observer: SyncObserver
    /// Remembers each accepted push, so this device's own position is not offered back on open (#105).
    let ownProgress: OwnProgressLog

    var descriptor: SyncConnectorDescriptor { resolve()?.descriptor ?? UnconfiguredConnector.descriptorValue }

    private func connector() throws -> SyncConnector {
        guard let c = resolve() else { throw SyncConnectorError.notConfigured }
        return c
    }

    func authorize() async throws { try await connector().authorize() }

    func fetchProgress(for book: BookIdentity) async throws -> ReadingPosition? {
        try await connector().fetchProgress(for: book)
    }

    func pushProgress(_ position: ReadingPosition, for book: BookIdentity) async throws {
        let c = try connector()
        do {
            try await c.pushProgress(position, for: book)
            ownProgress.record(position, connectorID: c.descriptor.id, bookKey: book.key)
            observer.pushed(nil)
        } catch {
            observer.pushed(error)
            throw error
        }
    }
}

/// Thread-safe hop from the `SyncQueue` actor / worker back to the main-actor coordinator.
final class SyncObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var onPush: (@MainActor (Error?) -> Void)?
    private var onPending: (@MainActor (Int) -> Void)?

    func install(onPush: @escaping @MainActor (Error?) -> Void, onPending: @escaping @MainActor (Int) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.onPush = onPush
        self.onPending = onPending
    }

    func pushed(_ error: Error?) {
        lock.lock(); let h = onPush; lock.unlock()
        if let h { Task { @MainActor in h(error) } }
    }

    func pendingChanged(_ count: Int) {
        lock.lock(); let h = onPending; lock.unlock()
        if let h { Task { @MainActor in h(count) } }
    }
}

/// Thin sync layer for the watch: conflict check on open, plus progress pushes delegated to
/// ReaderCore's `SyncQueue` (latest entry per document, debounce, exponential backoff, attempt cap,
/// persistence). Connector-agnostic: the active `SyncConnector` (KOReader Sync, Readest, ...) comes from
/// `CredentialsStore`. Policy: push when leaving a book and when the app goes to background (immediate),
/// roughly every 60 s while reading (debounced), and offline retries via the queue's backoff.
@MainActor
final class SyncCoordinator: ObservableObject {
    static let queueKey = "sync.queue.v1"
    /// Open-check diagnostics (Console.app, category "sync"): the service's row next to what the watch made
    /// of it, so a wrong offer can be traced to the row's fields.
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Folito", category: "sync")

    @Published private(set) var status: SyncStatus = .idle
    /// Why the last sync failed; meaningful while `status == .error`.
    @Published private(set) var failure: SyncFailure?
    @Published private(set) var isConfigured: Bool = false
    @Published private(set) var pendingCount: Int = 0

    let device: DeviceIdentity
    let queue: SyncQueue
    /// Last position this device pushed per connector and book (services without device ids, #105).
    let ownProgress: OwnProgressLog
    /// Synced (ahead) and declined remote positions per book, and the books' sync identities (#132).
    let remoteMemory: SyncedProgressStore
    private let policy: SyncConflictPolicy
    private let connector: @Sendable () -> SyncConnector?
    private var chain: Task<Void, Never>?
    /// The remote position as the service returned it (CFI not yet placed) for each book with an open
    /// offer, so declining remembers exactly that row.
    private var offered: [String: ReadingPosition] = [:]

    init(device: DeviceIdentity = DeviceIdentity(),
         defaults: UserDefaults = .standard,
         policy: SyncConflictPolicy = DefaultSyncConflictPolicy(),
         config: SyncQueue.Config = SyncQueue.Config(),
         clock: SyncClock = SystemSyncClock(),
         connector: @escaping @Sendable () -> SyncConnector? = { CredentialsStore.activeConnector() }) {
        self.device = device
        self.policy = policy
        self.connector = connector
        let observer = SyncObserver()
        let ownProgress = OwnProgressLog(defaults: defaults)
        self.ownProgress = ownProgress
        self.remoteMemory = SyncedProgressStore(defaults: defaults)
        let restored = defaults.data(forKey: Self.queueKey)
        self.queue = SyncQueue(
            connector: ActiveSyncConnector(resolve: connector, observer: observer, ownProgress: ownProgress),
            clock: clock, config: config, restoring: restored,
            onChange: { data in
                defaults.set(data, forKey: Self.queueKey)
                let count = (try? JSONDecoder().decode([PendingProgress].self, from: data))?.count ?? 0
                observer.pendingChanged(count)
            })
        let active = connector()
        self.isConfigured = active != nil
        self.pendingCount = restored.flatMap { try? JSONDecoder().decode([PendingProgress].self, from: $0) }?.count ?? 0
        observer.install(
            onPush: { [weak self] error in
                guard let self else { return }
                self.record(error)
            },
            onPending: { [weak self] count in self?.pendingCount = count })

        let queue = self.queue
        let activeID = active?.descriptor.id
        Task {
            if let activeID {
                await queue.retainOnly(connectorID: activeID)
                await queue.resume()
            } else if restored != nil {
                // Sync is optional: progress still queued once no service is configured is dropped.
                await queue.removeAll()
            }
        }
    }

    /// KOSync-only initializer (tests and previews written before connectors).
    convenience init(device: DeviceIdentity = DeviceIdentity(),
                     defaults: UserDefaults = .standard,
                     policy: SyncConflictPolicy = DefaultSyncConflictPolicy(),
                     config: SyncQueue.Config = SyncQueue.Config(),
                     clock: SyncClock = SystemSyncClock(),
                     credentials: @escaping @Sendable () -> KOSyncCredentials?,
                     makeClient: @escaping @Sendable (KOSyncCredentials) -> KOSyncClientProtocol = { KOSyncClient(credentials: $0) }) {
        self.init(device: device, defaults: defaults, policy: policy, config: config, clock: clock,
                  connector: { credentials().map { KOSyncConnector(client: makeClient($0)) as SyncConnector } })
    }

    /// Call when settings changed (new credentials or another service) or the app returns to foreground.
    func configurationChanged() {
        guard let active = connector() else {
            isConfigured = false
            // Credentials removed (or never set): nothing may stay queued and the UI shows no sync state.
            resetPending()
            // The complications and the Library show the local positions again.
            remoteMemory.clearAllSynced()
            return
        }
        isConfigured = true
        // Switching services: positions queued for the previous one are never sent to the new one.
        let queue = self.queue
        let id = active.descriptor.id
        let previous = chain
        chain = Task {
            await previous?.value
            await queue.retainOnly(connectorID: id)
            await queue.resume()
        }
    }

    /// Restarts delivery of queued progress (entries still honour their backoff). Called on foreground
    /// and from the ~60 s foreground timer.
    func retryPending() {
        guard isConfigured else { return }
        let queue = self.queue
        Task { await queue.resume() }
    }

    /// The active connector's id (`"readest"`, `"kosync"`, ...), nil when sync is off.
    var activeConnectorID: String? { connector()?.descriptor.id }

    // MARK: Open-book check

    /// Fetches the remote position and applies the conflict policy. Failures degrade to `.keepLocal`.
    /// Forward only, like Readest and KOReader (#112): a remote position is offered only when it is ahead of
    /// `local` by more than the policy's threshold; one that is behind is ignored silently.
    /// The remote position is never offered when it is the spot `local` is at or the last position this
    /// device pushed: Readest keeps no device id, so that is how the watch recognises its own write (#105).
    ///
    /// `resolveRemote` places what only the reader can place (Readest's CFI, `ReadingPosition.resolvingCFI`):
    /// a mixed Readest row whose CFI is further than its XPointer is then judged at the CFI spot.
    func decisionOnOpen(book: BookIdentity, local: ReadingPosition,
                        resolveRemote: (ReadingPosition) -> ReadingPosition = { $0 }) async -> ProgressDecision {
        // The background refresh asks for the book the complications show with this identity (#132).
        remoteMemory.setIdentity(book)
        guard let connector = connector() else { return .keepLocal }
        status = .syncing
        do {
            let raw = try await connector.fetchProgress(for: book)
            status = .idle
            // The book is open: what the refresh found is answered by the offer below (or is stale).
            remoteMemory.clearSynced(for: book.key)
            offered.removeValue(forKey: book.key)
            guard let raw else { return .keepLocal }
            // "Stay Here" was the answer to this very row: not offered again until the service changes (#132).
            if let declined = remoteMemory.declined(for: book.key), declined.matches(raw) { return .keepLocal }
            let lastPushed = ownProgress.lastPushed(connectorID: connector.descriptor.id, bookKey: book.key)
            let resolved = resolveRemote(raw)
            let decision = policy.decide(local: local, remote: resolved, ownDeviceID: device.id,
                                         lastPushed: lastPushed)
            let row = "cfi=\(raw.cfi ?? "-") xpointer=\(raw.xpointer) pct=\(raw.percentage) progress=\(raw.page ?? 0)/\(raw.pageCount ?? 0)"
            let made = "xpointer=\(resolved.xpointer) pct=\(resolved.percentage)"
            let here = "local=\(local.xpointer) pct=\(local.percentage) lastPushed=\(lastPushed?.xpointer ?? "-")"
            Self.log.debug("open check \(connector.descriptor.id, privacy: .public): row \(row, privacy: .public) -> \(made, privacy: .public); \(here, privacy: .public)")
            if case .offerRemote = decision { offered[book.key] = raw }
            return decision
        } catch {
            record(error)
            return .keepLocal
        }
    }

    /// The user answered "Stay Here": the offered row is not offered again, nor shown as synced progress,
    /// until the service holds another position for the book.
    func offerDeclined(book: BookIdentity) {
        guard let raw = offered.removeValue(forKey: book.key) else { return }
        remoteMemory.setDeclined(RemoteFingerprint(raw), for: book.key)
        remoteMemory.clearSynced(for: book.key)
    }

    /// The user went to a remote position ("Go to Position" or "Go to Synced Position"): the local position
    /// is now the synced one.
    func offerAccepted(book: BookIdentity) {
        offered.removeValue(forKey: book.key)
        remoteMemory.clearDeclined(for: book.key)
        remoteMemory.clearSynced(for: book.key)
    }

    // MARK: Glance refresh (#132)

    /// What `refreshSynced` found.
    enum SyncedRefresh: Equatable {
        /// The service is further than the local position (not this watch's own write, not declined):
        /// stored as the synced position.
        case ahead(ReadingPosition)
        /// Nothing newer on the service (missing, behind, own or declined): any synced position is dropped.
        case nothing
        /// Sync is off: no request; synced positions are dropped, the local positions are shown.
        case off
        /// The request failed: nothing changes.
        case failed
    }

    /// One GET of `book`'s remote position for the complications and the Library (background refresh,
    /// launch, foreground). Same rules as the open-time offer, but quiet: the reader's sync status is not
    /// touched. `resolveRemote` may load the book to place a Readest CFI.
    func refreshSynced(book: BookIdentity, local: ReadingPosition,
                       resolveRemote: (ReadingPosition) async -> ReadingPosition = { $0 }) async -> SyncedRefresh {
        guard let connector = connector() else {
            remoteMemory.clearAllSynced()
            return .off
        }
        let raw: ReadingPosition?
        do {
            raw = try await connector.fetchProgress(for: book)
        } catch {
            return .failed
        }
        guard let raw, remoteMemory.declined(for: book.key)?.matches(raw) != true else {
            remoteMemory.clearSynced(for: book.key)
            return .nothing
        }
        let remote = await resolveRemote(raw)
        let lastPushed = ownProgress.lastPushed(connectorID: connector.descriptor.id, bookKey: book.key)
        guard case .offerRemote(let ahead) = policy.decide(local: local, remote: remote, ownDeviceID: device.id,
                                                           lastPushed: lastPushed) else {
            remoteMemory.clearSynced(for: book.key)
            return .nothing
        }
        remoteMemory.setSynced(ahead, for: book.key)
        return .ahead(ahead)
    }

    /// What "Go to Synced Position" in the reader menu found on the service.
    enum SyncedPosition: Equatable {
        case position(ReadingPosition)
        /// The service has no position for this book.
        case missing
        /// Sync is off (no service set up).
        case notConfigured
        /// The service could not be reached or answered with an error (the status explains it).
        case failed
    }

    /// The remote position for `book`, fetched on demand and returned whatever its direction (#112).
    /// The open-time check only offers a position that is ahead, like Readest and KOReader; this is the
    /// manual way back to a position that is behind the local one.
    /// `resolveRemote` is the same as for `decisionOnOpen`, so the menu goes where the offer would.
    func syncedPosition(book: BookIdentity,
                        resolveRemote: (ReadingPosition) -> ReadingPosition = { $0 }) async -> SyncedPosition {
        guard let connector = connector() else { isConfigured = false; return .notConfigured }
        status = .syncing
        do {
            let remote = try await connector.fetchProgress(for: book).map(resolveRemote)
            status = .idle
            return remote.map { SyncedPosition.position($0) } ?? .missing
        } catch {
            record(error)
            return .failed
        }
    }

    /// Percentage-only form (tests written before positions carried an XPointer).
    func decisionOnOpen(book: BookIdentity, localPercentage: Double) async -> ProgressDecision {
        await decisionOnOpen(book: book, local: ReadingPosition(xpointer: "", percentage: localPercentage))
    }

    func decisionOnOpen(document: String, localPercentage: Double) async -> ProgressDecision {
        await decisionOnOpen(book: BookIdentity(partialMD5: document), localPercentage: localPercentage)
    }

    // MARK: Push

    /// Records the latest position for `book`. With `immediately == false` the push is debounced by the
    /// queue; otherwise it is flushed now and, on a transient failure, retried with backoff.
    func report(book: BookIdentity, xpointer: String, percentage: Double, page: Int? = nil, pageCount: Int? = nil,
                immediately: Bool) {
        // Sync is optional: without credentials nothing is queued or persisted (PositionStore keeps the
        // local position). When credentials arrive later the open-time check + conflict policy apply.
        guard let active = connector() else { isConfigured = false; return }
        isConfigured = true
        let entry = SyncEntry(
            connectorID: active.descriptor.id, book: book,
            position: ReadingPosition(xpointer: xpointer, percentage: min(max(percentage, 0), 1),
                                      page: page, pageCount: pageCount, timestamp: Date(),
                                      deviceID: device.id, deviceName: device.name))
        let queue = self.queue
        // Chained so that two quick reports reach the queue in call order.
        let previous = chain
        chain = Task {
            await previous?.value
            if immediately {
                await queue.enqueue(entry)
                let result = await queue.flush()
                if !result.retained.isEmpty && !result.unauthorized { await queue.resume() }
            } else {
                await queue.schedule(entry)
            }
        }
    }

    func report(document: String, xpointer: String, percentage: Double, immediately: Bool) {
        report(book: BookIdentity(partialMD5: document), xpointer: xpointer, percentage: percentage,
               immediately: immediately)
    }

    /// Forgets queued progress for a deleted book.
    func discard(document: String) {
        let queue = self.queue
        let previous = chain
        chain = Task {
            await previous?.value
            await queue.remove(document: document)
        }
        ownProgress.remove(bookKey: document)
        remoteMemory.remove(bookKey: document)
    }

    var hasPending: Bool { pendingCount > 0 }

    // MARK: Settings screen

    enum ConnectionResult: Equatable {
        case notConfigured, ok, unauthorized, offline, failed
        /// The service ended the session (Readest refresh token rejected): sign in again on the iPhone.
        case signInAgain
    }

    /// Sets the status (and the failure behind it) from the outcome of a sync call; nil means success.
    private func record(_ error: Error?) {
        guard let error else { status = .idle; failure = nil; return }
        status = SyncErrorClassifier.status(for: error)
        failure = SyncErrorClassifier.failure(for: error)
    }

    func testConnection() async -> ConnectionResult {
        guard let connector = connector() else { return .notConfigured }
        status = .syncing
        do {
            try await connector.authorize()
            status = .idle
            return .ok
        } catch {
            record(error)
            if SyncErrors.isUnauthorized(error) {
                return connector.descriptor.usesSession ? .signInAgain : .unauthorized
            }
            return status == .offline ? .offline : .failed
        }
    }

    func resetPending() {
        let queue = self.queue
        let previous = chain
        chain = Task {
            await previous?.value
            await queue.removeAll()
        }
        pendingCount = 0
        status = .idle
    }
}
