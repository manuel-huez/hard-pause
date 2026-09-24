import Foundation

struct PauseCoreClockReading: Codable, Equatable, Sendable {
    let elapsedSinceBoot: TimeInterval
    let bootIdentifier: String?
}

struct PauseCoreClockCheckpoint: Codable, Equatable, Sendable {
    let logicalTime: TimeInterval
    let elapsedSinceBoot: TimeInterval?
    let bootIdentifier: String?
}

struct PauseCoreClockProjection: Codable, Equatable, Sendable {
    let logicalTime: TimeInterval
    let verifiedElapsed: TimeInterval
    let isSameBoot: Bool
}

enum PauseCoreClock {
    private struct Arguments: Encodable {
        let checkpoint: PauseCoreClockCheckpoint
        let reading: PauseCoreClockReading
    }

    static func project(
        checkpoint: PauseCoreClockCheckpoint,
        reading: PauseCoreClockReading
    ) -> PauseCoreClockProjection {
        (try? RustCoreBridge.call(
            "clock.project",
            Arguments(checkpoint: checkpoint, reading: reading)
        ))
            ?? PauseCoreClockProjection(
                logicalTime: checkpoint.logicalTime,
                verifiedElapsed: 0,
                isSameBoot: false
            )
    }
}
