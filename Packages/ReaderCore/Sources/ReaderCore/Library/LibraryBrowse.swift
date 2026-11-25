import Foundation

// Search, sort and browse of the iPhone Library (#114). Pure rules, so they are unit-tested on Linux; the
// Library view builds `LibraryBookFacts` for each of its rows (local books and books only in Readest) and asks
// these for the rows and sections to show.

/// What searching, sorting and grouping need to know about one row of the Library.
public struct LibraryBookFacts: Sendable, Equatable {
    public var title: String
    /// Every author, as shown (empty when unknown).
    public var authors: [String]
    public var series: BookSeries?
    /// When the book was added (imported on this iPhone, or added to Readest for a book only there).
    public var addedAt: Date?
    /// The last reading activity known for the book (watch position, read status, Readest row change).
    public var lastReadAt: Date?
    public var isFinished: Bool

    public init(title: String, authors: [String] = [], series: BookSeries? = nil, addedAt: Date? = nil,
                lastReadAt: Date? = nil, isFinished: Bool = false) {
        self.title = title
        self.authors = authors
        self.series = series
        self.addedAt = addedAt
        self.lastReadAt = lastReadAt
        self.isFinished = isFinished
    }

    /// The newest of `lastReadAt` and `addedAt`: a book just added counts as just touched.
    public var lastActivity: Date? {
        switch (lastReadAt, addedAt) {
        case let (read?, added?): return max(read, added)
        case let (read?, nil): return read
        case let (nil, added?): return added
        case (nil, nil): return nil
        }
    }
}

/// The Library's sort orders (the sort menu).
public enum LibrarySortOrder: String, CaseIterable, Sendable {
    /// Default: unfinished books first, each group by its last activity, newest first.
    case recentlyRead
    /// Newest first.
    case recentlyAdded
    /// A to Z (case, accents and width ignored; numbers in numeric order), then author.
    case title
    /// A to Z by the first author as shown, then series and position, then title.
    case author
}

/// How the Library lists its rows. Each mode other than `books` groups the rows into sections; a book can be in
/// several sections (one per author). A user collection would be one more grouping (#164).
public enum LibraryBrowseMode: String, CaseIterable, Sendable {
    case books
    case authors
    case series
}

/// One section of the Library.
public struct LibrarySection<Item>: Identifiable {
    public enum Kind: Equatable, Sendable {
        /// Every row (browse mode `books`).
        case all
        case author(String)
        case series(String)
        /// The books without an author (browse mode `authors`), after the authors.
        case unknownAuthor
        /// The books without a series (browse mode `series`), after the series.
        case noSeries
    }

    public var kind: Kind
    public var items: [Item]

    public init(kind: Kind, items: [Item]) {
        self.kind = kind
        self.items = items
    }

    /// Stable across updates: the kind and its folded name.
    public var id: String {
        switch kind {
        case .all: return "all"
        case .author(let name): return "author:" + LibrarySearch.normalize(name)
        case .series(let name): return "series:" + LibrarySearch.normalize(name)
        case .unknownAuthor: return "unknownAuthor"
        case .noSeries: return "noSeries"
        }
    }
}

public enum LibrarySearch {
    /// The form compared by search and grouping: case, diacritics and width folded ("Émile" = "emile", "ｆ" =
    /// "f"), typographic quotes and dashes made plain ("Alice’s" = "Alice's"), whitespace collapsed and trimmed.
    public static func normalize(_ text: String) -> String {
        var plain = ""
        plain.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}", "\u{02BC}": plain.unicodeScalars.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}", "\u{00AB}", "\u{00BB}": plain.unicodeScalars.append("\"")
            case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}": plain.unicodeScalars.append("-")
            default: plain.unicodeScalars.append(scalar)
            }
        }
        let folded = plain.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            // Letters that do not decompose into a base letter and a mark.
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: "đ", with: "d")
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The words of a query, normalized; empty for a blank query.
    public static func terms(_ query: String) -> [String] {
        normalize(query).split(separator: " ").map(String.init)
    }

    /// Whether a book matches: every word of the query is found in its title, one of its authors or its series
    /// name (each word may be in a different one). A blank query matches every book.
    public static func matches(_ query: String, _ facts: LibraryBookFacts) -> Bool {
        let words = terms(query)
        guard !words.isEmpty else { return true }
        let fields = ([facts.title] + facts.authors + [facts.series?.name].compactMap { $0 }).map(normalize)
        return words.allSatisfy { word in fields.contains { $0.contains(word) } }
    }

    /// The items that match `query`, in their order.
    public static func filter<T>(_ items: [T], query: String, facts: (T) -> LibraryBookFacts) -> [T] {
        guard !terms(query).isEmpty else { return items }
        return items.filter { matches(query, facts($0)) }
    }
}

