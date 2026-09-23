import Foundation
import XCTest

final class ProtectedServiceEngineTests: XCTestCase {
    func testUpdateGateSurvivesRestartAndBlocksActivationUntilOwnerCancels() throws {
        let store = FakeProtectedStateStore()
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)
        let created = try engine.create(ProtectedCreateRequest(draft: serviceTestDraft()))
        let block = try XCTUnwrap(created.blocks.first)
        let token = UUID()

        _ = try engine.prepareUpdate(ProtectedBlockRequest(id: token))
        let restarted = try ProtectedServiceEngine(
            stateStore: store,
            enforcer: FakeProtectionEnforcer(),
            clock: clock
        )
        _ = try restarted.prepareUpdate(ProtectedBlockRequest(id: token))

        XCTAssertThrowsError(
            try restarted.activate(
                ProtectedRevisionRequest(id: block.id, expectedRevision: block.revision)
            )
        ) { error in
            XCTAssertEqual(error as? ProtectedStateError, .updateInProgress)
        }
        XCTAssertThrowsError(
            try restarted.prepareUpdate(ProtectedBlockRequest(id: UUID()))
        ) { error in
            XCTAssertEqual(error as? ProtectedStateError, .updateInProgress)
        }
        XCTAssertThrowsError(
            try restarted.cancelUpdate(ProtectedBlockRequest(id: UUID()))
        ) { error in
            XCTAssertEqual(error as? ProtectedStateError, .updateNotOwned)
        }

