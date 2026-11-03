import Foundation

/// Open-book decision for any connector.
public enum ProgressDecision: Equatable, Sendable {
    case keepLocal
    case offerRemote(ReadingPosition)
}

public extension SyncConflictPolicy {
    /// Connector-neutral form of `decide(localPercentage:remote:ownDeviceID:)`: the same rule (offer the
    /// remote position when another device is ahead), applied to a `ReadingPosition`. A remote position
    /// without a device id (Readest stores none) counts as another device.
    func decide(localPercentage: Double, remote: ReadingPosition?, ownDeviceID: String) -> ProgressDecision {
        guard let remote else { return .keepLocal }
        let k = KOSyncProgress(document: "", progress: remote.xpointer, percentage: remote.percentage,
                               device: remote.deviceName, device_id: remote.deviceID)
        switch decide(localPercentage: localPercentage, remote: k, ownDeviceID: ownDeviceID) {
        case .keepLocal: return .keepLocal
        case .offerRemote: return .offerRemote(remote)
        }
    }
}
