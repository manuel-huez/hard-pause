import XCTest

@testable import HardPause

final class LockStateMachineTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    func testHardPauseRejectsBreaksAndForcesDeviceProtection() throws {
        var state = LockState()
        var policy = LockPolicy()
        policy.protectionMode = .lockdown
        policy.preventsAppRemoval = false
        policy.requiresAutomaticDateAndTime = false
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: noon,
            elapsedTime: reading(100)
        )

        XCTAssertEqual(state.policy.protectionMode, .lockdown)
        XCTAssertTrue(state.policy.preventsAppRemoval)
        XCTAssertTrue(state.policy.requiresAutomaticDateAndTime)
        let activated = state
        XCTAssertThrowsError(
            try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))
        ) { error in
            XCTAssertEqual(error as? LockStateError, .breaksUnavailableInHardPause)
        }
        XCTAssertEqual(state, activated)
    }

    func testHardPauseRejectsFixedDuration() {
        var state = LockState()
        var policy = LockPolicy()
        policy.protectionMode = .lockdown
        policy.fixedDuration = 3_600

        XCTAssertThrowsError(
            try LockStateMachine.activate(
                &state,
                policy: policy,
                at: noon,
                elapsedTime: reading(100)
            )
        ) { error in
            XCTAssertEqual(error as? LockPolicyError, .fixedDurationUnavailableInLockdown)
        }
        XCTAssertEqual(state, LockState())
    }

    func testHardPauseFullUnlockStillUsesConfiguredDelay() throws {
        var state = LockState()
        var policy = LockPolicy()
        policy.protectionMode = .lockdown
        policy.fullUnlockDelay = 14_400
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: noon,
            elapsedTime: reading(100)
        )

        try LockStateMachine.requestEnd(&state, at: noon, elapsedTime: reading(100))
        XCTAssertEqual(state.phase, .waitingForEnd)
        XCTAssertEqual(state.nextTransitionAt, noon.addingTimeInterval(14_400))

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(14_399),
            elapsedTime: reading(14_499)
        )
        XCTAssertEqual(state.phase, .waitingForEnd)
        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(14_400),
            elapsedTime: reading(14_500)
        )
        XCTAssertEqual(state.phase, .inactive)
    }

    func testBreakWaitsThenRelocksOnOriginalSchedule() throws {
        var state = try activeState()

        try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))

        XCTAssertEqual(state.phase, .waitingForBreak)
        XCTAssertEqual(state.monitoringStartsAt, noon.addingTimeInterval(3_600))
        XCTAssertEqual(state.monitoringEndsAt, noon.addingTimeInterval(4_500))

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )
        XCTAssertEqual(state.phase, .breakActive)
        XCTAssertEqual(state.nextTransitionAt, noon.addingTimeInterval(4_500))

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(4_500),
            elapsedTime: reading(4_600)
        )
        XCTAssertEqual(state.phase, .locked)
        XCTAssertNil(state.nextTransitionAt)
    }

    func testFullUnlockUsesSameFixedDelay() throws {
        var state = try activeState()

        try LockStateMachine.requestEnd(&state, at: noon, elapsedTime: reading(100))
        XCTAssertEqual(state.phase, .waitingForEnd)
        XCTAssertEqual(state.nextTransitionAt, noon.addingTimeInterval(3_600))

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )
        XCTAssertEqual(state.phase, .inactive)
    }

    func testPendingBreakRejectsBreakAndEndRequestsWithoutChangingState() throws {
        var state = try activeState()
        try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))
        let pending = state

        XCTAssertThrowsError(
            try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))
        ) { error in
            XCTAssertEqual(error as? LockStateError, .requestAlreadyPending)
        }
        XCTAssertEqual(state, pending)

        XCTAssertThrowsError(
            try LockStateMachine.requestEnd(&state, at: noon, elapsedTime: reading(100))
        ) { error in
            XCTAssertEqual(error as? LockStateError, .requestAlreadyPending)
        }
        XCTAssertEqual(state, pending)
    }

    func testPendingBreakCanBeCancelledWithoutChangingFixedEnd() throws {
        var state = LockState()
        var policy = LockPolicy()
        policy.waitDuration = 3_600
        policy.breakDuration = 900
        policy.fixedDuration = 7_200
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: noon,
            elapsedTime: reading(100)
        )
        try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))
        let automaticEndAt = state.automaticEndAt

        try LockStateMachine.cancelBreak(
            &state,
            at: noon.addingTimeInterval(30),
            elapsedTime: reading(130)
        )

        XCTAssertEqual(state.phase, .locked)
        XCTAssertNil(state.nextTransitionAt)
        XCTAssertNil(state.breakEndsAt)
        XCTAssertEqual(state.automaticEndAt, automaticEndAt)
        XCTAssertEqual(state.lastEvaluationDate, noon.addingTimeInterval(30))
        XCTAssertEqual(state.monitoringEndsAt, automaticEndAt)
    }

    func testCancelBreakRejectsMissingOrFullUnlockRequest() throws {
        var state = try activeState()
        XCTAssertThrowsError(
            try LockStateMachine.cancelBreak(&state, at: noon, elapsedTime: reading(100))
        ) { error in
            XCTAssertEqual(error as? LockStateError, .noPendingBreakRequest)
        }

        try LockStateMachine.requestEnd(&state, at: noon, elapsedTime: reading(100))
        let pendingUnlock = state
        XCTAssertThrowsError(
            try LockStateMachine.cancelBreak(&state, at: noon, elapsedTime: reading(100))
        ) { error in
            XCTAssertEqual(error as? LockStateError, .noPendingBreakRequest)
        }
        XCTAssertEqual(state, pendingUnlock)
    }

    func testFullUnlockRequestDuringBreakRestoresBlocking() throws {
        var state = try activeState()
        try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))
        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )
        XCTAssertEqual(state.phase, .breakActive)

        try LockStateMachine.requestEnd(
            &state,
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )

        XCTAssertEqual(state.phase, .waitingForEnd)
        XCTAssertTrue(state.blocksTargets)
        XCTAssertNil(state.breakEndsAt)
    }

    func testForwardOrBackwardWallClockDoesNotSkipDelayDuringSameBoot() throws {
        var state = try activeState()
        try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(10_800),
            elapsedTime: reading(200)
        )
        XCTAssertEqual(state.phase, .waitingForBreak)
        XCTAssertEqual(state.lastEvaluationDate, noon)

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(-10_800),
            elapsedTime: reading(3_700)
        )
        XCTAssertEqual(state.phase, .breakActive)
        XCTAssertEqual(state.lastEvaluationDate, noon.addingTimeInterval(3_600))
    }

    func testRequestCheckpointDoesNotRepeatPreRequestTimeAfterReboot() throws {
        var state = try activeState()
        let requestDate = noon.addingTimeInterval(7_200)
        try LockStateMachine.requestBreak(
            &state,
            at: requestDate,
            elapsedTime: reading(7_300)
        )

        LockStateMachine.reconcile(
            &state,
            at: requestDate,
            elapsedTime: reading(50, boot: "boot-b")
        )
        LockStateMachine.reconcile(
            &state,
            at: requestDate.addingTimeInterval(3_599),
            elapsedTime: reading(3_649, boot: "boot-b")
        )
        XCTAssertEqual(state.phase, .waitingForBreak)

        LockStateMachine.reconcile(
            &state,
            at: requestDate.addingTimeInterval(3_600),
            elapsedTime: reading(3_650, boot: "boot-b")
        )
        XCTAssertEqual(state.phase, .breakActive)
    }

    func testTransitionCheckpointDoesNotExtendBreakAfterReboot() throws {
        var state = try activeState()
        try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))
        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )
        XCTAssertEqual(state.phase, .breakActive)

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(50, boot: "boot-b")
        )
        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(4_499),
            elapsedTime: reading(949, boot: "boot-b")
        )
        XCTAssertEqual(state.phase, .breakActive)

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(4_500),
            elapsedTime: reading(950, boot: "boot-b")
        )
        XCTAssertEqual(state.phase, .locked)
    }

    func testSleepInclusiveElapsedTimeCompletesDelay() throws {
        var state = try activeState()
        try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )

        XCTAssertEqual(state.phase, .breakActive)
    }

    func testDifferentBootGetsNoElapsedOrWallClockCredit() throws {
        var state = try activeState()
        try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(86_400),
            elapsedTime: reading(50_000, boot: "boot-b")
        )

        XCTAssertEqual(state.phase, .waitingForBreak)
        XCTAssertEqual(state.lastEvaluationDate, noon)
        XCTAssertEqual(state.lastSystemUptime, 50_000)
        XCTAssertEqual(state.lastBootIdentifier, "boot-b")

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(90_000),
            elapsedTime: reading(53_600, boot: "boot-b")
        )
        XCTAssertEqual(state.phase, .breakActive)
    }

    func testSameBootReconcileWithoutTransitionDoesNotMutateState() throws {
        var state = try activeState()
        try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))
        let pending = state

        XCTAssertFalse(
            LockStateMachine.reconcile(
                &state,
                at: noon.addingTimeInterval(10),
                elapsedTime: reading(110)
            )
        )
        XCTAssertEqual(state, pending)
    }

    func testSeparateFullUnlockDelayDoesNotChangeTimeoutDelay() throws {
        var state = LockState()
        var policy = LockPolicy()
        policy.waitDuration = 3_600
        policy.fullUnlockDelay = 14_400
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: noon,
            elapsedTime: reading(100)
        )

        try LockStateMachine.requestEnd(&state, at: noon, elapsedTime: reading(100))

        XCTAssertEqual(state.nextTransitionAt, noon.addingTimeInterval(14_400))
        XCTAssertEqual(state.policy.waitDuration, 3_600)
    }

    func testFixedDurationEndsWhileTimeoutRequestIsPending() throws {
        var state = LockState()
        var policy = LockPolicy()
        policy.waitDuration = 14_400
        policy.fixedDuration = 7_200
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: noon,
            elapsedTime: reading(100)
        )
        try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(7_200),
            elapsedTime: reading(7_300)
        )

        XCTAssertEqual(state.phase, .inactive)
        XCTAssertNil(state.automaticEndAt)
    }

    func testFixedDurationEndsWhileFullUnlockRequestIsPending() throws {
        var state = LockState()
        var policy = LockPolicy()
        policy.fullUnlockDelay = 14_400
        policy.fixedDuration = 7_200
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: noon,
            elapsedTime: reading(100)
        )
        try LockStateMachine.requestEnd(&state, at: noon, elapsedTime: reading(100))

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(7_200),
            elapsedTime: reading(7_300)
        )

        XCTAssertEqual(state.phase, .inactive)
    }

    func testFixedEndInsideTimeoutKeepsTheNaturalBreakWindow() throws {
        var state = LockState()
        var policy = LockPolicy()
        policy.waitDuration = 3_600
        policy.breakDuration = 900
        policy.fixedDuration = 3_900
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: noon,
            elapsedTime: reading(100)
        )
        try LockStateMachine.requestBreak(&state, at: noon, elapsedTime: reading(100))

        XCTAssertEqual(state.phase, .waitingForBreak)
        XCTAssertEqual(state.monitoringStartsAt, noon.addingTimeInterval(3_600))
        XCTAssertEqual(state.monitoringEndsAt, noon.addingTimeInterval(4_500))
    }

    func testFixedDurationGetsNoPoweredOffCredit() throws {
        var state = LockState()
        var policy = LockPolicy()
        policy.fixedDuration = 3_600
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: noon,
            elapsedTime: reading(100)
        )

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(86_400),
            elapsedTime: reading(50, boot: "boot-b")
        )
        XCTAssertEqual(state.phase, .locked)

        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(90_000),
            elapsedTime: reading(3_650, boot: "boot-b")
        )
        XCTAssertEqual(state.phase, .inactive)
    }

    func testCollectionRejectsSeventeenthActiveBlock() throws {
        let blocks = (0..<17).map { LockBlock(name: "Pause \($0)") }
        var collection = LockCollection(blocks: blocks)
        for block in blocks.prefix(16) {
            try LockCollectionStateMachine.activate(
                &collection,
                blockID: block.id,
                at: noon,
                elapsedTime: reading(100)
            )
        }

        XCTAssertThrowsError(
            try LockCollectionStateMachine.activate(
                &collection,
                blockID: blocks[16].id,
                at: noon,
                elapsedTime: reading(100)
            )
        ) { error in
            XCTAssertEqual(error as? LockCollectionError, .maximumActiveBlocks)
        }
        XCTAssertEqual(collection.activeBlocks.count, 16)
        XCTAssertEqual(
            Set(collection.activeBlocks.compactMap(\.state.storeSlot)),
            Set(0..<LockCollection.maximumActiveBlocks)
        )
    }

    func testFreedStoreSlotIsReusedWithoutRemappingOtherActiveBlocks() throws {
        let blocks = (0..<3).map { LockBlock(name: "Pause \($0)") }
        var collection = LockCollection(blocks: blocks)
        try LockCollectionStateMachine.activate(
            &collection,
            blockID: blocks[0].id,
            at: noon,
            elapsedTime: reading(100)
        )
        try LockCollectionStateMachine.activate(
            &collection,
            blockID: blocks[1].id,
            at: noon,
            elapsedTime: reading(100)
        )
        try LockCollectionStateMachine.requestEnd(
            &collection,
            blockID: blocks[0].id,
            at: noon,
            elapsedTime: reading(100)
        )
        LockCollectionStateMachine.reconcile(
            &collection,
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )

        try LockCollectionStateMachine.activate(
            &collection,
            blockID: blocks[2].id,
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )

        XCTAssertNil(collection.block(id: blocks[0].id)?.state.storeSlot)
        XCTAssertEqual(collection.block(id: blocks[1].id)?.state.storeSlot, 1)
        XCTAssertEqual(collection.block(id: blocks[2].id)?.state.storeSlot, 0)
    }

    private func activeState() throws -> LockState {
        var state = LockState()
        var policy = LockPolicy()
        policy.waitDuration = 3_600
        policy.breakDuration = 900
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: noon,
            elapsedTime: reading(100)
        )
        return state
    }

    private func reading(
        _ durationSinceBoot: TimeInterval,
        boot: String = "boot-a"
    ) -> ElapsedTimeReading {
        ElapsedTimeReading(durationSinceBoot: durationSinceBoot, bootIdentifier: boot)
    }
}
