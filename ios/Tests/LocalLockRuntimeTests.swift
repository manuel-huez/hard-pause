import Foundation
import XCTest

@testable import HardPause

final class LocalLockRuntimeTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    func testTwoActiveBlocksKeepUnionBlockedWhenOneTimeoutOpens() throws {
        try withRuntime { runtime, restrictions, _, _, _ in
            let (firstID, secondID) = try activateTwoBlocks(using: runtime)
            _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
                try LockCollectionStateMachine.requestBreak(
                    &collection,
                    blockID: firstID,
                    at: noon,
                    elapsedTime: reading(100)
                )
            }

            let opened = try runtime.reconcile(
                at: noon.addingTimeInterval(3_600),
                elapsedTime: reading(3_700)
            )

            XCTAssertEqual(opened.block(id: firstID)?.state.phase, .breakActive)
            XCTAssertEqual(opened.block(id: secondID)?.state.phase, .locked)
            XCTAssertEqual(
                restrictions.applied.last?.blocks.filter(\.state.blocksTargets).map(\.id),
                [secondID]
            )

            let stillOpen = try runtime.reconcile(
                at: noon.addingTimeInterval(3_601),
                elapsedTime: reading(3_701)
            )
            XCTAssertEqual(stillOpen.block(id: firstID)?.state.phase, .breakActive)
        }
    }

    func testThirtyMinuteTimeoutOpensAndSurvivesRepeatedMidBreakReconcile() throws {
        try withRuntime { runtime, _, _, _, _ in
            let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
            let id = try XCTUnwrap(initial.blocks.first?.id)
            _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
                collection.blocks[0].draftPolicy.breakDuration = 1_800
                try LockCollectionStateMachine.activate(
                    &collection,
                    blockID: id,
                    at: noon,
                    elapsedTime: reading(100)
                )
                try LockCollectionStateMachine.requestBreak(
                    &collection,
                    blockID: id,
                    at: noon,
                    elapsedTime: reading(100)
                )
            }

            for offset in [3_600.0, 3_610.0, 4_200.0, 5_399.0] {
                let collection = try runtime.reconcile(
                    at: noon.addingTimeInterval(offset),
                    elapsedTime: reading(100 + offset)
                )
                XCTAssertEqual(collection.block(id: id)?.state.phase, .breakActive)
            }
        }
    }

    func testFifteenMinuteTimeoutKeepsAcceptedScheduleThroughOpenAndRefresh() throws {
        try withRuntime { runtime, _, scheduler, _, _ in
            let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
            let id = try XCTUnwrap(initial.blocks.first?.id)
            _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
                try LockCollectionStateMachine.activate(
                    &collection,
                    blockID: id,
                    at: noon,
                    elapsedTime: reading(100)
                )
                try LockCollectionStateMachine.requestBreak(
                    &collection,
                    blockID: id,
                    at: noon,
                    elapsedTime: reading(100)
                )
            }
            let accepted = try XCTUnwrap(scheduler.intervals[id])

            let opened = try runtime.reconcile(
                at: noon.addingTimeInterval(3_600),
                elapsedTime: reading(3_700)
            )
            XCTAssertEqual(opened.block(id: id)?.state.phase, .breakActive)
            XCTAssertEqual(scheduler.intervals[id], accepted)

            let refreshed = try runtime.reconcile(
                at: noon.addingTimeInterval(3_601),
                elapsedTime: reading(3_701)
            )
            XCTAssertEqual(refreshed.block(id: id)?.state.phase, .breakActive)
            XCTAssertEqual(scheduler.intervals[id], accepted)
        }
    }

    func testMixedRelockAndBreakOpenUsesTighteningOnlyPrecommitProjection() throws {
        try withRuntime { runtime, restrictions, _, _, _ in
            let (firstID, secondID) = try prepareSimultaneousMixedTransition(using: runtime)
            restrictions.reset()

            let reconciled = try runtime.reconcile(
                at: noon.addingTimeInterval(4_500),
                elapsedTime: reading(4_600)
            )

            XCTAssertEqual(reconciled.block(id: firstID)?.state.phase, .locked)
            XCTAssertEqual(reconciled.block(id: secondID)?.state.phase, .breakActive)
            XCTAssertEqual(restrictions.applied.count, 2)
            XCTAssertTrue(
                restrictions.applied[0].blocks.allSatisfy(\.state.blocksTargets),
                "Precommit enforcement must contain only tightening changes"
            )
            XCTAssertEqual(
                restrictions.applied[1].blocks.filter(\.state.blocksTargets).map(\.id),
                [firstID]
            )
        }
    }

    func testScheduleFailureDuringMixedTransitionDoesNotRelaxEitherStoredBlock() throws {
        try withRuntime { runtime, restrictions, scheduler, _, _ in
            let (firstID, secondID) = try prepareSimultaneousMixedTransition(using: runtime)
            restrictions.reset()
            scheduler.failsNextEnsure = true

            XCTAssertThrowsError(
                try runtime.reconcile(
                    at: noon.addingTimeInterval(4_500),
                    elapsedTime: reading(4_600)
                )
            )

            let stored = try runtime.load()
            XCTAssertEqual(stored.block(id: firstID)?.state.phase, .breakActive)
            XCTAssertEqual(stored.block(id: secondID)?.state.phase, .waitingForBreak)
            XCTAssertEqual(restrictions.applied.count, 1)
            XCTAssertTrue(restrictions.applied[0].blocks.allSatisfy(\.state.blocksTargets))
            XCTAssertEqual(Set(scheduler.intervals.keys), Set([secondID]))

            let repaired = try runtime.reconcile(
                at: noon.addingTimeInterval(4_500),
                elapsedTime: reading(4_600)
            )
            XCTAssertEqual(repaired.block(id: firstID)?.state.phase, .locked)
            XCTAssertEqual(repaired.block(id: secondID)?.state.phase, .breakActive)
        }
    }

    func testMixedRelockAndFullEndUsesTighteningOnlyPrecommitProjection() throws {
        try withRuntime { runtime, restrictions, _, _, _ in
            let (firstID, secondID) = try prepareSimultaneousRelockAndEnd(using: runtime)
            restrictions.reset()

            let reconciled = try runtime.reconcile(
                at: noon.addingTimeInterval(4_500),
                elapsedTime: reading(4_600)
            )

            XCTAssertEqual(reconciled.block(id: firstID)?.state.phase, .locked)
            XCTAssertEqual(reconciled.block(id: secondID)?.state.phase, .inactive)
            XCTAssertEqual(restrictions.applied.count, 2)
            XCTAssertTrue(restrictions.applied[0].activeBlocks.allSatisfy(\.state.blocksTargets))
            XCTAssertEqual(restrictions.applied[1].activeBlocks.map(\.id), [firstID])
        }
    }

    func testScheduleFailureDuringMixedRelockAndEndDoesNotRelaxStoredBlocks() throws {
        try withRuntime { runtime, restrictions, scheduler, _, _ in
            let (firstID, secondID) = try prepareSimultaneousRelockAndEnd(using: runtime)
            restrictions.reset()
            scheduler.failsNextEnsure = true

            XCTAssertThrowsError(
                try runtime.reconcile(
                    at: noon.addingTimeInterval(4_500),
                    elapsedTime: reading(4_600)
                )
            )

            let stored = try runtime.load()
            XCTAssertEqual(stored.block(id: firstID)?.state.phase, .breakActive)
            XCTAssertEqual(stored.block(id: secondID)?.state.phase, .waitingForEnd)
            XCTAssertEqual(restrictions.applied.count, 1)
            XCTAssertTrue(restrictions.applied[0].activeBlocks.allSatisfy(\.state.blocksTargets))
            XCTAssertTrue(scheduler.intervals.isEmpty)

            let repaired = try runtime.reconcile(
                at: noon.addingTimeInterval(4_500),
                elapsedTime: reading(4_600)
            )
            XCTAssertEqual(repaired.block(id: firstID)?.state.phase, .locked)
            XCTAssertEqual(repaired.block(id: secondID)?.state.phase, .inactive)
        }
    }

    func testEachPendingBlockKeepsItsOwnSchedule() throws {
        try withRuntime { runtime, _, scheduler, _, _ in
            let (firstID, secondID) = try activateTwoBlocks(using: runtime)
            _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
                try LockCollectionStateMachine.requestBreak(
                    &collection,
                    blockID: firstID,
                    at: noon,
                    elapsedTime: reading(100)
                )
                try LockCollectionStateMachine.requestEnd(
                    &collection,
                    blockID: secondID,
                    at: noon,
                    elapsedTime: reading(100)
                )
            }

            XCTAssertEqual(Set(scheduler.intervals.keys), Set([firstID, secondID]))
            XCTAssertNotEqual(scheduler.intervals[firstID], nil)
            XCTAssertNotEqual(scheduler.intervals[secondID], nil)
        }
    }

    func testAggregateRecoveryRestoresEveryActiveBlock() throws {
        try withRuntime { runtime, restrictions, _, directory, _ in
            let (firstID, secondID) = try activateTwoBlocks(using: runtime)
            try Data("not-json".utf8).write(
                to: directory.appendingPathComponent("lock-state-v1.json")
            )

            let recovered = try runtime.reconcile(at: noon, elapsedTime: reading(100))

            XCTAssertEqual(Set(recovered.activeBlocks.map(\.id)), Set([firstID, secondID]))
            XCTAssertTrue(recovered.activeBlocks.allSatisfy { $0.state.phase == .locked })
            XCTAssertEqual(restrictions.applied.last?.activeBlocks.count, 2)
            XCTAssertTrue(recovered.activeBlocks.allSatisfy { $0.state.recoveryNotice != nil })
        }
    }

    func testRuntimeRejectsActiveNameAndDraftPolicyEdits() throws {
        try withRuntime { runtime, _, _, _, _ in
            let collection = try activateFirstBlock(using: runtime)
            let id = try XCTUnwrap(collection.blocks.first?.id)
            let original = try XCTUnwrap(collection.block(id: id))

            XCTAssertThrowsError(
                try runtime.mutate { candidate in
                    let index = try candidate.index(of: id)
                    candidate.blocks[index].name = "Changed"
                    candidate.blocks[index].draftPolicy.breakDuration = 7_200
                }
            ) { error in
                XCTAssertEqual(error as? LockCollectionError, .activeBlockCannotBeEdited)
            }

            XCTAssertEqual(try runtime.load().block(id: id), original)
        }
    }

    func testRuntimeRejectsDeletingAnActiveBlock() throws {
        try withRuntime { runtime, _, _, _, _ in
            let collection = try activateFirstBlock(using: runtime)
            let id = try XCTUnwrap(collection.blocks.first?.id)

            XCTAssertThrowsError(
                try runtime.mutate { candidate in
                    candidate.blocks.removeAll { $0.id == id }
                }
            ) { error in
                XCTAssertEqual(error as? LockCollectionError, .activeBlockCannotBeEdited)
            }
            XCTAssertNotNil(try runtime.load().block(id: id))
        }
    }

    func testRuntimeRejectsInvalidOrDuplicateActiveStoreSlots() throws {
        try withRuntime { runtime, _, _, _, _ in
            let (firstID, secondID) = try activateTwoBlocks(using: runtime)

            XCTAssertThrowsError(
                try runtime.mutate { collection in
                    let index = try collection.index(of: firstID)
                    collection.blocks[index].state.storeSlot = 16
                }
            ) { error in
                XCTAssertEqual(error as? LockCollectionError, .invalidStoreSlot)
            }

            XCTAssertThrowsError(
                try runtime.mutate { collection in
                    let first = try collection.index(of: firstID)
                    let second = try collection.index(of: secondID)
                    collection.blocks[second].state.storeSlot =
                        collection.blocks[first].state.storeSlot
                }
            ) { error in
                XCTAssertEqual(error as? LockCollectionError, .invalidStoreSlot)
            }

            XCTAssertThrowsError(
                try runtime.mutate { collection in
                    let first = try collection.index(of: firstID)
                    let second = try collection.index(of: secondID)
                    let firstSlot = collection.blocks[first].state.storeSlot
                    collection.blocks[first].state.storeSlot =
                        collection.blocks[second].state.storeSlot
                    collection.blocks[second].state.storeSlot = firstSlot
                }
            ) { error in
                XCTAssertEqual(error as? LockCollectionError, .activeBlockCannotBeEdited)
            }
        }
    }

    func testFixedStorePoolDoesNotGrowAfterSixtyDrafts() throws {
        let stores = RecordingStoreBackend()
        let service = RestrictionService(stores: stores)
        var collection = LockCollection(
            blocks: (0..<60).map { LockBlock(name: "Draft \($0)") }
        )

        service.apply(collection)

        XCTAssertEqual(stores.slots, Array(0..<LockCollection.maximumActiveBlocks))
        XCTAssertTrue(stores.states.allSatisfy { $0 == nil })
        XCTAssertEqual(stores.legacyClearCount, 1)

        stores.reset()
        let activeID = collection.blocks[40].id
        try LockCollectionStateMachine.activate(
            &collection,
            blockID: activeID,
            at: noon,
            elapsedTime: reading(100)
        )
        service.apply(collection)

        XCTAssertEqual(stores.slots.count, LockCollection.maximumActiveBlocks)
        XCTAssertEqual(stores.slots.first, 0)
        XCTAssertEqual(try XCTUnwrap(stores.states.first ?? nil).phase, .locked)
        XCTAssertEqual(Set(stores.slots), Set(0..<LockCollection.maximumActiveBlocks))
    }

    func testSixtyDraftCreateDeleteCyclesDoNotApplyRestrictionStores() throws {
        try withRuntime { runtime, restrictions, _, _, _ in
            _ = try runtime.reconcile(at: noon, elapsedTime: reading(100))
            restrictions.reset()

            for number in 0..<60 {
                let block = LockBlock(name: "Draft \(number)")
                _ = try runtime.mutate { collection in
                    collection.blocks.append(block)
                }
                _ = try runtime.mutate { collection in
                    collection.blocks.removeAll { $0.id == block.id }
                }
            }

            XCTAssertTrue(restrictions.applied.isEmpty)
        }
    }

    func testScheduleLimitFailureKeepsExistingBlockLocked() throws {
        try withRuntime { runtime, restrictions, scheduler, _, _ in
            let active = try activateFirstBlock(using: runtime)
            let id = try XCTUnwrap(active.blocks.first?.id)
            let applicationsBefore = restrictions.applied.count
            scheduler.failsNextEnsure = true

            XCTAssertThrowsError(
                try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
                    try LockCollectionStateMachine.requestBreak(
                        &collection,
                        blockID: id,
                        at: noon,
                        elapsedTime: reading(100)
                    )
                }
            ) { error in
                XCTAssertEqual(error as? TransitionSchedulerError, .tooManyActiveSchedules)
            }

            XCTAssertEqual(try runtime.load().block(id: id)?.state.phase, .locked)
            XCTAssertEqual(restrictions.applied.count, applicationsBefore)
        }
    }

    func testMissingRelockScheduleFailsClosedForOnlyAffectedBlock() throws {
        try withRuntime { runtime, restrictions, scheduler, _, _ in
            let (firstID, secondID) = try activateTwoBlocks(using: runtime)
            _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
                try LockCollectionStateMachine.requestBreak(
                    &collection,
                    blockID: firstID,
                    at: noon,
                    elapsedTime: reading(100)
                )
            }
            scheduler.intervals[firstID] = nil

            let recovered = try runtime.reconcile(
                at: noon.addingTimeInterval(3_600),
                elapsedTime: reading(3_700)
            )

            XCTAssertEqual(recovered.block(id: firstID)?.state.phase, .locked)
            XCTAssertEqual(recovered.block(id: secondID)?.state.phase, .locked)
            XCTAssertTrue(recovered.block(id: firstID)?.state.blocksTargets == true)
            XCTAssertEqual(restrictions.applied.last?.blocks.filter(\.state.blocksTargets).count, 2)
        }
    }

    func testFixedEndOfOneBlockDoesNotClearOtherBlock() throws {
        try withRuntime { runtime, restrictions, _, _, _ in
            var collection = try runtime.reconcile(at: noon, elapsedTime: reading(100))
            let firstID = try XCTUnwrap(collection.blocks.first?.id)
            let second = LockBlock(name: "Second")
            collection = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { candidate in
                candidate.blocks.append(second)
                candidate.blocks[0].draftPolicy.fixedDuration = 3_600
                try LockCollectionStateMachine.activate(
                    &candidate,
                    blockID: firstID,
                    at: noon,
                    elapsedTime: reading(100)
                )
                try LockCollectionStateMachine.activate(
                    &candidate,
                    blockID: second.id,
                    at: noon,
                    elapsedTime: reading(100)
                )
            }
            XCTAssertEqual(collection.activeBlocks.count, 2)

            let ended = try runtime.reconcile(
                at: noon.addingTimeInterval(3_600),
                elapsedTime: reading(3_700)
            )

            XCTAssertEqual(ended.block(id: firstID)?.state.phase, .inactive)
            XCTAssertEqual(ended.block(id: second.id)?.state.phase, .locked)
            XCTAssertEqual(restrictions.applied.last?.activeBlocks.map(\.id), [second.id])
        }
    }

    func testEndWarningExpiresFixedDurationInsideBreakWithoutForegroundPolling() throws {
        try withRuntime { runtime, _, scheduler, _, _ in
            let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
            let id = try XCTUnwrap(initial.blocks.first?.id)
            _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
                collection.blocks[0].draftPolicy.waitDuration = 3_600
                collection.blocks[0].draftPolicy.breakDuration = 900
                collection.blocks[0].draftPolicy.fixedDuration = 3_900
                try LockCollectionStateMachine.activate(
                    &collection,
                    blockID: id,
                    at: noon,
                    elapsedTime: reading(100)
                )
                try LockCollectionStateMachine.requestBreak(
                    &collection,
                    blockID: id,
                    at: noon,
                    elapsedTime: reading(100)
                )
            }
            let opened = try runtime.reconcile(
                at: noon.addingTimeInterval(3_600),
                elapsedTime: reading(3_700)
            )
            XCTAssertEqual(opened.block(id: id)?.state.phase, .breakActive)

            let early = try runtime.reconcile(
                at: noon.addingTimeInterval(3_899.5),
                elapsedTime: reading(3_999.5),
                endWarningFor: id
            )
            XCTAssertEqual(early.block(id: id)?.state.phase, .breakActive)
            XCTAssertNotNil(scheduler.intervals[id])

            let expired = try runtime.reconcile(
                at: noon.addingTimeInterval(3_900),
                elapsedTime: reading(4_000)
            )
            XCTAssertEqual(expired.block(id: id)?.state.phase, .inactive)
        }
    }

    func testEarlyEndWarningAfterWallClockJumpRearmsFromElapsedTime() throws {
        try withRuntime { runtime, _, scheduler, _, _ in
            let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
            let id = try XCTUnwrap(initial.blocks.first?.id)
            _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
                collection.blocks[0].draftPolicy.waitDuration = 3_600
                collection.blocks[0].draftPolicy.breakDuration = 900
                collection.blocks[0].draftPolicy.fixedDuration = 3_900
                try LockCollectionStateMachine.activate(
                    &collection,
                    blockID: id,
                    at: noon,
                    elapsedTime: reading(100)
                )
                try LockCollectionStateMachine.requestBreak(
                    &collection,
                    blockID: id,
                    at: noon,
                    elapsedTime: reading(100)
                )
            }

            let jumpedWallClock = noon.addingTimeInterval(20_000)
            let rearmed = try runtime.reconcile(
                at: jumpedWallClock,
                elapsedTime: reading(3_100),
                endWarningFor: id
            )

            XCTAssertEqual(rearmed.block(id: id)?.state.phase, .waitingForBreak)
            let interval = try XCTUnwrap(scheduler.intervals[id])
            XCTAssertEqual(interval.start, jumpedWallClock.addingTimeInterval(600))
            XCTAssertEqual(interval.end, jumpedWallClock.addingTimeInterval(1_500))
            XCTAssertEqual(rearmed.block(id: id)?.state.registeredScheduleWarningTime, 600)

            let expired = try runtime.reconcile(
                at: jumpedWallClock.addingTimeInterval(900),
                elapsedTime: reading(4_000),
                endWarningFor: id
            )
            XCTAssertEqual(expired.block(id: id)?.state.phase, .inactive)
        }
    }

    func testUnrestorableBreakScheduleRelocksImmediatelyAndPersistsFailsafe() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let restrictions = RecordingRestrictions()
        let scheduler = DestructiveThenRecoveringScheduler()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory),
            restrictions: restrictions,
            scheduler: scheduler,
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
        let id = try XCTUnwrap(initial.blocks.first?.id)
        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
            collection.blocks[0].draftPolicy.waitDuration = 3_600
            collection.blocks[0].draftPolicy.breakDuration = 1_800
            collection.blocks[0].draftPolicy.fixedDuration = 3_900
            try LockCollectionStateMachine.activate(
                &collection,
                blockID: id,
                at: noon,
                elapsedTime: reading(100)
            )
            try LockCollectionStateMachine.requestBreak(
                &collection,
                blockID: id,
                at: noon,
                elapsedTime: reading(100)
            )
        }
        _ = try runtime.reconcile(
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )
        restrictions.reset()
        scheduler.destroyScheduleAndFailNext(for: id)

        let recovered = try runtime.reconcile(
            at: noon.addingTimeInterval(20_000),
            elapsedTime: reading(3_701),
            endWarningFor: id
        )

        XCTAssertEqual(recovered.block(id: id)?.state.phase, .locked)
        XCTAssertNotNil(recovered.block(id: id)?.state.recoveryNotice)
        XCTAssertTrue(recovered.block(id: id)?.state.blocksTargets == true)
        XCTAssertEqual(try runtime.load(), recovered)
        XCTAssertEqual(restrictions.applied.count, 1)
        XCTAssertTrue(restrictions.applied[0].block(id: id)?.state.blocksTargets == true)
        XCTAssertNotNil(scheduler.intervals[id])
    }

    func testUnrestorableVisibleBreakScheduleStillRelocksImmediately() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let restrictions = RecordingRestrictions()
        let scheduler = AmbiguousThenRecoveringScheduler()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory),
            restrictions: restrictions,
            scheduler: scheduler,
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
        let id = try XCTUnwrap(initial.blocks.first?.id)
        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
            collection.blocks[0].draftPolicy.waitDuration = 3_600
            collection.blocks[0].draftPolicy.breakDuration = 1_800
            collection.blocks[0].draftPolicy.fixedDuration = 3_900
            try LockCollectionStateMachine.activate(
                &collection,
                blockID: id,
                at: noon,
                elapsedTime: reading(100)
            )
            try LockCollectionStateMachine.requestBreak(
                &collection,
                blockID: id,
                at: noon,
                elapsedTime: reading(100)
            )
        }
        _ = try runtime.reconcile(
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )
        restrictions.reset()
        scheduler.failNextReplacementAfterSideEffect = true

        let recovered = try runtime.reconcile(
            at: noon.addingTimeInterval(20_000),
            elapsedTime: reading(3_701),
            endWarningFor: id
        )

        XCTAssertEqual(recovered.block(id: id)?.state.phase, .locked)
        XCTAssertNotNil(recovered.block(id: id)?.state.recoveryNotice)
        XCTAssertTrue(recovered.block(id: id)?.state.blocksTargets == true)
        XCTAssertEqual(try runtime.load(), recovered)
        XCTAssertEqual(restrictions.applied.count, 1)
        XCTAssertTrue(restrictions.applied[0].block(id: id)?.state.blocksTargets == true)
        XCTAssertNotNil(scheduler.intervals[id])
    }

    func testBreakRestrictionsRelaxOnlyAfterCollectionCommit() throws {
        try withRuntime { runtime, restrictions, _, directory, _ in
            let active = try activateFirstBlock(using: runtime)
            let id = try XCTUnwrap(active.blocks.first?.id)
            _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
                try LockCollectionStateMachine.requestBreak(
                    &collection,
                    blockID: id,
                    at: noon,
                    elapsedTime: reading(100)
                )
            }
            var storedPhaseWhenRelaxed: LockPhase?
            restrictions.onApply = { collection in
                guard collection.block(id: id)?.state.blocksTargets == false else { return }
                storedPhaseWhenRelaxed = try? JSONDecoder().decode(
                    LockCollection.self,
                    from: Data(contentsOf: directory.appendingPathComponent("lock-state-v1.json"))
                ).block(id: id)?.state.phase
            }

            _ = try runtime.reconcile(
                at: noon.addingTimeInterval(3_600),
                elapsedTime: reading(3_700)
            )

            XCTAssertEqual(storedPhaseWhenRelaxed, .breakActive)
        }
    }

    func testInitialActivationSavesIntentThenTightensBeforeCollectionCommit() throws {
        try withRuntime { runtime, restrictions, _, directory, _ in
            let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
            let id = try XCTUnwrap(initial.blocks.first?.id)
            var storedPhaseWhenApplied: LockPhase?
            var intentExistedWhenApplied = false
            restrictions.onApply = { collection in
                guard collection.block(id: id)?.state.blocksTargets == true else { return }
                storedPhaseWhenApplied = try? JSONDecoder().decode(
                    LockCollection.self,
                    from: Data(contentsOf: directory.appendingPathComponent("lock-state-v1.json"))
                ).block(id: id)?.state.phase
                intentExistedWhenApplied = FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("activation-intent-v1.json").path
                )
            }

            _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
                try LockCollectionStateMachine.activate(
                    &collection,
                    blockID: id,
                    at: noon,
                    elapsedTime: reading(100)
                )
            }

            XCTAssertEqual(storedPhaseWhenApplied, .inactive)
            XCTAssertTrue(intentExistedWhenApplied)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("activation-intent-v1.json").path))
        }
    }

    func testActivationPrimaryWriteFailureRecoversIntentInsteadOfClearingProtection() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let restrictions = RecordingRestrictions()
        let repository = LockRepository(containerURL: directory, beforeWrite: gate.check)
        let runtime = LocalLockRuntime(
            repository: repository, restrictions: restrictions, scheduler: RecordingScheduler(),
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
        let id = try XCTUnwrap(initial.blocks.first?.id)
        gate.failNext = true
        XCTAssertThrowsError(
            try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) {
                try LockCollectionStateMachine.activate(&$0, blockID: id, at: self.noon, elapsedTime: self.reading(100))
            })
        XCTAssertTrue(try XCTUnwrap(restrictions.applied.last?.block(id: id)).state.blocksTargets)
        XCTAssertFalse(try repository.load().hasActiveBlocks)
        let recovered = try runtime.reconcile(at: noon.addingTimeInterval(1), elapsedTime: reading(101))
        XCTAssertTrue(try XCTUnwrap(recovered.block(id: id)).state.blocksTargets)
        XCTAssertEqual(recovered.block(id: id)?.state.activatedAt, noon)
    }

    func testActivationIntentWriteFailureDoesNotApplyNewRestrictions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let restrictions = RecordingRestrictions()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory, beforeIntentWrite: gate.check),
            restrictions: restrictions, scheduler: RecordingScheduler(),
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
        let id = try XCTUnwrap(initial.blocks.first?.id)
        restrictions.reset()
        gate.failNext = true
        XCTAssertThrowsError(
            try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) {
                try LockCollectionStateMachine.activate(&$0, blockID: id, at: self.noon, elapsedTime: self.reading(100))
            })
        XCTAssertTrue(restrictions.applied.isEmpty)
        XCTAssertFalse(try runtime.load().hasActiveBlocks)
    }

    func testIntentCleanupFailureStillRelocksExpiredBreak() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var failCleanup = false
        let restrictions = RecordingRestrictions()
        let scheduler = RecordingScheduler()
        let runtime = LocalLockRuntime(
            repository: LockRepository(
                containerURL: directory,
                beforeIntentClear: {
                    if failCleanup { throw SimulatedWriteError.failed }
                }),
            restrictions: restrictions, scheduler: scheduler,
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let first = try activateFirstBlock(using: runtime)
        let id = try XCTUnwrap(first.blocks.first?.id)
        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) {
            try LockCollectionStateMachine.requestBreak(&$0, blockID: id, at: self.noon, elapsedTime: self.reading(100))
        }
        _ = try runtime.reconcile(at: noon.addingTimeInterval(3_600), elapsedTime: reading(3_700))
        failCleanup = true
        XCTAssertThrowsError(
            try runtime.mutate(wallClockNow: noon.addingTimeInterval(3_601), elapsedTime: reading(3_701)) {
                let block = LockBlock(name: "Second")
                $0.blocks.append(block)
                try LockCollectionStateMachine.activate(
                    &$0, blockID: block.id, at: self.noon.addingTimeInterval(3_601), elapsedTime: self.reading(3_701))
            })
        scheduler.intervals.removeValue(forKey: id)
        restrictions.reset()
        XCTAssertThrowsError(try runtime.reconcile(at: noon.addingTimeInterval(3_602), elapsedTime: reading(3_702)))
        XCTAssertTrue(try XCTUnwrap(restrictions.applied.last?.block(id: id)).state.blocksTargets)
        restrictions.reset()
        XCTAssertThrowsError(try runtime.reconcile(at: noon.addingTimeInterval(4_500), elapsedTime: reading(4_600)))
        XCTAssertTrue(try XCTUnwrap(restrictions.applied.last?.block(id: id)).state.blocksTargets)
        XCTAssertTrue(try runtime.load().hasActiveBlocks)
        failCleanup = false
        let recovered = try runtime.reconcile(at: noon.addingTimeInterval(4_501), elapsedTime: reading(4_601))
        XCTAssertTrue(try XCTUnwrap(recovered.block(id: id)).state.blocksTargets)
    }

    func testPendingActivationRecoveryNeverOpensAnotherBreakBeforeCommit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let restrictions = RecordingRestrictions()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory, beforeWrite: gate.check),
            restrictions: restrictions, scheduler: RecordingScheduler(),
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let initial = try activateFirstBlock(using: runtime)
        let firstID = try XCTUnwrap(initial.blocks.first?.id)
        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) {
            try LockCollectionStateMachine.requestBreak(
                &$0, blockID: firstID, at: self.noon, elapsedTime: self.reading(100))
        }
        let second = LockBlock(name: "Second")
        restrictions.reset()
        gate.failNext = true
        XCTAssertThrowsError(
            try runtime.mutate(wallClockNow: noon.addingTimeInterval(3_600), elapsedTime: reading(3_700)) {
                $0.blocks.append(second)
                try LockCollectionStateMachine.activate(
                    &$0, blockID: second.id, at: self.noon.addingTimeInterval(3_600), elapsedTime: self.reading(3_700))
            })
        XCTAssertTrue(restrictions.applied.allSatisfy { $0.block(id: firstID)?.state.blocksTargets == true })
        restrictions.reset()
        gate.failNext = true
        XCTAssertThrowsError(try runtime.reconcile(at: noon.addingTimeInterval(3_601), elapsedTime: reading(3_701)))
        XCTAssertFalse(restrictions.applied.isEmpty)
        XCTAssertTrue(restrictions.applied.allSatisfy { $0.block(id: firstID)?.state.blocksTargets == true })
        let recovered = try runtime.reconcile(at: noon.addingTimeInterval(3_602), elapsedTime: reading(3_702))
        XCTAssertEqual(recovered.block(id: firstID)?.state.phase, .breakActive)
        XCTAssertTrue(try XCTUnwrap(recovered.block(id: second.id)).state.blocksTargets)
    }

    func testIntentSurvivesInterruptionBeforeTighteningAndMissingPrimary() throws {
        for removePrimary in [false, true] {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let gate = WriteFailureGate()
            let restrictions = RecordingRestrictions()
            let runtime = LocalLockRuntime(
                repository: LockRepository(containerURL: directory, afterIntentWrite: gate.check),
                restrictions: restrictions, scheduler: RecordingScheduler(),
                recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
            )
            let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
            let id = try XCTUnwrap(initial.blocks.first?.id)
            restrictions.reset()
            gate.failNext = true
            XCTAssertThrowsError(
                try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) {
                    try LockCollectionStateMachine.activate(
                        &$0, blockID: id, at: self.noon, elapsedTime: self.reading(100))
                })
            XCTAssertTrue(restrictions.applied.isEmpty)
            if removePrimary {
                try FileManager.default.removeItem(at: directory.appendingPathComponent("lock-state-v1.json"))
            }
            let recovered = try runtime.reconcile(at: noon.addingTimeInterval(1), elapsedTime: reading(101))
            XCTAssertTrue(try XCTUnwrap(recovered.block(id: id)).state.blocksTargets)
            XCTAssertEqual(recovered.block(id: id)?.state.activatedAt, noon)
        }
    }

    func testPendingActivationStaysBlockedWhileAnotherBlockRelocksDuringRecovery() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let restrictions = RecordingRestrictions()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory, beforeWrite: gate.check),
            restrictions: restrictions, scheduler: RecordingScheduler(),
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let initial = try activateFirstBlock(using: runtime)
        let firstID = try XCTUnwrap(initial.blocks.first?.id)
        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) {
            try LockCollectionStateMachine.requestBreak(
                &$0, blockID: firstID, at: self.noon, elapsedTime: self.reading(100))
        }
        _ = try runtime.reconcile(at: noon.addingTimeInterval(3_600), elapsedTime: reading(3_700))
        let second = LockBlock(name: "Second")
        gate.failNext = true
        XCTAssertThrowsError(
            try runtime.mutate(wallClockNow: noon.addingTimeInterval(3_601), elapsedTime: reading(3_701)) {
                $0.blocks.append(second)
                try LockCollectionStateMachine.activate(
                    &$0, blockID: second.id, at: self.noon.addingTimeInterval(3_601), elapsedTime: self.reading(3_701))
            })
        restrictions.reset()
        gate.failNext = true
        XCTAssertThrowsError(try runtime.reconcile(at: noon.addingTimeInterval(4_500), elapsedTime: reading(4_600)))
        XCTAssertFalse(restrictions.applied.isEmpty)
        XCTAssertTrue(
            restrictions.applied.allSatisfy {
                $0.block(id: firstID)?.state.blocksTargets == true
                    && $0.block(id: second.id)?.state.blocksTargets == true
            })
        let final = try runtime.reconcile(at: noon.addingTimeInterval(4_501), elapsedTime: reading(4_601))
        XCTAssertEqual(final.activeBlocks.count, 2)
    }

    func testSecondActivationRetainsOriginalIntentBaseAcrossRepeatedWriteFailures() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory, beforeWrite: gate.check),
            restrictions: RecordingRestrictions(), scheduler: RecordingScheduler(),
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
        let firstID = try XCTUnwrap(initial.blocks.first?.id)
        gate.failNext = true
        XCTAssertThrowsError(
            try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) {
                try LockCollectionStateMachine.activate(
                    &$0, blockID: firstID, at: self.noon, elapsedTime: self.reading(100))
            })
        let second = LockBlock(name: "Second")
        gate.failNext = true
        XCTAssertThrowsError(
            try runtime.mutate(wallClockNow: noon.addingTimeInterval(1), elapsedTime: reading(101)) {
                $0.blocks.append(second)
                try LockCollectionStateMachine.activate(
                    &$0, blockID: second.id, at: self.noon.addingTimeInterval(1), elapsedTime: self.reading(101))
            })
        let recovered = try runtime.reconcile(at: noon.addingTimeInterval(2), elapsedTime: reading(102))
        XCTAssertEqual(Set(recovered.activeBlocks.map(\.id)), [firstID, second.id])
    }

    func testCommittedPrimaryWinsOverStaleActivationIntentAfterFullUnlock() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory, beforeIntentClear: gate.check),
            restrictions: RecordingRestrictions(), scheduler: RecordingScheduler(),
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
        let id = try XCTUnwrap(initial.blocks.first?.id)
        gate.failNext = true
        XCTAssertThrowsError(
            try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) {
                try LockCollectionStateMachine.activate(&$0, blockID: id, at: self.noon, elapsedTime: self.reading(100))
            })
        let intentURL = directory.appendingPathComponent("activation-intent-v1.json")
        let staleIntent = try Data(contentsOf: intentURL)
        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) {
            try LockCollectionStateMachine.requestEnd(&$0, blockID: id, at: self.noon, elapsedTime: self.reading(100))
        }
        XCTAssertFalse(
            try runtime.reconcile(at: noon.addingTimeInterval(3_600), elapsedTime: reading(3_700)).hasActiveBlocks)
        try staleIntent.write(to: intentURL)
        let recovered = try runtime.reconcile(at: noon.addingTimeInterval(3_601), elapsedTime: reading(3_701))
        XCTAssertFalse(recovered.hasActiveBlocks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentURL.path))
    }

    func testPrimaryWriteFailureDuringMixedTransitionNeverAppliesRelaxation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let restrictions = RecordingRestrictions()
        let scheduler = RecordingScheduler()
        let repository = LockRepository(containerURL: directory, beforeWrite: gate.check)
        let runtime = LocalLockRuntime(
            repository: repository,
            restrictions: restrictions,
            scheduler: scheduler,
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let (firstID, secondID) = try prepareSimultaneousMixedTransition(using: runtime)
        restrictions.reset()
        gate.failNext = true

        XCTAssertThrowsError(
            try runtime.reconcile(
                at: noon.addingTimeInterval(4_500),
                elapsedTime: reading(4_600)
            )
        )

        let stored = try runtime.load()
        XCTAssertEqual(stored.block(id: firstID)?.state.phase, .breakActive)
        XCTAssertEqual(stored.block(id: secondID)?.state.phase, .waitingForBreak)
        XCTAssertEqual(restrictions.applied.count, 1)
        XCTAssertTrue(restrictions.applied[0].blocks.allSatisfy(\.state.blocksTargets))
    }

    func testPrimaryWriteFailureDuringMixedRelockAndEndNeverAppliesRelaxation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let restrictions = RecordingRestrictions()
        let scheduler = RecordingScheduler()
        let repository = LockRepository(containerURL: directory, beforeWrite: gate.check)
        let runtime = LocalLockRuntime(
            repository: repository,
            restrictions: restrictions,
            scheduler: scheduler,
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let (firstID, secondID) = try prepareSimultaneousRelockAndEnd(using: runtime)
        restrictions.reset()
        gate.failNext = true

        XCTAssertThrowsError(
            try runtime.reconcile(
                at: noon.addingTimeInterval(4_500),
                elapsedTime: reading(4_600)
            )
        )

        let stored = try runtime.load()
        XCTAssertEqual(stored.block(id: firstID)?.state.phase, .breakActive)
        XCTAssertEqual(stored.block(id: secondID)?.state.phase, .waitingForEnd)
        XCTAssertEqual(restrictions.applied.count, 1)
        XCTAssertTrue(restrictions.applied[0].activeBlocks.allSatisfy(\.state.blocksTargets))
    }

    func testActivationReconcilesAStaleExpiredBreakBeforeApplyingAllStores() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let restrictions = RecordingRestrictions()
        let scheduler = RecordingScheduler()
        let repository = LockRepository(containerURL: directory, beforeWrite: gate.check)
        let runtime = LocalLockRuntime(
            repository: repository,
            restrictions: restrictions,
            scheduler: scheduler,
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
        let firstID = try XCTUnwrap(initial.blocks.first?.id)
        let second = LockBlock(name: "Second")
        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
            collection.blocks.append(second)
            try LockCollectionStateMachine.activate(
                &collection,
                blockID: firstID,
                at: noon,
                elapsedTime: reading(100)
            )
            try LockCollectionStateMachine.requestBreak(
                &collection,
                blockID: firstID,
                at: noon,
                elapsedTime: reading(100)
            )
        }
        _ = try runtime.reconcile(
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )
        gate.failNext = true
        XCTAssertThrowsError(
            try runtime.reconcile(
                at: noon.addingTimeInterval(4_500),
                elapsedTime: reading(4_600)
            )
        )
        XCTAssertEqual(try runtime.load().block(id: firstID)?.state.phase, .breakActive)
        restrictions.reset()

        let activated = try runtime.mutate(
            wallClockNow: noon.addingTimeInterval(4_501),
            elapsedTime: reading(4_601)
        ) { collection in
            try LockCollectionStateMachine.activate(
                &collection,
                blockID: second.id,
                at: noon.addingTimeInterval(4_501),
                elapsedTime: reading(4_601)
            )
        }

        XCTAssertEqual(activated.block(id: firstID)?.state.phase, .locked)
        XCTAssertEqual(activated.block(id: second.id)?.state.phase, .locked)
        XCTAssertEqual(restrictions.applied.count, 2)
        XCTAssertEqual(restrictions.applied[0].activeBlocks.map(\.id), [firstID])
        XCTAssertEqual(Set(restrictions.applied[1].activeBlocks.map(\.id)), Set([firstID, second.id]))
    }

    func testRequestReconcilesAStaleExpiredBreakBeforeApplyingAllStores() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let restrictions = RecordingRestrictions()
        let scheduler = RecordingScheduler()
        let repository = LockRepository(containerURL: directory, beforeWrite: gate.check)
        let runtime = LocalLockRuntime(
            repository: repository,
            restrictions: restrictions,
            scheduler: scheduler,
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let (firstID, secondID) = try activateTwoBlocks(using: runtime)
        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
            try LockCollectionStateMachine.requestBreak(
                &collection,
                blockID: firstID,
                at: noon,
                elapsedTime: reading(100)
            )
        }
        _ = try runtime.reconcile(
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )
        gate.failNext = true
        XCTAssertThrowsError(
            try runtime.reconcile(
                at: noon.addingTimeInterval(4_500),
                elapsedTime: reading(4_600)
            )
        )
        restrictions.reset()

        let requested = try runtime.mutate(
            wallClockNow: noon.addingTimeInterval(4_501),
            elapsedTime: reading(4_601)
        ) { collection in
            try LockCollectionStateMachine.requestBreak(
                &collection,
                blockID: secondID,
                at: noon.addingTimeInterval(4_501),
                elapsedTime: reading(4_601)
            )
        }

        XCTAssertEqual(requested.block(id: firstID)?.state.phase, .locked)
        XCTAssertEqual(requested.block(id: secondID)?.state.phase, .waitingForBreak)
        XCTAssertEqual(restrictions.applied.count, 1)
        XCTAssertTrue(restrictions.applied[0].activeBlocks.allSatisfy(\.state.blocksTargets))
    }

    func testFailedUserMutationStillCommitsFullReconciliation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let restrictions = RecordingRestrictions()
        let scheduler = RecordingScheduler()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory, beforeWrite: gate.check),
            restrictions: restrictions,
            scheduler: scheduler,
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let (expiredID, draftID) = try prepareStaleExpiredBreak(
            using: runtime,
            writeGate: gate
        )
        restrictions.reset()

        XCTAssertThrowsError(
            try runtime.mutate(
                wallClockNow: noon.addingTimeInterval(4_501),
                elapsedTime: reading(4_601)
            ) { collection in
                let draftIndex = try collection.index(of: draftID)
                collection.blocks[draftIndex].name = "Partial change"
                throw SimulatedMutationError.failed
            }
        ) { error in
            XCTAssertTrue(error is SimulatedMutationError)
        }

        let stored = try runtime.load()
        XCTAssertEqual(stored.block(id: expiredID)?.state.phase, .locked)
        XCTAssertEqual(stored.block(id: draftID)?.name, "Second")
        XCTAssertEqual(restrictions.applied.count, 1)
        XCTAssertTrue(restrictions.applied[0].block(id: expiredID)?.state.blocksTargets == true)
    }

    func testPrimaryWriteFailureOverridesUserErrorDuringRequiredReconciliation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let restrictions = RecordingRestrictions()
        let scheduler = RecordingScheduler()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory, beforeWrite: gate.check),
            restrictions: restrictions,
            scheduler: scheduler,
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let (expiredID, draftID) = try prepareStaleExpiredBreak(
            using: runtime,
            writeGate: gate
        )
        restrictions.reset()
        gate.failNext = true

        XCTAssertThrowsError(
            try runtime.mutate(
                wallClockNow: noon.addingTimeInterval(4_501),
                elapsedTime: reading(4_601)
            ) { collection in
                let draftIndex = try collection.index(of: draftID)
                collection.blocks[draftIndex].name = "Partial change"
                throw SimulatedMutationError.failed
            }
        ) { error in
            XCTAssertTrue(error is SimulatedWriteError)
        }

        let stored = try runtime.load()
        XCTAssertEqual(stored.block(id: expiredID)?.state.phase, .breakActive)
        XCTAssertEqual(stored.block(id: draftID)?.name, "Second")
        XCTAssertEqual(restrictions.applied.count, 1)
        XCTAssertTrue(restrictions.applied[0].block(id: expiredID)?.state.blocksTargets == true)
    }

    func testScheduleFailureOverridesUserErrorDuringRequiredReconciliation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WriteFailureGate()
        let restrictions = RecordingRestrictions()
        let scheduler = RecordingScheduler()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory, beforeWrite: gate.check),
            restrictions: restrictions,
            scheduler: scheduler,
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )
        let (expiredID, draftID) = try prepareStaleExpiredBreak(
            using: runtime,
            writeGate: gate
        )
        restrictions.reset()
        scheduler.failsNextEnsure = true

        XCTAssertThrowsError(
            try runtime.mutate(
                wallClockNow: noon.addingTimeInterval(4_501),
                elapsedTime: reading(4_601)
            ) { collection in
                let draftIndex = try collection.index(of: draftID)
                collection.blocks[draftIndex].name = "Partial change"
                throw SimulatedMutationError.failed
            }
        ) { error in
            XCTAssertEqual(error as? TransitionSchedulerError, .tooManyActiveSchedules)
        }

        let stored = try runtime.load()
        XCTAssertEqual(stored.block(id: expiredID)?.state.phase, .breakActive)
        XCTAssertEqual(stored.block(id: draftID)?.name, "Second")
        XCTAssertEqual(restrictions.applied.count, 1)
        XCTAssertTrue(restrictions.applied[0].block(id: expiredID)?.state.blocksTargets == true)
    }

    func testRecoveryWriteFailureDuringMixedTransitionNeverAppliesRelaxation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let restrictions = RecordingRestrictions()
        let scheduler = RecordingScheduler()
        let recoveryPolicies = FailureInjectingRecoveryStore()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory),
            restrictions: restrictions,
            scheduler: scheduler,
            recoveryPolicies: recoveryPolicies
        )
        let (firstID, secondID) = try prepareSimultaneousMixedTransition(using: runtime)
        restrictions.reset()
        recoveryPolicies.failLoad = true
        recoveryPolicies.failSave = true

        XCTAssertThrowsError(
            try runtime.reconcile(
                at: noon.addingTimeInterval(4_500),
                elapsedTime: reading(4_600)
            )
        )

        let stored = try runtime.load()
        XCTAssertEqual(stored.block(id: firstID)?.state.phase, .breakActive)
        XCTAssertEqual(stored.block(id: secondID)?.state.phase, .waitingForBreak)
        XCTAssertEqual(restrictions.applied.count, 1)
        XCTAssertTrue(restrictions.applied[0].activeBlocks.allSatisfy(\.state.blocksTargets))
    }

    func testRecoveryWriteFailureDuringMixedRelockAndEndNeverAppliesRelaxation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let restrictions = RecordingRestrictions()
        let scheduler = RecordingScheduler()
        let recoveryPolicies = FailureInjectingRecoveryStore()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory),
            restrictions: restrictions,
            scheduler: scheduler,
            recoveryPolicies: recoveryPolicies
        )
        let (firstID, secondID) = try prepareSimultaneousRelockAndEnd(using: runtime)
        restrictions.reset()
        recoveryPolicies.failLoad = true
        recoveryPolicies.failSave = true

        XCTAssertThrowsError(
            try runtime.reconcile(
                at: noon.addingTimeInterval(4_500),
                elapsedTime: reading(4_600)
            )
        )

        let stored = try runtime.load()
        XCTAssertEqual(stored.block(id: firstID)?.state.phase, .breakActive)
        XCTAssertEqual(stored.block(id: secondID)?.state.phase, .waitingForEnd)
        XCTAssertEqual(restrictions.applied.count, 1)
        XCTAssertTrue(restrictions.applied[0].activeBlocks.allSatisfy(\.state.blocksTargets))
    }

    func testFailedV1MigrationRetryUsesSameStoreSlotAndUnlockClearsIt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var legacy = LockState()
        try LockStateMachine.activate(
            &legacy,
            policy: LockPolicy(),
            at: noon,
            elapsedTime: reading(100)
        )
        legacy.revision = 4
        try JSONEncoder().encode(legacy).write(
            to: directory.appendingPathComponent("lock-state-v1.json")
        )

        let gate = WriteFailureGate()
        gate.failNext = true
        let restrictions = RecordingRestrictions()
        let repository = LockRepository(containerURL: directory, beforeWrite: gate.check)
        let runtime = LocalLockRuntime(
            repository: repository,
            restrictions: restrictions,
            scheduler: RecordingScheduler(),
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )

        XCTAssertThrowsError(try runtime.reconcile(at: noon, elapsedTime: reading(100)))
        XCTAssertEqual(restrictions.applied.last?.activeBlocks.first?.id, HardPauseConstants.legacyBlockID)
        XCTAssertEqual(restrictions.applied.last?.activeBlocks.first?.state.storeSlot, 0)

        let migrated = try runtime.reconcile(at: noon, elapsedTime: reading(100))
        XCTAssertEqual(migrated.activeBlocks.first?.id, HardPauseConstants.legacyBlockID)
        XCTAssertEqual(migrated.activeBlocks.first?.state.storeSlot, 0)

        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
            try LockCollectionStateMachine.requestEnd(
                &collection,
                blockID: HardPauseConstants.legacyBlockID,
                at: noon,
                elapsedTime: reading(100)
            )
        }
        let ended = try runtime.reconcile(
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )

        XCTAssertEqual(ended.blocks.first?.state.phase, .inactive)
        XCTAssertNil(ended.blocks.first?.state.storeSlot)
        XCTAssertEqual(restrictions.applied.last?.blocks.first?.id, HardPauseConstants.legacyBlockID)
        XCTAssertEqual(restrictions.applied.last?.blocks.first?.state.phase, .inactive)
    }

    func testActiveReplacementStoreIsAppliedBeforeLegacyStoreIsCleared() throws {
        let stores = RecordingStoreBackend()
        let service = RestrictionService(stores: stores)
        var state = LockState()
        try LockStateMachine.activate(
            &state,
            policy: LockPolicy(),
            at: noon,
            elapsedTime: reading(100)
        )
        state.storeSlot = 0

        service.apply(
            LockCollection(
                blocks: [
                    LockBlock(
                        id: HardPauseConstants.legacyBlockID,
                        name: "My pause",
                        draftPolicy: state.policy,
                        state: state
                    )
                ]
            )
        )

        XCTAssertEqual(
            Array(stores.events.prefix(2)),
            [.apply(slot: 0, phase: .locked), .clearLegacy]
        )
    }

    func testInactiveV1MigrationClearsLegacyStore() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONEncoder().encode(LockState()).write(
            to: directory.appendingPathComponent("lock-state-v1.json")
        )
        let stores = RecordingStoreBackend()
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory),
            restrictions: RestrictionService(stores: stores),
            scheduler: RecordingScheduler(),
            recoveryPolicies: RecoveryPolicyRepository(containerURL: directory)
        )

        let migrated = try runtime.reconcile(at: noon, elapsedTime: reading(100))

        XCTAssertFalse(migrated.hasActiveBlocks)
        XCTAssertEqual(stores.events.first, .clearLegacy)
        XCTAssertEqual(stores.legacyClearCount, 1)
    }

    private func activateFirstBlock(using runtime: LocalLockRuntime) throws -> LockCollection {
        let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
        let id = try XCTUnwrap(initial.blocks.first?.id)
        return try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
            try LockCollectionStateMachine.activate(
                &collection,
                blockID: id,
                at: noon,
                elapsedTime: reading(100)
            )
        }
    }

    private func activateTwoBlocks(using runtime: LocalLockRuntime) throws -> (UUID, UUID) {
        let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
        let firstID = try XCTUnwrap(initial.blocks.first?.id)
        let second = LockBlock(name: "Second")
        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
            collection.blocks.append(second)
            try LockCollectionStateMachine.activate(
                &collection,
                blockID: firstID,
                at: noon,
                elapsedTime: reading(100)
            )
            try LockCollectionStateMachine.activate(
                &collection,
                blockID: second.id,
                at: noon,
                elapsedTime: reading(100)
            )
        }
        return (firstID, second.id)
    }

    private func prepareSimultaneousMixedTransition(
        using runtime: LocalLockRuntime
    ) throws -> (UUID, UUID) {
        let (firstID, secondID) = try activateTwoBlocks(using: runtime)
        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
            try LockCollectionStateMachine.requestBreak(
                &collection,
                blockID: firstID,
                at: noon,
                elapsedTime: reading(100)
            )
        }
        _ = try runtime.mutate(
            wallClockNow: noon.addingTimeInterval(900),
            elapsedTime: reading(1_000)
        ) { collection in
            try LockCollectionStateMachine.requestBreak(
                &collection,
                blockID: secondID,
                at: noon.addingTimeInterval(900),
                elapsedTime: reading(1_000)
            )
        }
        _ = try runtime.reconcile(
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )
        return (firstID, secondID)
    }

    private func prepareStaleExpiredBreak(
        using runtime: LocalLockRuntime,
        writeGate: WriteFailureGate
    ) throws -> (UUID, UUID) {
        let initial = try runtime.reconcile(at: noon, elapsedTime: reading(100))
        let firstID = try XCTUnwrap(initial.blocks.first?.id)
        let second = LockBlock(name: "Second")
        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
            collection.blocks.append(second)
            try LockCollectionStateMachine.activate(
                &collection,
                blockID: firstID,
                at: noon,
                elapsedTime: reading(100)
            )
            try LockCollectionStateMachine.requestBreak(
                &collection,
                blockID: firstID,
                at: noon,
                elapsedTime: reading(100)
            )
        }
        _ = try runtime.reconcile(
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )
        writeGate.failNext = true
        XCTAssertThrowsError(
            try runtime.reconcile(
                at: noon.addingTimeInterval(4_500),
                elapsedTime: reading(4_600)
            )
        )
        XCTAssertEqual(try runtime.load().block(id: firstID)?.state.phase, .breakActive)
        return (firstID, second.id)
    }

    private func prepareSimultaneousRelockAndEnd(
        using runtime: LocalLockRuntime
    ) throws -> (UUID, UUID) {
        let (firstID, secondID) = try activateTwoBlocks(using: runtime)
        _ = try runtime.mutate(wallClockNow: noon, elapsedTime: reading(100)) { collection in
            try LockCollectionStateMachine.requestBreak(
                &collection,
                blockID: firstID,
                at: noon,
                elapsedTime: reading(100)
            )
        }
        _ = try runtime.mutate(
            wallClockNow: noon.addingTimeInterval(900),
            elapsedTime: reading(1_000)
        ) { collection in
            try LockCollectionStateMachine.requestEnd(
                &collection,
                blockID: secondID,
                at: noon.addingTimeInterval(900),
                elapsedTime: reading(1_000)
            )
        }
        _ = try runtime.reconcile(
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )
        return (firstID, secondID)
    }

    private func withRuntime(
        _ body: (
            LocalLockRuntime,
            RecordingRestrictions,
            RecordingScheduler,
            URL,
            RecoveryPolicyRepository
        ) throws -> Void
    ) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let restrictions = RecordingRestrictions()
        let scheduler = RecordingScheduler()
        let recoveryPolicies = RecoveryPolicyRepository(containerURL: directory)
        let runtime = LocalLockRuntime(
            repository: LockRepository(containerURL: directory),
            restrictions: restrictions,
            scheduler: scheduler,
            recoveryPolicies: recoveryPolicies
        )
        try body(runtime, restrictions, scheduler, directory, recoveryPolicies)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func reading(
        _ durationSinceBoot: TimeInterval,
        boot: String = "boot-a"
    ) -> ElapsedTimeReading {
        ElapsedTimeReading(durationSinceBoot: durationSinceBoot, bootIdentifier: boot)
    }
}

