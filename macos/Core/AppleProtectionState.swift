import Foundation

enum AppleLockdownStoredPhase: String, Codable, Equatable, Sendable {
    case inactive
    case provisioningSetup
    case pendingSetup
    case active
    case waitingForFullUnlock
    case releaseInProgress
    case completingRelease
}

struct AppleLockdownConfiguration: Codable, Equatable, Sendable {
    let fullUnlockDelay: TimeInterval
    let enablesAdultFilter: Bool
    let filterWasAlreadyEnabled: Bool
    let shareAcrossDevicesVerified: Bool?

    init(_ request: AppleLockdownSetupRequest) {
        fullUnlockDelay = request.fullUnlockDelay
        enablesAdultFilter = request.enablesAdultFilter
        filterWasAlreadyEnabled = request.filterWasAlreadyEnabled
        shareAcrossDevicesVerified = request.shareAcrossDevicesVerified
    }

    func validate() throws {
        try AppleLockdownSetupRequest(
            fullUnlockDelay: fullUnlockDelay,
            enablesAdultFilter: enablesAdultFilter,
            filterWasAlreadyEnabled: filterWasAlreadyEnabled,
            shareAcrossDevicesVerified: shareAcrossDevicesVerified
        ).validate()
    }
}

struct AppleLockdownState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    private(set) var phase: AppleLockdownStoredPhase
    private(set) var configuration: AppleLockdownConfiguration?
    private(set) var credentialID: UUID?
    private(set) var operationID: UUID?
    private(set) var accumulatedElapsed: TimeInterval
    private(set) var anchorContinuousTime: TimeInterval?
    private(set) var anchorBootIdentifier: String?
    private(set) var requestedAtElapsed: TimeInterval?
    private(set) var requestedAtWallTime: Date?
    private(set) var mirroredDomains: [String]?
    private(set) var mirroredAllowedDomains: [String]?
    private(set) var hasUsedPlan: Bool?
    private(set) var pendingWebsiteSync: AppleWebsiteSyncPermit?

    init() {
        schemaVersion = Self.currentSchemaVersion
        phase = .inactive
        configuration = nil
        credentialID = nil
        operationID = nil
        accumulatedElapsed = 0
        anchorContinuousTime = nil
        anchorBootIdentifier = nil
        requestedAtElapsed = nil
        requestedAtWallTime = nil
        mirroredDomains = nil
        mirroredAllowedDomains = nil
        // An inactive state can be synthesized by either service during a
        // live handoff when no Apple state file exists. Keep its encoding the
        // same as older services until a new setup starts.
        hasUsedPlan = nil
        pendingWebsiteSync = nil
    }

    mutating func beginSetup(
        _ request: AppleLockdownSetupRequest,
        operationID: UUID = UUID(),
        credentialID: UUID = UUID()
    ) throws {
        try request.validate()
        guard phase == .inactive else {
            if phase == .provisioningSetup || phase == .pendingSetup {
                throw AppleLockdownError.setupAlreadyPending
            }
            throw AppleLockdownError.protectionNotActive
        }
        phase = .provisioningSetup
        configuration = AppleLockdownConfiguration(request)
        self.credentialID = credentialID
        self.operationID = operationID
        resetClock()
        hasUsedPlan = false
    }

    mutating func markSetupCredentialReady() throws {
        guard phase == .provisioningSetup else {
            throw AppleLockdownError.setupNotPending
        }
        phase = .pendingSetup
    }

    mutating func completeSetup(operationID: UUID) throws {
        try requireOperation(operationID, phase: .pendingSetup)
        phase = .active
        self.operationID = nil
        resetClock()
    }

    mutating func requestEnd(at reading: ClockReading) throws {
        switch phase {
        case .active:
            phase = .waitingForFullUnlock
            accumulatedElapsed = 0
            requestedAtElapsed = 0
            requestedAtWallTime = reading.wallTime
            anchorContinuousTime = reading.continuousTime
            anchorBootIdentifier = reading.bootIdentifier
        case .waitingForFullUnlock:
            advance(to: reading)
        case .releaseInProgress, .completingRelease:
            throw AppleLockdownError.releaseAlreadyRequested
        default:
            throw AppleLockdownError.protectionNotActive
        }
    }

    mutating func reconcilePlanUse(hasDependentPlans: Bool, at reading: ClockReading) throws {
        guard configuration?.fullUnlockDelay == 0, phase == .active else { return }
        if hasDependentPlans {
            hasUsedPlan = true
        } else if hasUsedPlan == true {
            try requestEnd(at: reading)
        }
    }

    mutating func beginRelease(operationID: UUID = UUID()) throws -> UUID {
        if phase == .releaseInProgress {
            guard let current = self.operationID else {
                throw AppleLockdownError.stateUnavailable
            }
            return current
        }
        guard phase == .waitingForFullUnlock, remainingDelay == 0 else {
            throw AppleLockdownError.releaseNotReady
        }
        phase = .releaseInProgress
        self.operationID = operationID
        return operationID
    }

    mutating func beginReleaseCompletion(operationID: UUID) throws {
        try requireOperation(operationID, phase: .releaseInProgress)
        phase = .completingRelease
    }

    mutating func completeCredentialCleanup() throws {
        guard phase == .completingRelease else {
            throw AppleLockdownError.stateUnavailable
        }
        self = AppleLockdownState()
    }

    private mutating func recordMirroredDomains(
        _ domains: [String], required: Set<String>, allowed: [String], requiredAllowed: Set<String>
    ) throws {
        guard isConfirmedActive, configuration?.enablesAdultFilter == true,
            Set(domains).isSubset(of: required),
            Set(allowed).isSubset(of: requiredAllowed),
            Set(mirroredDomains ?? []).intersection(required).isSubset(of: domains),
            Set(mirroredAllowedDomains ?? []).intersection(requiredAllowed).isSubset(of: allowed),
            domains == Array(Set(domains)).sorted(),
            domains.allSatisfy({ DomainRule.normalize($0) == $0 }),
            allowed == Array(Set(allowed)).sorted(),
            allowed.allSatisfy({ DomainRule.normalize($0) == $0 })
        else { throw AppleLockdownError.invalidRequest("Screen Time website sync is not available.") }
        mirroredDomains = domains
        mirroredAllowedDomains = allowed
    }

    private mutating func claimMirroredDomains(
        _ additions: [String], required: Set<String>, allowed: [String], requiredAllowed: Set<String>
    ) throws {
        guard isConfirmedActive, configuration?.enablesAdultFilter == true,
            additions == Array(Set(additions)).sorted(),
            additions.allSatisfy({ DomainRule.normalize($0) == $0 }),
            Set(additions).isSubset(of: required),
            allowed == Array(Set(allowed)).sorted(),
            allowed.allSatisfy({ DomainRule.normalize($0) == $0 }),
            Set(allowed).isSubset(of: requiredAllowed)
        else { throw AppleLockdownError.invalidRequest("Screen Time website sync is not available.") }
        mirroredDomains = Array(Set(mirroredDomains ?? []).union(additions)).sorted()
        mirroredAllowedDomains = Array(Set(mirroredAllowedDomains ?? []).union(allowed)).sorted()
    }

    mutating func prepareWebsiteSync(
        _ claim: AppleWebsiteSyncClaim, targets: AppleWebsiteSyncTargets, writer: AppleWebsiteSyncWriter
    ) throws {
        let captured = pendingWebsiteSync?.targets ?? targets
        guard claim.expectedDomains == captured.restricted,
            claim.expectedAllowedDomains == captured.allowed
        else { throw AppleLockdownError.websiteSyncTargetsChanged }
        try claimMirroredDomains(
            claim.domains, required: Set(captured.restricted),
            allowed: claim.allowedDomains, requiredAllowed: Set(captured.allowed))
        // A delayed reply from a dead writer must not finish its replacement's work.
        let operationID = pendingWebsiteSync?.writer == writer ? pendingWebsiteSync?.operationID : nil
        pendingWebsiteSync = AppleWebsiteSyncPermit(
            operationID: operationID ?? UUID(), targets: captured, writer: writer)
    }

    mutating func completeWebsiteSync(
        _ completion: AppleWebsiteSyncCompletion, writer: AppleWebsiteSyncWriter
    ) throws {
        guard let permit = pendingWebsiteSync, permit.operationID == completion.operationID,
            permit.writer == writer
        else {
            throw AppleLockdownError.operationMismatch
        }
        guard
            [completion.verifiedDomains, completion.verifiedAllowedDomains].allSatisfy({ domains in
                domains == Array(Set(domains)).sorted() && domains.allSatisfy { DomainRule.normalize($0) == $0 }
            })
        else { throw AppleLockdownError.invalidRequest("Screen Time website verification is incomplete.") }
        if phase == .releaseInProgress {
            guard permit.targets.restricted.isEmpty, permit.targets.allowed.isEmpty,
                completion.mirroredDomains.isEmpty, completion.mirroredAllowedDomains.isEmpty,
                Set(completion.verifiedDomains).isDisjoint(with: mirroredDomains ?? []),
                Set(completion.verifiedAllowedDomains).isDisjoint(with: mirroredAllowedDomains ?? [])
            else { throw AppleLockdownError.invalidRequest("Screen Time website removal is incomplete.") }
        } else {
            guard completion.verifiedDomains == permit.targets.restricted,
                completion.verifiedAllowedDomains == permit.targets.allowed
            else { throw AppleLockdownError.invalidRequest("Screen Time website verification is incomplete.") }
        }
        try recordMirroredDomains(
            completion.mirroredDomains, required: Set(permit.targets.restricted),
            allowed: completion.mirroredAllowedDomains, requiredAllowed: Set(permit.targets.allowed))
        pendingWebsiteSync = nil
    }

    mutating func advance(to reading: ClockReading) {
        guard phase == .waitingForFullUnlock else { return }
        let projection = PauseCoreClock.project(
            checkpoint: PauseCoreClockCheckpoint(
                logicalTime: accumulatedElapsed,
                elapsedSinceBoot: anchorContinuousTime,
                bootIdentifier: anchorBootIdentifier
            ),
            reading: PauseCoreClockReading(
                elapsedSinceBoot: reading.continuousTime,
                bootIdentifier: reading.bootIdentifier
            )
        )
        accumulatedElapsed = projection.logicalTime
        anchorContinuousTime = reading.continuousTime
        anchorBootIdentifier = reading.bootIdentifier
    }

    var remainingDelay: TimeInterval? {
        guard phase == .waitingForFullUnlock, let configuration, let requestedAtElapsed else {
            return nil
        }
        return max(0, requestedAtElapsed + configuration.fullUnlockDelay - accumulatedElapsed)
    }

    var isConfirmedActive: Bool {
        switch phase {
        case .active, .waitingForFullUnlock, .releaseInProgress, .completingRelease:
            return true
        default:
            return false
        }
    }

    var preventsMaintenance: Bool { phase != .inactive }

    func snapshot() -> AppleLockdownSnapshot {
        let publicPhase: AppleLockdownPhase
        switch phase {
        case .inactive:
            publicPhase = .inactive
        case .provisioningSetup, .pendingSetup:
            publicPhase = .pendingSetup
        case .active:
            publicPhase = .active
        case .waitingForFullUnlock:
            publicPhase = remainingDelay == 0 ? .readyForRelease : .waitingForFullUnlock
        case .releaseInProgress, .completingRelease:
            publicPhase = .releaseInProgress
        }
        return AppleLockdownSnapshot(
            phase: publicPhase,
            fullUnlockDelay: configuration?.fullUnlockDelay,
            remainingDelay: publicPhase == .readyForRelease ? 0 : remainingDelay,
            enablesAdultFilter: configuration?.enablesAdultFilter ?? false,
            filterWasAlreadyEnabled: configuration?.filterWasAlreadyEnabled ?? false,
            shareAcrossDevicesVerified: configuration?.shareAcrossDevicesVerified,
            mirroredDomains: mirroredDomains ?? [],
            mirroredAllowedDomains: mirroredAllowedDomains ?? [],
            operationID: publicPhase == .pendingSetup || publicPhase == .releaseInProgress
                ? operationID : nil,
            websiteSyncOperationID: pendingWebsiteSync?.operationID
        )
    }

    func validateForPersistence() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AppleLockdownError.stateUnavailable
        }
        guard accumulatedElapsed.isFinite, accumulatedElapsed >= 0 else {
            throw AppleLockdownError.stateUnavailable
        }
        if let anchorContinuousTime {
            guard anchorContinuousTime.isFinite, anchorContinuousTime >= 0 else {
                throw AppleLockdownError.stateUnavailable
            }
        }
        guard anchorBootIdentifier?.utf8.count ?? 0 <= 256 else {
            throw AppleLockdownError.stateUnavailable
        }
        if let permit = pendingWebsiteSync {
            guard [.active, .waitingForFullUnlock, .releaseInProgress].contains(phase),
                configuration?.enablesAdultFilter == true,
                permit.writer.processID > 0, permit.writer.startedAtSeconds > 0,
                permit.writer.startedAtMicroseconds < 1_000_000,
                [permit.targets.restricted, permit.targets.allowed].allSatisfy({ domains in
                    domains == Array(Set(domains)).sorted() && domains.allSatisfy { DomainRule.normalize($0) == $0 }
                }),
                Set(permit.targets.restricted).isDisjoint(with: permit.targets.allowed),
                phase != .releaseInProgress || (permit.targets.restricted.isEmpty && permit.targets.allowed.isEmpty)
            else { throw AppleLockdownError.stateUnavailable }
        }
        if let mirroredDomains, let mirroredAllowedDomains {
            guard mirroredDomains == Array(Set(mirroredDomains)).sorted(),
                mirroredDomains.allSatisfy({ DomainRule.normalize($0) == $0 }),
                mirroredAllowedDomains == Array(Set(mirroredAllowedDomains)).sorted(),
                mirroredAllowedDomains.allSatisfy({ DomainRule.normalize($0) == $0 })
            else { throw AppleLockdownError.stateUnavailable }
        } else if mirroredDomains != nil || mirroredAllowedDomains != nil {
            throw AppleLockdownError.stateUnavailable
        }
        if let requestedAtElapsed {
            guard requestedAtElapsed.isFinite,
                requestedAtElapsed >= 0,
                requestedAtElapsed <= accumulatedElapsed
            else {
                throw AppleLockdownError.stateUnavailable
            }
        }
        if let requestedAtWallTime {
            guard requestedAtWallTime.timeIntervalSinceReferenceDate.isFinite else {
                throw AppleLockdownError.stateUnavailable
            }
        }

        switch phase {
        case .inactive:
            guard configuration == nil, credentialID == nil, operationID == nil,
                requestedAtElapsed == nil, requestedAtWallTime == nil,
                mirroredDomains == nil, mirroredAllowedDomains == nil
            else {
                throw AppleLockdownError.stateUnavailable
            }
        case .provisioningSetup, .pendingSetup:
            try requireStoredSetupFields()
            guard requestedAtElapsed == nil, requestedAtWallTime == nil else {
                throw AppleLockdownError.stateUnavailable
            }
        case .active:
            try requireStoredActiveFields(operationRequired: false)
            guard requestedAtElapsed == nil, requestedAtWallTime == nil else {
                throw AppleLockdownError.stateUnavailable
            }
        case .waitingForFullUnlock:
            try requireStoredActiveFields(operationRequired: false)
            guard requestedAtElapsed != nil, requestedAtWallTime != nil,
                anchorContinuousTime != nil
            else {
                throw AppleLockdownError.stateUnavailable
            }
        case .releaseInProgress, .completingRelease:
            try requireStoredActiveFields(operationRequired: true)
            guard requestedAtElapsed != nil, requestedAtWallTime != nil else {
                throw AppleLockdownError.stateUnavailable
            }
        }
    }

    private func requireStoredSetupFields() throws {
        guard let configuration, credentialID != nil, operationID != nil else {
            throw AppleLockdownError.stateUnavailable
        }
        try configuration.validate()
    }

    private func requireStoredActiveFields(operationRequired: Bool) throws {
        guard let configuration, credentialID != nil,
            operationRequired ? operationID != nil : operationID == nil
        else {
            throw AppleLockdownError.stateUnavailable
        }
        try configuration.validate()
    }

    private func requireOperation(
        _ operationID: UUID,
        phase expectedPhase: AppleLockdownStoredPhase
    ) throws {
        guard phase == expectedPhase else {
            throw expectedPhase == .pendingSetup
                ? AppleLockdownError.setupNotPending : AppleLockdownError.releaseInProgress
        }
        guard self.operationID == operationID else {
            throw AppleLockdownError.operationMismatch
        }
    }

    private mutating func resetClock() {
        accumulatedElapsed = 0
        anchorContinuousTime = nil
        anchorBootIdentifier = nil
        requestedAtElapsed = nil
        requestedAtWallTime = nil
    }
}
