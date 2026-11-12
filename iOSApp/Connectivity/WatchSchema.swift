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
        /// Phone -> watch: stamp of the credentials or of the "sync turned off" action. Watch -> phone
        /// (`library` context): the stamp it last applied.
        static let settingsStamp = "settingsStamp"
        static let syncConnector = SyncSettingsWire.connectorKey
        static let syncCredentials = SyncSettingsWire.credentialsKey
        /// `true` = the user turned sync off on the phone; the watch removes its credentials and queue.
        static let syncCleared = SyncSettingsWire.clearedKey
        static let settingsVersion = SyncSettingsWire.versionKey
        static let hashes = "hashes"
        /// Watch -> phone (`library` context): estimated seconds left per book hash.
        static let timeRemaining = "timeRemaining"
        /// Watch -> phone (`library` context): whole percent read per book hash.
        static let progress = "progress"
        /// Phone -> watch: a small JPEG of the book's cover (book file metadata, or a `book_cover` message).
        static let cover = "cover"
        static let dictionaryId = "dictionaryId"
        static let dictionaries = "dictionaries"
        static let sha256 = "sha256"
        /// Watch -> phone (`library` context): hashes of the books the user deleted on the watch.
        static let removed = "removed"
        /// Watch -> phone (`library` context, `book_removed`): id of the watch app installation (a new one after
        /// a reinstall, reset or re-pair).
        static let watchID = "watchID"
    }
    enum MessageType {
        static let book = "book"
        static let settings = "settings"
        /// Phone -> watch (transferUserInfo): the active sync connector and its credentials.
        static let credentials = "credentials"
        static let deleteBook = "delete_book"
        /// Phone -> watch (transferUserInfo): the cover of a book the watch already has.
        static let bookCover = "book_cover"
        /// Watch -> phone (applicationContext): hashes of the books stored on the watch.
        static let library = "library"
        /// Phone -> watch (transferFile): a compact offline dictionary.
        static let dictionary = "dictionary"
        static let deleteDictionary = "delete_dictionary"
        /// Watch -> phone (sendMessage, or transferUserInfo when not reachable): the user deleted a book there.
        static let bookRemoved = "book_removed"
    }

    /// What the watch's `library` context says about its books.
    struct LibraryReport: Equatable {
        var hashes: Set<String>
        /// Books the user deleted on the watch (empty from watch apps that predate the key).
        var removed: Set<String> = []
        /// The watch app installation that reported (nil from watch apps that predate the key).
        var watchID: String? = nil
    }

    /// The `library` report of a context; nil for any other message.
    static func libraryReport(from context: [String: Any]) -> LibraryReport? {
        guard let hashes = libraryHashes(from: context) else { return nil }
        let removed = (context[Key.removed] as? [String] ?? []).filter { !$0.isEmpty }
        return LibraryReport(hashes: hashes, removed: Set(removed), watchID: nonEmpty(context[Key.watchID]))
    }

    /// `(hash, watchID)` of a `book_removed` message; nil for any other message.
    static func bookRemoved(from info: [String: Any]) -> (hash: String, watchID: String?)? {
        guard (info[Key.type] as? String) == MessageType.bookRemoved, let hash = nonEmpty(info[Key.documentHash]) else { return nil }
        return (hash, nonEmpty(info[Key.watchID]))
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// File metadata of a dictionary transfer; the watch installs it only if size and SHA-256 match.
    static func dictionaryMetadata(id: String, sha256: String, size: Int64) -> [String: Any] {
        [Key.type: MessageType.dictionary, Key.dictionaryId: id, Key.sha256: sha256, Key.size: size]
    }

    static func deleteDictionary(id: String) -> [String: Any] {
        [Key.type: MessageType.deleteDictionary, Key.dictionaryId: id]
    }

    /// Ids of the dictionaries the watch reports in its `library` context; nil for any other message.
    static func libraryDictionaries(from context: [String: Any]) -> Set<String>? {
        guard (context[Key.type] as? String) == MessageType.library,
              let list = context[Key.dictionaries] as? [String] else { return nil }
        return Set(list)
    }

    /// `cover`: the watch thumbnail (JPEG, a few KB), omitted for books without a cover.
    static func bookMetadata(for entry: LibraryEntry, formatVersion: Int, cover: Data? = nil) -> [String: Any] {
        var metadata: [String: Any] = [Key.type: MessageType.book,
                                       Key.documentHash: entry.documentHash,
                                       Key.title: entry.title,
                                       Key.author: entry.author,
                                       Key.size: entry.size,
                                       Key.formatVersion: formatVersion]
        if let cover, !cover.isEmpty { metadata[Key.cover] = cover }
        return metadata
    }

    static func bookCover(hash: String, cover: Data) -> [String: Any] {
        [Key.type: MessageType.bookCover, Key.documentHash: hash, Key.cover: cover]
    }

    /// Fraction read (0...1) per book that the watch reports in its `library` context (empty when it reports
    /// none, nil for any other message). Invalid values are dropped.
    static func libraryProgress(from context: [String: Any]) -> [String: Double]? {
        guard (context[Key.type] as? String) == MessageType.library else { return nil }
        let raw = context[Key.progress] as? [String: Any] ?? [:]
        var result: [String: Double] = [:]
        for (hash, value) in raw {
            let percent = (value as? Int).map(Double.init) ?? (value as? Double)
            if let percent, percent.isFinite, percent >= 0, percent <= 100 { result[hash] = percent / 100 }
        }
        return result
    }

    /// "Sync turned off" state: an explicit marker and the stamp of the clear action (newer than any earlier
    /// save, so the watch applies it exactly once). Carries no credentials.
    static func clearedInfo(stamp: Int) -> [String: Any] {
        [Key.type: MessageType.settings, Key.syncCleared: true,
         Key.settingsVersion: SyncSettingsWire.version, Key.settingsStamp: stamp]
    }

    /// Phone -> watch credentials message (`transferUserInfo`, never the application context: the system keeps
    /// the latest context on disk on both devices, outside the Keychain). `credentials` must be the connector's
    /// `watchCredentials(from:)`. `stamp` is the time the user saved them; resends reuse it so the watch can
    /// ignore credentials it has already applied.
    static func credentialsMessage(connectorID: String, credentials: SyncCredentials, stamp: Int) -> [String: Any] {
        var info: [String: Any] = [Key.type: MessageType.credentials, Key.settingsStamp: stamp]
        info.merge(SyncSettingsWire.encode(connectorID: connectorID, credentials: credentials)) { _, new in new }
        return info
    }

    /// Stamp of a credentials message; nil for any other message.
    static func credentialsStamp(from info: [String: Any]) -> Int? {
        guard (info[Key.type] as? String) == MessageType.credentials else { return nil }
        return info[Key.settingsStamp] as? Int
    }

    /// Stamp of the sync settings the watch last applied, from its `library` context (0 when it has applied
    /// none, e.g. a freshly installed watch app); nil for any other message.
    static func librarySettingsStamp(from context: [String: Any]) -> Int? {
        guard (context[Key.type] as? String) == MessageType.library else { return nil }
        return context[Key.settingsStamp] as? Int ?? 0
    }

    /// Whether the credentials saved with `phoneStamp` still have to be sent: the watch has not reported
    /// applying them (or anything newer). `watchStamp` nil = the watch has not reported yet.
    static func needsCredentials(watchStamp: Int?, phoneStamp: Int) -> Bool {
        (watchStamp ?? 0) < phoneStamp
    }

    /// Phone -> watch settings context. It never carries credentials (see `credentialsMessage`).
    /// `clearedStamp` (set only while no credentials are saved) makes the watch drop its own credentials.
    /// Typography is present once the user has changed it anywhere (stamp > 0).
    static func settingsContext(clearedStamp: Int? = nil, typography: ReaderTypography?) -> [String: Any] {
        var info: [String: Any] = [Key.type: MessageType.settings, Key.settingsVersion: SyncSettingsWire.version]
        if let clearedStamp, clearedStamp > 0 { info = clearedInfo(stamp: clearedStamp) }
        if let typography, typography.stamp > 0 {
            info.merge(TypographySync.context(for: typography)) { _, new in new }
        }
        return info
    }

    /// Hashes the watch reports in its `library` context; nil for any other message.
    static func libraryHashes(from context: [String: Any]) -> Set<String>? {
        guard (context[Key.type] as? String) == MessageType.library,
              let list = context[Key.hashes] as? [String] else { return nil }
        return Set(list)
    }

    /// Seconds of reading left per book that the watch reports in its `library` context (empty when it
    /// reports none, nil for any other message). Invalid values are dropped.
    static func libraryTimeRemaining(from context: [String: Any]) -> [String: TimeInterval]? {
        guard (context[Key.type] as? String) == MessageType.library else { return nil }
        let raw = context[Key.timeRemaining] as? [String: Any] ?? [:]
        var result: [String: TimeInterval] = [:]
        for (hash, value) in raw {
            let seconds = (value as? Double) ?? (value as? Int).map(Double.init)
            if let seconds, seconds.isFinite, seconds > 0 { result[hash] = seconds }
        }
        return result
    }

    static func deleteBook(hash: String) -> [String: Any] {
        [Key.type: MessageType.deleteBook, Key.documentHash: hash]
    }
}
