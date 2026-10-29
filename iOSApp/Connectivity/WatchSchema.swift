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
        /// `true` = the user turned sync off on the phone; the watch removes its credentials and queue.
        static let kosyncCleared = "kosync_cleared"
        static let syncConnector = SyncSettingsWire.connectorKey
        static let syncCredentials = SyncSettingsWire.credentialsKey
        static let syncCleared = SyncSettingsWire.clearedKey
        static let settingsVersion = SyncSettingsWire.versionKey
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

    /// "Sync turned off" state: no credential keys, an explicit marker and the stamp of the clear action
    /// (newer than any earlier save, so the watch applies it exactly once).
    static func clearedInfo(stamp: Int) -> [String: Any] {
        [Key.type: MessageType.settings, Key.kosyncCleared: true, Key.syncCleared: true,
         Key.settingsVersion: SyncSettingsWire.version, Key.settingsStamp: stamp]
    }

    /// Generic connector settings (`sync_connector` + `sync_credentials`, settings version 2). For KOSync the
    /// three `kosync_*` keys are added too, so watch builds from before connectors keep syncing.
    static func connectorInfo(connectorID: String, credentials: SyncCredentials, stamp: Int) -> [String: Any] {
        var info: [String: Any] = [Key.type: MessageType.settings, Key.settingsStamp: stamp]
        info.merge(SyncSettingsWire.encode(connectorID: connectorID, credentials: credentials)) { _, new in new }
        if connectorID == KOSyncConnectorFactory.id {
            info[Key.kosyncServer] = credentials[KOSyncConnectorFactory.Key.server] ?? ""
            info[Key.kosyncUser] = credentials[KOSyncConnectorFactory.Key.user] ?? ""
            info[Key.kosyncPassword] = credentials[KOSyncConnectorFactory.Key.password] ?? ""
        }
        return info
    }

    /// Phone -> watch settings context. Sync keys are present only when a connector's credentials are saved;
    /// `clearedStamp` (used only when there are no credentials) makes the watch drop its own credentials.
    /// Typography is present once the user has changed it anywhere (stamp > 0). nil when there is nothing to send.
    static func settingsContext(sync: (connectorID: String, credentials: SyncCredentials, stamp: Int)?,
                                clearedStamp: Int? = nil,
                                typography: ReaderTypography?) -> [String: Any]? {
        var info: [String: Any] = [Key.type: MessageType.settings]
        var hasContent = false
        if let s = sync {
            info = connectorInfo(connectorID: s.connectorID, credentials: s.credentials, stamp: s.stamp)
            hasContent = true
        } else if let clearedStamp, clearedStamp > 0 {
            info = clearedInfo(stamp: clearedStamp)
            hasContent = true
        }
        if let typography, typography.stamp > 0 {
            info.merge(TypographySync.context(for: typography)) { _, new in new }
            hasContent = true
        }
        return hasContent ? info : nil
    }

    /// KOSync-only form (kept for callers and tests written before connectors).
    static func settingsContext(kosync: (server: String, user: String, password: String, stamp: Int)?,
                                clearedStamp: Int? = nil,
                                typography: ReaderTypography?) -> [String: Any]? {
        let sync = kosync.map { k in
            (connectorID: KOSyncConnectorFactory.id,
             credentials: SyncCredentials([KOSyncConnectorFactory.Key.server: k.server,
                                           KOSyncConnectorFactory.Key.user: k.user,
                                           KOSyncConnectorFactory.Key.password: k.password]),
             stamp: k.stamp)
        }
        return settingsContext(sync: sync, clearedStamp: clearedStamp, typography: typography)
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
