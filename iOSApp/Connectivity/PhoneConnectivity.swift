import Foundation
import WatchConnectivity
import ReaderCore

/// WCSession wrapper for the phone side.
final class PhoneConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var activationState: WCSessionActivationState = .notActivated
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false
    /// documentHash of book transfers still in flight.
    @Published private(set) var outstandingHashes: Set<String> = []
    /// Last connectivity error, for debugging only (never shown in the UI, so it is not localized).
    @Published private(set) var lastError: String?

    /// Called on the main queue when a book transfer finishes successfully.
    var onTransferFinished: ((String) -> Void)?
    /// Saved sync settings to mirror on the watch (nil when not configured). Read on the main queue.
    var settingsProvider: (() -> WatchSettings?)?
    /// Stamp of the "sync turned off" action while no credentials are saved (nil = never turned off).
    var clearedStampProvider: (() -> Int?)?
    /// Typography to mirror on the watch (stamp 0 = never changed, nothing is sent). Read on the main queue.
    var typographyProvider: (() -> ReaderTypography)?
    /// The watch published a typography copy (applied by the owner only if its stamp is newer).
    var onWatchTypography: ((ReaderTypography) -> Void)?
    /// Books not yet confirmed on the watch, with their payload files. Read on the main queue.
    var unsentBooksProvider: (() -> [(entry: LibraryEntry, fileURL: URL)])?
    /// The watch reported the hashes of the books it currently stores.
    var onWatchLibrary: ((Set<String>) -> Void)?
    /// Dictionaries installed on the phone that should be on the watch: id, file, SHA-256, size.
    var dictionariesProvider: (() -> [(id: String, fileURL: URL, sha256: String, size: Int64)])?
    /// Ids of the dictionaries the watch reported (nil until it has reported).
    @Published private(set) var watchDictionaries: Set<String>?
    /// Reading time left per book hash, as estimated by the watch (empty until it reports any).
    @Published private(set) var watchTimeRemaining: [String: TimeInterval] = [:]
    /// Fraction read per book, as the watch reports it (books opened there only).
    @Published private(set) var watchProgress: [String: Double] = [:]
    /// The watch thumbnail of a book's cover, sent with the book (set by the app).
    var coverProvider: ((LibraryEntry) -> Data?)?
    /// Ids of dictionary transfers in flight.
    @Published private(set) var outstandingDictionaries: Set<String> = []
    /// When each dictionary transfer was last delivered: the watch installs it and only then lists it, so a
    /// delivered file is not resent while that happens.
    private var deliveredDictionaries: [String: Date] = [:]
    static let installGracePeriod: TimeInterval = 10 * 60

    /// Stamp of the sync settings the watch reported as applied (nil until it has reported).
    private var watchSettingsStamp: Int?
    /// Stamp and time of the last credentials message delivered: the watch applies it and only then reports
    /// its stamp, so a delivered message is not resent while that happens.
    private var deliveredCredentials: (stamp: Int, at: Date)?
    static let credentialsGracePeriod: TimeInterval = 60

    /// Active sync connector and the credentials the watch needs (the connector's `watchCredentials(from:)`).
    struct WatchSettings: Equatable {
        var connectorID: String
        var credentials: SyncCredentials
        var stamp: Int
    }

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// What the Library screen shows about the watch (see `WatchStatus`).
    var status: WatchStatus {
        WatchStatus(supported: WCSession.isSupported(), activation: activationState, paired: isPaired,
                    appInstalled: isWatchAppInstalled, reachable: isReachable)
    }

    // MARK: Sending

    /// True when the session is active and the watch app can receive data.
    private var canSend: Bool {
        guard let session else { return false }
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    func send(book entry: LibraryEntry, fileURL: URL, formatVersion: Int) {
        guard let session, session.activationState == .activated else {
            lastError = "Watch session is not active."; return // i18n-ignore: diagnostics, not shown in the UI
        }
        // Not installed yet: the book stays unsent and `syncWatchState()` sends it once the watch app appears.
        guard canSend else { return }
        guard !outstandingHashes.contains(entry.documentHash) else { return }
        session.transferFile(fileURL, metadata: WatchSchema.bookMetadata(for: entry, formatVersion: formatVersion,
                                                                        cover: coverProvider?(entry)))
        outstandingHashes.insert(entry.documentHash)
    }

    /// Sends the cover of a book the watch already has (it gained one after it was sent).
    func send(cover: Data, hash: String) {
        guard let session, canSend else { return }
        session.transferUserInfo(WatchSchema.bookCover(hash: hash, cover: cover))
    }

    /// Sends a compact dictionary file. A transfer of the same id still in flight is cancelled first
    /// (an update replaces it).
    func send(dictionary id: String, fileURL: URL, sha256: String, size: Int64) {
        guard canSend, let session else { return }
        for transfer in session.outstandingFileTransfers
        where (transfer.file.metadata?[WatchSchema.Key.dictionaryId] as? String) == id {
            transfer.cancel()
        }
        session.transferFile(fileURL, metadata: WatchSchema.dictionaryMetadata(id: id, sha256: sha256, size: size))
        outstandingDictionaries.insert(id)
    }

    func sendDeleteDictionary(id: String) {
        guard let session, session.activationState == .activated else { return }
        for transfer in session.outstandingFileTransfers
        where (transfer.file.metadata?[WatchSchema.Key.dictionaryId] as? String) == id {
            transfer.cancel()
        }
        session.transferUserInfo(WatchSchema.deleteDictionary(id: id))
        watchDictionaries?.remove(id)
        refreshOutstanding()
    }

    /// Sends the installed dictionaries the watch has not reported, once it has reported its list.
    private func syncDictionaries() {
        guard let onWatch = watchDictionaries else { return }
        let now = Date()
        for d in dictionariesProvider?() ?? [] where !onWatch.contains(d.id) && !outstandingDictionaries.contains(d.id) {
            if let delivered = deliveredDictionaries[d.id], now.timeIntervalSince(delivered) < Self.installGracePeriod { continue }
            send(dictionary: d.id, fileURL: d.fileURL, sha256: d.sha256, size: d.size)
        }
    }

    func cancelTransfers() {
        session?.outstandingFileTransfers.forEach { $0.cancel() }
        refreshOutstanding()
    }

    /// Mirrors the non-secret settings (typography, "sync turned off") with `updateApplicationContext`:
    /// latest-state semantics, so only the newest settings are delivered (also to a watch app installed later).
    /// Credentials never go into the context, which the system keeps on disk on both devices outside the
    /// Keychain: see `sendCredentials`.
    func sendSettings(_ settings: WatchSettings?, typography: ReaderTypography?) {
        guard canSend, let session else { return }
        let cleared = settings == nil ? clearedStampProvider?() : nil
        do { try session.updateApplicationContext(WatchSchema.settingsContext(clearedStamp: cleared, typography: typography)) }
        catch { lastError = "Could not send settings: \(error.localizedDescription)" } // i18n-ignore
        sendCredentials(settings)
    }

    /// Sends the credentials with `transferUserInfo` until the watch reports their stamp in its `library`
    /// context. The system queues the message while the watch is unreachable and drops it from the queue once
    /// delivered; a reinstalled watch app reports stamp 0, so it gets the credentials again. At most one
    /// credentials message is queued: older ones (and all of them once sync is off) are cancelled.
    private func sendCredentials(_ settings: WatchSettings?) {
        guard canSend, let session else { return }
        let queued = session.outstandingUserInfoTransfers.filter { WatchSchema.credentialsStamp(from: $0.userInfo) != nil }
        guard let settings,
              WatchSchema.needsCredentials(watchStamp: watchSettingsStamp, phoneStamp: settings.stamp) else {
            queued.forEach { $0.cancel() }
            return
        }
        var alreadyQueued = false
        for transfer in queued {
            if WatchSchema.credentialsStamp(from: transfer.userInfo) == settings.stamp { alreadyQueued = true }
            else { transfer.cancel() }
        }
        if alreadyQueued { return }
        if let delivered = deliveredCredentials, delivered.stamp == settings.stamp,
           Date().timeIntervalSince(delivered.at) < Self.credentialsGracePeriod { return }
        session.transferUserInfo(WatchSchema.credentialsMessage(connectorID: settings.connectorID,
                                                                credentials: settings.credentials,
                                                                stamp: settings.stamp))
    }

    /// Brings the watch up to date: current settings and every book it has not confirmed. Idempotent;
    /// called on activation, watch state / reachability changes, app foreground and watch library reports.
    func syncWatchState() {
        guard canSend else { return }
        sendSettings(settingsProvider?(), typography: typographyProvider?())
        for (entry, url) in unsentBooksProvider?() ?? [] {
            send(book: entry, fileURL: url, formatVersion: ProcessedBook.currentFormatVersion)
        }
        syncDictionaries()
    }

    func sendDelete(hash: String) {
        guard let session, session.activationState == .activated else { return }
        session.transferUserInfo(WatchSchema.deleteBook(hash: hash))
    }

    private func refreshOutstanding() {
        let transfers = session?.outstandingFileTransfers ?? []
        outstandingHashes = Set(transfers.compactMap { $0.file.metadata?[WatchSchema.Key.documentHash] as? String })
        outstandingDictionaries = Set(transfers.compactMap { $0.file.metadata?[WatchSchema.Key.dictionaryId] as? String })
    }

    private func refreshFlags(_ s: WCSession) {
        activationState = s.activationState
        isPaired = s.isPaired
        isWatchAppInstalled = s.isWatchAppInstalled
        isReachable = s.isReachable
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.refreshFlags(session)
            self.refreshOutstanding()
            if let error { self.lastError = error.localizedDescription }
            if state == .activated {
                // The watch may already have published its library while we were not running.
                if let hashes = WatchSchema.libraryHashes(from: session.receivedApplicationContext) {
                    self.onWatchLibrary?(hashes)
                }
                self.watchDictionaries = WatchSchema.libraryDictionaries(from: session.receivedApplicationContext)
                self.watchSettingsStamp = WatchSchema.librarySettingsStamp(from: session.receivedApplicationContext)
                if let times = WatchSchema.libraryTimeRemaining(from: session.receivedApplicationContext) {
                    self.watchTimeRemaining = times
                }
                if let progress = WatchSchema.libraryProgress(from: session.receivedApplicationContext) {
                    self.watchProgress = progress
                }
                if let typography = TypographySync.decode(from: session.receivedApplicationContext) {
                    self.onWatchTypography?(typography)
                }
                self.syncWatchState()
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.refreshFlags(session)
            self.syncWatchState() // e.g. isWatchAppInstalled just became true
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.refreshFlags(session)
            if session.isReachable { self.syncWatchState() }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let hashes = WatchSchema.libraryHashes(from: applicationContext)
        let dictionaries = WatchSchema.libraryDictionaries(from: applicationContext)
        let typography = TypographySync.decode(from: applicationContext)
        let times = WatchSchema.libraryTimeRemaining(from: applicationContext)
        let progress = WatchSchema.libraryProgress(from: applicationContext)
        let settingsStamp = WatchSchema.librarySettingsStamp(from: applicationContext)
        guard hashes != nil || typography != nil || dictionaries != nil else { return }
        DispatchQueue.main.async {
            if let typography { self.onWatchTypography?(typography) }
            if let times { self.watchTimeRemaining = times }
            if let progress { self.watchProgress = progress }
            if let hashes { self.onWatchLibrary?(hashes) }
            if let dictionaries { self.watchDictionaries = dictionaries }
            if let settingsStamp { self.watchSettingsStamp = settingsStamp }
            self.syncWatchState()
        }
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard error == nil, let stamp = WatchSchema.credentialsStamp(from: userInfoTransfer.userInfo) else { return }
        DispatchQueue.main.async { self.deliveredCredentials = (stamp, Date()) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let hash = fileTransfer.file.metadata?[WatchSchema.Key.documentHash] as? String
        let dictionaryId = fileTransfer.file.metadata?[WatchSchema.Key.dictionaryId] as? String
        DispatchQueue.main.async {
            if let hash { self.outstandingHashes.remove(hash) }
            if let dictionaryId {
                // Delivered is not installed: the watch confirms by listing it in its library context.
                self.outstandingDictionaries.remove(dictionaryId)
                if error == nil { self.deliveredDictionaries[dictionaryId] = Date() }
                if let error { self.lastError = "Dictionary transfer failed: \(error.localizedDescription)" } // i18n-ignore
                return
            }
            if let error {
                self.lastError = "Transfer failed: \(error.localizedDescription)" // i18n-ignore
            } else if let hash {
                self.onTransferFinished?(hash)
            }
        }
    }
}
