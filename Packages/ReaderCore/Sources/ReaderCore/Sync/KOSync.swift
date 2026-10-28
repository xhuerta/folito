import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KOSyncCredentials: Sendable, Equatable {
    public var serverURL: URL
    public var username: String
    /// Plain password; the client sends `md5(password)` hex as `x-auth-key`.
    public var password: String

    public init(serverURL: URL = URL(string: "https://sync.koreader.rocks")!, username: String, password: String) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
    }
}

public struct KOSyncProgress: Codable, Sendable, Equatable {
    public var document: String
    public var progress: String
    public var percentage: Double
    public var device: String
    public var device_id: String
    public var timestamp: Int?

    public init(document: String, progress: String, percentage: Double,
                device: String = "WristReader", device_id: String, timestamp: Int? = nil) {
        self.document = document
        self.progress = progress
        self.percentage = percentage
        self.device = device
        self.device_id = device_id
        self.timestamp = timestamp
    }
}

public enum KOSyncError: Error, Equatable {
    case notImplemented
    case unauthorized
    case userExists
    case notFound
    case server(status: Int)
    case offline
    case invalidResponse
}

public protocol KOSyncClientProtocol: Sendable {
    func authorize() async throws
    func createUser() async throws
    func pushProgress(_ progress: KOSyncProgress) async throws
    /// Returns nil when the server has no progress for the document.
    func fetchProgress(document: String) async throws -> KOSyncProgress?
}

public enum SyncDecision: Equatable, Sendable {
    case keepLocal
    case offerRemote(KOSyncProgress)
}

public protocol SyncConflictPolicy: Sendable {
    /// Open-book policy: offer remote when it is ahead of local by more than `threshold` (default 0.005).
    func decide(localPercentage: Double, remote: KOSyncProgress?, ownDeviceID: String) -> SyncDecision
}

public struct KOSyncClient: KOSyncClientProtocol {
    public init(credentials: KOSyncCredentials, session: URLSession = .shared) {}
    public func authorize() async throws { throw KOSyncError.notImplemented }
    public func createUser() async throws { throw KOSyncError.notImplemented }
    public func pushProgress(_ progress: KOSyncProgress) async throws { throw KOSyncError.notImplemented }
    public func fetchProgress(document: String) async throws -> KOSyncProgress? { throw KOSyncError.notImplemented }
}

public struct DefaultSyncConflictPolicy: SyncConflictPolicy {
    public var threshold: Double
    public init(threshold: Double = 0.005) { self.threshold = threshold }
    public func decide(localPercentage: Double, remote: KOSyncProgress?, ownDeviceID: String) -> SyncDecision { .keepLocal }
}
