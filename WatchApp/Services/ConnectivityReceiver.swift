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
///  - watch -> phone (applicationContext): `{ type: "library", hashes: [<documentHash>], typography?, typographyStamp? }`
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

    /// The phone resends its settings (same stamp) on every activation / state change; apply them only
    /// when newer than what was applied, so a Reset on the watch is not undone by a stale resend.
    /// Messages without a stamp (older phone builds) are always applied.
    static func shouldApplySettings(incomingStamp: Int?, lastApplied: Int) -> Bool {
        guard let incomingStamp else { return true }
        return incomingStamp > lastApplied
    }

    /// Context published to the phone: the hashes of the books stored on the watch.
    /// The watch's typography rides along so the phone can mirror it (last writer wins by stamp).
    static func libraryContext(hashes: [String], typography: ReaderTypography? = nil) -> [String: Any] {
        var context: [String: Any] = [typeKey: libraryType, hashesKey: hashes.sorted()]
        if let typography { context.merge(TypographySync.context(for: typography)) { _, new in new } }
        return context
    }

    private let library: BookLibrary
    private let typography: @MainActor () -> ReaderTypography
    private let onTypography: @MainActor (ReaderTypography) -> Void
    private let onSettingsChanged: @MainActor () -> Void

    init(library: BookLibrary,
         typography: @escaping @MainActor () -> ReaderTypography,
         onTypography: @escaping @MainActor (ReaderTypography) -> Void,
         onSettingsChanged: @escaping @MainActor () -> Void) {
        self.library = library
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

    /// Tells the phone which books are on the watch so it can (re)send the missing ones.
    func publishLibrary() {
        let library = self.library
        let typography = self.typography
        Task { @MainActor in
            let session = WCSession.default
            guard WCSession.isSupported(), session.activationState == .activated else { return }
            let hashes = library.entries.map(\.documentHash)
            try? session.updateApplicationContext(Self.libraryContext(hashes: hashes, typography: typography()))
        }
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
