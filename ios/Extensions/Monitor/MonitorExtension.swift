import DeviceActivity
import Foundation
import OSLog

final class MonitorExtension: DeviceActivityMonitor {
    private let logger = Logger(subsystem: "com.hardpause.app", category: "MonitorExtension")

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        reconcileStoredState()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        reconcileStoredState()
    }

    override func intervalWillStartWarning(for activity: DeviceActivityName) {
        super.intervalWillStartWarning(for: activity)
        reconcileStoredState()
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
        reconcileStoredState(endWarningFor: HardPauseConstants.blockID(for: activity))
    }

    private func reconcileStoredState(endWarningFor blockID: UUID? = nil) {
        // The stored phase is authoritative, so delayed callbacks cannot advance a newer lock.
        let runtime = LocalLockRuntime()
        do {
            _ = try runtime.reconcile(endWarningFor: blockID)
        } catch {
            logger.fault(
                "Could not reconcile or recover the stored lock: \(error.localizedDescription, privacy: .public)")
        }
    }
}