private final class RecordingRestrictions: RestrictionApplying {
    private(set) var applied: [LockCollection] = []
    var onApply: ((LockCollection) -> Void)?

    func apply(_ collection: LockCollection) {
        applied.append(collection)
        onApply?(collection)
    }

    func reset() {
        applied.removeAll()
    }
}

private final class RecordingScheduler: TransitionScheduling {
    var intervals: [UUID: DateInterval] = [:]
    var failsNextEnsure = false

    func ensureSchedules(for collection: LockCollection) throws {
        intervals = Dictionary(
            uniqueKeysWithValues: collection.blocks.compactMap { block in
                TransitionScheduleProjection.registeredInterval(for: block.state).map {
                    (block.id, $0)
                }
            })
        if failsNextEnsure {
            failsNextEnsure = false
            throw TransitionSchedulerError.tooManyActiveSchedules
        }
    }

    func hasSchedule(for block: LockBlock) -> Bool {
        let expected = TransitionScheduleProjection.registeredInterval(for: block.state)
        return expected != nil && intervals[block.id] == expected
    }
}

private final class DestructiveThenRecoveringScheduler: TransitionScheduling {
    private(set) var intervals: [UUID: DateInterval] = [:]
    private var blockIDToDestroy: UUID?

    func destroyScheduleAndFailNext(for blockID: UUID) {
        blockIDToDestroy = blockID
    }

