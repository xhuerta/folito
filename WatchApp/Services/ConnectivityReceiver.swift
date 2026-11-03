import Foundation
import WatchConnectivity
import ReaderCore

/// Receives books (transferFile), settings (applicationContext, or transferUserInfo from older phones)
/// and delete requests from the iPhone, and tells the phone which books it holds.
/// Wire names (see docs/WATCH_CONNECTIVITY.md):
///  - file metadata keys: documentHash, title, author, size; payload = LZFSE-compressed ProcessedBook JSON
///  - settings (`type == "settings"`): sync_connector + sync_credentials (any connector; KOSync also as
///    kosync_server, kosync_user, kosync_password for older watch builds), settingsStamp,
///    or `sync_cleared` / `kosync_cleared == true` + settingsStamp (sync turned off on the phone),
///    and (independently, last writer wins) typography + typographyStamp
///  - delete: `{ type: "delete_book", documentHash: <hash> }` (userInfo or message)
///  - dictionary file metadata: `{ type: "dictionary", dictionaryId, sha256, size }`; payload = compact
///    dictionary (docs/DICTIONARIES.md), installed only if its size and SHA-256 match
///  - delete dictionary: `{ type: "delete_dictionary", dictionaryId: <id> }` (userInfo)
///  - watch -> phone (applicationContext): `{ type: "library", hashes: [<documentHash>], dictionaries: [<id>],
///    typography?, typographyStamp? }`
/// WCSessionDelegate callbacks arrive on a background queue; all heavy work is hopped off the main actor.
final class ConnectivityReceiver: NSObject, WCSessionDelegate {
    static let typeKey = "type"
    static let deleteType = "delete_book"
    static let documentHashKey = "documentHash"

    /// Hash of the book to delete, per docs/WATCH_CONNECTIVITY.md (`type == "delete_book"` + `documentHash`).
    /// Also accepts the legacy shape `{ "delete_book": <hash> }`.
    static func deleteHash(from info: [String: Any]) -> String? {
        if (info[typeKey] as? String) == deleteType, let hash = info[documentHashKey] as? String, !hash.isEmpty {
            return hash
        }
        if let hash = info[deleteType] as? String, !hash.isEmpty { return hash }
        return nil
    }

    static let settingsStampKey = "settings.appliedStamp"
    static let libraryType = "library"
    static let hashesKey = "hashes"
    static let dictionaryType = "dictionary"
    static let deleteDictionaryType = "delete_dictionary"
    static let dictionaryIdKey = "dictionaryId"
    static let dictionariesKey = "dictionaries"
    static let sha256Key = "sha256"
    static let sizeKey = "size"

    /// A dictionary file transfer: its id, expected SHA-256 and size; nil for any other file (books).
    static func dictionaryTransfer(from metadata: [String: Any]?) -> (id: String, sha256: String, size: Int64)? {
        guard let metadata, (metadata[typeKey] as? String) == dictionaryType,
              let id = metadata[dictionaryIdKey] as? String, !id.isEmpty,
              let sha = metadata[sha256Key] as? String, sha.count == 64 else { return nil }
        let size = (metadata[sizeKey] as? NSNumber)?.int64Value ?? -1
        guard size > 0 else { return nil }
        return (id, sha, size)
    }

