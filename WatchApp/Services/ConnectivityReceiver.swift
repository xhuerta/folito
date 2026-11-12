import Foundation
import WatchConnectivity
import ReaderCore

/// Receives books (transferFile), settings (applicationContext), sync credentials (transferUserInfo)
/// and delete requests from the iPhone, and tells the phone which books it holds.
/// Wire names (see docs/WATCH_CONNECTIVITY.md):
///  - file metadata keys: documentHash, title, author, size, cover? (JPEG thumbnail); payload = LZFSE-compressed
///    ProcessedBook JSON
///  - cover of a book already here: `{ type: "book_cover", documentHash, cover }` (userInfo)
///  - settings (`type == "settings"`, applicationContext; never credentials): `sync_cleared == true` +
///    settingsStamp (sync turned off on the phone), and (independently, last writer wins) typography +
///    typographyStamp
///  - credentials (`type == "credentials"`, userInfo): sync_connector + sync_credentials + settingsStamp,
///    moved to the Keychain on receipt
///  - delete: `{ type: "delete_book", documentHash: <hash> }` (userInfo)
///  - dictionary file metadata: `{ type: "dictionary", dictionaryId, sha256, size }`; payload = compact
///    dictionary (docs/DICTIONARIES.md), installed only if its size and SHA-256 match
///  - delete dictionary: `{ type: "delete_dictionary", dictionaryId: <id> }` (userInfo)
///  - watch -> phone (applicationContext): `{ type: "library", hashes: [<documentHash>], dictionaries: [<id>],
///    settingsStamp (last applied; tells the phone whether to send the credentials), removed: [<documentHash>]
///    (deleted here by the user), watchID (this installation), typography?, typographyStamp? }`
///  - watch -> phone: `{ type: "book_removed", documentHash, watchID }` when the user deletes a book here
///    (sendMessage when reachable, else transferUserInfo)
/// WCSessionDelegate callbacks arrive on a background queue; all heavy work is hopped off the main actor.
final class ConnectivityReceiver: NSObject, WCSessionDelegate {
    static let typeKey = "type"
    static let deleteType = "delete_book"
    static let documentHashKey = "documentHash"

    /// Hash of the book to delete, per docs/WATCH_CONNECTIVITY.md (`type == "delete_book"` + `documentHash`).
    static func deleteHash(from info: [String: Any]) -> String? {
        guard (info[typeKey] as? String) == deleteType, let hash = info[documentHashKey] as? String,
              !hash.isEmpty else { return nil }
        return hash
    }

    static let settingsType = "settings"
    static let credentialsType = "credentials"
    /// Phone -> watch: stamp of the credentials / turn-off. Watch -> phone: the stamp last applied.
    static let stampKey = "settingsStamp"

    enum SyncSettingsAction: Equatable { case none, store, clear }

    /// What to do with the sync part of a message. Credentials arrive as a `credentials` message, "sync turned
    /// off" as a marker in the `settings` context; both carry a stamp and are applied only when it is newer
    /// than the last one applied (the phone resends, and a Reset on the watch must not be undone by a resend).
    static func syncSettingsAction(for info: [String: Any], lastApplied: Int) -> SyncSettingsAction {
        guard SyncSettingsWire.isSupported(info),
              shouldApplySettings(incomingStamp: info[stampKey] as? Int, lastApplied: lastApplied) else { return .none }
        let type = info[typeKey] as? String
        if type == credentialsType { return SyncSettingsWire.decode(info) != nil ? .store : .none }
        if type == settingsType { return CredentialsStore.isClearRequest(info) ? .clear : .none }
        return .none
    }

    static let settingsStampKey = "settings.appliedStamp"
    static let libraryType = "library"
    static let hashesKey = "hashes"
    static let dictionaryType = "dictionary"
    static let deleteDictionaryType = "delete_dictionary"
    static let dictionaryIdKey = "dictionaryId"
    static let dictionariesKey = "dictionaries"
    /// Watch -> phone: estimated seconds left per book (`ReadingTimeRemaining.bookSeconds`), keyed by hash.
    static let timeRemainingKey = "timeRemaining"
    /// Watch -> phone: whole percent read per book that has been opened.
    static let progressKey = "progress"
    static let coverKey = "cover"
    /// Watch -> phone: books the user deleted here, so the phone does not send them back automatically.
    static let removedKey = "removed"
    /// Watch -> phone: this watch app installation's id (a new one after a reinstall, reset or re-pair), so the
    /// phone sends books deleted on a previous watch to this one again.
    static let watchIDKey = "watchID"
    static let bookRemovedType = "book_removed"
    static let watchIDDefaultsKey = "connectivity.watchID"
    static let removedDefaultsKey = "connectivity.userRemovedBooks"
    /// At most this many deletions are remembered (the phone keeps its own mark anyway).
    static let maxRemembered = 500

