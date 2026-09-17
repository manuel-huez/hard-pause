import Foundation

/// A platform-supplied sleep-inclusive elapsed clock reading.
struct PauseCoreClockReading: Equatable, Sendable {
    let elapsedSinceBoot: TimeInterval
    let bootIdentifier: String?
}

/// A saved point on a platform's logical timeline.
struct PauseCoreClockCheckpoint: Equatable, Sendable {
    let logicalTime: TimeInterval
    let elapsedSinceBoot: TimeInterval?
    let bootIdentifier: String?
}

struct PauseCoreClockProjection: Equatable, Sendable {
    let logicalTime: TimeInterval
    let verifiedElapsed: TimeInterval
    let isSameBoot: Bool
}

enum PauseCoreClock {
    /// Advances only when both readings identify the same boot and the elapsed clock did not move back.
    static func project(
        checkpoint: PauseCoreClockCheckpoint,
        reading: PauseCoreClockReading
    ) -> PauseCoreClockProjection {
        guard
            checkpoint.logicalTime.isFinite,
            let checkpointBoot = checkpoint.bootIdentifier,
            let currentBoot = reading.bootIdentifier,
            checkpointBoot == currentBoot,
            let checkpointElapsed = checkpoint.elapsedSinceBoot,
            checkpointElapsed.isFinite,
            checkpointElapsed >= 0,
            reading.elapsedSinceBoot.isFinite,
            reading.elapsedSinceBoot >= checkpointElapsed
        else {
            return PauseCoreClockProjection(
                logicalTime: checkpoint.logicalTime,
                verifiedElapsed: 0,
                isSameBoot: false
            )
        }

        let delta = reading.elapsedSinceBoot - checkpointElapsed
        let logicalTime = checkpoint.logicalTime + delta
        guard delta.isFinite, logicalTime.isFinite, logicalTime >= checkpoint.logicalTime else {
            return PauseCoreClockProjection(
                logicalTime: checkpoint.logicalTime,
                verifiedElapsed: 0,
                isSameBoot: false
            )
        }
        return PauseCoreClockProjection(
            logicalTime: logicalTime,
            verifiedElapsed: delta,
            isSameBoot: true
        )
    }
}
