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

    struct WatchSettings: Equatable {
        var server: String
        var user: String
        var password: String
        var stamp: Int
    }

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    var statusText: String {
        guard WCSession.isSupported() else { return "Not supported" }
        if activationState != .activated { return "Activating…" }
        if !isPaired { return "No watch paired" }
        if !isWatchAppInstalled { return "Watch app not installed" }
        return isReachable ? "Watch reachable" : "Watch not reachable (transfers are queued)"
    }

    // MARK: Sending

    /// True when the session is active and the watch app can receive data.
    private var canSend: Bool {
        guard let session else { return false }
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    func send(book entry: LibraryEntry, fileURL: URL, formatVersion: Int) {
        guard let session, session.activationState == .activated else {
            lastError = "Watch session is not active."; return
        }
        // Not installed yet: the book stays unsent and `syncWatchState()` sends it once the watch app appears.
        guard canSend else { return }
        guard !outstandingHashes.contains(entry.documentHash) else { return }
        session.transferFile(fileURL, metadata: WatchSchema.bookMetadata(for: entry, formatVersion: formatVersion))
        outstandingHashes.insert(entry.documentHash)
    }

    func cancelTransfers() {
        session?.outstandingFileTransfers.forEach { $0.cancel() }
        refreshOutstanding()
    }

    /// Mirrors the settings with `updateApplicationContext`: latest-state semantics, so only the newest
    /// settings are delivered (also to a watch app installed later), unlike a queue of userInfo transfers.
    func sendSettings(_ settings: WatchSettings?, typography: ReaderTypography?) {
        guard canSend, let session else { return }
        let kosync = settings.map { (server: $0.server, user: $0.user, password: $0.password, stamp: $0.stamp) }
        let cleared = settings == nil ? clearedStampProvider?() : nil
        guard let info = WatchSchema.settingsContext(kosync: kosync, clearedStamp: cleared, typography: typography) else { return }
        do { try session.updateApplicationContext(info) }
        catch { lastError = "Could not send settings: \(error.localizedDescription)" }
    }

    /// Brings the watch up to date: current settings and every book it has not confirmed. Idempotent;
    /// called on activation, watch state / reachability changes, app foreground and watch library reports.
    func syncWatchState() {
        guard canSend else { return }
        sendSettings(settingsProvider?(), typography: typographyProvider?())
        for (entry, url) in unsentBooksProvider?() ?? [] {
            send(book: entry, fileURL: url, formatVersion: ProcessedBook.currentFormatVersion)
        }
    }

    func sendDelete(hash: String) {
        guard let session, session.activationState == .activated else { return }
        session.transferUserInfo(WatchSchema.deleteBook(hash: hash))
    }

    private func refreshOutstanding() {
        let hashes = session?.outstandingFileTransfers.compactMap {
            $0.file.metadata?[WatchSchema.Key.documentHash] as? String
        } ?? []
        outstandingHashes = Set(hashes)
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
        let typography = TypographySync.decode(from: applicationContext)
        guard hashes != nil || typography != nil else { return }
        DispatchQueue.main.async {
            if let typography { self.onWatchTypography?(typography) }
            if let hashes { self.onWatchLibrary?(hashes) }
            self.syncWatchState()
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let hash = fileTransfer.file.metadata?[WatchSchema.Key.documentHash] as? String
        DispatchQueue.main.async {
            if let hash { self.outstandingHashes.remove(hash) }
            if let error {
                self.lastError = "Transfer failed: \(error.localizedDescription)"
            } else if let hash {
                self.onTransferFinished?(hash)
            }
        }
    }
}