    /// This installation's id, created on first use and kept in `UserDefaults` (gone with the app).
    static func watchID(in defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: watchIDDefaultsKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: watchIDDefaultsKey)
        return id
    }

    /// `book_removed` message for the phone.
    static func bookRemovedMessage(hash: String, watchID: String) -> [String: Any] {
        [typeKey: bookRemovedType, documentHashKey: hash, watchIDKey: watchID]
    }

    /// Hashes the user deleted here, newest last, without the books stored again since (sent anew from the
    /// phone), at most `maxRemembered`.
    static func userRemoved(_ list: [String], adding hash: String? = nil, stored: Set<String>) -> [String] {
        var result = list.filter { !stored.contains($0) && $0 != hash }
        if let hash { result.append(hash) }
        return Array(result.suffix(maxRemembered))
    }
    static let bookCoverType = "book_cover"

    /// The cover thumbnail in a book transfer's metadata or a `book_cover` message, if any.
    static func cover(from info: [String: Any]?) -> Data? {
        guard let data = info?[coverKey] as? Data, !data.isEmpty, data.count <= BookStorage.maxCoverBytes else { return nil }
        return data
    }

    /// `(hash, cover)` of a `book_cover` message, nil for any other message.
    static func bookCover(from info: [String: Any]) -> (hash: String, cover: Data)? {
        guard (info[typeKey] as? String) == bookCoverType, let hash = info[documentHashKey] as? String, !hash.isEmpty,
              let cover = cover(from: info) else { return nil }
        return (hash, cover)
    }
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

    /// Sync settings are applied only when strictly newer than what was applied; a message without a stamp
    /// is ignored.
    static func shouldApplySettings(incomingStamp: Int?, lastApplied: Int) -> Bool {
        guard let incomingStamp else { return false }
        return incomingStamp > lastApplied
    }

    /// Context published to the phone: the hashes of the books stored on the watch.
    /// The watch's typography rides along so the phone can mirror it (last writer wins by stamp).
    /// `timeRemaining` (seconds left per book) is sent only for books in `hashes`, rounded to whole minutes
    /// so an unchanged estimate does not produce a new context.
    /// `settingsStamp` is the stamp of the sync settings last applied (0 = none): the phone sends its
    /// credentials until this matches, which is also how a reinstalled watch app gets them again.
    static func libraryContext(hashes: [String], dictionaries: [String] = [],
                               settingsStamp: Int = 0,
                               removed: [String] = [],
                               watchID: String? = nil,
                               typography: ReaderTypography? = nil,
                               timeRemaining: [String: ReadingTimeRemaining] = [:],
                               progress: [String: Double] = [:]) -> [String: Any] {
        var context: [String: Any] = [typeKey: libraryType, hashesKey: hashes.sorted(),
                                      dictionariesKey: dictionaries.sorted(), stampKey: settingsStamp,
                                      removedKey: removed.sorted()]
        if let watchID { context[watchIDKey] = watchID }
        var times: [String: Double] = [:]
        for hash in hashes {
            if let t = timeRemaining[hash] { times[hash] = Double(ReadingTimeEstimator.displayMinutes(t.bookSeconds) * 60) }
        }
        if !times.isEmpty { context[timeRemainingKey] = times }
        var percents: [String: Int] = [:]
        for hash in hashes {
            if let p = progress[hash], p.isFinite, p > 0 { percents[hash] = min(100, max(0, Int((p * 100).rounded()))) }
        }
        if !percents.isEmpty { context[progressKey] = percents }
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
            let defaults = UserDefaults.standard
            let stamp = defaults.integer(forKey: Self.settingsStampKey)
            let removed = Self.userRemoved(defaults.stringArray(forKey: Self.removedDefaultsKey) ?? [], stored: Set(hashes))
            defaults.set(removed, forKey: Self.removedDefaultsKey)
            try? session.updateApplicationContext(Self.libraryContext(hashes: hashes, dictionaries: dictionaryIds,
                                                                      settingsStamp: stamp,
                                                                      removed: removed,
                                                                      watchID: Self.watchID(in: defaults),
                                                                      typography: typography(),
                                                                      timeRemaining: library.positions.readingTimes.all(),
                                                                      progress: library.progress))
        }
    }

    /// The user deleted a book here: remembered in the library report (latest state, so the phone learns it even
    /// if the message is lost) and told to the phone right away, with `sendMessage` when it is reachable (the
    /// iPhone Library updates at once) and `transferUserInfo` (queued, guaranteed) otherwise or on failure.
    /// Call before `publishLibrary`.
    func reportUserRemoval(of hash: String) {
        let defaults = UserDefaults.standard
        // Books stored again are dropped from the list by `publishLibrary`.
        defaults.set(Self.userRemoved(defaults.stringArray(forKey: Self.removedDefaultsKey) ?? [], adding: hash, stored: []),
                     forKey: Self.removedDefaultsKey)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return } // the library report carries it later
        let message = Self.bookRemovedMessage(hash: hash, watchID: Self.watchID(in: defaults))
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
        } else {
            session.transferUserInfo(message)
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
        let cover = Self.cover(from: file.metadata)
        Task { @MainActor in await library.importReceivedFile(at: copy, cover: cover) }
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
        let defaults = UserDefaults.standard
        switch Self.syncSettingsAction(for: info, lastApplied: defaults.integer(forKey: Self.settingsStampKey)) {
        case .store: changed = CredentialsStore.apply(credentialsMessage: info)
        case .clear: CredentialsStore.clear(); changed = true
        case .none: break
        }
        if changed {
            defaults.set(info[Self.stampKey] as? Int ?? 0, forKey: Self.settingsStampKey)
            publishLibrary() // reports the applied stamp, so the phone stops sending the credentials
        }
        let deleteHash = Self.deleteHash(from: info)
        let bookCover = Self.bookCover(from: info)
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
            if let bookCover { library.setCover(bookCover.cover, documentHash: bookCover.hash) }
        }
    }
}