    func ensureSchedules(for collection: LockCollection) throws {
        intervals = Dictionary(
            uniqueKeysWithValues: collection.blocks.compactMap { block in
                TransitionScheduleProjection.registeredInterval(for: block.state).map {
                    (block.id, $0)
                }
            })
        if let blockIDToDestroy {
            self.blockIDToDestroy = nil
            intervals[blockIDToDestroy] = nil
            throw TransitionSchedulerError.scheduleRestoreFailed
        }
    }

    func hasSchedule(for block: LockBlock) -> Bool {
        let expected = TransitionScheduleProjection.registeredInterval(for: block.state)
        return expected != nil && intervals[block.id] == expected
    }
}

private final class AmbiguousThenRecoveringScheduler: TransitionScheduling {
    private(set) var intervals: [UUID: DateInterval] = [:]
    var failNextReplacementAfterSideEffect = false

    func ensureSchedules(for collection: LockCollection) throws {
        intervals = Dictionary(
            uniqueKeysWithValues: collection.blocks.compactMap { block in
                TransitionScheduleProjection.registeredInterval(for: block.state).map {
                    (block.id, $0)
                }
            })
        if failNextReplacementAfterSideEffect {
            failNextReplacementAfterSideEffect = false
            throw TransitionSchedulerError.scheduleRestoreFailed
        }
    }

