import Foundation

/// Stable per-install identity sent to the sync server so devices can tell each other apart.
struct DeviceIdentity {
    static let deviceName = "WristReader"
    private static let key = "sync.deviceID"

    let id: String
    var name: String { Self.deviceName }

    init(defaults: UserDefaults = .standard) {
        if let existing = defaults.string(forKey: Self.key), !existing.isEmpty {
            id = existing
        } else {
            let new = UUID().uuidString
            defaults.set(new, forKey: Self.key)
            id = new
        }
    }
}
