import Foundation
import XCTest

final class ProtectedServiceEngineTests: XCTestCase {
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
