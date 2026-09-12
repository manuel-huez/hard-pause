import Foundation
import OSLog

struct LocalLockRuntime {
    private let repository: LockRepository
    private let restrictions: any RestrictionApplying
    private let scheduler: any TransitionScheduling
    private let recoveryPolicies: any RecoveryPolicyStoring
    private let logger = Logger(subsystem: "com.hardpause.app", category: "LockRuntime")

    init(
        repository: LockRepository = LockRepository(),
        restrictions: any RestrictionApplying = RestrictionService(),
        scheduler: any TransitionScheduling = TransitionScheduler(),
        recoveryPolicies: any RecoveryPolicyStoring = RecoveryPolicyRepository()
    ) {
        self.repository = repository
        self.restrictions = restrictions
        self.scheduler = scheduler
        self.recoveryPolicies = recoveryPolicies
    }

    func load() throws -> LockCollection {
        try repository.load()
    }

    func reconcile(
        at date: Date = Date(),
        elapsedTime: ElapsedTimeReading = ElapsedTimeClock.current,
        endWarningFor blockID: UUID? = nil
    ) throws -> LockCollection {
        try mutate(
            wallClockNow: date,
            elapsedTime: elapsedTime,
            rearmEndWarningFor: blockID
        ) { _ in }
    }

    func mutate(
        wallClockNow: Date = Date(),
        elapsedTime: ElapsedTimeReading = ElapsedTimeClock.current,
        rearmEndWarningFor blockID: UUID? = nil,
        _ mutation: (inout LockCollection) throws -> Void
    ) throws -> LockCollection {
        var precommitEnforcement: [BlockEnforcementConfiguration]?
        var mutationFailure: Error?
        let saved = try repository.transaction(
            recover: { failure in
                guard let snapshot = try recoveryPolicies.load(), !snapshot.blocks.isEmpty else {
                    if case .missingState = failure { return nil }
                    throw failure
                }
                return try snapshot.restore(at: wallClockNow, elapsedTime: elapsedTime)
            },
            transform: { collection in
                _ = LockCollectionStateMachine.reconcile(
                    &collection,
                    at: wallClockNow,
                    elapsedTime: elapsedTime
                )
                var mutationCandidate = collection
                do {
                    try mutation(&mutationCandidate)
                    collection = mutationCandidate
                } catch {
                    mutationFailure = error
                }
            },
            prepare: { current, candidate, source in
                try candidate.validateRuntimeMutation(from: current)
                _ = candidate.failClosedBlocksWithoutReliableRelockSchedules(
                    using: scheduler,
                    wallClockNow: wallClockNow,
                    elapsedTime: elapsedTime
                )
                if let blockID,
                    let index = candidate.blocks.firstIndex(where: { $0.id == blockID })
                {
                    let state = candidate.blocks[index].state
                    if let warningDeadline = TransitionScheduleProjection.endWarningDeadline(
                        for: state
                    ),
                        state.effectiveDate(
                            wallClockDate: wallClockNow,
                            elapsedTime: elapsedTime
                        ) < warningDeadline
                    {
                        candidate.blocks[index].state.registeredScheduleStartsAt = nil
                        candidate.blocks[index].state.registeredScheduleEndsAt = nil
                        candidate.blocks[index].state.registeredScheduleWarningTime = nil
                    }
                }
                for index in candidate.blocks.indices {
                    TransitionScheduleProjection.prepareRegistration(
                        for: &candidate.blocks[index].state,
                        wallClockNow: wallClockNow,
                        elapsedTime: elapsedTime
                    )
                }

                let tighteningProjection = candidate.tighteningProjection(from: current)
                let precommitProjection: LockCollection? =
                    if source == .recovered || source == .migrated {
                        tighteningProjection ?? current
                    } else {
                        tighteningProjection
                    }
                if let precommitProjection,
                    precommitProjection.hasActiveBlocks || source == .migrated
                {
                    restrictions.apply(precommitProjection)
                    precommitEnforcement = precommitProjection.enforcementConfiguration
                }

                if candidate.hasActiveBlocks {
                    let snapshot =
                        current.activeIDs.isSubset(of: candidate.activeIDs)
                        ? RecoverySnapshot(collection: candidate)
                        : RecoverySnapshot(collection: current)
                    if candidate.isOnlyRelocking(comparedWith: current) {
                        repairRecoverySnapshotIfPossible(snapshot)
                    } else {
                        try ensureRecoverySnapshot(snapshot)
                    }
                }

                while true {
                    do {
                        try scheduler.ensureSchedules(for: candidate)
                        break
                    } catch {
                        let restorationFailed =
                            (error as? TransitionSchedulerError) == .scheduleRestoreFailed
                        let relockedOpenBlock =
                            candidate.failClosedBlocksWithoutReliableRelockSchedules(
                                using: scheduler,
                                wallClockNow: wallClockNow,
                                elapsedTime: elapsedTime,
                                forceAllOpenBlocks: restorationFailed
                            )
                        guard relockedOpenBlock else { throw error }
                        if let saferProjection = candidate.tighteningProjection(from: current) {
                            restrictions.apply(saferProjection)
                            precommitEnforcement = saferProjection.enforcementConfiguration
                        }
                    }
                }
                let enforcementChanged =
                    current.enforcementConfiguration != candidate.enforcementConfiguration
                let appliedFinalConfiguration =
                    precommitEnforcement == candidate.enforcementConfiguration
                if precommitEnforcement != nil, appliedFinalConfiguration {
                    candidate.enforcementNeedsRefresh = nil
                } else if enforcementChanged {
                    candidate.enforcementNeedsRefresh = true
                }
            },
            afterCommit: { _, saved, _ in
                if saved.enforcementNeedsRefresh == true {
                    restrictions.apply(saved)
                    saved.enforcementNeedsRefresh = nil
                }
                synchronizeRecoverySnapshot(afterCommit: saved)
            }
        )
        if let mutationFailure { throw mutationFailure }
        return saved
    }

