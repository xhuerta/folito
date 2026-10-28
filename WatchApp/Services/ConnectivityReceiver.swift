import Foundation
import WatchConnectivity

/// Receives books (transferFile), settings (transferUserInfo) and delete requests from the iPhone.
/// Wire names (see docs/WATCH_CONNECTIVITY.md on the iOS branch):
///  - file metadata keys: documentHash, title, author, size; payload = LZFSE-compressed ProcessedBook JSON
///  - userInfo keys: kosync_server, kosync_user, kosync_password
///  - delete: `{ type: "delete_book", documentHash: <hash> }` (userInfo or message)
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

    private let library: BookLibrary
    private let onSettingsChanged: @MainActor () -> Void

    init(library: BookLibrary, onSettingsChanged: @escaping @MainActor () -> Void) {
        self.library = library
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
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
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

    // MARK: Handling

    private func handle(_ info: [String: Any]) {
        let changed = CredentialsStore.apply(userInfo: info)
        let deleteHash = Self.deleteHash(from: info)
        let library = self.library
        let notify = onSettingsChanged
        Task { @MainActor in
            if changed { notify() }
            if let hash = deleteHash { library.delete(documentHash: hash) }
        }
    }
}
