import Foundation

/// A book found on Open Library, as offered to the user (or, when the user opted in, applied in the background).
/// See docs/ONLINE_METADATA.md.
public struct OnlineBookMatch: Codable, Sendable, Hashable, Identifiable {
    /// Open Library key: an edition (`/books/OL…M`) for an ISBN match, a work (`/works/OL…W`) for a search match.
    public var key: String
    public var title: String
    public var authors: [String]
    public var year: Int?
    public var publisher: String?
    public var subjects: [String]
    /// Filled in lazily (`OpenLibraryClient.description(for:)`): neither API that finds a match returns it.
    public var description: String?
    /// Open Library cover id (`covers.openlibrary.org/b/id/{id}-L.jpg`).
    public var coverID: Int?
    /// True when Open Library matched the book's own ISBN (an exact edition), not a title and author search.
    public var matchedByISBN: Bool

    public var id: String { key }

    public init(key: String, title: String, authors: [String] = [], year: Int? = nil, publisher: String? = nil,
                subjects: [String] = [], description: String? = nil, coverID: Int? = nil, matchedByISBN: Bool = false) {
        self.key = key
        self.title = title
        self.authors = authors
        self.year = year
        self.publisher = publisher
        self.subjects = subjects
        self.description = description
        self.coverID = coverID
        self.matchedByISBN = matchedByISBN
    }

    /// The book's page on Open Library (the attribution link).
    public var pageURL: URL? { OpenLibraryAPI.pageURL(key: key) }
    /// The large cover; a missing cover answers 404 (`default=false`), never a blank image.
    public var coverURL: URL? { coverID.map { OpenLibraryAPI.coverURL(id: $0, size: "L") } }
}

/// What a lookup asks for. Only the ISBN, or the title and the first author, are ever sent.
public struct OnlineLookupQuery: Sendable, Equatable {
    public var isbn: String?
    public var title: String
    public var authors: [String]

    public init(isbn: String?, title: String, authors: [String]) {
        self.isbn = isbn
        self.title = title
        self.authors = authors
    }
}

/// Endpoints, request building and response parsing for Open Library (https://openlibrary.org/developers/api).
public enum OpenLibraryAPI {
    public static let base = URL(string: "https://openlibrary.org")!
    /// Identifies the app as their API etiquette asks: name, version and a contact URL. Never any user data.
    public static let userAgent = "Folito/1.0 (https://folito.app; book details lookup)"
    /// Search results to ask for; the app shows at most `maxMatches` of them.
    public static let searchLimit = 10
    public static let maxMatches = 5
    static let searchFields = "key,title,author_name,first_publish_year,cover_i,subject"

    // MARK: Request building

    /// Books API by ISBN (`jscmd=data`, the format their docs call stable). An ISBN-10 is sent together with its
    /// ISBN-13 in the same request, since older editions are sometimes indexed by only one of them.
    public static func booksURL(isbn raw: String) -> URL? {
        guard let isbn13 = ISBN.normalize(raw) else { return nil }
        var keys = ["ISBN:\(isbn13)"]
        if let isbn10 = ISBN.compactISBN10(raw) { keys.append("ISBN:\(isbn10)") }
        return url(path: "/api/books", query: [("bibkeys", keys.joined(separator: ",")), ("format", "json"),
                                               ("jscmd", "data")])
    }

    /// Search API by title and author (first author only), limited to the fields the app shows.
    public static func searchURL(title: String, author: String?) -> URL? {
        let t = searchTerm(title)
        guard !t.isEmpty else { return nil }
        var query: [(String, String)] = [("title", t)]
        if let author, case let a = searchTerm(author), !a.isEmpty { query.append(("author", a)) }
        query += [("limit", String(searchLimit)), ("fields", searchFields)]
        return url(path: "/search.json", query: query)
    }

    /// JSON of an edition or a work (for its description). Nil for anything but a well-formed Open Library key.
    public static func recordURL(key: String) -> URL? {
        guard isValidKey(key) else { return nil }
        return url(path: key + ".json", query: [])
    }

    public static func pageURL(key: String) -> URL? {
        guard isValidKey(key) else { return nil }
        return URL(string: base.absoluteString + key)
    }

