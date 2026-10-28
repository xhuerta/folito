import Foundation
import WatchConnectivity

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

    func send(book entry: LibraryEntry, fileURL: URL, formatVersion: Int) {
        guard let session, session.activationState == .activated else {
            lastError = "Watch session is not active."; return
        }
        guard !outstandingHashes.contains(entry.documentHash) else { return }
        session.transferFile(fileURL, metadata: WatchSchema.bookMetadata(for: entry, formatVersion: formatVersion))
        outstandingHashes.insert(entry.documentHash)
    }

    func cancelTransfers() {
        session?.outstandingFileTransfers.forEach { $0.cancel() }
        refreshOutstanding()
    }

    func sendSettings(server: String, user: String, password: String) {
        guard let session, session.activationState == .activated else { return }
        // transferUserInfo is queued and delivered in order, even if the watch app is not running.
        session.transferUserInfo(WatchSchema.settingsInfo(server: server, user: user, password: password))
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
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.refreshFlags(session) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.refreshFlags(session) }
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