    private func ensureRecoverySnapshot(_ snapshot: RecoverySnapshot) throws {
        for block in snapshot.blocks {
            try block.policy.validateManagedSettingsLimits()
        }
        do {
            if try recoveryPolicies.load() == snapshot { return }
        } catch {
            // A valid primary snapshot may replace a damaged recovery copy.
        }
        try recoveryPolicies.save(snapshot)
    }

    private func repairRecoverySnapshotIfPossible(_ snapshot: RecoverySnapshot) {
        do {
            try ensureRecoverySnapshot(snapshot)
        } catch {
            logger.error(
                "Blocking was restored, but its recovery snapshot could not be repaired: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func synchronizeRecoverySnapshot(afterCommit collection: LockCollection) {
        do {
            if collection.hasActiveBlocks {
                try ensureRecoverySnapshot(RecoverySnapshot(collection: collection))
            } else {
                try recoveryPolicies.clear()
            }
        } catch {
            logger.error(
                "Could not synchronize the recovery snapshot: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

private struct BlockEnforcementConfiguration: Equatable {
    let storeSlot: Int
    let blocksTargets: Bool
    let policy: LockPolicy
}

extension LockCollection {
    fileprivate func validateRuntimeMutation(from current: LockCollection) throws {
        guard activeBlocks.count <= Self.maximumActiveBlocks else {
            throw LockCollectionError.maximumActiveBlocks
        }
        guard blocks.allSatisfy({ !LockBlock.normalizedName($0.name).isEmpty }) else {
            throw LockCollectionError.invalidName
        }
        guard Set(blocks.map(\.id)).count == blocks.count else {
            throw LockCollectionError.duplicateBlockIdentifier
        }
        let activeSlots = activeBlocks.compactMap(\.state.storeSlot)
        guard activeSlots.count == activeBlocks.count,
            Set(activeSlots).count == activeSlots.count,
            activeSlots.allSatisfy({ (0..<Self.maximumActiveBlocks).contains($0) }),
            blocks.filter({ !$0.state.isActive }).allSatisfy({ $0.state.storeSlot == nil })
        else {
            throw LockCollectionError.invalidStoreSlot
        }
        let candidateByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        for oldBlock in current.activeBlocks {
            guard let newBlock = candidateByID[oldBlock.id] else {
                throw LockCollectionError.activeBlockCannotBeEdited
            }
            guard newBlock.name == oldBlock.name,
                newBlock.draftPolicy == oldBlock.draftPolicy,
                newBlock.state.policy == oldBlock.state.policy,
                !newBlock.state.isActive || newBlock.state.storeSlot == oldBlock.state.storeSlot
            else {
                throw LockCollectionError.activeBlockCannotBeEdited
            }
        }
    }

    fileprivate var activeIDs: Set<UUID> {
        Set(activeBlocks.map(\.id))
    }

    fileprivate var enforcementConfiguration: [BlockEnforcementConfiguration] {
        activeBlocks.compactMap {
            guard let storeSlot = $0.state.storeSlot else { return nil }
            return BlockEnforcementConfiguration(
                storeSlot: storeSlot,
                blocksTargets: $0.state.blocksTargets,
                policy: $0.state.policy
            )
        }.sorted { $0.storeSlot < $1.storeSlot }
    }

    fileprivate func tighteningProjection(from current: LockCollection) -> LockCollection? {
        var projection = current
        let candidateByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        var tightened = false
        for index in projection.blocks.indices {
            let old = projection.blocks[index]
            guard old.state.isActive,
                let candidate = candidateByID[old.id],
                candidate.state.blocksTargets,
                !old.state.blocksTargets || old.state.policy != candidate.state.policy
            else { continue }
            projection.blocks[index].state = candidate.state
            tightened = true
        }
        return tightened ? projection : nil
    }

    fileprivate mutating func failClosedBlocksWithoutReliableRelockSchedules(
        using scheduler: any TransitionScheduling,
        wallClockNow: Date,
        elapsedTime: ElapsedTimeReading,
        forceAllOpenBlocks: Bool = false
    ) -> Bool {
        var recovered = false
        for index in blocks.indices where blocks[index].state.phase == .breakActive {
            guard forceAllOpenBlocks || !scheduler.hasSchedule(for: blocks[index]) else {
                continue
            }
            LockStateMachine.recoverMissingRelockSchedule(&blocks[index].state)
            TransitionScheduleProjection.prepareRegistration(
                for: &blocks[index].state,
                wallClockNow: wallClockNow,
                elapsedTime: elapsedTime
            )
            recovered = true
        }
        return recovered
    }

    fileprivate func isOnlyRelocking(comparedWith current: LockCollection) -> Bool {
        guard activeIDs == current.activeIDs else { return false }
        let currentByID = Dictionary(uniqueKeysWithValues: current.blocks.map { ($0.id, $0.state) })
        var foundRelock = false
        for block in activeBlocks {
            guard let old = currentByID[block.id], old.policy == block.state.policy else {
                return false
            }
            if old.blocksTargets, !block.state.blocksTargets {
                return false
            }
            if !old.blocksTargets, block.state.blocksTargets {
                foundRelock = true
            }
        }
        return foundRelock
    }
}