    /// Cover by id; `default=false` makes a missing cover a 404 instead of a blank image.
    public static func coverURL(id: Int, size: String) -> URL {
        URL(string: "https://covers.openlibrary.org/b/id/\(id)-\(size).jpg?default=false")!
    }

    /// `/books/OL123M`, `/works/OL45W`.
    public static func isValidKey(_ key: String) -> Bool {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty else { return false }
        let id = parts[2]
        let suffix: Character
        switch parts[1] {
        case "books": suffix = "M"
        case "works": suffix = "W"
        default: return false
        }
        guard id.hasPrefix("OL"), id.last == suffix, id.count > 3 else { return false }
        return id.dropFirst(2).dropLast().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// A title or name as a search term: Solr query syntax characters become spaces, whitespace is collapsed.
    public static func searchTerm(_ raw: String) -> String {
        let special = Set("\\+-!():^[]\"{}~*?|&/;")
        let mapped = String(raw.map { special.contains($0) || $0.isNewline ? " " : $0 })
        return mapped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Query strings are percent-encoded strictly (RFC 3986 unreserved characters only), so `+`, `&` and `=`
    /// inside a value can never change the query.
    static func url(path: String, query: [(String, String)]) -> URL? {
        var s = base.absoluteString + path
        if !query.isEmpty {
            s += "?" + query.map { "\($0.0)=\(escape($0.1))" }.joined(separator: "&")
        }
        return URL(string: s)
    }

    public static func escape(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        allowed.insert(charactersIn: ",:") // kept readable in bibkeys ("ISBN:978…,ISBN:0…") and fields lists
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: Parsing

    /// The first book in a Books API (`jscmd=data`) answer, or nil when Open Library does not know the ISBN.
    public static func parseBooks(_ data: Data) throws -> OnlineBookMatch? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineMetadataError.invalidResponse
        }
        for key in root.keys.sorted() {
            guard let book = root[key] as? [String: Any], let title = nonEmpty(book["title"] as? String) else { continue }
            let olKey = (book["key"] as? String).flatMap { isValidKey($0) ? $0 : nil }
                ?? editionKey(fromURL: book["url"] as? String)
            guard let olKey else { continue }
            let authors = (book["authors"] as? [[String: Any]] ?? []).compactMap { nonEmpty($0["name"] as? String) }
            let publisher = (book["publishers"] as? [[String: Any]])?.lazy.compactMap { nonEmpty($0["name"] as? String) }.first
            let subjects = (book["subjects"] as? [[String: Any]] ?? []).compactMap { nonEmpty($0["name"] as? String) }
            let cover = (book["cover"] as? [String: Any]).flatMap { c in
                (c["large"] as? String ?? c["medium"] as? String).flatMap(coverID(fromURL:))
            }
            return OnlineBookMatch(key: olKey, title: title, authors: authors,
                                   year: (book["publish_date"] as? String).flatMap(EPUBMetadataReader.year(from:)),
                                   publisher: publisher, subjects: trimSubjects(subjects), coverID: cover,
                                   matchedByISBN: true)
        }
        return nil
    }

    /// The documents of a Search API answer, in Open Library's order.
    public static func parseSearch(_ data: Data) throws -> [OnlineBookMatch] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = root["docs"] as? [[String: Any]] else { throw OnlineMetadataError.invalidResponse }
        return docs.compactMap { doc in
            guard let key = doc["key"] as? String, isValidKey(key), let title = nonEmpty(doc["title"] as? String) else {
                return nil
            }
            return OnlineBookMatch(key: key, title: title,
                                   authors: (doc["author_name"] as? [String] ?? []).compactMap(nonEmpty),
                                   year: doc["first_publish_year"] as? Int,
                                   subjects: trimSubjects((doc["subject"] as? [String] ?? []).compactMap(nonEmpty)),
                                   coverID: (doc["cover_i"] as? Int).flatMap { $0 > 0 ? $0 : nil })
        }
    }

