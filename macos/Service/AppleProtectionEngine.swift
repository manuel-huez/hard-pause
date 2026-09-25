import Foundation

final class AppleLockdownEngine: @unchecked Sendable {
    private let stateStore: AppleLockdownStateStoring
    private let credentialVault: AppleLockdownCredentialVault
    private let passcodeGenerator: AppleLockdownPasscodeGenerating
    private let clock: ServiceClock
    private let lock = NSLock()
    private let timerQueue = DispatchQueue(
        label: "org.hardpause.service.apple-protection",
        qos: .utility
    )
    private var timer: DispatchSourceTimer?
    private var state: AppleLockdownState
    private var frozenForLiveUpdate: Bool

    init(
        stateStore: AppleLockdownStateStoring,
        credentialVault: AppleLockdownCredentialVault,
        passcodeGenerator: AppleLockdownPasscodeGenerating = SecureAppleLockdownPasscodeGenerator(),
        clock: ServiceClock = SystemServiceClock(),
        preloadedState: AppleLockdownState? = nil
    ) throws {
        self.stateStore = stateStore
        self.credentialVault = credentialVault
        self.passcodeGenerator = passcodeGenerator
        self.clock = clock
        state = try preloadedState ?? stateStore.load()
        frozenForLiveUpdate = preloadedState != nil
    }

    deinit { timer?.cancel() }

