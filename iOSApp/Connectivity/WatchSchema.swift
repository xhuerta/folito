import Foundation

/// Message schema shared (by convention, see docs/WATCH_CONNECTIVITY.md) with the watch app.
enum WatchSchema {
    enum Key {
        static let type = "type"
        static let documentHash = "documentHash"
        static let title = "title"
        static let author = "author"
        static let size = "size"
        static let formatVersion = "formatVersion"
        static let kosyncServer = "kosync_server"
        static let kosyncUser = "kosync_user"
        static let kosyncPassword = "kosync_password"
    }
    enum MessageType {
        static let book = "book"
        static let settings = "settings"
        static let deleteBook = "delete_book"
    }

    static func bookMetadata(for entry: LibraryEntry, formatVersion: Int) -> [String: Any] {
        [Key.type: MessageType.book,
         Key.documentHash: entry.documentHash,
         Key.title: entry.title,
         Key.author: entry.author,
         Key.size: entry.size,
         Key.formatVersion: formatVersion]
    }

    static func settingsInfo(server: String, user: String, password: String) -> [String: Any] {
        [Key.type: MessageType.settings,
         Key.kosyncServer: server,
         Key.kosyncUser: user,
         Key.kosyncPassword: password]
    }

    static func deleteBook(hash: String) -> [String: Any] {
        [Key.type: MessageType.deleteBook, Key.documentHash: hash]
    }
}