    func hasSchedule(for block: LockBlock) -> Bool {
        let expected = TransitionScheduleProjection.registeredInterval(for: block.state)
        return expected != nil && intervals[block.id] == expected
    }
}

private final class RecordingStoreBackend: RestrictionStoreApplying {
    private(set) var slots: [Int] = []
    private(set) var states: [LockState?] = []
    private(set) var legacyClearCount = 0
    private(set) var events: [RecordingStoreEvent] = []

    func apply(_ state: LockState?, toSlot slot: Int) {
        slots.append(slot)
        states.append(state)
        events.append(.apply(slot: slot, phase: state?.phase))
    }

    func clearLegacyStore() {
        legacyClearCount += 1
        events.append(.clearLegacy)
    }

    func reset() {
        slots = []
        states = []
        legacyClearCount = 0
        events = []
    }
}

private enum RecordingStoreEvent: Equatable {
    case apply(slot: Int, phase: LockPhase?)
    case clearLegacy
}

private enum SimulatedWriteError: Error {
    case failed
}

private enum SimulatedMutationError: Error {
    case failed
}

private final class WriteFailureGate {
    var failNext = false

    func check() throws {
        if failNext {
            failNext = false
            throw SimulatedWriteError.failed
        }
    }
}

private enum SimulatedRecoveryError: Error {
    case failed
}

private final class FailureInjectingRecoveryStore: RecoveryPolicyStoring {
    var failLoad = false
    var failSave = false
    private var snapshot: RecoverySnapshot?

    func load() throws -> RecoverySnapshot? {
        if failLoad { throw SimulatedRecoveryError.failed }
        return snapshot
    }

    func save(_ snapshot: RecoverySnapshot) throws {
        if failSave { throw SimulatedRecoveryError.failed }
        self.snapshot = snapshot
    }

    func clear() throws {
        snapshot = nil
    }
}