    /// An edition's or a work's description (a string, or `{"type": "/type/text", "value": …}`), cleaned to
    /// plain text, and the edition's first work (where to look next when the edition has none).
    public static func parseRecord(_ data: Data) throws -> (description: String?, workKey: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineMetadataError.invalidResponse
        }
        let raw = root["description"] as? String ?? (root["description"] as? [String: Any])?["value"] as? String
        let work = (root["works"] as? [[String: Any]])?.first?["key"] as? String
        return (raw.flatMap(cleanDescription), work.flatMap { isValidKey($0) ? $0 : nil })
    }

    /// Open Library descriptions are Markdown-ish: drops "----" trailers ("Also contained in:"), reference-style
    /// link definitions and source notes, turns `[text](url)` and `[text][1]` into `text`, and removes HTML.
    public static func cleanDescription(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if let range = text.range(of: "\n-{3,}", options: .regularExpression) { text = String(text[..<range.lowerBound]) }
        if text.contains("<") { text = EPUBMetadataReader.plainText(fromHTML: text) }
        let lines = text.components(separatedBy: "\n").filter {
            $0.range(of: #"^\s*\[[^\]]+\]:\s*\S+"#, options: .regularExpression) == nil
        }
        text = lines.joined(separator: "\n")
        text = text.replacingOccurrences(of: #"\(\[[^\]]*\]\[\d+\]\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\[\d+\]"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return nonEmpty(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func coverID(fromURL s: String) -> Int? {
        guard let range = s.range(of: #"/b/id/(\d+)-"#, options: .regularExpression) else { return nil }
        return Int(s[range].dropFirst(6).dropLast())
    }

    static func editionKey(fromURL s: String?) -> String? {
        guard let s, let range = s.range(of: #"/books/OL\d+M"#, options: .regularExpression) else { return nil }
        return String(s[range])
    }

    static func trimSubjects(_ subjects: [String]) -> [String] {
        var seen = Set<String>()
        return Array(subjects.filter { seen.insert($0.lowercased()).inserted }.prefix(8))
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

// MARK: - Match scoring

/// How well a search result fits the book: title similarity (70%) and author similarity (30%), each a Dice
/// coefficient over normalised words (case and accents folded, punctuation and leading articles dropped).
/// An ISBN match scores 1.
public enum MatchScoring {
    /// Search results below this are not offered.
    public static let minimumScore = 0.5
    /// The background lookup applies a search result only at or above this, and only when it clearly beats the
    /// runner-up (`isConfident`). An ISBN match is always confident.
    public static let confidentScore = 0.85

    public static func score(_ match: OnlineBookMatch, for query: OnlineLookupQuery) -> Double {
        if match.matchedByISBN { return 1 }
        let titleScore = max(similarity(match.title, query.title), similarity(mainTitle(match.title), mainTitle(query.title)))
        let queryAuthors = query.authors.filter { !words($0).isEmpty }
        guard !queryAuthors.isEmpty else { return titleScore }
        var authorScore = 0.0
        for a in queryAuthors {
            for b in match.authors {
                authorScore = max(authorScore, authorSimilarity(a, b))
            }
        }
        return 0.7 * titleScore + 0.3 * authorScore
    }

    /// Up to `limit` matches at or above `minimumScore`, best first (ties keep Open Library's order).
    public static func rank(_ matches: [OnlineBookMatch], for query: OnlineLookupQuery,
                            limit: Int = OpenLibraryAPI.maxMatches) -> [OnlineBookMatch] {
        let scored = matches.enumerated().map { (offset: $0.offset, match: $0.element, score: score($0.element, for: query)) }
        return scored.filter { $0.score >= minimumScore }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .prefix(limit).map(\.match)
    }

    /// Whether the best of `ranked` is safe to apply without asking.
    public static func isConfident(_ ranked: [OnlineBookMatch], for query: OnlineLookupQuery) -> Bool {
        guard let best = ranked.first else { return false }
        if best.matchedByISBN { return true }
        let top = score(best, for: query)
        guard top >= confidentScore else { return false }
        // A runner-up that is just as good (another book of the same name) makes the choice ambiguous, unless it
        // is the same title and author again (Open Library sometimes lists duplicate works).
        if ranked.count > 1 {
            let second = ranked[1]
            let sameBook = words(second.title) == words(best.title) && second.authors.map(words) == best.authors.map(words)
            if !sameBook, score(second, for: query) >= top - 0.05 { return false }
        }
        return true
    }

    static let articles: Set<String> = ["the", "a", "an", "el", "la", "los", "las", "le", "les", "l", "der", "die",
                                        "das", "il", "lo", "gli", "o", "os", "as"]

    /// Lowercased, accent-folded words without punctuation; a leading article is dropped.
    public static func words(_ s: String) -> [String] {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let cleaned = String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        var w = cleaned.split(separator: " ").map(String.init)
        if w.count > 1, let first = w.first, articles.contains(first) { w.removeFirst() }
        return w
    }

    /// Dice coefficient of the two word multisets.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        var remaining = wb
        var common = 0
        for w in wa {
            if let i = remaining.firstIndex(of: w) { common += 1; remaining.remove(at: i) }
        }
        return 2 * Double(common) / Double(wa.count + wb.count)
    }

    /// The title before a subtitle separator (": ", " - ", "(").
    static func mainTitle(_ s: String) -> String {
        var t = s
        for sep in [":", " - ", " — ", "("] {
            if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) }
        }
        return t
    }

    /// 1 for the same surname (last word, or the part before a comma in "Austen, Jane"), else word similarity.
    static func authorSimilarity(_ a: String, _ b: String) -> Double {
        func surname(_ s: String) -> String? {
            if let comma = s.firstIndex(of: ",") { return words(String(s[..<comma])).last }
            return words(s).last
        }
        if let sa = surname(a), let sb = surname(b), sa == sb { return 1 }
        return similarity(a, b)
    }
}

// MARK: - Online details and the merge rules

/// Which pieces of a match the user can apply.
public struct OnlineFieldSelection: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let cover = OnlineFieldSelection(rawValue: 1)
    public static let description = OnlineFieldSelection(rawValue: 2)
    /// Year, publisher and subjects.
    public static let publication = OnlineFieldSelection(rawValue: 4)
    public static let all: OnlineFieldSelection = [.cover, .description, .publication]
}

/// The fields of a book that came from Open Library. Kept apart from the EPUB's own `EPUBDetails`, so the EPUB's
/// data is never overwritten and "Remove Online Details" simply drops this.
public struct OnlineBookDetails: Codable, Sendable, Equatable {
    /// The Open Library record the details came from (attribution link).
    public var sourceKey: String
    public var description: String?
    public var year: Int?
    public var publisher: String?
    public var subjects: [String]
    /// True when the stored cover is Open Library's (the EPUB had none).
    public var hasCover: Bool

    public init(sourceKey: String, description: String? = nil, year: Int? = nil, publisher: String? = nil,
                subjects: [String] = [], hasCover: Bool = false) {
        self.sourceKey = sourceKey
        self.description = description
        self.year = year
        self.publisher = publisher
        self.subjects = subjects
        self.hasCover = hasCover
    }

    public var sourceURL: URL? { OpenLibraryAPI.pageURL(key: sourceKey) }
    public var isEmpty: Bool {
        description == nil && year == nil && publisher == nil && subjects.isEmpty && !hasCover
    }
}

/// Where a shown value came from.
public enum DetailSource: Sendable, Equatable {
    case epub, openLibrary
}

public struct SourcedValue<Value: Sendable & Equatable>: Sendable, Equatable {
    public var value: Value
    public var source: DetailSource
}

/// What the detail screen shows: the EPUB's value when it has one, else Open Library's.
public struct MergedBookDetails: Sendable, Equatable {
    public var description: SourcedValue<String>?
    public var year: SourcedValue<Int>?
    public var publisher: SourcedValue<String>?
    public var subjects: SourcedValue<[String]>?
}

public enum OnlineMetadataMerge {
    /// What the book is missing. `hasEPUBCover` is false for a book drawn with the generated placeholder.
    public static func missing(details: EPUBDetails?, hasEPUBCover: Bool) -> OnlineFieldSelection {
        var missing: OnlineFieldSelection = []
        if !hasEPUBCover { missing.insert(.cover) }
        if isBlank(details?.description) { missing.insert(.description) }
        if details?.year == nil || isBlank(details?.publisher) || (details?.subjects ?? []).isEmpty {
            missing.insert(.publication)
        }
        return missing
    }

    /// Whether a background or bulk lookup is worth it: no cover or no description.
    public static func needsLookup(details: EPUBDetails?, hasEPUBCover: Bool, online: OnlineBookDetails?) -> Bool {
        let m = missing(details: details, hasEPUBCover: hasEPUBCover)
        let coverMissing = m.contains(.cover) && online?.hasCover != true
        let descriptionMissing = m.contains(.description) && online?.description == nil
        return coverMissing || descriptionMissing
    }

    /// The pieces of `match` that would fill something the book is missing (and that it does not already have
    /// from an earlier online lookup).
    public static func applicable(_ match: OnlineBookMatch, details: EPUBDetails?, hasEPUBCover: Bool,
                                  online: OnlineBookDetails?) -> OnlineFieldSelection {
        let m = missing(details: details, hasEPUBCover: hasEPUBCover)
        var result: OnlineFieldSelection = []
        if m.contains(.cover), match.coverID != nil, online?.hasCover != true { result.insert(.cover) }
        if m.contains(.description), !isBlank(match.description), online?.description == nil { result.insert(.description) }
        if m.contains(.publication) {
            let fills = (details?.year == nil && online?.year == nil && match.year != nil)
                || (isBlank(details?.publisher) && online?.publisher == nil && !isBlank(match.publisher))
                || ((details?.subjects ?? []).isEmpty && (online?.subjects ?? []).isEmpty && !match.subjects.isEmpty)
            if fills { result.insert(.publication) }
        }
        return result
    }

    /// Applies the chosen pieces of `match`, filling only what the EPUB lacks. `coverStored` says whether the
    /// cover image was actually downloaded and stored. Returns the new online details (nil when nothing is left).
    public static func apply(_ match: OnlineBookMatch, selection: OnlineFieldSelection, details: EPUBDetails?,
                             hasEPUBCover: Bool, online: OnlineBookDetails?, coverStored: Bool) -> OnlineBookDetails? {
        let allowed = applicable(match, details: details, hasEPUBCover: hasEPUBCover, online: online)
            .intersection(selection)
        var result = online ?? OnlineBookDetails(sourceKey: match.key)
        if allowed.contains(.cover), coverStored, !hasEPUBCover {
            result.hasCover = true
            result.sourceKey = match.key
        }
        if allowed.contains(.description), isBlank(details?.description), let text = match.description, !isBlank(text) {
            result.description = text
            result.sourceKey = match.key
        }
        if allowed.contains(.publication) {
            if details?.year == nil, result.year == nil, let year = match.year { result.year = year }
            if isBlank(details?.publisher), result.publisher == nil, let p = match.publisher, !isBlank(p) { result.publisher = p }
            if (details?.subjects ?? []).isEmpty, result.subjects.isEmpty { result.subjects = match.subjects }
            result.sourceKey = match.key
        }
        return result.isEmpty ? nil : result
    }

    /// The values to show, EPUB first.
    public static func merged(details: EPUBDetails?, online: OnlineBookDetails?) -> MergedBookDetails {
        func pick<T: Sendable & Equatable>(_ epub: T?, _ web: T?) -> SourcedValue<T>? {
            if let epub { return SourcedValue(value: epub, source: .epub) }
            if let web { return SourcedValue(value: web, source: .openLibrary) }
            return nil
        }
        let epubDescription = isBlank(details?.description) ? nil : details?.description
        let epubPublisher = isBlank(details?.publisher) ? nil : details?.publisher
        let epubSubjects = (details?.subjects ?? []).isEmpty ? nil : details?.subjects
        let webSubjects = (online?.subjects ?? []).isEmpty ? nil : online?.subjects
        return MergedBookDetails(description: pick(epubDescription, online?.description),
                                 year: pick(details?.year, online?.year),
                                 publisher: pick(epubPublisher, online?.publisher),
                                 subjects: pick(epubSubjects, webSubjects))
    }

    static func isBlank(_ s: String?) -> Bool {
        s?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}
