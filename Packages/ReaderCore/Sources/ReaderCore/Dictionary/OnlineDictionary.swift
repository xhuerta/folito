import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP seam so the providers are testable without a network.
public protocol DictionaryHTTPFetching: Sendable {
    /// Returns body and HTTP status. Throws `DictionaryError.offline` when there is no connection.
    func get(_ url: URL) async throws -> (data: Data, status: Int)
}

public struct URLSessionDictionaryFetcher: DictionaryHTTPFetching, @unchecked Sendable {
    /// Wikimedia asks API clients for a descriptive User-Agent with contact information.
    public static let userAgent = "Folito/1.0 (https://github.com/xhuerta/wristreader; watchOS EPUB reader)"
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    public func get(_ url: URL) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DictionaryError.invalidResponse }
            return (data, http.statusCode)
        } catch let e as DictionaryError {
            throw e
        } catch let e as URLError {
            if e.code == .cancelled { throw e }
            throw DictionaryError.offline
        }
    }
}

/// One remote dictionary. Looks up exactly one headword; `DictionaryService` handles retries and cache.
public protocol DictionarySource: Sendable {
    func fetch(word: String, language: String) async throws -> DictionaryEntry
}

/// Wiktionary (English edition) REST API: `https://en.wiktionary.org/api/rest_v1/page/definition/{word}`.
/// Covers every language in one place (sections keyed by the word's language code), with definitions in
/// English. Other editions (es/fr/de...) answer HTTP 501 for this endpoint, so they cannot be used.
public struct WiktionarySource: DictionarySource {
    private let fetcher: DictionaryHTTPFetching
    public init(fetcher: DictionaryHTTPFetching) { self.fetcher = fetcher }

    public static func url(for word: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let encoded = word.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://en.wiktionary.org/api/rest_v1/page/definition/" + encoded)
    }

    public func fetch(word: String, language: String) async throws -> DictionaryEntry {
        guard let url = Self.url(for: word) else { throw DictionaryError.notFound }
        let (data, status) = try await fetcher.get(url)
        try DictionaryHTTP.check(status)
        guard let entry = WiktionaryParser.parse(data, word: word, language: language) else {
            // 200 with unparsable JSON is an invalid response; valid JSON without our language is a miss.
            if (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { throw DictionaryError.notFound }
            throw DictionaryError.invalidResponse
        }
        return entry
    }
}

/// api.dictionaryapi.dev (English only in practice; used as a fallback for English).
public struct DictionaryAPISource: DictionarySource {
    private let fetcher: DictionaryHTTPFetching
    public init(fetcher: DictionaryHTTPFetching) { self.fetcher = fetcher }

    public static func url(for word: String, language: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let encoded = word.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://api.dictionaryapi.dev/api/v2/entries/\(language)/" + encoded)
    }

    public func fetch(word: String, language: String) async throws -> DictionaryEntry {
        guard language == "en" else { throw DictionaryError.notFound }
        guard let url = Self.url(for: word, language: language) else { throw DictionaryError.notFound }
        let (data, status) = try await fetcher.get(url)
        try DictionaryHTTP.check(status)
        guard let entry = DictionaryAPIParser.parse(data, language: language) else { throw DictionaryError.notFound }
        return entry
    }
}

enum DictionaryHTTP {
    static func check(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 404: throw DictionaryError.notFound
        case 429: throw DictionaryError.rateLimited
        default: throw DictionaryError.server(status: status)
        }
    }
}

/// Cache -> sources, over the normalised candidate forms of the word.
public struct DictionaryService: DictionaryProviding {
    private let sources: [DictionarySource]
    private let cache: DictionaryCache?

    public init(sources: [DictionarySource], cache: DictionaryCache?) {
        self.sources = sources
        self.cache = cache
    }

    /// Wiktionary first, dictionaryapi.dev as English fallback.
    public static func online(cache: DictionaryCache?, fetcher: DictionaryHTTPFetching = URLSessionDictionaryFetcher()) -> DictionaryService {
        DictionaryService(sources: [WiktionarySource(fetcher: fetcher), DictionaryAPISource(fetcher: fetcher)], cache: cache)
    }

    public func lookup(_ word: String, language: String?) async throws -> DictionaryEntry {
        let lang = WordNormalizer.primaryLanguage(language)
        let candidates = WordNormalizer.candidates(for: word, language: lang)
        guard !candidates.isEmpty else { throw DictionaryError.notFound }

        // Anything cached for any candidate wins before touching the network (works offline).
        for candidate in candidates {
            if let hit = cache?.get(DictionaryCache.key(word: candidate, language: lang)) { return hit }
        }
        var firstFailure: DictionaryError?
        for candidate in candidates {
            for source in sources {
                do {
                    let entry = try await source.fetch(word: candidate, language: lang)
                    cache?.put(entry, for: DictionaryCache.key(word: candidate, language: lang))
                    return entry
                } catch DictionaryError.notFound {
                    continue
                } catch let e as DictionaryError {
                    // Offline / busy: retrying other forms against the same failing network is pointless.
                    if e == .offline || e == .rateLimited { throw e }
                    firstFailure = firstFailure ?? e
                }
            }
        }
        throw firstFailure ?? DictionaryError.notFound
    }
}
