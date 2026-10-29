import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Supabase session for Readest Cloud (`POST /auth/v1/token`).
public struct ReadestSession: Codable, Sendable, Equatable {
    public var accessToken: String
    /// Single use: Supabase rotates it on every refresh. Only one device may refresh a session.
    public var refreshToken: String
    /// Local-clock expiry (now + `expires_in`), like the koplugin, so a wrong device clock cannot force
    /// a refresh on every request.
    public var expiresAt: Date
    public var lifetime: TimeInterval
    public var userID: String
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, lifetime: TimeInterval,
                userID: String, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.lifetime = lifetime
        self.userID = userID
        self.email = email
    }

    func jsonString() -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: (try? enc.encode(self)) ?? Data(), as: UTF8.self)
    }

    init?(jsonString: String) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let s = try? dec.decode(ReadestSession.self, from: Data(jsonString.utf8)) else { return nil }
        self = s
    }
}

public protocol ReadestClock: Sendable { func now() -> Date }
public struct SystemReadestClock: ReadestClock { public init() {}; public func now() -> Date { Date() } }

/// Supabase email/password auth (the koplugin's `sign_in_password` / `refresh_token`).
/// The session lives in a `SyncCredentialStore` (`ReadestConnectorFactory.Key.session`); rotated tokens are
/// written back immediately. Concurrent callers share one in-flight refresh, because refresh tokens are
/// single use.
public actor ReadestAuth {
    private let config: ReadestConfiguration
    private let http: URLSession
    private let store: SyncCredentialStore
    private let clock: ReadestClock
    private var refreshTask: Task<ReadestSession, Error>?

    public init(config: ReadestConfiguration = .readestCloud, session: URLSession = .shared,
                store: SyncCredentialStore, clock: ReadestClock = SystemReadestClock()) {
        self.config = config
        self.http = session
        self.store = store
        self.clock = clock
    }

    private typealias Key = ReadestConnectorFactory.Key

    public var currentSession: ReadestSession? {
        store.load()?[Key.session].flatMap(ReadestSession.init(jsonString:))
    }

    /// True after the server rejected the refresh token: no request is sent until a new sign-in.
    public var needsSignIn: Bool { store.load()?[Key.authRequired] == "1" || currentSession == nil }

    /// Password grant. Does not touch the store: the caller decides where the new session goes.
    public func signIn(email: String, password: String) async throws -> ReadestSession {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (status, data) = try await post(path: "token", query: ["grant_type": "password"], body: body)
        switch status {
        case 200: break
        case 400, 401, 422: throw ReadestError.invalidCredentials
        case 429: throw ReadestError.rateLimited
        default: throw ReadestError.server(status: status, message: ReadestHTTP.message(from: data))
        }
        return try parse(data, fallbackEmail: email)
    }

    /// An access token valid for at least a minute (or half its lifetime), refreshing when needed.
    public func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard !needsSignIn, let current = currentSession else {
            throw currentSession == nil ? ReadestError.notSignedIn : ReadestError.unauthorized
        }
        let margin = max(60, current.lifetime / 2)
        if !forceRefresh, current.expiresAt >= clock.now().addingTimeInterval(margin) { return current.accessToken }
        return try await refresh(from: current).accessToken
    }

    public func userID() throws -> String {
        guard let s = currentSession else { throw ReadestError.notSignedIn }
        return s.userID
    }

    /// Best-effort `POST /auth/v1/logout?scope=local`: revokes this session only (the default scope
    /// would also sign out the user's Kobo and Readest apps). Fails silently with an expired token.
    public func revoke(accessToken: String) async {
        var comps = URLComponents(url: config.supabaseURL.appendingPathComponent("auth/v1/logout"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "scope", value: "local")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await ReadestHTTP.perform(req, session: http)
    }

    private func refresh(from current: ReadestSession) async throws -> ReadestSession {
        if let task = refreshTask { return try await task.value }
        let task = Task { () -> ReadestSession in
            let body = try JSONSerialization.data(withJSONObject: ["refresh_token": current.refreshToken])
            let (status, data) = try await self.post(path: "token", query: ["grant_type": "refresh_token"], body: body)
            switch status {
            case 200: break
            case 400, 401, 403: throw ReadestError.unauthorized
            case 429: throw ReadestError.rateLimited
            default: throw ReadestError.server(status: status, message: ReadestHTTP.message(from: data))
            }
            return try self.parse(data, fallbackEmail: current.email)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let s = try await task.value
            var creds = store.load() ?? SyncCredentials()
            creds[Key.session] = s.jsonString()
            if let email = s.email { creds[Key.email] = email }
            store.save(creds)
            return s
        } catch ReadestError.unauthorized {
            // Rejected refresh token: keep the account (so the UI can say who must sign in again) but never
            // reuse the token; a new sign-in on the iPhone replaces the whole session.
            var creds = store.load() ?? SyncCredentials()
            creds[Key.authRequired] = "1"
            store.save(creds)
            throw ReadestError.unauthorized
        }
    }

    nonisolated func parse(_ data: Data, fallbackEmail: String?) throws -> ReadestSession {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = obj["access_token"] as? String, let refresh = obj["refresh_token"] as? String,
              let lifetime = (obj["expires_in"] as? NSNumber)?.doubleValue, lifetime > 0 else {
            throw ReadestError.invalidResponse
        }
        let user = obj["user"] as? [String: Any]
        guard let id = user?["id"] as? String else { throw ReadestError.invalidResponse }
        return ReadestSession(accessToken: access, refreshToken: refresh,
                              expiresAt: clock.now().addingTimeInterval(lifetime), lifetime: lifetime,
                              userID: id, email: (user?["email"] as? String) ?? fallbackEmail)
    }

    nonisolated private func post(path: String, query: [String: String], body: Data) async throws -> (Int, Data) {
        var comps = URLComponents(url: config.supabaseURL.appendingPathComponent("auth/v1/" + path),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        return try await ReadestHTTP.perform(req, session: http)
    }
}
