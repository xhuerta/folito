import Foundation
import WatchConnectivity

/// Receives books (transferFile), settings (transferUserInfo) and delete requests from the iPhone.
/// Wire names (see docs/WATCH_CONNECTIVITY.md on the iOS branch):
///  - file metadata keys: documentHash, title, author, size; payload = LZFSE-compressed ProcessedBook JSON
///  - userInfo keys: kosync_server, kosync_user, kosync_password
///  - `delete_book` (userInfo or message): value = documentHash
/// WCSessionDelegate callbacks arrive on a background queue; all heavy work is hopped off the main actor.
final class ConnectivityReceiver: NSObject, WCSessionDelegate {
    static let deleteKey = "delete_book"

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
        let deleteHash = info[Self.deleteKey] as? String
        let library = self.library
        let notify = onSettingsChanged
        Task { @MainActor in
            if changed { notify() }
            if let hash = deleteHash { library.delete(documentHash: hash) }
        }
    }
}