public enum LibraryBrowsing {
    /// Compares two texts as a reader expects in a list: case, accents and width ignored, numbers in numeric
    /// order ("Book 2" before "Book 10"), in the rules of `locale`.
    public static func compare(_ a: String, _ b: String, locale: Locale) -> ComparisonResult {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric]
        let x = LibrarySearch.normalize(a), y = LibrarySearch.normalize(b)
        let result = x.compare(y, options: options, range: nil, locale: locale)
        if result != .orderedSame || x == y { return result }
        return x < y ? .orderedAscending : .orderedDescending
    }

    /// The items in `order`. Every order is stable: items that compare equal keep the order they came in (for the
    /// Library: local books newest first, then the books only in Readest, newest first).
    public static func sorted<T>(_ items: [T], by order: LibrarySortOrder, locale: Locale = .current,
                                 facts: (T) -> LibraryBookFacts) -> [T] {
        let keyed = items.enumerated().map { (offset: $0.offset, item: $0.element, facts: facts($0.element)) }
        let sorted = keyed.sorted { a, b in
            let result = compare(a.facts, b.facts, by: order, locale: locale)
            return result == .orderedSame ? a.offset < b.offset : result == .orderedAscending
        }
        return sorted.map(\.item)
    }

    /// The order of two books (ascending = `a` first).
    public static func compare(_ a: LibraryBookFacts, _ b: LibraryBookFacts, by order: LibrarySortOrder,
                               locale: Locale) -> ComparisonResult {
        switch order {
        case .recentlyRead:
            if a.isFinished != b.isFinished { return a.isFinished ? .orderedDescending : .orderedAscending }
            return newestFirst(a.lastActivity, b.lastActivity)
        case .recentlyAdded:
            return newestFirst(a.addedAt, b.addedAt)
        case .title:
            let byTitle = compare(a.title, b.title, locale: locale)
            if byTitle != .orderedSame { return byTitle }
            return compare(a.authors.first ?? "", b.authors.first ?? "", locale: locale)
        case .author:
            // Books without an author after the others.
            let x = a.authors.first ?? "", y = b.authors.first ?? ""
            if x.isEmpty != y.isEmpty { return x.isEmpty ? .orderedDescending : .orderedAscending }
            let byAuthor = compare(x, y, locale: locale)
            if byAuthor != .orderedSame { return byAuthor }
            let bySeries = seriesOrder(a, b, locale: locale)
            if bySeries != .orderedSame { return bySeries }
            return compare(a.title, b.title, locale: locale)
        }
    }

    /// Newest first; a missing date after every date.
    private static func newestFirst(_ x: Date?, _ y: Date?) -> ComparisonResult {
        switch (x, y) {
        case let (x?, y?): return x == y ? .orderedSame : (x > y ? .orderedAscending : .orderedDescending)
        case (.some, nil): return .orderedAscending
        case (nil, .some): return .orderedDescending
        case (nil, nil): return .orderedSame
        }
    }

    /// Series name, then position in the series (a book without a position after the numbered ones; 2.5 between
    /// 2 and 3). Books without a series after the others.
    static func seriesOrder(_ a: LibraryBookFacts, _ b: LibraryBookFacts, locale: Locale) -> ComparisonResult {
        switch (a.series, b.series) {
        case (nil, nil): return .orderedSame
        case (.some, nil): return .orderedAscending
        case (nil, .some): return .orderedDescending
        case let (x?, y?):
            let byName = compare(x.name, y.name, locale: locale)
            if byName != .orderedSame { return byName }
            return positionOrder(x.index, y.index)
        }
    }

    /// Ascending position; no position after every position.
    private static func positionOrder(_ x: Double?, _ y: Double?) -> ComparisonResult {
        switch (x, y) {
        case let (x?, y?): return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case (.some, nil): return .orderedAscending
        case (nil, .some): return .orderedDescending
        case (nil, nil): return .orderedSame
        }
    }

    /// The sections to list for `mode`:
    /// - `books`: one section with every item, in `order`;
    /// - `authors`: one section per author, A to Z, the books in `order` (a book with two authors is in both),
    ///   then the books without an author;
    /// - `series`: one section per series, A to Z, the books by their position in it (then title), then the books
    ///   without a series, in `order`.
    /// Names are grouped in their folded form (`LibrarySearch.normalize`): "Le Guin" and "le guin" are one
    /// section, named as the first book in `order` writes it. Empty sections are never returned.
    public static func sections<T>(_ items: [T], mode: LibraryBrowseMode, order: LibrarySortOrder,
                                   locale: Locale = .current,
                                   facts: (T) -> LibraryBookFacts) -> [LibrarySection<T>] {
        let ordered = sorted(items, by: order, locale: locale, facts: facts)
        switch mode {
        case .books:
            return ordered.isEmpty ? [] : [LibrarySection(kind: .all, items: ordered)]
        case .authors:
            var groups = Groups<T>()
            var none: [T] = []
            for item in ordered {
                let names = facts(item).authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if names.isEmpty { none.append(item); continue }
                var seen = Set<String>()
                for name in names where seen.insert(LibrarySearch.normalize(name)).inserted {
                    groups.add(item, name: name)
                }
            }
            var result = groups.sortedByName(locale: locale).map { LibrarySection(kind: .author($0.name), items: $0.items) }
            if !none.isEmpty { result.append(LibrarySection(kind: .unknownAuthor, items: none)) }
            return result
        case .series:
            var groups = Groups<T>()
            var none: [T] = []
            for item in ordered {
                let name = facts(item).series?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if name.isEmpty { none.append(item) } else { groups.add(item, name: name) }
            }
            var result = groups.sortedByName(locale: locale).map { group in
                // Stable: books at the same position (or both without one) keep `order`'s order.
                let inSeries = group.items.enumerated().sorted { a, b in
                    let fa = facts(a.element), fb = facts(b.element)
                    let byPosition = positionOrder(fa.series?.index, fb.series?.index)
                    if byPosition != .orderedSame { return byPosition == .orderedAscending }
                    let byTitle = compare(fa.title, fb.title, locale: locale)
                    if byTitle != .orderedSame { return byTitle == .orderedAscending }
                    return a.offset < b.offset
                }.map(\.element)
                return LibrarySection(kind: .series(group.name), items: inSeries)
            }
            if !none.isEmpty { result.append(LibrarySection(kind: .noSeries, items: none)) }
            return result
        }
    }

    /// Items grouped by a folded name, each group named as its first item writes it.
    private struct Groups<T> {
        private var order: [String] = []
        private var groups: [String: (name: String, items: [T])] = [:]

        mutating func add(_ item: T, name: String) {
            let key = LibrarySearch.normalize(name)
            if groups[key] == nil {
                order.append(key)
                groups[key] = (name, [])
            }
            groups[key]?.items.append(item)
        }

        func sortedByName(locale: Locale) -> [(name: String, items: [T])] {
            order.compactMap { groups[$0] }.sorted { compare($0.name, $1.name, locale: locale) == .orderedAscending }
        }
    }
}

