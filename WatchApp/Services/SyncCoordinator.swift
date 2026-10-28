import Foundation
import SwiftUI
import ReaderCore

enum SyncStatus: Equatable {
    case idle, syncing, offline, error
}

/// Maps errors to the user-visible status. Pure, unit-tested.
enum SyncErrorClassifier {
    static func status(for error: Error) -> SyncStatus {
        if let e = error as? KOSyncError {
            switch e {
            case .offline: return .offline
            default: return .error
            }
        }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            default: return .error
            }
        }
        return .error
    }
}

/// Bridges `SyncQueue` (which owns one client for its lifetime) to credentials that can change at any
/// time: they are looked up on every call. Without credentials every push fails with `.unauthorized`,
/// which `SyncQueue` keeps queued without counting an attempt.
struct CredentialsBackedClient: KOSyncClientProtocol {
    let credentials: @Sendable () -> KOSyncCredentials?
    let makeClient: @Sendable (KOSyncCredentials) -> KOSyncClientProtocol
    /// Reports the outcome of each push (nil = success) so the UI status can follow the queue's worker.
    let observer: SyncObserver

    private func client() throws -> KOSyncClientProtocol {
        guard let c = credentials() else { throw KOSyncError.unauthorized }
        return makeClient(c)
    }

    func authorize() async throws { try await client().authorize() }
    func createUser() async throws { try await client().createUser() }
    func fetchProgress(document: String) async throws -> KOSyncProgress? {
        try await client().fetchProgress(document: document)
    }
    func pushProgress(_ progress: KOSyncProgress) async throws {
        let c = try client()
        do {
            try await c.pushProgress(progress)
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
/// persistence). Policy: PUT when leaving a book and when the app goes to background (immediate),
/// roughly every 60 s while reading (debounced), and offline retries via the queue's backoff.
@MainActor
final class SyncCoordinator: ObservableObject {
    static let queueKey = "sync.queue.v1"
    /// Key used by the previous ad-hoc store (`[document: KOSyncProgress]`); migrated once.
    static let legacyKey = "sync.pendingProgress"

    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var isConfigured: Bool = false
    @Published private(set) var pendingCount: Int = 0

    let device: DeviceIdentity
    let queue: SyncQueue
    private let policy: SyncConflictPolicy
    private let credentials: @Sendable () -> KOSyncCredentials?
    private let makeClient: @Sendable (KOSyncCredentials) -> KOSyncClientProtocol
    private var chain: Task<Void, Never>?

    init(device: DeviceIdentity = DeviceIdentity(),
         defaults: UserDefaults = .standard,
         policy: SyncConflictPolicy = DefaultSyncConflictPolicy(),
         config: SyncQueue.Config = SyncQueue.Config(),
         clock: SyncClock = SystemSyncClock(),
         credentials: @escaping @Sendable () -> KOSyncCredentials? = { CredentialsStore.current() },
         makeClient: @escaping @Sendable (KOSyncCredentials) -> KOSyncClientProtocol = { KOSyncClient(credentials: $0) }) {
        self.device = device
        self.policy = policy
        self.credentials = credentials
        self.makeClient = makeClient
        let observer = SyncObserver()
        let restored = defaults.data(forKey: Self.queueKey)
        self.queue = SyncQueue(
            client: CredentialsBackedClient(credentials: credentials, makeClient: makeClient, observer: observer),
            clock: clock, config: config, restoring: restored,
            onChange: { data in
                defaults.set(data, forKey: Self.queueKey)
                let count = (try? JSONDecoder().decode([PendingProgress].self, from: data))?.count ?? 0
                observer.pendingChanged(count)
            })
        self.isConfigured = credentials() != nil
        self.pendingCount = restored.flatMap { try? JSONDecoder().decode([PendingProgress].self, from: $0) }?.count ?? 0
        observer.install(
            onPush: { [weak self] error in
                guard let self else { return }
                self.status = error.map(SyncErrorClassifier.status(for:)) ?? .idle
            },
            onPending: { [weak self] count in self?.pendingCount = count })

        let legacy = Self.takeLegacyPending(defaults)
        let queue = self.queue
        let configured = isConfigured
        Task {
            for p in legacy { await queue.enqueue(p) }
            if configured { await queue.resume() }
        }
    }

    private static func takeLegacyPending(_ defaults: UserDefaults) -> [KOSyncProgress] {
        guard let data = defaults.data(forKey: legacyKey) else { return [] }
        defaults.removeObject(forKey: legacyKey)
        let dict = (try? JSONDecoder().decode([String: KOSyncProgress].self, from: data)) ?? [:]
        return dict.values.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
    }

    private func client() -> KOSyncClientProtocol? {
        credentials().map(makeClient)
    }

    /// Call when settings changed (new credentials) or the app returns to foreground.
    func configurationChanged() {
        isConfigured = credentials() != nil
        if !isConfigured { status = .idle }
        retryPending()
    }

    /// Restarts delivery of queued progress (entries still honour their backoff). Called on foreground
    /// and from the ~60 s foreground timer.
    func retryPending() {
        guard isConfigured else { return }
        let queue = self.queue
        Task { await queue.resume() }
    }

    // MARK: Open-book check

    /// GETs the remote progress and applies the conflict policy. Failures degrade to `.keepLocal`.
    func decisionOnOpen(document: String, localPercentage: Double) async -> SyncDecision {
        guard let client = client() else { return .keepLocal }
        status = .syncing
        do {
            let remote = try await client.fetchProgress(document: document)
            status = .idle
            return policy.decide(localPercentage: localPercentage, remote: remote, ownDeviceID: device.id)
        } catch {
            status = SyncErrorClassifier.status(for: error)
            return .keepLocal
        }
    }

    // MARK: Push

    /// Records the latest position for `document`. With `immediately == false` the push is debounced
    /// by the queue; otherwise it is flushed now and, on a transient failure, retried with backoff.
    func report(document: String, xpointer: String, percentage: Double, immediately: Bool) {
        let progress = KOSyncProgress(document: document, progress: xpointer,
                                      percentage: min(max(percentage, 0), 1),
                                      device: device.name, device_id: device.id,
                                      timestamp: Int(Date().timeIntervalSince1970))
        let configured = isConfigured || credentials() != nil
        if configured { isConfigured = true }
        let queue = self.queue
        // Chained so that two quick reports reach the queue in call order.
        let previous = chain
        chain = Task {
            await previous?.value
            if !configured {
                await queue.enqueue(progress)
            } else if immediately {
                await queue.enqueue(progress)
                let result = await queue.flush()
                if !result.retained.isEmpty && !result.unauthorized { await queue.resume() }
            } else {
                await queue.schedule(progress)
            }
        }
    }

    /// Forgets queued progress for a deleted book.
    func discard(document: String) {
        let queue = self.queue
        let previous = chain
        chain = Task {
            await previous?.value
            await queue.remove(document: document)
        }
    }

    var hasPending: Bool { pendingCount > 0 }

    // MARK: Settings screen

    enum ConnectionResult: Equatable {
        case notConfigured, ok, unauthorized, offline, failed
    }

    func testConnection() async -> ConnectionResult {
        guard let client = client() else { return .notConfigured }
        status = .syncing
        do {
            try await client.authorize()
            status = .idle
            return .ok
        } catch {
            status = SyncErrorClassifier.status(for: error)
            if let e = error as? KOSyncError, e == .unauthorized { return .unauthorized }
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
