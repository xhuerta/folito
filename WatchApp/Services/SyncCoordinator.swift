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

/// Thin sync layer for the watch: conflict check on open, debounced offline-tolerant pushes.
/// Pending progress (latest per document) is persisted and retried on foreground / timers.
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var isConfigured: Bool = false

    let device: DeviceIdentity
    private let pending: PendingProgressStore
    private let policy: SyncConflictPolicy
    private let credentials: () -> KOSyncCredentials?
    private let makeClient: (KOSyncCredentials) -> KOSyncClientProtocol
    private let debounce: TimeInterval
    private var debounceTask: Task<Void, Never>?
    private var isFlushing = false

    init(device: DeviceIdentity = DeviceIdentity(),
         pending: PendingProgressStore = PendingProgressStore(),
         policy: SyncConflictPolicy = DefaultSyncConflictPolicy(),
         debounce: TimeInterval = 5,
         credentials: @escaping () -> KOSyncCredentials? = { CredentialsStore.current() },
         makeClient: @escaping (KOSyncCredentials) -> KOSyncClientProtocol = { KOSyncClient(credentials: $0) }) {
        self.device = device
        self.pending = pending
        self.policy = policy
        self.debounce = debounce
        self.credentials = credentials
        self.makeClient = makeClient
        self.isConfigured = credentials() != nil
    }

    private func client() -> KOSyncClientProtocol? {
        credentials().map(makeClient)
    }

    /// Call when settings changed (new credentials) or the app returns to foreground.
    func configurationChanged() {
        isConfigured = credentials() != nil
        if !isConfigured { status = .idle }
        Task { await flushPending() }
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

    /// Records the latest position for `document`. With `immediately == false` the push is debounced.
    func report(document: String, xpointer: String, percentage: Double, immediately: Bool) {
        let progress = KOSyncProgress(document: document, progress: xpointer,
                                      percentage: min(max(percentage, 0), 1),
                                      device: device.name, device_id: device.id,
                                      timestamp: Int(Date().timeIntervalSince1970))
        pending.upsert(progress)
        guard isConfigured || credentials() != nil else { return }
        debounceTask?.cancel()
        if immediately {
            Task { await flushPending() }
        } else {
            let delay = debounce
            debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.flushPending()
            }
        }
    }

    /// Pushes every pending entry; stops at the first failure and keeps the rest for a later retry.
    func flushPending() async {
        guard !isFlushing else { return }
        guard let client = client() else { return }
        let items = pending.all()
        guard !items.isEmpty else { return }
        isFlushing = true
        status = .syncing
        defer { isFlushing = false }
        for item in items {
            do {
                try await client.pushProgress(item)
                pending.remove(item)
            } catch {
                status = SyncErrorClassifier.status(for: error)
                return
            }
        }
        status = .idle
    }

    var hasPending: Bool { !pending.isEmpty }

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
        debounceTask?.cancel()
        pending.removeAll()
        status = .idle
    }
}
