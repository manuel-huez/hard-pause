import Foundation
import Testing

@testable import PauseCore

@Suite("Shared Apple lifecycle fixtures")
struct PauseCoreTests {
    @Test("JSON traces preserve shared transitions and explicit platform differences")
    func lifecycleFixtures() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "apple-lifecycle",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let traces = try JSONDecoder().decode([Trace].self, from: Data(contentsOf: url))

        for trace in traces {
            var state = PauseCoreLifecycleState(
                isActive: true,
                naturalEndAt: trace.naturalEndAt,
                pendingRequest: nil,
                breakEndsAt: nil
            )
            for command in trace.commands {
                switch command.kind {
                case "break":
                    try PauseCoreLifecycle.requestBreak(
                        &state,
                        at: command.at,
                        delay: command.delay ?? 0,
                        duration: command.duration ?? 0
                    )
                case "unlock":
                    try PauseCoreLifecycle.requestFullUnlock(
                        &state,
                        at: command.at,
                        delay: command.delay ?? 0,
                        profile: trace.profile == "macOS" ? .macOS : .iOS
                    )
                case "cancelBreak":
                    try PauseCoreLifecycle.cancelBreak(&state)
                case "reconcile":
                    PauseCoreLifecycle.reconcile(&state, at: command.at)
                default:
                    Issue.record("Unknown fixture command: \(command.kind)")
                }
                #expect(phaseName(PauseCoreLifecycle.phase(of: state, at: command.at)) == command.phase)
            }
        }
    }

    @Test("A changed boot never advances the logical timeline")
    func changedBootPausesElapsedTime() {
        let changedBoot = PauseCoreClock.project(
            checkpoint: PauseCoreClockCheckpoint(
                logicalTime: 60,
                elapsedSinceBoot: 160,
                bootIdentifier: "boot-a"
            ),
            reading: PauseCoreClockReading(elapsedSinceBoot: 10_000, bootIdentifier: "boot-b")
        )
        #expect(changedBoot.logicalTime == 60)
        #expect(changedBoot.verifiedElapsed == 0)
        #expect(!changedBoot.isSameBoot)

        let resumed = PauseCoreClock.project(
            checkpoint: PauseCoreClockCheckpoint(
                logicalTime: changedBoot.logicalTime,
                elapsedSinceBoot: 10_000,
                bootIdentifier: "boot-b"
            ),
            reading: PauseCoreClockReading(elapsedSinceBoot: 10_120, bootIdentifier: "boot-b")
        )
        #expect(resumed.logicalTime == 180)
        #expect(resumed.isSameBoot)
    }

    @Test("Invalid elapsed readings cannot fast-forward a commitment")
    func invalidElapsedReadingsAreRejected() {
        let checkpoint = PauseCoreClockCheckpoint(
            logicalTime: 60,
            elapsedSinceBoot: 160,
            bootIdentifier: "boot-a"
        )
        for elapsed in [TimeInterval.nan, .infinity, -1] {
            let projection = PauseCoreClock.project(
                checkpoint: checkpoint,
                reading: PauseCoreClockReading(
                    elapsedSinceBoot: elapsed,
                    bootIdentifier: "boot-a"
                )
            )
            #expect(projection.logicalTime == 60)
            #expect(!projection.isSameBoot)
        }
    }

    @Test("Transaction stages keep tightening before commit and relaxation after commit")
    func transactionOrder() {
        let activation = PauseCoreTransactionPlan(
            requiresSchedulePrerequisite: true,
            hasTightening: true,
            intentFailurePolicy: .stop,
            savesCandidate: true,
            hasRelaxation: true
        )
        #expect(
            activation.orderedStages == [
                .prepareSchedulePrerequisite,
                .saveIntent(.stop),
                .applyTightening,
                .saveCandidate,
                .clearIntent,
                .applyRelaxation,
            ]
        )

        let emergencyRelock = PauseCoreTransactionPlan(
            requiresSchedulePrerequisite: false,
            hasTightening: true,
            intentFailurePolicy: .continueForSafety,
            savesCandidate: true,
            hasRelaxation: false
        )
        #expect(emergencyRelock.orderedStages.contains(.saveIntent(.continueForSafety)))
        #expect(emergencyRelock.orderedStages.contains(.applyTightening))
    }

    private func phaseName(_ phase: PauseCoreLifecyclePhase) -> String {
        switch phase {
        case .inactive: "inactive"
        case .active: "active"
        case .waitingForBreak: "waitingForBreak"
        case .waitingForFullUnlock: "waitingForFullUnlock"
        case .breakActive: "breakActive"
        }
    }
}

private struct Trace: Decodable {
    let profile: String
    let naturalEndAt: TimeInterval?
    let commands: [Command]
}

private struct Command: Decodable {
    let kind: String
    let at: TimeInterval
    let delay: TimeInterval?
    let duration: TimeInterval?
    let phase: String
}