    func start() {
        withLock {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: timerQueue)
            source.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(1))
            source.setEventHandler { [weak self] in self?.checkpoint() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    func status() throws -> AppleLockdownSnapshot {
        try withLock {
            if !frozenForLiveUpdate { try reconcileLocked(at: clock.read()) }
            if state.phase == .inactive, try credentialVault.containsAnyCredential() {
                throw AppleLockdownError.stateUnavailable
            }
            return state.snapshot()
        }
    }

    func beginSetup(
        _ request: AppleLockdownSetupRequest
    ) throws -> AppleLockdownCredentialOperation {
        try withLock {
            try requireNotFrozen()
            guard try !credentialVault.containsAnyCredential() else {
                throw AppleLockdownError.stateUnavailable
            }
            if state.phase == .provisioningSetup {
                throw AppleLockdownError.setupAlreadyPending
            }
            var candidate = state
            try candidate.beginSetup(request)
            try stateStore.save(candidate)
            state = candidate
            return try prepareSetupCredentialLocked()
        }
    }

    func resumeSetup(
        _ request: AppleLockdownOperationRequest
    ) throws -> AppleLockdownCredentialOperation {
        try withLock {
            try requireNotFrozen()
            guard state.operationID == request.operationID else {
                throw AppleLockdownError.operationMismatch
            }
            if state.phase == .provisioningSetup {
                return try prepareSetupCredentialLocked()
            }
            guard state.phase == .pendingSetup, let credentialID = state.credentialID else {
                throw AppleLockdownError.setupNotPending
            }
            let passcode = try credentialVault.read(credentialID: credentialID)
            return AppleLockdownCredentialOperation(
                operationID: request.operationID,
                passcode: passcode,
                snapshot: state.snapshot()
            )
        }
    }

    func completeSetup(
        _ request: AppleLockdownOperationRequest
    ) throws -> AppleLockdownSnapshot {
        try withLock {
            try requireNotFrozen()
            var candidate = state
            try candidate.completeSetup(operationID: request.operationID)
            guard let credentialID = state.credentialID else {
                throw AppleLockdownError.credentialUnavailable
            }
            _ = try credentialVault.read(credentialID: credentialID)
            try stateStore.save(candidate)
            state = candidate
            return state.snapshot()
        }
    }

    func websiteSyncCredential() throws -> (
        passcode: String, mirroredDomains: [String], mirroredAllowedDomains: [String]
    ) {
        try withLock {
            try requireNotFrozen()
            guard [.active, .waitingForFullUnlock, .releaseInProgress].contains(state.phase),
                state.configuration?.enablesAdultFilter == true,
                let credentialID = state.credentialID
            else { throw AppleLockdownError.protectionNotActive }
            return (
                try credentialVault.read(credentialID: credentialID),
                state.mirroredDomains ?? [], state.mirroredAllowedDomains ?? []
            )
        }
    }

    func recordMirroredDomains(
        _ domains: [String], required: Set<String>, allowed: [String], requiredAllowed: Set<String>
    ) throws {
        try withLock {
            try requireNotFrozen()
            guard [.active, .waitingForFullUnlock, .releaseInProgress].contains(state.phase) else {
                throw AppleLockdownError.protectionNotActive
            }
            var candidate = state
            try candidate.recordMirroredDomains(
                domains, required: required, allowed: allowed, requiredAllowed: requiredAllowed)
            try stateStore.save(candidate)
            state = candidate
        }
    }

    func claimMirroredDomains(
        _ additions: [String], required: Set<String>, allowed: [String], requiredAllowed: Set<String>
    ) throws {
        try withLock {
            try requireNotFrozen()
            guard [.active, .waitingForFullUnlock, .releaseInProgress].contains(state.phase) else {
                throw AppleLockdownError.protectionNotActive
            }
            var candidate = state
            try candidate.claimMirroredDomains(
                additions, required: required, allowed: allowed, requiredAllowed: requiredAllowed)
            try stateStore.save(candidate)
            state = candidate
        }
    }

    func confirmSetupNotApplied(
        _ request: AppleLockdownOperationRequest
    ) throws -> AppleLockdownSnapshot {
        throw AppleLockdownError.setupCancellationUnavailable
    }

    func requestEnd() throws -> AppleLockdownSnapshot {
        try withLock {
            try requireNotFrozen()
            var candidate = state
            try candidate.requestEnd(at: clock.read())
            try stateStore.save(candidate)
            state = candidate
            return state.snapshot()
        }
    }

    func beginRelease(
        normalProtectionIsInactiveAndHealthy: Bool
    ) throws -> AppleLockdownCredentialOperation {
        try withLock {
            try requireNotFrozen()
            guard normalProtectionIsInactiveAndHealthy else {
                throw AppleLockdownError.normalProtectionActiveOrUnhealthy
            }
            var candidate = state
            candidate.advance(to: clock.read())
            let operationID = try candidate.beginRelease()
            if candidate != state {
                try stateStore.save(candidate)
                state = candidate
            }
            guard let credentialID = state.credentialID else {
                throw AppleLockdownError.credentialUnavailable
            }
            let passcode = try credentialVault.read(credentialID: credentialID)
            return AppleLockdownCredentialOperation(
                operationID: operationID,
                passcode: passcode,
                snapshot: state.snapshot()
            )
        }
    }

    func completeRelease(
        _ request: AppleLockdownOperationRequest
    ) throws -> AppleLockdownSnapshot {
        try withLock {
            try requireNotFrozen()
            var candidate = state
            try candidate.beginReleaseCompletion(operationID: request.operationID)
            try stateStore.save(candidate)
            state = candidate
            try finishCredentialCleanupLocked()
            return state.snapshot()
        }
    }

    func requireSafeMaintenance() throws {
        try withLock {
            guard !state.preventsMaintenance else {
                throw AppleLockdownError.releaseInProgress
            }
            guard try !credentialVault.containsAnyCredential() else {
                throw AppleLockdownError.stateUnavailable
            }
        }
    }

    func activationReadiness() -> (allowsLockdown: Bool, blocksAnyActivation: Bool) {
        withLock {
            let allowsLockdown = state.phase == .active || state.phase == .waitingForFullUnlock
            let blocksAnyActivation =
                state.phase == .releaseInProgress
                || state.phase == .completingRelease
            return (allowsLockdown, blocksAnyActivation)
        }
    }

    func freezeForLiveUpdate() throws -> String {
        try withLock {
            if !frozenForLiveUpdate {
                switch state.phase {
                case .inactive, .active, .waitingForFullUnlock: break
                default: throw AppleLockdownError.releaseInProgress
                }
                try reconcileLocked(at: clock.read())
                frozenForLiveUpdate = true
            }
            return try ServiceStateDigest.hash(state)
        }
    }

    func checkpointForLiveUpdateFinalization() throws {
        try withLock {
            guard frozenForLiveUpdate else { throw AppleLockdownError.unavailable }
            try reconcileLocked(at: clock.read())
        }
    }

    func commitInactiveMigration() throws {
        try withLock {
            guard frozenForLiveUpdate, !state.preventsMaintenance else {
                throw AppleLockdownError.releaseInProgress
            }
            try stateStore.save(state)
        }
    }

    func unfreezeAfterLiveUpdate() {
        withLock { frozenForLiveUpdate = false }
    }

    func stateDigest() throws -> String {
        try withLock { try ServiceStateDigest.hash(state) }
    }

    private func requireNotFrozen() throws {
        guard !frozenForLiveUpdate else { throw ProtectedStateError.updateInProgress }
    }

    private func prepareSetupCredentialLocked() throws -> AppleLockdownCredentialOperation {
        guard state.phase == .provisioningSetup,
            let credentialID = state.credentialID,
            let operationID = state.operationID
        else {
            throw AppleLockdownError.setupNotPending
        }

        let passcode: String
        do {
            passcode = try credentialVault.read(credentialID: credentialID)
        } catch AppleLockdownError.credentialUnavailable {
            let generated = try passcodeGenerator.generate()
            try credentialVault.save(passcode: generated, credentialID: credentialID)
            let readBack = try credentialVault.read(credentialID: credentialID)
            guard generated == readBack else {
                throw AppleLockdownError.credentialStoreFailed
            }
            passcode = readBack
        }

        var candidate = state
        try candidate.markSetupCredentialReady()
        try stateStore.save(candidate)
        state = candidate
        return AppleLockdownCredentialOperation(
            operationID: operationID,
            passcode: passcode,
            snapshot: state.snapshot()
        )
    }

    private func finishCredentialCleanupLocked() throws {
        guard let credentialID = state.credentialID else {
            throw AppleLockdownError.stateUnavailable
        }
        try credentialVault.delete(credentialID: credentialID)
        var candidate = state
        try candidate.completeCredentialCleanup()
        try stateStore.save(candidate)
        state = candidate
    }

    private func reconcileLocked(at reading: ClockReading) throws {
        switch state.phase {
        case .waitingForFullUnlock:
            var candidate = state
            candidate.advance(to: reading)
            try stateStore.save(candidate)
            state = candidate
        case .completingRelease:
            try finishCredentialCleanupLocked()
        default:
            break
        }
    }

    private func checkpoint() {
        withLock {
            if !frozenForLiveUpdate { try? reconcileLocked(at: clock.read()) }
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
