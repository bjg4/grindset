import Foundation

@main
enum LeaseTests {
    static func main() {
        func reason(alive: Bool = true, connected: Bool = true, stop: Bool = false,
                    now: Double = 100, deadline: Double? = nil, battery: Bool = false, percent: Int? = nil) -> String? {
            LidLeasePolicy.stopReason(parentAlive: alive, connected: connected, stopRequested: stop,
                now: now, deadline: deadline, onBattery: battery, percent: percent)
        }
        precondition(reason() == nil)
        precondition(reason(alive: false) == "app-exited")
        precondition(reason(connected: false) == "app-exited")
        precondition(reason(stop: true) == "stopped")
        precondition(reason(deadline: 100) == "expired")
        precondition(reason(deadline: 101) == nil)
        precondition(reason(battery: true, percent: 10) == "battery-low")
        precondition(reason(battery: true, percent: 11) == nil)
        precondition(reason(battery: false, percent: 5) == nil)
        precondition(reason(battery: true, percent: nil) == nil)
        print("10 lid-lease policy checks passed")
    }
}