        _ = try restarted.cancelUpdate(ProtectedBlockRequest(id: token))
        _ = try restarted.cancelUpdate(ProtectedBlockRequest(id: token))
        let activated = try restarted.activate(
            ProtectedRevisionRequest(id: block.id, expectedRevision: block.revision)
        )
        XCTAssertFalse(activated.effectiveRestrictions.blockedDomains.isEmpty)
    }

    func testPrepareUpdateRejectsActiveState() throws {
        let prepared = try activeState()
        let store = FakeProtectedStateStore(prepared.state)
        let engine = try ProtectedServiceEngine(
            stateStore: store,
            enforcer: FakeProtectionEnforcer(),
            clock: FakeServiceClock(serviceTestReading(0))
        )

        XCTAssertThrowsError(
            try engine.prepareUpdate(ProtectedBlockRequest(id: UUID()))
        ) { error in
            XCTAssertEqual(error as? ProtectedStateError, .updateUnavailable)
        }
        XCTAssertNil(store.persisted.updateGateToken)
    }

    func testLiveFreezeKeepsBreakRulesAndStopsStateWritesUntilCancellation() throws {
        let prepared = try breakState(includeSecondBlock: false)
        let store = FakeProtectedStateStore(prepared.state)
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(60))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)
        let gate = ProtectedLiveUpdateGate(
            token: UUID(),
            generation: UUID(),
            successorDigest: String(repeating: "a", count: 64)
        )

        try engine.beginLiveUpdate(gate)
        let frozenSaveCount = store.mainSaveCount
        XCTAssertEqual(enforcer.applications.last?.blockedDomains, ["a.example"])
        XCTAssertEqual(engine.list().effectiveRestrictions.blockedDomains, ["a.example"])
        clock.reading = serviceTestReading(130)
        engine.tickForTesting()
        XCTAssertEqual(store.mainSaveCount, frozenSaveCount)
        XCTAssertEqual(enforcer.applicationScans.last?.blockedDomains, ["a.example"])

        _ = try engine.endLiveUpdate(token: gate.token, finalized: false)
        XCTAssertNil(store.persisted.liveUpdateGate)
        XCTAssertEqual(store.persisted.lastLiveUpdateCompletion?.phase, .cancelled)
        XCTAssertEqual(store.persisted.effectiveRestrictions().blockedDomains, ["a.example"])
    }

    func testFailedFreezeApplyKeepsDurableGateUntilCancellation() throws {
        let prepared = try activeState()
        let store = FakeProtectedStateStore(prepared.state)
        let enforcer = FakeProtectionEnforcer()
        let engine = try ProtectedServiceEngine(
            stateStore: store,
            enforcer: enforcer,
            clock: FakeServiceClock(serviceTestReading(0))
        )
        let gate = ProtectedLiveUpdateGate(
            token: UUID(),
            generation: UUID(),
            successorDigest: String(repeating: "a", count: 64)
        )
        enforcer.applyFailures = 1

        XCTAssertThrowsError(try engine.beginLiveUpdate(gate))
        XCTAssertEqual(store.persisted.liveUpdateGate, gate)
        XCTAssertThrowsError(try engine.requestEnd(ProtectedBlockRequest(id: prepared.id))) {
            XCTAssertEqual($0 as? ProtectedStateError, .updateInProgress)
        }
        let restored = try engine.endLiveUpdate(token: gate.token, finalized: false)
        XCTAssertNil(store.persisted.liveUpdateGate)
        XCTAssertTrue(restored.protection.isEnforcing)
    }

    func testStandbyCannotRetireBeforeMatchingDurableCompletion() throws {
        let prepared = try activeState()
        var state = prepared.state
        let gate = ProtectedLiveUpdateGate(
            token: UUID(),
            generation: UUID(),
            successorDigest: String(repeating: "b", count: 64)
        )
        try state.beginLiveUpdate(gate)
        let store = FakeProtectedStateStore(state)
        let enforcer = FakeProtectionEnforcer()
        let standby = try ProtectedStandbyEngine(
            stateStore: store,
            state: state,
            appleStateDigest: String(repeating: "c", count: 64),
            token: gate.token,
            runningDigest: gate.successorDigest,
            enforcer: enforcer,
            clock: FakeServiceClock(serviceTestReading(0))
        )

        XCTAssertTrue(try standby.readiness(token: gate.token).isEnforcing)
        XCTAssertEqual(store.mainSaveCount, 0)
        XCTAssertThrowsError(try standby.retire(token: gate.token))
        try state.endLiveUpdate(token: gate.token, finalized: true)
        store.persisted = state
        let retired = try standby.retire(token: gate.token)
        XCTAssertEqual(retired.phase, .finalized)
        XCTAssertFalse(retired.isEnforcing)
        XCTAssertFalse(standby.list().protection.isEnforcing)
        XCTAssertEqual(enforcer.applications.last?.blockedDomains, [])
    }

    func testStandbyRetirementFailureIsReportedAndCanBeRetried() throws {
        let prepared = try activeState()
        var state = prepared.state
        let gate = ProtectedLiveUpdateGate(
            token: UUID(),
            generation: UUID(),
            successorDigest: String(repeating: "b", count: 64)
        )
        try state.beginLiveUpdate(gate)
        let store = FakeProtectedStateStore(state)
        let enforcer = FakeProtectionEnforcer()
        let standby = try ProtectedStandbyEngine(
            stateStore: store,
            state: state,
            appleStateDigest: String(repeating: "c", count: 64),
            token: gate.token,
            runningDigest: gate.successorDigest,
            enforcer: enforcer,
            clock: FakeServiceClock(serviceTestReading(0))
        )
        try state.endLiveUpdate(token: gate.token, finalized: false)
        store.persisted = state
        enforcer.applyFailures = 1

        XCTAssertThrowsError(try standby.retire(token: gate.token))
        XCTAssertFalse(try standby.readiness(token: gate.token).isEnforcing)
        XCTAssertEqual(standby.list().protection.issues.first?.code, "standby_retirement_failed")
        XCTAssertEqual(try standby.retire(token: gate.token).phase, .cancelled)
        XCTAssertFalse(standby.list().protection.isEnforcing)
    }

    func testInspectLiveUpdateDistinguishesOldAndNewPrimary() throws {
        let store = FakeProtectedStateStore()
        let engine = try ProtectedServiceEngine(
            stateStore: store,
            enforcer: FakeProtectionEnforcer(),
            clock: FakeServiceClock(serviceTestReading(0))
        )
        let gate = ProtectedLiveUpdateGate(
            token: UUID(),
            generation: UUID(),
            successorDigest: String(repeating: "a", count: 64)
        )
        try engine.beginLiveUpdate(gate)
        let apple = try AppleLockdownEngine(
            stateStore: FakeAppleLockdownStateStore(),
            credentialVault: FakeAppleLockdownVault()
        )
        let request = try ProtectedServiceCodec.encode(ProtectedLiveUpdateRequest(token: gate.token))

        for (digest, phase) in [
            (String(repeating: "b", count: 64), ProtectedLiveUpdatePhase.frozen),
            (gate.successorDigest, .standbyReady),
        ] {
            let endpoint = ProtectedServiceEndpoint(
                engine: engine,
                appleLockdown: apple,
                coordinator: ProtectedServiceCoordinator(),
                runningDigest: digest
            )
            var response: NSData?
            endpoint.inspectLiveUpdate(request) { response = $0 }
            let reply = try ProtectedServiceCodec.decode(
                ProtectedLiveUpdateReply.self,
                from: XCTUnwrap(response)
            )
            XCTAssertNil(reply.error)
            XCTAssertEqual(reply.status?.phase, phase)
            XCTAssertEqual(reply.status?.generation, gate.generation)
            XCTAssertTrue(reply.status?.isEnforcing == true)
        }
    }

    func testInactiveMigrationIsReadOnlyUntilTokenIsCommitted() throws {
        let store = FakeProtectedStateStore()
        let engine = try ProtectedServiceEngine(
            stateStore: store,
            enforcer: FakeProtectionEnforcer(),
            preloadedState: store.persisted
        )
        let token = UUID()
        XCTAssertEqual(store.mainSaveCount, 0)
        XCTAssertThrowsError(try engine.create(ProtectedCreateRequest(draft: serviceTestDraft()))) {
            XCTAssertEqual($0 as? ProtectedStateError, .updateInProgress)
        }
        XCTAssertEqual(store.mainSaveCount, 0)
        _ = try engine.finalizeInactiveMigration(token: token)
        XCTAssertEqual(store.persisted.lastInactiveMigrationToken, token)
        _ = try engine.create(ProtectedCreateRequest(draft: serviceTestDraft()))
    }

    func testPrepareUpdateRejectsUnhealthyService() throws {
        let store = FakeProtectedStateStore()
        let enforcer = FakeProtectionEnforcer()
        enforcer.outcome = EnforcementOutcome(
            issues: [
                ProtectionIssue(
                    code: "test_issue",
                    message: "Injected unhealthy service.",
                    blockIDs: []
                )
            ],
            closedApplications: []
        )
        let engine = try ProtectedServiceEngine(
            stateStore: store,
            enforcer: enforcer,
            clock: FakeServiceClock(serviceTestReading(0))
        )

        XCTAssertThrowsError(
            try engine.prepareUpdate(ProtectedBlockRequest(id: UUID()))
        ) { error in
            XCTAssertEqual(error as? ProtectedStateError, .updateUnavailable)
        }
        XCTAssertNil(store.persisted.updateGateToken)
    }

    func testProtectedStateWithoutUpdateGateTokenDecodesAsUngated() throws {
        let data = Data(#"{"schemaVersion":2,"blocks":[]}"#.utf8)

        let state = try JSONDecoder().decode(ProtectedState.self, from: data)

        XCTAssertNil(state.updateGateToken)
    }

    func testExpiredBreakRelocksBeforeInvalidRequestReturnsError() throws {
        let prepared = try breakState(includeSecondBlock: false)
        let store = FakeProtectedStateStore(prepared.state)
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(60))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)
        enforcer.applications.removeAll()
        clock.reading = serviceTestReading(121)

        XCTAssertThrowsError(
            try engine.requestBreak(ProtectedBlockRequest(id: UUID()))
        ) { error in
            XCTAssertEqual(error as? ProtectedStateError, .blockNotFound)
        }

        XCTAssertEqual(store.persisted.effectiveRestrictions().blockedDomains, ["a.example"])
        XCTAssertEqual(enforcer.applications.last?.blockedDomains, ["a.example"])
    }

    func testCancelBreakKeepsProtectionAndOtherFullUnlockDeadline() throws {
        var state = ProtectedState()
        let breakBlock = try state.create(
            serviceTestDraft(name: "Break", domains: ["break.example"], breakDelay: 60)
        )
        let unlockBlock = try state.create(
            serviceTestDraft(name: "Unlock", domains: ["unlock.example"], fullUnlockDelay: 180)
        )
        try state.activate(
            id: breakBlock.id,
            expectedRevision: breakBlock.revision,
            at: serviceTestReading(0)
        )
        try state.activate(
            id: unlockBlock.id,
            expectedRevision: unlockBlock.revision,
            at: serviceTestReading(0)
        )
        try state.request(.breakAccess, id: breakBlock.id, at: serviceTestReading(0))
        try state.request(.fullUnlock, id: unlockBlock.id, at: serviceTestReading(0))
        let store = FakeProtectedStateStore(state)
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(30))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)

        let snapshot = try engine.cancelBreak(ProtectedBlockRequest(id: breakBlock.id))

        XCTAssertEqual(
            snapshot.blocks.first(where: { $0.id == breakBlock.id })?.phase,
            .active(naturalEndRemaining: nil)
        )
        XCTAssertEqual(
            snapshot.blocks.first(where: { $0.id == unlockBlock.id })?.phase,
            .waitingForFullUnlock(remaining: 150, naturalEndRemaining: nil)
        )
        XCTAssertEqual(
            Set(store.persisted.effectiveRestrictions().blockedDomains),
            Set(["break.example", "unlock.example"])
        )
    }

    func testCancelAtBreakDeadlinePersistsOpenedBreakBeforeReturningError() throws {
        var state = ProtectedState()
        let block = try state.create(
            serviceTestDraft(domains: ["example.com"], breakDelay: 60, breakDuration: 60)
        )
        try state.activate(id: block.id, expectedRevision: block.revision, at: serviceTestReading(0))
        try state.request(.breakAccess, id: block.id, at: serviceTestReading(0))
        let store = FakeProtectedStateStore(state)
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)
        clock.reading = serviceTestReading(60)

        XCTAssertThrowsError(try engine.cancelBreak(ProtectedBlockRequest(id: block.id))) { error in
            XCTAssertEqual(error as? ProtectedStateError, .noPendingBreakRequest)
        }

        XCTAssertTrue(store.persisted.effectiveRestrictions().blockedDomains.isEmpty)
        XCTAssertEqual(
            engine.list().blocks.first?.phase,
            .breakActive(remaining: 60, fullUnlockRemaining: nil, naturalEndRemaining: nil)
        )
        XCTAssertEqual(enforcer.applications.last?.blockedDomains, [])
    }

    func testRelockWriteFailureKeepsTighteningApplied() throws {
        let prepared = try breakState(includeSecondBlock: false)
        let store = FakeProtectedStateStore(prepared.state)
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(60))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)
        enforcer.applications.removeAll()
        store.mainSaveFailures = 1
        clock.reading = serviceTestReading(121)

        engine.tickForTesting()

        XCTAssertEqual(enforcer.applications.map(\.blockedDomains), [["a.example"]])
        XCTAssertTrue(store.persisted.effectiveRestrictions().blockedDomains.isEmpty)
        XCTAssertEqual(store.pending?.effectiveRestrictions().blockedDomains, ["a.example"])
    }

    func testMixedRelockAndBreakOpeningKeepsUnionWhenWriteFails() throws {
        let prepared = try breakState(includeSecondBlock: true)
        let store = FakeProtectedStateStore(prepared.state)
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(60))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)
        enforcer.applications.removeAll()
        store.mainSaveFailures = 1
        clock.reading = serviceTestReading(121)

        engine.tickForTesting()

        XCTAssertEqual(
            Set(try XCTUnwrap(enforcer.applications.last).blockedDomains),
            Set(["a.example", "b.example"])
        )
        XCTAssertEqual(store.persisted.effectiveRestrictions().blockedDomains, ["b.example"])
        XCTAssertEqual(store.pending?.effectiveRestrictions().blockedDomains, ["a.example"])
        XCTAssertFalse(
            enforcer.applications.contains { Set($0.blockedDomains) == Set(["a.example"]) },
            "B must not relax until the candidate state is durable."
        )
    }

    func testPendingCandidateAdvancesBeforeRetrySoExpiredBreakNeverReopens() throws {
        let prepared = try breakState(includeSecondBlock: true)
        let store = FakeProtectedStateStore(prepared.state)
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(60))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)
        store.mainSaveFailures = 1
        clock.reading = serviceTestReading(121)
        engine.tickForTesting()
        enforcer.applications.removeAll()

        clock.reading = serviceTestReading(181)
        engine.tickForTesting()

        XCTAssertEqual(
            Set(store.persisted.effectiveRestrictions().blockedDomains),
            Set(["a.example", "b.example"])
        )
        XCTAssertFalse(
            enforcer.applications.contains { Set($0.blockedDomains) == Set(["a.example"]) }
        )
    }

    func testRestartReconcilesExpiredBreakBeforeFirstEnforcement() throws {
        let prepared = try breakState(includeSecondBlock: false)
        let store = FakeProtectedStateStore(prepared.state)
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(121))

        _ = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)

        XCTAssertFalse(enforcer.applications.isEmpty)
        XCTAssertTrue(enforcer.applications.allSatisfy { $0.blockedDomains == ["a.example"] })
        XCTAssertEqual(store.persisted.effectiveRestrictions().blockedDomains, ["a.example"])
    }

    func testRestartSaveFailureStillRelocksExpiredBreak() throws {
        let prepared = try breakState(includeSecondBlock: false)
        let store = FakeProtectedStateStore(prepared.state)
        store.mainSaveFailures = 1
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(121))

        _ = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)

        XCTAssertFalse(enforcer.applications.isEmpty)
        XCTAssertTrue(enforcer.applications.allSatisfy { $0.blockedDomains == ["a.example"] })
        XCTAssertTrue(store.persisted.effectiveRestrictions().blockedDomains.isEmpty)
        XCTAssertEqual(store.pending?.effectiveRestrictions().blockedDomains, ["a.example"])
    }

    func testActivationPersistsIntentBeforeApplyingAndAcknowledging() throws {
        let events = TestEventLog()
        let store = FakeProtectedStateStore(events: events)
        let enforcer = FakeProtectionEnforcer(events: events)
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)
        let created = try engine.create(ProtectedCreateRequest(draft: serviceTestDraft()))
        let block = try XCTUnwrap(created.blocks.first)
        events.values.removeAll()

        _ = try engine.activate(
            ProtectedRevisionRequest(id: block.id, expectedRevision: block.revision)
        )

        XCTAssertEqual(
            events.values,
            ["save-pending", "apply:example.com", "save-main", "clear-pending"]
        )
        XCTAssertNil(store.pending)
        XCTAssertEqual(store.persisted.effectiveRestrictions().blockedDomains, ["example.com"])
    }

    func testActivationDoesNotApplyWhenDurableIntentCannotBeSaved() throws {
        let events = TestEventLog()
        let store = FakeProtectedStateStore(events: events)
        let enforcer = FakeProtectionEnforcer(events: events)
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)
        let created = try engine.create(ProtectedCreateRequest(draft: serviceTestDraft()))
        let block = try XCTUnwrap(created.blocks.first)
        events.values.removeAll()
        enforcer.applications.removeAll()
        store.pendingSaveFailures = 1

        XCTAssertThrowsError(
            try engine.activate(
                ProtectedRevisionRequest(id: block.id, expectedRevision: block.revision)
            )
        )

        XCTAssertEqual(events.values, ["save-pending"])
        XCTAssertTrue(enforcer.applications.isEmpty)
        XCTAssertTrue(store.persisted.effectiveRestrictions().blockedDomains.isEmpty)
    }

    func testJournalCleanupFailureBlocksLaterCommitAndCannotReplayAfterFullUnlock() throws {
        let store = FakeProtectedStateStore()
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)
        let created = try engine.create(ProtectedCreateRequest(draft: serviceTestDraft()))
        let block = try XCTUnwrap(created.blocks.first)
        store.clearFailures = 1

        XCTAssertThrowsError(
            try engine.activate(
                ProtectedRevisionRequest(id: block.id, expectedRevision: block.revision)
            )
        )
        XCTAssertNotNil(store.pending)
        XCTAssertEqual(store.persisted.effectiveRestrictions().blockedDomains, ["example.com"])

        _ = try engine.requestEnd(ProtectedBlockRequest(id: block.id))
        XCTAssertNil(store.pending)
        clock.reading = serviceTestReading(180)
        engine.tickForTesting()
        XCTAssertTrue(store.persisted.effectiveRestrictions().blockedDomains.isEmpty)

        let restartedEnforcer = FakeProtectionEnforcer()
        let restarted = try ProtectedServiceEngine(
            stateStore: store,
            enforcer: restartedEnforcer,
            clock: clock
        )
        XCTAssertTrue(restarted.list().effectiveRestrictions.blockedDomains.isEmpty)
        XCTAssertTrue(restartedEnforcer.applications.allSatisfy { $0.blockedDomains.isEmpty })
    }

    func testRepeatedListsDoNotWriteOrReapplyUnchangedActiveState() throws {
        let prepared = try activeState()
        let store = FakeProtectedStateStore(prepared.state)
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)
        store.mainSaveCount = 0
        enforcer.applications.removeAll()

        for _ in 0..<20 { _ = engine.list() }

        XCTAssertEqual(store.mainSaveCount, 0)
        XCTAssertTrue(enforcer.applications.isEmpty)
    }

    func testApplicationScanDoesNotForceStateCheckpointOrFullReapply() throws {
        let prepared = try activeState()
        let store = FakeProtectedStateStore(prepared.state)
        let enforcer = FakeProtectionEnforcer()
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try ProtectedServiceEngine(stateStore: store, enforcer: enforcer, clock: clock)
        store.mainSaveCount = 0
        enforcer.applications.removeAll()
        clock.reading = serviceTestReading(2.1)

        engine.tickForTesting()

        XCTAssertEqual(store.mainSaveCount, 0)
        XCTAssertTrue(enforcer.applications.isEmpty)
        XCTAssertEqual(enforcer.applicationScans.count, 1)
    }

    private func activeState() throws -> (state: ProtectedState, id: UUID) {
        var state = ProtectedState()
        let block = try state.create(serviceTestDraft(domains: ["a.example"]))
        try state.activate(id: block.id, expectedRevision: block.revision, at: serviceTestReading(0))
        return (state, block.id)
    }

    private func breakState(
        includeSecondBlock: Bool
    ) throws -> (state: ProtectedState, firstID: UUID, secondID: UUID?) {
        var state = ProtectedState()
        let first = try state.create(
            serviceTestDraft(
                name: "A",
                domains: ["a.example"],
                breakDelay: 60,
                breakDuration: 60
            )
        )
        try state.activate(id: first.id, expectedRevision: first.revision, at: serviceTestReading(0))
        try state.request(.breakAccess, id: first.id, at: serviceTestReading(0))

        var secondID: UUID?
        if includeSecondBlock {
            let second = try state.create(
                serviceTestDraft(
                    name: "B",
                    domains: ["b.example"],
                    breakDelay: 120,
                    breakDuration: 60
                )
            )
            try state.activate(
                id: second.id,
                expectedRevision: second.revision,
                at: serviceTestReading(0)
            )
            try state.request(.breakAccess, id: second.id, at: serviceTestReading(0))
            secondID = second.id
        }
        _ = state.advance(to: serviceTestReading(60))
        return (state, first.id, secondID)
    }
}
