import Foundation
import ReaderCore

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
        static let settingsStamp = "settingsStamp"
        static let hashes = "hashes"
    }
    enum MessageType {
        static let book = "book"
        static let settings = "settings"
        static let deleteBook = "delete_book"
        /// Watch -> phone (applicationContext): hashes of the books stored on the watch.
        static let library = "library"
    }

    static func bookMetadata(for entry: LibraryEntry, formatVersion: Int) -> [String: Any] {
        [Key.type: MessageType.book,
         Key.documentHash: entry.documentHash,
         Key.title: entry.title,
         Key.author: entry.author,
         Key.size: entry.size,
         Key.formatVersion: formatVersion]
    }

    /// `stamp` is the time the user saved the settings; resends reuse it so the watch can ignore
    /// settings it has already applied.
    static func settingsInfo(server: String, user: String, password: String, stamp: Int = 0) -> [String: Any] {
        [Key.type: MessageType.settings,
         Key.kosyncServer: server,
         Key.kosyncUser: user,
         Key.kosyncPassword: password,
         Key.settingsStamp: stamp]
    }

    /// Phone -> watch settings context. KOSync fields are present only when valid credentials are saved;
    /// typography is present once the user has changed it anywhere (stamp > 0). nil when there is nothing to send.
    static func settingsContext(kosync: (server: String, user: String, password: String, stamp: Int)?,
                                typography: ReaderTypography?) -> [String: Any]? {
        var info: [String: Any] = [Key.type: MessageType.settings]
        var hasContent = false
        if let k = kosync {
            info = settingsInfo(server: k.server, user: k.user, password: k.password, stamp: k.stamp)
            hasContent = true
        }
        if let typography, typography.stamp > 0 {
            info.merge(TypographySync.context(for: typography)) { _, new in new }
            hasContent = true
        }
        return hasContent ? info : nil
    }

    /// Hashes the watch reports in its `library` context; nil for any other message.
    static func libraryHashes(from context: [String: Any]) -> Set<String>? {
        guard (context[Key.type] as? String) == MessageType.library,
              let list = context[Key.hashes] as? [String] else { return nil }
        return Set(list)
    }

    static func deleteBook(hash: String) -> [String: Any] {
        [Key.type: MessageType.deleteBook, Key.documentHash: hash]
    }
}
