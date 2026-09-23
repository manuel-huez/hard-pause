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
    private var readOnlyUntilFinalize: Bool

    private let checkpointInterval: TimeInterval = 30
    private let applicationScanInterval: TimeInterval = 2
    private let enforcementRetryInterval: TimeInterval = 5

    init(
        stateStore: ProtectedStateStoring,
        enforcer: ProtectionEnforcing,
        clock: ServiceClock = SystemServiceClock(),
        preloadedState: ProtectedState? = nil
    ) throws {
        self.stateStore = stateStore
        self.enforcer = enforcer
        self.clock = clock
        state = try preloadedState ?? stateStore.load()
        readOnlyUntilFinalize = preloadedState != nil
        let reading = clock.read()
        lastCheckpointContinuous = reading.continuousTime
        lastApplicationScanContinuous = reading.continuousTime
        lastRetryContinuous = reading.continuousTime
        if state.liveUpdateGate == nil {
            do {
                try reconcileLocked(at: reading, forceCheckpoint: true)
            } catch {
                recordRuntimeIssue(
                    code: "state_checkpoint_failed",
                    message: error.localizedDescription,
                    blockIDs: currentSafetyProjection().restrictions.contributingBlockIDs
                )
            }
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
                if state.liveUpdateGate == nil {
                    try resumePendingCommitLocked(at: reading)
                    try reconcileLocked(at: reading, forceCheckpoint: false)
                }
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

    func activate(
        _ request: ProtectedRevisionRequest,
        appleLockdownActive: Bool = false
    ) throws -> ProtectedServiceSnapshot {
        try mutate { state, reading in
            if state.blocks.first(where: { $0.id == request.id })?.draft.protectionMode
                == .lockdown,
                !appleLockdownActive
            {
                throw AppleLockdownError.protectionNotActive
            }
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

    func cancelBreak(_ request: ProtectedBlockRequest) throws -> ProtectedServiceSnapshot {
        try mutate { state, reading in
            try state.cancelBreakRequest(id: request.id, at: reading)
        }
    }

    func requestEnd(_ request: ProtectedBlockRequest) throws -> ProtectedServiceSnapshot {
        try mutate { state, reading in
            try state.request(.fullUnlock, id: request.id, at: reading)
        }
    }

    func prepareUpdate(_ request: ProtectedBlockRequest) throws -> ProtectedServiceSnapshot {
        try withLock {
            guard !readOnlyUntilFinalize else { throw ProtectedStateError.updateUnavailable }
            let reading = clock.read()
            guard state.liveUpdateGate == nil else {
                throw ProtectedStateError.updateInProgress
            }
            try resumePendingCommitLocked(at: reading)
            try reconcileLocked(at: reading, forceCheckpoint: false)
            if state.updateGateToken == request.id {
                return snapshotLocked(at: reading.wallTime)
            }
            guard state.updateGateToken == nil else {
                throw ProtectedStateError.updateInProgress
            }
            let snapshot = snapshotLocked(at: reading.wallTime)
            guard state.blocks.allSatisfy({ $0.activation == nil }),
                state.effectiveRestrictions().contributingBlockIDs.isEmpty,
                pendingSafetyProjection == nil,
                pendingCommitCandidate == nil,
                !journalCleanupPending,
                snapshot.protection.isEnforcing,
                snapshot.protection.lastAppliedAt != nil,
                snapshot.protection.issues.isEmpty
            else {
                throw ProtectedStateError.updateUnavailable
            }
            var candidate = state
            try candidate.prepareUpdate(token: request.id)
            try commitLocked(
                candidate,
                at: reading,
                saveRequired: true,
                durableIntentRequiredBeforeTightening: true
            )
            return snapshotLocked(at: reading.wallTime)
        }
    }

    func cancelUpdate(_ request: ProtectedBlockRequest) throws -> ProtectedServiceSnapshot {
        try withLock {
            guard !readOnlyUntilFinalize else { throw ProtectedStateError.updateUnavailable }
            let reading = clock.read()
            guard state.liveUpdateGate == nil else {
                throw ProtectedStateError.updateInProgress
            }
            try resumePendingCommitLocked(at: reading)
            guard state.updateGateToken != nil else {
                return snapshotLocked(at: reading.wallTime)
            }
            var candidate = state
            try candidate.cancelUpdate(token: request.id)
            try commitLocked(
                candidate,
                at: reading,
                saveRequired: true,
                durableIntentRequiredBeforeTightening: true
            )
            return snapshotLocked(at: reading.wallTime)
        }
    }

    func tickForTesting() { tick() }

    func liveUpdateGate() -> ProtectedLiveUpdateGate? { withLock { state.liveUpdateGate } }

    func currentStateDigest() throws -> String {
        try withLock { try ServiceStateDigest.hash(state) }
    }

    func finalizeInactiveMigration(token: UUID) throws -> ProtectedServiceSnapshot {
        try withLock {
            guard readOnlyUntilFinalize,
                state.liveUpdateGate == nil,
                state.blocks.allSatisfy({ $0.activation == nil })
            else { throw ProtectedStateError.updateUnavailable }
            var candidate = state
            candidate.completeInactiveMigration(token: token)
            try stateStore.save(candidate)
            state = candidate
            readOnlyUntilFinalize = false
            return snapshotLocked(at: clock.read().wallTime)
        }
    }

    func beginLiveUpdate(_ gate: ProtectedLiveUpdateGate) throws {
        try withLock {
            guard !readOnlyUntilFinalize else { throw ProtectedStateError.updateUnavailable }
            if let existing = state.liveUpdateGate {
                guard existing == gate else { throw ProtectedStateError.updateInProgress }
                return
            }
            let reading = clock.read()
            try resumePendingCommitLocked(at: reading)
            try reconcileLocked(at: reading, forceCheckpoint: true)
            let health = snapshotLocked(at: reading.wallTime).protection
            guard state.updateGateToken == nil,
                pendingSafetyProjection == nil,
                pendingCommitCandidate == nil,
                !journalCleanupPending,
                health.isEnforcing,
                health.lastAppliedAt != nil,
                health.issues.isEmpty
            else { throw ProtectedStateError.updateUnavailable }
            var candidate = state
            try candidate.beginLiveUpdate(gate)
            try commitLocked(
                candidate,
                at: reading,
                saveRequired: true,
                durableIntentRequiredBeforeTightening: true
            )
            applyCurrentRestrictionsLocked(at: reading.wallTime)
            let status = snapshotLocked(at: reading.wallTime).protection
            guard status.isEnforcing, status.lastAppliedAt != nil else {
                throw ProtectedStateError.updateUnavailable
            }
        }
    }

    func endLiveUpdate(token: UUID, finalized: Bool) throws -> ProtectedServiceSnapshot {
        try withLock {
            guard state.liveUpdateGate?.token == token else {
                throw ProtectedStateError.updateNotOwned
            }
            let reading = clock.read()
            var candidate = state
            try candidate.endLiveUpdate(token: token, finalized: finalized)
            _ = candidate.advance(to: reading)
            try commitLocked(
                candidate,
                at: reading,
                saveRequired: true,
                durableIntentRequiredBeforeTightening: false
            )
            readOnlyUntilFinalize = false
            applyCurrentRestrictionsLocked(at: reading.wallTime)
            return snapshotLocked(at: reading.wallTime)
        }
    }

    func liveUpdateStatus(
        appleStateDigest: String,
        phase: ProtectedLiveUpdatePhase = .frozen
    ) throws -> ProtectedLiveUpdateStatus {
        try withLock {
            guard let gate = state.liveUpdateGate else {
                throw ProtectedStateError.updateUnavailable
            }
            let protection = snapshotLocked(at: clock.read().wallTime).protection
            return ProtectedLiveUpdateStatus(
                phase: phase,
                generation: gate.generation,
                stateDigest: try ServiceStateDigest.hash(state),
                appleStateDigest: appleStateDigest,
                successorDigest: gate.successorDigest,
                isEnforcing: protection.isEnforcing && protection.lastAppliedAt != nil,
                issues: protection.issues
            )
        }
    }

    private func mutate(
        _ operation: (inout ProtectedState, ClockReading) throws -> Void
    ) throws -> ProtectedServiceSnapshot {
        try withLock {
            let reading = clock.read()
            try resumePendingCommitLocked(at: reading)
            guard state.updateGateToken == nil,
                state.liveUpdateGate == nil,
                !readOnlyUntilFinalize
            else {
                throw ProtectedStateError.updateInProgress
            }
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
                if state.liveUpdateGate == nil {
                    try resumePendingCommitLocked(at: reading)
                    try reconcileLocked(at: reading, forceCheckpoint: false)
                }
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
        let plan = PauseCoreTransactionPlan(
            requiresSchedulePrerequisite: false,
            hasTightening: stagedRestrictions != oldRestrictions,
            intentFailurePolicy: durableIntentRequiredBeforeTightening ? .stop : .continueForSafety,
            savesCandidate: saveRequired,
            hasRelaxation: candidateRestrictions != stagedRestrictions
        )
        let stages = plan.orderedStages
        let needsPrecommitApply = stages.contains(.applyTightening)
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
                if plan.intentFailurePolicy == .stop { throw error }
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
            if stages.contains(.saveCandidate) { try stateStore.save(candidate) }
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
        if stages.contains(.applyRelaxation) {
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
            ?? SafetyProjection(
                restrictions: state.liveUpdateGate == nil
                    ? state.effectiveRestrictions() : state.conservativeUpdateRestrictions(),
                state: state
            )
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

final class ProtectedStandbyEngine: @unchecked Sendable {
    private let stateStore: ProtectedStateStoring
    private let enforcer: ProtectionEnforcing
    private let clock: ServiceClock
    private let state: ProtectedState
    private let gate: ProtectedLiveUpdateGate
    private let appleStateDigest: String
    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "org.hardpause.service.standby.timer")
    private var timer: DispatchSourceTimer?
    private var enforcementIssues: [ProtectionIssue] = []
    private var applicationIssues: [ProtectionIssue] = []
    private var lastAppliedAt: Date?
    private var retired = false

    init(
        stateStore: ProtectedStateStoring,
        state: ProtectedState,
        appleStateDigest: String,
        token: UUID,
        runningDigest: String,
        enforcer: ProtectionEnforcing,
        clock: ServiceClock = SystemServiceClock()
    ) throws {
        guard let gate = state.liveUpdateGate,
            gate.token == token,
            gate.successorDigest == runningDigest
        else { throw ProtectedStateError.updateNotOwned }
        self.stateStore = stateStore
        self.state = state
        self.gate = gate
        self.appleStateDigest = appleStateDigest
        self.enforcer = enforcer
        self.clock = clock
        let now = clock.read().wallTime
        let outcome = try enforcer.apply(state.conservativeUpdateRestrictions(), state: state, at: now)
        enforcementIssues = outcome.issues.filter { !$0.code.hasPrefix("application_") }
        applicationIssues = outcome.issues.filter { $0.code.hasPrefix("application_") }
        lastAppliedAt = now
    }

    deinit { timer?.cancel() }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(deadline: .now() + 1, repeating: 2)
        source.setEventHandler { [weak self] in self?.scan() }
        timer = source
        source.resume()
    }

    func readiness(token: UUID) throws -> ProtectedLiveUpdateStatus {
        lock.lock()
        defer { lock.unlock() }
        guard gate.token == token, !retired else { throw ProtectedStateError.updateNotOwned }
        return ProtectedLiveUpdateStatus(
            phase: .standbyReady,
            generation: gate.generation,
            stateDigest: try ServiceStateDigest.hash(state),
            appleStateDigest: appleStateDigest,
            successorDigest: gate.successorDigest,
            isEnforcing: enforcementIssues.isEmpty && applicationIssues.isEmpty
                && lastAppliedAt != nil,
            issues: enforcementIssues + applicationIssues
        )
    }

    func list() -> ProtectedServiceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let issues = enforcementIssues + applicationIssues
        return state.snapshot(
            at: clock.read().wallTime,
            protection: ProtectionStatus(
                serviceVersion: ProtectedServiceContract.serviceVersion,
                isEnforcing: !retired && issues.isEmpty && lastAppliedAt != nil,
                lastAppliedAt: lastAppliedAt,
                issues: issues,
                recentApplicationClosures: []
            )
        )
    }

    func retire(token: UUID) throws -> ProtectedLiveUpdateStatus {
        lock.lock()
        defer { lock.unlock() }
        guard gate.token == token, !retired else { throw ProtectedStateError.updateNotOwned }
        let current = try stateStore.loadReadOnly(requireCurrentFormat: true)
        guard let completion = current.lastLiveUpdateCompletion,
            current.liveUpdateGate == nil,
            completion.token == gate.token,
            completion.generation == gate.generation,
            completion.successorDigest == gate.successorDigest,
            completion.phase == .finalized || completion.phase == .cancelled
        else { throw ProtectedStateError.updateUnavailable }
        let outcome: EnforcementOutcome
        do {
            outcome = try enforcer.apply(
                EffectiveRestrictions(
                    blockedDomains: [],
                    blockedApplications: [],
                    contributingBlockIDs: []
                ),
                state: current,
                at: clock.read().wallTime
            )
        } catch {
            enforcementIssues = [
                ProtectionIssue(
                    code: "standby_retirement_failed",
                    message: error.localizedDescription,
                    blockIDs: state.conservativeUpdateRestrictions().contributingBlockIDs
                )
            ]
            throw error
        }
        enforcementIssues = outcome.issues.filter { !$0.code.hasPrefix("application_") }
        applicationIssues = outcome.issues.filter { $0.code.hasPrefix("application_") }
        guard outcome.issues.isEmpty else { throw ProtectedStateError.updateUnavailable }
        retired = true
        return ProtectedLiveUpdateStatus(
            phase: completion.phase,
            generation: gate.generation,
            stateDigest: try ServiceStateDigest.hash(current),
            appleStateDigest: appleStateDigest,
            successorDigest: gate.successorDigest,
            isEnforcing: false,
            issues: []
        )
    }

    private func scan() {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return }
        let outcome = enforcer.closeApplications(
            state.conservativeUpdateRestrictions(),
            state: state,
            at: clock.read().wallTime
        )
        applicationIssues = outcome.issues
    }
}
