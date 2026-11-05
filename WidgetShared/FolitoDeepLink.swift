import Foundation

/// URLs a complication opens the watch app with (`widgetURL`), handled by `FolitoWatchApp.onOpenURL`.
///
/// - `folito://library`: the library (also the placeholder's link when no book is in progress).
/// - `folito://book/<documentHash>`: the book, at its saved reading position.
enum FolitoDeepLink: Equatable, Sendable {
    case library
    case book(id: String)

    static let scheme = "folito"

    var url: URL {
        switch self {
        case .library:
            return URL(string: "\(Self.scheme)://library")!
        case .book(let id):
            return URL(string: "\(Self.scheme)://book/\(id)")!
        }
    }

    /// Parses a deep link; nil for anything that is not one of ours (other scheme, unknown host, bad id).
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        switch host {
        case "library" where parts.isEmpty:
            self = .library
        case "book" where parts.count == 1 && Self.isValidBookID(parts[0]):
            self = .book(id: parts[0])
        default:
            return nil
        }
    }

    /// Book ids are document hashes: short, URL-safe tokens. Anything else is rejected.
    static func isValidBookID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        return id.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }
    }

    static func forSnapshot(_ snapshot: ReadingSnapshot?) -> FolitoDeepLink {
        guard let snapshot, isValidBookID(snapshot.bookID) else { return .library }
        return .book(id: snapshot.bookID)
    }
}
