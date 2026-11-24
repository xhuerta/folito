import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OPDSError: Error, Equatable, Sendable {
    /// No connection, or the request timed out.
    case offline
    /// The host name could not be resolved, or the address is not a valid web address.
    case cannotFindHost
    /// TLS failed (untrusted or expired certificate).
    case insecureConnection
    /// iOS refused a plain `http://` address (App Transport Security).
    case httpNotAllowed
    /// 401/403: the catalog wants a sign-in, which Folito does not support yet.
    case authenticationRequired
    case notFound
    case server(status: Int)
    /// The answer is not an OPDS/Atom feed (for example a web page).
    case notAFeed
    /// The download is not an EPUB file (for example an HTML error page).
    case notAnEPUB
    /// Bigger than `OPDSClient.maxFeedBytes` / `maxBookBytes`.
    case tooLarge
}

/// One HTTP GET. The app uses `URLSessionOPDSTransport`; tests use a mock, so unit tests never touch the network.
public protocol OPDSTransport: Sendable {
    /// Returns the body, the status code and the final URL (after redirects).
    func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int, url: URL)
}

/// An ephemeral `URLSession`: no cookies, no cache on disk, no credentials.
public struct URLSessionOPDSTransport: OPDSTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int, url: URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OPDSError.notAFeed }
            return (data, http.statusCode, http.url ?? url)
        } catch let error as OPDSError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw OPDSClient.map(error)
        } catch {
            throw OPDSError.offline
        }
    }
}

/// Reads OPDS catalog pages and downloads EPUBs from them. Only the addresses the user opens are requested; no
/// cookies, credentials or anything about the user or their library are sent (docs/PRIVACY_DATA_MAP.md).
public actor OPDSClient {
    /// Identifies the app, like the Open Library lookup. Never any user data.
    public static let userAgent = "Folito/1.0 (https://folito.app; OPDS catalog browser)"
    public static let maxFeedBytes = 10 * 1024 * 1024
    public static let maxBookBytes = 200 * 1024 * 1024
    static let feedAccept = "application/atom+xml;profile=opds-catalog, application/atom+xml;q=0.9, application/xml;q=0.8, */*;q=0.5"
    static let epubAccept = "application/epub+zip, */*;q=0.5"
    public static let maxImageBytes = 5 * 1024 * 1024
    static let imageAccept = "image/*"

    private let transport: OPDSTransport
    private let userAgent: String
    /// Requests sent so far (tests check that nothing is contacted unasked).
    public private(set) var requestLog: [URL] = []

    public init(transport: OPDSTransport = URLSessionOPDSTransport(), userAgent: String = OPDSClient.userAgent) {
        self.transport = transport
        self.userAgent = userAgent
    }

    /// One catalog page. Relative links are resolved against the address the page was finally served from.
    public func feed(at url: URL) async throws -> OPDSFeed {
        let response = try await get(url, accept: Self.feedAccept)
        guard response.data.count <= Self.maxFeedBytes else { throw OPDSError.tooLarge }
        return try OPDSParser.parse(response.data, url: response.url)
    }

    /// The EPUB behind `link`. Fails with `.notAnEPUB` unless the bytes are a ZIP archive.
    public func download(_ link: OPDSLink) async throws -> Data {
        let response = try await get(link.url, accept: Self.epubAccept)
        guard response.data.count <= Self.maxBookBytes else { throw OPDSError.tooLarge }
        guard Self.isZIP(response.data) else { throw OPDSError.notAnEPUB }
        return response.data
    }

    /// A cover or thumbnail the catalog links to (same ephemeral session: no cookies, no cache on disk).
    public func image(at url: URL) async throws -> Data {
        let response = try await get(url, accept: Self.imageAccept)
        guard response.data.count <= Self.maxImageBytes else { throw OPDSError.tooLarge }
        return response.data
    }

    private func get(_ url: URL, accept: String) async throws -> (data: Data, status: Int, url: URL) {
        try Task.checkCancellation()
        requestLog.append(url)
        let response = try await transport.get(url, headers: ["User-Agent": userAgent, "Accept": accept])
        switch response.status {
        case 200..<300: return response
        case 401, 403: throw OPDSError.authenticationRequired
        case 404, 410: throw OPDSError.notFound
        default: throw OPDSError.server(status: response.status)
        }
    }

    static func isZIP(_ data: Data) -> Bool {
        data.starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    /// Maps the URL loading errors the user can act on; everything else counts as being offline.
    public static func map(_ error: URLError) -> OPDSError {
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection:
            return .httpNotAllowed
        case .cannotFindHost, .dnsLookupFailed, .unsupportedURL, .badURL:
            return .cannotFindHost
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRequired,
             .clientCertificateRejected:
            return .insecureConnection
        case .userAuthenticationRequired:
            return .authenticationRequired
        default:
            return .offline
        }
    }
}
