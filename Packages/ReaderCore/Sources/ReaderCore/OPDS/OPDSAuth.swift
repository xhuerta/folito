import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A user name and password for a self-hosted catalog (HTTP Basic, RFC 7617). The app keeps them in the iPhone
/// Keychain only; nothing here writes them anywhere. `description` never shows the password, so the value cannot
/// leak into a log through string interpolation.
public struct OPDSCredentials: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// `Basic base64(user:password)`, UTF-8 (RFC 7617 `charset="UTF-8"`, which every server named in docs/OPDS.md
    /// accepts).
    public var authorizationHeader: String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// Why these credentials cannot be used, or nil. Basic auth cannot carry a colon in the user name, and control
    /// characters (a pasted line break) would corrupt the header.
    public var problem: Problem? {
        if username.isEmpty { return .missingUsername }
        if password.isEmpty { return .missingPassword }
        if username.contains(":") { return .colonInUsername }
        if (username + password).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .controlCharacters
        }
        return nil
    }

    public enum Problem: Sendable, Equatable {
        case missingUsername, missingPassword, colonInUsername, controlCharacters
    }

    public var description: String { "OPDSCredentials(username: \(username), password: <redacted>)" }
    public var debugDescription: String { description }
}

/// Scheme, host and port of an address: the server a sign-in belongs to. Credentials saved for a catalog are sent
/// only to requests whose origin is the same and whose scheme is `https`.
public struct OPDSOrigin: Hashable, Sendable, Codable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = components.port ?? (scheme == "https" ? 443 : 80)
    }

    public var isSecure: Bool { scheme == "https" }

    /// `https://books.example.net:443`: the Keychain account of the server's sign-in.
    public var description: String { "\(scheme)://\(host):\(port)" }
}

/// Where credentials may go (docs/OPDS.md, "Sign-in").
public enum OPDSSignInPolicy {
    /// Sign-in is offered only for `https` catalogs: over plain `http` a password would cross the network in the
    /// clear (Basic auth is only Base64), so Folito refuses instead of asking the user to accept the risk.
    public static func canSignIn(to catalogURL: URL) -> Bool {
        OPDSOrigin(catalogURL)?.isSecure == true
    }

    /// True when credentials saved for `origin` may be attached to a request for `url`: the same scheme, host and
    /// port, and that scheme is `https`.
    public static func mayAuthorize(_ url: URL, for origin: OPDSOrigin) -> Bool {
        origin.isSecure && OPDSOrigin(url) == origin
    }

    /// The request a redirect leads to, without the `Authorization` header unless it stays on the same `https`
    /// origin as the original request. Used by `URLSessionOPDSTransport`, so a catalog that redirects to another
    /// host (a CDN, a login page, plain http) never receives the password.
    public static func redirected(_ request: URLRequest, from original: URL?) -> URLRequest {
        guard request.value(forHTTPHeaderField: "Authorization") != nil else { return request }
        if let original, let origin = OPDSOrigin(original), let url = request.url, mayAuthorize(url, for: origin) {
            return request
        }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        return stripped
    }
}

/// The sign-ins the client may use, by server, held in memory while the app runs (the app fills it from the
/// Keychain). Thread-safe: the client reads it from its actor, the app writes it from the main actor.
public final class OPDSCredentialVault: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OPDSOrigin: OPDSCredentials] = [:]

    public init() {}

    /// Saves (or, with nil, forgets) the sign-in of `origin`. Plain-http origins are never stored.
    public func set(_ credentials: OPDSCredentials?, for origin: OPDSOrigin) {
        lock.lock(); defer { lock.unlock() }
        items[origin] = origin.isSecure ? credentials : nil
    }

    public func credentials(for origin: OPDSOrigin) -> OPDSCredentials? {
        lock.lock(); defer { lock.unlock() }
        return items[origin]
    }

    /// The sign-in to send with a request for `url`, if it is an `https` address of a server with a saved sign-in.
    public func credentials(forRequestTo url: URL) -> OPDSCredentials? {
        guard let origin = OPDSOrigin(url), origin.isSecure else { return nil }
        return credentials(for: origin)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
}
