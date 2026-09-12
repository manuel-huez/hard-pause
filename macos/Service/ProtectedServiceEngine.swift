import Foundation

private struct SafetyProjection {
    let restrictions: EffectiveRestrictions
    let state: ProtectedState
}

final class ProtectedServiceEngine: @unchecked Sendable {
    private let stateStore: ProtectedStateStoring
    private let enforcer: ProtectionEnforcing
    private let clock: ServiceClock
    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "org.hardpause.service.timer", qos: .utility)
    private var timer: DispatchSourceTimer?

    private var state: ProtectedState
    private var pendingSafetyProjection: SafetyProjection?
    private var pendingCommitCandidate: ProtectedState?
    private var journalCleanupPending = false
    private var enforcementIssues: [ProtectionIssue] = []
    private var runtimeIssues: [ProtectionIssue] = []
    private var applicationIssues: [ProtectionIssue] = []
    private var recentClosures: [ClosedApplicationNotice] = []
    private var lastAppliedAt: Date?
    private var lastCheckpointContinuous: TimeInterval
    private var lastApplicationScanContinuous: TimeInterval
    private var lastRetryContinuous: TimeInterval
    private var needsEnforcementRetry = false

    private let checkpointInterval: TimeInterval = 30
    private let applicationScanInterval: TimeInterval = 2
    private let enforcementRetryInterval: TimeInterval = 5

    init(
        stateStore: ProtectedStateStoring,
        enforcer: ProtectionEnforcing,
        clock: ServiceClock = SystemServiceClock()
    ) throws {
        self.stateStore = stateStore
        self.enforcer = enforcer
        self.clock = clock
        state = try stateStore.load()
        let reading = clock.read()
        lastCheckpointContinuous = reading.continuousTime
        lastApplicationScanContinuous = reading.continuousTime
        lastRetryContinuous = reading.continuousTime
        do {
            try reconcileLocked(at: reading, forceCheckpoint: true)
        } catch {
            recordRuntimeIssue(
                code: "state_checkpoint_failed",
                message: error.localizedDescription,
                blockIDs: currentSafetyProjection().restrictions.contributingBlockIDs
            )
        }
        applyCurrentRestrictionsLocked(at: reading.wallTime)
    }

    deinit { timer?.cancel() }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    func list() -> ProtectedServiceSnapshot {
        withLock {
            let reading = clock.read()
            do {
                try resumePendingCommitLocked(at: reading)
                try reconcileLocked(at: reading, forceCheckpoint: false)
            } catch {
                recordRuntimeIssue(
                    code: "state_checkpoint_failed",
                    message: error.localizedDescription,
                    blockIDs: currentSafetyProjection().restrictions.contributingBlockIDs
                )
            }
            return snapshotLocked(at: reading.wallTime)
        }
    }

    func create(_ request: ProtectedCreateRequest) throws -> ProtectedServiceSnapshot {
        try mutate { state, _ in _ = try state.create(request.draft) }
    }

    func update(_ request: ProtectedUpdateRequest) throws -> ProtectedServiceSnapshot {
        try mutate { state, _ in
            try state.update(
                id: request.id,
                expectedRevision: request.expectedRevision,
                draft: request.draft
            )
        }
    }

    func delete(_ request: ProtectedRevisionRequest) throws -> ProtectedServiceSnapshot {
        try mutate { state, _ in
            try state.delete(id: request.id, expectedRevision: request.expectedRevision)
        }
    }

    func activate(_ request: ProtectedRevisionRequest) throws -> ProtectedServiceSnapshot {
        try mutate { state, reading in
            try state.activate(
                id: request.id,
                expectedRevision: request.expectedRevision,
                at: reading
            )
        }
    }

    func requestBreak(_ request: ProtectedBlockRequest) throws -> ProtectedServiceSnapshot {
        try mutate { state, reading in
            try state.request(.breakAccess, id: request.id, at: reading)
        }
    }

    func requestEnd(_ request: ProtectedBlockRequest) throws -> ProtectedServiceSnapshot {
        try mutate { state, reading in
            try state.request(.fullUnlock, id: request.id, at: reading)
        }
    }

    func tickForTesting() { tick() }

    private func mutate(
        _ operation: (inout ProtectedState, ClockReading) throws -> Void
    ) throws -> ProtectedServiceSnapshot {
        try withLock {
            let reading = clock.read()
            try resumePendingCommitLocked(at: reading)
            try reconcileLocked(at: reading, forceCheckpoint: false)
            var candidate = state
            try operation(&candidate, reading)
            try commitLocked(
                candidate,
                at: reading,
                saveRequired: true,
                durableIntentRequiredBeforeTightening: true
            )
            return snapshotLocked(at: reading.wallTime)
        }
    }

    private func tick() {
        withLock {
            let reading = clock.read()
            do {
                try resumePendingCommitLocked(at: reading)
                try reconcileLocked(at: reading, forceCheckpoint: false)
            } catch {
                recordRuntimeIssue(
                    code: "state_checkpoint_failed",
                    message: error.localizedDescription,
                    blockIDs: currentSafetyProjection().restrictions.contributingBlockIDs
                )
            }
            if reading.continuousTime - lastApplicationScanContinuous >= applicationScanInterval {
                closeApplicationsLocked(at: reading.wallTime)
                lastApplicationScanContinuous = reading.continuousTime
            }
            if needsEnforcementRetry,
                reading.continuousTime - lastRetryContinuous >= enforcementRetryInterval
            {
                applyCurrentRestrictionsLocked(at: reading.wallTime)
                lastRetryContinuous = reading.continuousTime
            }
        }
    }

    private func reconcileLocked(at reading: ClockReading, forceCheckpoint: Bool) throws {
        guard state.blocks.contains(where: { $0.activation != nil }) else { return }
        let oldKinds = phaseKinds(in: state)
        var candidate = state
        _ = candidate.advance(to: reading)
        let newKinds = phaseKinds(in: candidate)
        let restrictionsChanged = candidate.effectiveRestrictions() != state.effectiveRestrictions()
        let phaseChanged = oldKinds != newKinds
        let checkpointDue =
            forceCheckpoint
            || reading.continuousTime < lastCheckpointContinuous
            || reading.continuousTime - lastCheckpointContinuous >= checkpointInterval
        if restrictionsChanged || phaseChanged || checkpointDue {
            try commitLocked(
                candidate,
                at: reading,
                saveRequired: true,
                durableIntentRequiredBeforeTightening: false
            )
        } else {
            state = candidate
        }
    }

    private func commitLocked(
        _ candidate: ProtectedState,
        at reading: ClockReading,
        saveRequired: Bool,
        durableIntentRequiredBeforeTightening: Bool
    ) throws {
        let oldRestrictions = state.effectiveRestrictions()
        let candidateRestrictions = candidate.effectiveRestrictions()
        let stagedRestrictions = oldRestrictions.union(candidateRestrictions)
        let needsPrecommitApply = stagedRestrictions != oldRestrictions
        var stagedOutcome = EnforcementOutcome.success
        var intentWasSaved = false

        if needsPrecommitApply {
            do {
                try stateStore.savePendingCandidate(candidate)
                intentWasSaved = true
            } catch {
                recordRuntimeIssue(
                    code: "state_write_failed",
                    message: error.localizedDescription,
                    blockIDs: stagedRestrictions.contributingBlockIDs
                )
                if durableIntentRequiredBeforeTightening { throw error }
            }
            do {
                stagedOutcome = try enforcer.apply(stagedRestrictions, state: candidate, at: reading.wallTime)
                updateOutcome(stagedOutcome, at: reading.wallTime)
                clearRuntimeIssues(codes: ["enforcement_apply_failed"])
            } catch {
                pendingSafetyProjection = SafetyProjection(
                    restrictions: stagedRestrictions,
                    state: candidate
                )
                if intentWasSaved { pendingCommitCandidate = candidate }
                recordRuntimeIssue(
                    code: "enforcement_apply_failed",
                    message: error.localizedDescription,
                    blockIDs: stagedRestrictions.contributingBlockIDs
                )
                needsEnforcementRetry = true
                throw error
            }
        }

        do {
            if saveRequired { try stateStore.save(candidate) }
        } catch {
            pendingSafetyProjection = SafetyProjection(
                restrictions: stagedRestrictions,
                state: candidate
            )
            if intentWasSaved { pendingCommitCandidate = candidate }
            recordRuntimeIssue(
                code: "state_write_failed",
                message: error.localizedDescription,
                blockIDs: stagedRestrictions.contributingBlockIDs
            )
            throw error
        }

        state = candidate
        pendingCommitCandidate = nil
        pendingSafetyProjection = nil
        lastCheckpointContinuous = reading.continuousTime
        clearRuntimeIssues(codes: ["state_write_failed", "state_checkpoint_failed"])
        if intentWasSaved {
            do {
                try stateStore.clearPendingCandidate()
                journalCleanupPending = false
                clearRuntimeIssues(codes: ["transition_journal_cleanup_failed"])
            } catch {
                journalCleanupPending = true
                recordRuntimeIssue(
                    code: "transition_journal_cleanup_failed",
                    message: error.localizedDescription,
                    blockIDs: candidateRestrictions.contributingBlockIDs
                )
                throw error
            }
        }
        if candidateRestrictions != stagedRestrictions {
            do {
                let outcome = try enforcer.apply(
                    candidateRestrictions,
                    state: candidate,
                    at: reading.wallTime
                )
                updateOutcome(outcome, at: reading.wallTime)
                clearRuntimeIssues(codes: ["enforcement_relaxation_failed"])
            } catch {
                recordRuntimeIssue(
                    code: "enforcement_relaxation_failed",
                    message: error.localizedDescription,
                    blockIDs: candidateRestrictions.contributingBlockIDs
                )
                needsEnforcementRetry = true
            }
        } else if needsPrecommitApply {
            updateOutcome(stagedOutcome, at: reading.wallTime)
        }
    }

    private func resumePendingCommitLocked(at reading: ClockReading) throws {
        if journalCleanupPending {
            do {
                try stateStore.clearPendingCandidate()
                journalCleanupPending = false
                clearRuntimeIssues(codes: ["transition_journal_cleanup_failed"])
            } catch {
                recordRuntimeIssue(
                    code: "transition_journal_cleanup_failed",
                    message: error.localizedDescription,
                    blockIDs: state.effectiveRestrictions().contributingBlockIDs
                )
                throw error
            }
        }
        guard var pendingCommitCandidate else { return }
        _ = pendingCommitCandidate.advance(to: reading)
        self.pendingCommitCandidate = pendingCommitCandidate
        try commitLocked(
            pendingCommitCandidate,
            at: reading,
            saveRequired: true,
            durableIntentRequiredBeforeTightening: true
        )
    }

    private func applyCurrentRestrictionsLocked(at date: Date) {
        let projection = currentSafetyProjection()
        do {
            let outcome = try enforcer.apply(
                projection.restrictions,
                state: projection.state,
                at: date
            )
            updateOutcome(outcome, at: date)
            clearRuntimeIssues(codes: ["enforcement_apply_failed"])
        } catch {
            recordRuntimeIssue(
                code: "enforcement_apply_failed",
                message: error.localizedDescription,
                blockIDs: projection.restrictions.contributingBlockIDs
            )
            needsEnforcementRetry = true
        }
    }

    private func closeApplicationsLocked(at date: Date) {
        let projection = currentSafetyProjection()
        let outcome = enforcer.closeApplications(
            projection.restrictions,
            state: projection.state,
            at: date
        )
        applicationIssues = outcome.issues
        appendClosures(outcome.closedApplications)
    }

    private func updateOutcome(_ outcome: EnforcementOutcome, at date: Date) {
        enforcementIssues = outcome.issues.filter { !$0.code.hasPrefix("application_") }
        applicationIssues = outcome.issues.filter { $0.code.hasPrefix("application_") }
        appendClosures(outcome.closedApplications)
        lastAppliedAt = date
        needsEnforcementRetry = !enforcementIssues.isEmpty
    }

    private func appendClosures(_ notices: [ClosedApplicationNotice]) {
        recentClosures = Array((notices + recentClosures).prefix(8))
    }

    private func recordRuntimeIssue(code: String, message: String, blockIDs: [UUID]) {
        runtimeIssues.removeAll { $0.code == code }
        runtimeIssues.insert(
            ProtectionIssue(code: code, message: message, blockIDs: blockIDs),
            at: 0
        )
        runtimeIssues = Array(runtimeIssues.prefix(16))
    }

    private func clearRuntimeIssues(codes: Set<String>) {
        runtimeIssues.removeAll { codes.contains($0.code) }
    }

    private func currentSafetyProjection() -> SafetyProjection {
        pendingSafetyProjection
            ?? SafetyProjection(restrictions: state.effectiveRestrictions(), state: state)
    }

    private func snapshotLocked(at date: Date) -> ProtectedServiceSnapshot {
        let issues = Array((runtimeIssues + enforcementIssues + applicationIssues).prefix(16))
        let status = ProtectionStatus(
            serviceVersion: ProtectedServiceContract.serviceVersion,
            isEnforcing: issues.isEmpty,
            lastAppliedAt: lastAppliedAt,
            issues: issues,
            recentApplicationClosures: recentClosures
        )
        return state.snapshot(at: date, protection: status)
    }

    private func phaseKinds(in state: ProtectedState) -> [UUID: Int] {
        Dictionary(
            uniqueKeysWithValues: state.blocks.map { block in
                let kind: Int
                switch block.activation?.phase() ?? .inactive {
                case .inactive: kind = 0
                case .active: kind = 1
                case .waitingForBreak: kind = 2
                case .waitingForFullUnlock: kind = 3
                case .breakActive: kind = 4
                }
                return (block.id, kind)
            }
        )
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
