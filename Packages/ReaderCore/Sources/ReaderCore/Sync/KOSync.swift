import Foundation
import Crypto
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
                device: String = "Folito", device_id: String, timestamp: Int? = nil) {
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

/// Client for the KOReader sync protocol (koreader-sync-server, kosync.koplugin, Readest).
///
/// Wire facts (verified against koreader-sync-server `syncs_controller.lua` / `errors.lua`):
/// - auth = `x-auth-user` + `x-auth-key` (md5 hex of the password) on every request except `/users/create`;
/// - `POST /users/create` body is `{username, password}` where `password` is already the md5 hex key;
///   201 on success, 402 when the user exists (or registration is disabled), 403 invalid fields;
/// - `PUT /syncs/progress` answers 200 `{document, timestamp}`; `GET` answers 200 with `{}` when unknown.
public struct KOSyncClient: KOSyncClientProtocol {
    public static let acceptHeader = "application/vnd.koreader.v1+json"

    private let credentials: KOSyncCredentials
    private let session: URLSession

    public init(credentials: KOSyncCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    /// Lowercase hex md5 of the UTF-8 password, as KOReader stores and sends it.
    public static func authKey(forPassword password: String) -> String {
        Insecure.MD5.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func authorize() async throws {
        let (status, data) = try await send(method: "GET", path: "users/auth", body: nil, authenticated: true)
        switch status {
        case 200:
            // A wrong base URL can hit a web UI answering 200 with HTML (Readest guards the same way).
            if !data.isEmpty, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] == nil {
                throw KOSyncError.invalidResponse
            }
        case 401: throw KOSyncError.unauthorized
        default: throw KOSyncError.server(status: status)
        }
    }

    public func createUser() async throws {
        struct Body: Encodable { let username: String; let password: String }
        let body = try JSONEncoder().encode(Body(username: credentials.username,
                                                 password: Self.authKey(forPassword: credentials.password)))
        let (status, _) = try await send(method: "POST", path: "users/create", body: body, authenticated: false)
        switch status {
        case 200, 201: return
        case 402: throw KOSyncError.userExists
        default: throw KOSyncError.server(status: status)
        }
    }

    public func pushProgress(_ progress: KOSyncProgress) async throws {
        // `timestamp` is server-assigned; never sent.
        struct Body: Encodable {
            let document: String, progress: String, percentage: Double, device: String, device_id: String
        }
        let body = try JSONEncoder().encode(Body(document: progress.document, progress: progress.progress,
                                                 percentage: progress.percentage, device: progress.device,
                                                 device_id: progress.device_id))
        let (status, _) = try await send(method: "PUT", path: "syncs/progress", body: body, authenticated: true)
        switch status {
        case 200, 202: return
        case 401: throw KOSyncError.unauthorized
        default: throw KOSyncError.server(status: status)
        }
    }

    public func fetchProgress(document: String) async throws -> KOSyncProgress? {
        let encoded = document.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? document
        let (status, data) = try await send(method: "GET", path: "syncs/progress/" + encoded,
                                            body: nil, authenticated: true)
        switch status {
        case 200: break
        case 401: throw KOSyncError.unauthorized
        case 404: return nil
        default: throw KOSyncError.server(status: status)
        }
        guard !data.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KOSyncError.invalidResponse
        }
        // The server answers `{}` (no document field) when nothing is stored.
        guard let progress = obj["progress"] as? String, let pct = (obj["percentage"] as? NSNumber)?.doubleValue,
              !progress.isEmpty || pct > 0 else { return nil }
        return KOSyncProgress(document: (obj["document"] as? String) ?? document,
                              progress: progress, percentage: pct,
                              device: (obj["device"] as? String) ?? "",
                              device_id: (obj["device_id"] as? String) ?? "",
                              timestamp: (obj["timestamp"] as? NSNumber)?.intValue)
    }

    // MARK: - Transport

    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
    ]

    /// Base URL + relative path, preserving any base path (e.g. `https://host/kosync/`) and ignoring a trailing slash.
    func makeURL(_ path: String) throws -> URL {
        var base = credentials.serverURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/" + path) else { throw KOSyncError.invalidResponse }
        return url
    }

    private func send(method: String, path: String, body: Data?, authenticated: Bool) async throws -> (Int, Data) {
        var request = URLRequest(url: try makeURL(path))
        request.httpMethod = method
        request.setValue(Self.acceptHeader, forHTTPHeaderField: "Accept")
        if authenticated {
            request.setValue(credentials.username, forHTTPHeaderField: "x-auth-user")
            request.setValue(Self.authKey(forPassword: credentials.password), forHTTPHeaderField: "x-auth-key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw KOSyncError.invalidResponse }
            return (http.statusCode, data)
        } catch let error as URLError {
            if Self.offlineCodes.contains(error.code) { throw KOSyncError.offline }
            throw error
        }
    }
}

public struct DefaultSyncConflictPolicy: SyncConflictPolicy {
    public var threshold: Double
    public init(threshold: Double = 0.005) { self.threshold = threshold }
    public func decide(localPercentage: Double, remote: KOSyncProgress?, ownDeviceID: String) -> SyncDecision {
        guard let remote, remote.device_id != ownDeviceID,
              remote.percentage - localPercentage > threshold else { return .keepLocal }
        return .offerRemote(remote)
    }
}