    /// Id of the dictionary to delete (`type == "delete_dictionary"`), nil for any other message.
    static func deleteDictionaryId(from info: [String: Any]) -> String? {
        guard (info[typeKey] as? String) == deleteDictionaryType,
              let id = info[dictionaryIdKey] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// The phone resends its settings (same stamp) on every activation / state change; apply them only
    /// when newer than what was applied, so a Reset on the watch is not undone by a stale resend.
    /// Messages without a stamp (older phone builds) are always applied.
    static func shouldApplySettings(incomingStamp: Int?, lastApplied: Int) -> Bool {
        guard let incomingStamp else { return true }
        return incomingStamp > lastApplied
    }

    /// Context published to the phone: the hashes of the books stored on the watch.
    /// The watch's typography rides along so the phone can mirror it (last writer wins by stamp).
    static func libraryContext(hashes: [String], dictionaries: [String] = [],
                               typography: ReaderTypography? = nil) -> [String: Any] {
        var context: [String: Any] = [typeKey: libraryType, hashesKey: hashes.sorted(),
                                      dictionariesKey: dictionaries.sorted()]
        if let typography { context.merge(TypographySync.context(for: typography)) { _, new in new } }
        return context
    }

    private let library: BookLibrary
    private let dictionaries: InstalledDictionaries
    private let onDictionariesChanged: @MainActor () -> Void
    private let typography: @MainActor () -> ReaderTypography
    private let onTypography: @MainActor (ReaderTypography) -> Void
    private let onSettingsChanged: @MainActor () -> Void

    init(library: BookLibrary,
         dictionaries: InstalledDictionaries,
         onDictionariesChanged: @escaping @MainActor () -> Void,
         typography: @escaping @MainActor () -> ReaderTypography,
         onTypography: @escaping @MainActor (ReaderTypography) -> Void,
         onSettingsChanged: @escaping @MainActor () -> Void) {
        self.library = library
        self.dictionaries = dictionaries
        self.onDictionariesChanged = onDictionariesChanged
        self.typography = typography
        self.onTypography = onTypography
        self.onSettingsChanged = onSettingsChanged
        super.init()
    }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // Files/userInfo queued while we were not running are delivered after activation.
        // The latest settings context may have arrived while the app was not running: apply it now.
        if activationState == .activated {
            handle(session.receivedApplicationContext)
            publishLibrary()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    /// Tells the phone which books and dictionaries are on the watch so it can (re)send the missing ones.
    func publishLibrary() {
        let library = self.library
        let typography = self.typography
        let dictionaryIds = dictionaries.infos.map(\.id)
        Task { @MainActor in
            let session = WCSession.default
            guard WCSession.isSupported(), session.activationState == .activated else { return }
            let hashes = library.entries.map(\.documentHash)
            try? session.updateApplicationContext(Self.libraryContext(hashes: hashes, dictionaries: dictionaryIds,
                                                                      typography: typography()))
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        if let transfer = Self.dictionaryTransfer(from: file.metadata) {
            receiveDictionary(file.fileURL, id: transfer.id, sha256: transfer.sha256, size: transfer.size)
            return
        }
        // The system deletes `file.fileURL` when this method returns: copy synchronously.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".book")
        do { try FileManager.default.copyItem(at: file.fileURL, to: copy) } catch { return }
        let library = self.library
        Task { @MainActor in await library.importReceivedFile(at: copy) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    /// Moves the received file out of the inbox synchronously (the system deletes it when the delegate
    /// returns; a move is cheap for tens of MB), then verifies and installs it off the main thread.
    private func receiveDictionary(_ url: URL, id: String, sha256: String, size: Int64) {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".folidict")
        do { try FileManager.default.moveItem(at: url, to: staged) } catch {
            do { try FileManager.default.copyItem(at: url, to: staged) } catch { return }
        }
        let dictionaries = self.dictionaries
        let changed = onDictionariesChanged
        Task.detached(priority: .utility) { [weak self] in
            // A damaged transfer is dropped; the phone resends whatever the watch does not report.
            let installed = (try? dictionaries.install(fileAt: staged, size: size, sha256: sha256))
            try? FileManager.default.removeItem(at: staged)
            guard installed != nil else { return }
            await changed()
            self?.publishLibrary()
        }
    }

    // MARK: Handling

    private func handle(_ info: [String: Any]) {
        var changed = false
        let isSettings = (info[Self.typeKey] as? String) == "settings" || CredentialsStore.hasSyncSettings(info)
        if isSettings {
            let stamp = info["settingsStamp"] as? Int
            let defaults = UserDefaults.standard
            let last = defaults.integer(forKey: Self.settingsStampKey)
            if Self.shouldApplySettings(incomingStamp: stamp, lastApplied: last) {
                changed = CredentialsStore.apply(userInfo: info)
                if let stamp { defaults.set(stamp, forKey: Self.settingsStampKey) }
            }
        }
        let deleteHash = Self.deleteHash(from: info)
        if let id = Self.deleteDictionaryId(from: info) {
            dictionaries.remove(id: id)
            let changed = onDictionariesChanged
            Task { @MainActor in changed() }
            publishLibrary()
        }
        let incomingTypography = TypographySync.decode(from: info)
        let library = self.library
        let notify = onSettingsChanged
        let applyTypography = onTypography
        Task { @MainActor in
            if let incomingTypography { applyTypography(incomingTypography) }
            if changed { notify() }
            if let hash = deleteHash { library.delete(documentHash: hash) }
        }
    }
}
