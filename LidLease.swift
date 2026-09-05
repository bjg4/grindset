import Foundation

/// Shared by the app and its short-lived privileged guard.
enum LidLeasePolicy {
    static let batteryFloor = 10
    static func stopReason(parentAlive: Bool, connected: Bool, stopRequested: Bool,
                           now: TimeInterval, deadline: TimeInterval?,
                           onBattery: Bool, percent: Int?) -> String? {
        if !parentAlive || !connected { return "app-exited" }
        if stopRequested { return "stopped" }
        if let deadline, now >= deadline { return "expired" }
        if onBattery, let percent, percent <= batteryFloor { return "battery-low" }
        return nil
    }
}
