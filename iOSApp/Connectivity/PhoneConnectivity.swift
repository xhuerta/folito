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
    /// Progress of each book transfer in flight, by documentHash (see `WatchTransferTracker`). Read from
    /// `WCSessionFileTransfer.progress` at most `progressInterval` apart, and published only when what a row
    /// shows changes. A book may be in `outstandingHashes` a moment before its first entry appears here.
    @Published private(set) var bookTransfers: [String: WatchTransferProgress] = [:]
    /// The same for dictionary transfers, by dictionary id.
    @Published private(set) var dictionaryTransfers: [String: WatchTransferProgress] = [:]
    /// Books whose last transfer failed (cleared when they are sent again). In memory only: after a relaunch the
    /// book is sent again by `syncWatchState()` if it is not on the watch.
    @Published private(set) var failedHashes: Set<String> = []
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
    /// Read status of the library's books, mirrored on the watch (last writer wins per book). Read on the main queue.
    var readStatusProvider: (() -> [String: ReadStatusMark])?
    /// The watch published its read status marks (merged by the owner, newer ones win).
    var onWatchReadStatus: (([String: ReadStatusMark]) -> Void)?
    /// Books not yet confirmed on the watch, with their payload files. Read on the main queue.
    var unsentBooksProvider: (() -> [(entry: LibraryEntry, fileURL: URL)])?
    /// The watch reported the books it currently stores (and those the user deleted there).
    var onWatchLibrary: ((WatchSchema.LibraryReport) -> Void)?
    /// The user deleted a book on the watch: hash and the watch app's installation id.
    var onWatchRemovedBook: ((String, String?) -> Void)?
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

    /// A file transfer whose progress is shown, with the movement seen so far.
    private struct TrackedTransfer {
        let transfer: WCSessionFileTransfer
        var tracker: WatchTransferTracker
    }
    /// Main queue only, like every other property here (delegate callbacks hop to it first).
    private var trackedBooks: [String: TrackedTransfer] = [:]
    private var trackedDictionaries: [String: TrackedTransfer] = [:]
    /// Book transfers cancelled on purpose: their `didFinish` error is not a failure.
    private var cancelledHashes: Set<String> = []
    /// Polls the tracked transfers' `progress` on the main run loop while any is in flight (4 times a second).
    /// Polling instead of KVO: `fractionCompleted` changes on a background queue for every chunk sent, and a
    /// fixed tick is both the throttle and the main-queue hop.
    private var progressTimer: Timer?
    static let progressInterval: TimeInterval = 0.25

    func activate() {
        #if DEBUG
        // App Store screenshots (`-UITestingSimulateWatch`, Debug builds only): show the Library as with a paired,
        // reachable watch that has the app. The real session is left inactive, so nothing is ever sent.
        if UITesting.simulatesWatch {
            activationState = .activated
            isPaired = true
            isWatchAppInstalled = true
            isReachable = true
            watchProgress = UITesting.simulatedWatchProgress
            // `-UITestingSimulateTransfer`: rows mid-transfer (sending and waiting), for the UI tests only.
            let transfers = UITesting.simulatedTransfers
            outstandingHashes = Set(transfers.keys)
            bookTransfers = transfers
            return
        }
        #endif
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
        let transfer = session.transferFile(fileURL, metadata: WatchSchema.bookMetadata(for: entry, formatVersion: formatVersion,
                                                                                       cover: coverProvider?(entry)))
        outstandingHashes.insert(entry.documentHash)
        failedHashes.remove(entry.documentHash)
        trackedBooks[entry.documentHash] = TrackedTransfer(transfer: transfer, tracker: WatchTransferTracker(startedAt: Date()))
        updateTransferProgress()
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
        let transfer = session.transferFile(fileURL, metadata: WatchSchema.dictionaryMetadata(id: id, sha256: sha256, size: size))
        outstandingDictionaries.insert(id)
        trackedDictionaries[id] = TrackedTransfer(transfer: transfer, tracker: WatchTransferTracker(startedAt: Date()))
        updateTransferProgress()
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
        for transfer in session?.outstandingFileTransfers ?? [] {
            if let hash = transfer.file.metadata?[WatchSchema.Key.documentHash] as? String { cancelledHashes.insert(hash) }
            transfer.cancel()
        }
        refreshOutstanding()
    }

    /// Mirrors the non-secret settings (typography, "sync turned off") with `updateApplicationContext`:
    /// latest-state semantics, so only the newest settings are delivered (also to a watch app installed later).
    /// Credentials never go into the context, which the system keeps on disk on both devices outside the
    /// Keychain: see `sendCredentials`.
    func sendSettings(_ settings: WatchSettings?, typography: ReaderTypography?) {
        guard canSend, let session else { return }
        let cleared = settings == nil ? clearedStampProvider?() : nil
        let context = WatchSchema.settingsContext(clearedStamp: cleared, typography: typography,
                                                  readStatus: readStatusProvider?() ?? [:])
        do { try session.updateApplicationContext(context) }
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
        // Transfers queued before a relaunch pick their progress up again; those no longer outstanding are dropped.
        let now = Date()
        var books: [String: TrackedTransfer] = [:]
        var dictionaries: [String: TrackedTransfer] = [:]
        for transfer in transfers {
            if let hash = transfer.file.metadata?[WatchSchema.Key.documentHash] as? String {
                books[hash] = TrackedTransfer(transfer: transfer,
                                              tracker: trackedBooks[hash]?.tracker ?? WatchTransferTracker(startedAt: now))
            } else if let id = transfer.file.metadata?[WatchSchema.Key.dictionaryId] as? String {
                dictionaries[id] = TrackedTransfer(transfer: transfer,
                                                   tracker: trackedDictionaries[id]?.tracker ?? WatchTransferTracker(startedAt: now))
            }
        }
        trackedBooks = books
        trackedDictionaries = dictionaries
        updateTransferProgress()
    }

    /// Reads every tracked transfer's `fractionCompleted`, publishes what the rows show when it changed, and runs
    /// the poll timer only while something is tracked. Main queue only.
    private func updateTransferProgress(now: Date = Date()) {
        let reachable = isReachable
        func advance(_ tracked: inout [String: TrackedTransfer]) -> [String: WatchTransferProgress] {
            var shown: [String: WatchTransferProgress] = [:]
            for key in Array(tracked.keys) {
                guard var item = tracked[key] else { continue }
                item.tracker.record(item.transfer.progress.fractionCompleted, at: now)
                tracked[key] = item
                shown[key] = item.tracker.progress(at: now, watchReachable: reachable)
            }
            return shown
        }
        let books = advance(&trackedBooks)
        let dictionaries = advance(&trackedDictionaries)
        if books != bookTransfers { bookTransfers = books }
        if dictionaries != dictionaryTransfers { dictionaryTransfers = dictionaries }

        if trackedBooks.isEmpty && trackedDictionaries.isEmpty {
            progressTimer?.invalidate()
            progressTimer = nil
        } else if progressTimer == nil {
            let timer = Timer(timeInterval: Self.progressInterval, repeats: true) { [weak self] _ in
                self?.updateTransferProgress()
            }
            timer.tolerance = Self.progressInterval / 5
            RunLoop.main.add(timer, forMode: .common)
            progressTimer = timer
        }
    }

    /// What a library row shows for `entry`: in flight, failed, on the watch, waiting or removed there.
    func bookState(for entry: LibraryEntry) -> BookWatchState {
        BookWatchState(entry, inFlight: outstandingHashes.contains(entry.documentHash),
                       failed: failedHashes.contains(entry.documentHash))
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
                if let report = WatchSchema.libraryReport(from: session.receivedApplicationContext) {
                    self.onWatchLibrary?(report)
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
                if let marks = WatchSchema.libraryReadStatus(from: session.receivedApplicationContext) {
                    self.onWatchReadStatus?(marks)
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
        let report = WatchSchema.libraryReport(from: applicationContext)
        let dictionaries = WatchSchema.libraryDictionaries(from: applicationContext)
        let typography = TypographySync.decode(from: applicationContext)
        let times = WatchSchema.libraryTimeRemaining(from: applicationContext)
        let progress = WatchSchema.libraryProgress(from: applicationContext)
        let settingsStamp = WatchSchema.librarySettingsStamp(from: applicationContext)
        let readStatus = WatchSchema.libraryReadStatus(from: applicationContext)
        guard report != nil || typography != nil || dictionaries != nil else { return }
        DispatchQueue.main.async {
            if let typography { self.onWatchTypography?(typography) }
            if let readStatus { self.onWatchReadStatus?(readStatus) }
            if let times { self.watchTimeRemaining = times }
            if let progress { self.watchProgress = progress }
            if let report { self.onWatchLibrary?(report) }
            if let dictionaries { self.watchDictionaries = dictionaries }
            if let settingsStamp { self.watchSettingsStamp = settingsStamp }
            self.syncWatchState()
        }
    }

    /// `book_removed` from the watch: sent with `sendMessage` when the phone is reachable (the Library updates at
    /// once) and with `transferUserInfo` otherwise.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleWatchMessage(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleWatchMessage(userInfo)
    }

    private func handleWatchMessage(_ info: [String: Any]) {
        guard let removed = WatchSchema.bookRemoved(from: info) else { return }
        DispatchQueue.main.async { self.onWatchRemovedBook?(removed.hash, removed.watchID) }
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard error == nil, let stamp = WatchSchema.credentialsStamp(from: userInfoTransfer.userInfo) else { return }
        DispatchQueue.main.async { self.deliveredCredentials = (stamp, Date()) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let hash = fileTransfer.file.metadata?[WatchSchema.Key.documentHash] as? String
        let dictionaryId = fileTransfer.file.metadata?[WatchSchema.Key.dictionaryId] as? String
        DispatchQueue.main.async {
            if let hash {
                self.outstandingHashes.remove(hash)
                self.trackedBooks[hash] = nil
                self.bookTransfers[hash] = nil
                let cancelled = self.cancelledHashes.remove(hash) != nil
                if error != nil && !cancelled { self.failedHashes.insert(hash) }
            }
            if let dictionaryId {
                self.trackedDictionaries[dictionaryId] = nil
                self.dictionaryTransfers[dictionaryId] = nil
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