/// When the watch's reports say a book was read (#114, "Recently Read"): the iPhone has no reading position of
/// its own, so a change of the fraction the watch reports for a book counts as reading it at the time the report
/// arrives.
public enum ReadingActivity {
    /// Whether `current` is a move from `previous` (nil = never reported, the same as 0).
    public static func hasMoved(from previous: Double?, to current: Double) -> Bool {
        guard current.isFinite else { return false }
        return abs(current - (previous ?? 0)) > 0.000_001
    }
}

// MARK: - Readest rows

extension ReadestCloudBook {
    /// The row's `metadata` (a JSON string in the DB row, or an object), nil when absent or unreadable.
    var metadataObject: [String: Any]? {
        let row = ((try? JSONSerialization.jsonObject(with: rawRow)) as? [String: Any]) ?? [:]
        switch row["metadata"] {
        case let object as [String: Any]:
            return object
        case let text as String:
            guard let data = text.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        default:
            return nil
        }
    }

    /// The book's series from the row's `metadata`, when Readest has one: `series` and `seriesIndex` (Readest's
    /// book metadata), or foliate-js's `belongsTo.series` (`{name, position}`, or a list of them). The position may
    /// be a number or a numeric string ("2.5"); nil when it is neither.
    public var series: BookSeries? {
        guard let metadata = metadataObject else { return nil }
        if let name = Self.text(metadata["series"]) {
            return BookSeries(name: name, index: Self.number(metadata["seriesIndex"] ?? metadata["series_index"]))
        }
        if let series = metadata["series"] as? [String: Any], let found = Self.series(series) { return found }
        if let belongsTo = metadata["belongsTo"] as? [String: Any] {
            if let one = belongsTo["series"] as? [String: Any], let found = Self.series(one) { return found }
            if let list = belongsTo["series"] as? [[String: Any]], let found = list.lazy.compactMap(Self.series).first {
                return found
            }
            if let name = Self.text(belongsTo["series"]) { return BookSeries(name: name) }
        }
        return nil
    }

    /// When the row was created (`created_at`): when the book was added to Readest.
    public var createdAt: Date? {
        let row = ((try? JSONSerialization.jsonObject(with: rawRow)) as? [String: Any]) ?? [:]
        return ReadestHTTP.date(row["created_at"] ?? row["createdAt"])
    }

    private static func series(_ object: [String: Any]) -> BookSeries? {
        guard let name = text(object["name"]) ?? text(object["title"]) else { return nil }
        return BookSeries(name: name, index: number(object["position"] ?? object["index"]))
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isFinite ? $0 : nil }
        }
        if let number = value as? NSNumber {
            // A JSON `true` is not a position: it decodes as a boolean NSNumber (type "c"; `is Bool` is also
            // true for the numbers 0 and 1).
            if String(cString: number.objCType) == "c" { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        return nil
    }
}
