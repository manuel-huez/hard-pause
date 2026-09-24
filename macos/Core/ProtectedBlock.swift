import Foundation

enum ProtectedBlockLimits {
    static let maximumBlocks = 128
    static let maximumRequirementLength = 16_384
    static let serviceStatusReplyReserve = 64 * 1_024
    static let minimumDelay: TimeInterval = 60
    static let maximumDelay: TimeInterval = 366 * 24 * 60 * 60
}

struct ProtectedApplication: Codable, Equatable, Hashable, Identifiable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let designatedRequirement: String?

    var id: String { "\(bundleIdentifier)\u{0}\(designatedRequirement ?? "legacy")" }
}

struct ProtectedRules: Codable, Equatable, Sendable {
    let blockedDomains: [String]
    let blockedApplications: [ProtectedApplication]
    let blockedAdultDomains: [String]
    let adultRulesVersion: Int?
    let blockedURLPatterns: [String]
    let blocksAdultWebsites: Bool

    var blocksStarterAdultSites: Bool { !blockedAdultDomains.isEmpty }
    var allBlockedDomains: [String] { blockedDomains + blockedAdultDomains }

    func includesAllRules(in previous: ProtectedRules) -> Bool {
        ProtectedPolicy.includesAllRules(self, in: previous)
    }

    func adding(
        domains: [String] = [],
        urlPatterns: [String] = [],
        applications: [ProtectedApplication] = [],
        adultWebsites: Bool = false
    ) -> ProtectedRules {
        ProtectedPolicy.addRules(
            self, domains: domains, urlPatterns: urlPatterns,
            applications: applications, adultWebsites: adultWebsites
        )
    }

    init(
        blockedDomains: [String],
        blockedApplications: [ProtectedApplication],
        blocksStarterAdultSites: Bool,
        blockedURLPatterns: [String] = [],
        blocksAdultWebsites: Bool = false
    ) {
        self = ProtectedPolicy.normalizeRules(
            ProtectedRules(
                blockedDomains: blockedDomains,
                blockedApplications: blockedApplications,
                blockedAdultDomains: blocksStarterAdultSites ? StarterAdultRules.domains : [],
                adultRulesVersion: blocksStarterAdultSites ? StarterAdultRules.version : nil,
                blockedURLPatterns: blockedURLPatterns,
                blocksAdultWebsites: blocksAdultWebsites
            ))
    }

    init(
        blockedDomains: [String],
        blockedApplications: [ProtectedApplication],
        blockedAdultDomains: [String],
        adultRulesVersion: Int?,
        blockedURLPatterns: [String] = [],
        blocksAdultWebsites: Bool = false
    ) {
        self.blocksAdultWebsites = blocksAdultWebsites
        self.blockedDomains = blockedDomains
        self.blockedApplications = blockedApplications
        self.blockedAdultDomains = blockedAdultDomains
        self.adultRulesVersion = adultRulesVersion
        self.blockedURLPatterns = blockedURLPatterns
    }

    private enum CodingKeys: String, CodingKey {
        case blockedDomains
        case blockedApplications
        case blockedAdultDomains
        case adultRulesVersion
        case blockedURLPatterns
        case blocksAdultWebsites
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            blockedDomains: try container.decode([String].self, forKey: .blockedDomains),
            blockedApplications: try container.decode(
                [ProtectedApplication].self,
                forKey: .blockedApplications
            ),
            blockedAdultDomains: try container.decode([String].self, forKey: .blockedAdultDomains),
            adultRulesVersion: try container.decodeIfPresent(Int.self, forKey: .adultRulesVersion),
            blockedURLPatterns: try container.decodeIfPresent(
                [String].self,
                forKey: .blockedURLPatterns
            ) ?? [],
            blocksAdultWebsites: container.contains(.blocksAdultWebsites)
                ? try container.decode(Bool.self, forKey: .blocksAdultWebsites) : false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blockedDomains, forKey: .blockedDomains)
        try container.encode(blockedApplications, forKey: .blockedApplications)
        try container.encode(blockedAdultDomains, forKey: .blockedAdultDomains)
        try container.encodeIfPresent(adultRulesVersion, forKey: .adultRulesVersion)
        try container.encode(blockedURLPatterns, forKey: .blockedURLPatterns)
        if blocksAdultWebsites { try container.encode(true, forKey: .blocksAdultWebsites) }
    }

    func validateForPersistence(allowLegacyApplicationIdentity: Bool = false) throws {
        try ProtectedPolicy.validateRules(
            self, allowLegacyApplicationIdentity: allowLegacyApplicationIdentity
        )
    }
}

struct ProtectedBlockDraft: Codable, Equatable, Sendable {
    let name: String
    let rules: ProtectedRules
    let protectionMode: ProtectionMode
    let breakDelay: TimeInterval
    let fullUnlockDelay: TimeInterval
    let breakDuration: TimeInterval
    let elapsedDuration: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case name
        case rules
        case protectionMode
        case breakDelay
        case fullUnlockDelay
        case breakDuration
        case elapsedDuration
    }

    init(
        name: String,
        rules: ProtectedRules,
        protectionMode: ProtectionMode = .softLock,
        breakDelay: TimeInterval,
        fullUnlockDelay: TimeInterval,
        breakDuration: TimeInterval,
        elapsedDuration: TimeInterval?
    ) {
        self.name = name
        self.rules = rules
        self.protectionMode = protectionMode
        self.breakDelay = breakDelay
        self.fullUnlockDelay = fullUnlockDelay
        self.breakDuration = breakDuration
        self.elapsedDuration = elapsedDuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        rules = try container.decode(ProtectedRules.self, forKey: .rules)
        if container.contains(.protectionMode) {
            protectionMode = try container.decode(ProtectionMode.self, forKey: .protectionMode)
        } else {
            protectionMode = .softLock
        }
        breakDelay = try container.decode(TimeInterval.self, forKey: .breakDelay)
        fullUnlockDelay = try container.decode(TimeInterval.self, forKey: .fullUnlockDelay)
        breakDuration = try container.decode(TimeInterval.self, forKey: .breakDuration)
        elapsedDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .elapsedDuration)
    }

    func validatedForMutation() throws -> ProtectedBlockDraft {
        let cleanName = try ProtectedPolicy.validateDraft(
            self, mutation: true, allowLegacyApplicationIdentity: false
        )
        return ProtectedBlockDraft(
            name: cleanName,
            rules: rules,
            protectionMode: protectionMode,
            breakDelay: breakDelay,
            fullUnlockDelay: fullUnlockDelay,
            breakDuration: breakDuration,
            elapsedDuration: elapsedDuration
        )
    }

    func validateForPersistence(allowLegacyApplicationIdentity: Bool = false) throws {
        _ = try ProtectedPolicy.validateDraft(
            self, mutation: false,
            allowLegacyApplicationIdentity: allowLegacyApplicationIdentity
        )
    }
}

enum ProtectedRequestKind: String, Codable, Equatable, Sendable {
    case breakAccess
    case fullUnlock
}

struct ProtectedPendingRequest: Codable, Equatable, Sendable {
    let kind: ProtectedRequestKind
    let requestedAtElapsed: TimeInterval
    let requestedAtWallTime: Date
}

struct ProtectedActivation: Codable, Equatable, Sendable {
    private(set) var frozenDraft: ProtectedBlockDraft
    let activatedAt: Date
    private(set) var accumulatedElapsed: TimeInterval
    private(set) var anchorContinuousTime: TimeInterval?
    private(set) var anchorBootIdentifier: String?
    private(set) var pendingRequest: ProtectedPendingRequest?
    private(set) var breakEndsAtElapsed: TimeInterval?

    init(draft: ProtectedBlockDraft, reading: ClockReading) {
        frozenDraft = draft
        activatedAt = reading.wallTime
        accumulatedElapsed = 0
        anchorContinuousTime = reading.continuousTime
        anchorBootIdentifier = reading.bootIdentifier
        pendingRequest = nil
        breakEndsAtElapsed = nil
    }

    mutating func addRules(from draft: ProtectedBlockDraft) {
        frozenDraft = draft
    }

    mutating func request(_ kind: ProtectedRequestKind, at reading: ClockReading) throws {
        guard advance(to: reading) else { throw ProtectedStateError.inactive }
        if kind == .breakAccess, !frozenDraft.protectionMode.allowsBreaks {
            throw ProtectedStateError.invalid("Hard Pause plans do not allow breaks.")
        }
        var lifecycle = coreLifecycleState
        do {
            switch kind {
            case .breakAccess:
                try PauseCoreLifecycle.requestBreak(
                    &lifecycle,
                    at: accumulatedElapsed,
                    delay: frozenDraft.breakDelay,
                    duration: frozenDraft.breakDuration
                )
            case .fullUnlock:
                try PauseCoreLifecycle.requestFullUnlock(
                    &lifecycle,
                    at: accumulatedElapsed,
                    delay: frozenDraft.fullUnlockDelay,
                    profile: .macOS
                )
            }
        } catch let error as PauseCoreLifecycleError {
            throw protectedStateError(for: error)
        }
        pendingRequest = ProtectedPendingRequest(
            kind: kind,
            requestedAtElapsed: accumulatedElapsed,
            requestedAtWallTime: reading.wallTime
        )
    }

    mutating func cancelBreakRequest(at reading: ClockReading) throws {
        guard advance(to: reading) else { throw ProtectedStateError.inactive }
        var lifecycle = coreLifecycleState
        do {
            try PauseCoreLifecycle.cancelBreak(&lifecycle)
        } catch let error as PauseCoreLifecycleError {
            throw protectedStateError(for: error)
        }
        pendingRequest = nil
    }

    @discardableResult
    mutating func advance(to reading: ClockReading) -> Bool {
        accrue(to: reading)
        var lifecycle = coreLifecycleState
        PauseCoreLifecycle.reconcile(&lifecycle, at: accumulatedElapsed)
        pendingRequest = lifecycle.pendingRequest == nil ? nil : pendingRequest
        breakEndsAtElapsed = lifecycle.breakEndsAt
        return lifecycle.isActive
    }

    func phase() -> ProtectedBlockPhase {
        switch PauseCoreLifecycle.phase(of: coreLifecycleState, at: accumulatedElapsed) {
        case .inactive:
            return .inactive
        case .active(let naturalEndRemaining):
            return .active(naturalEndRemaining: naturalEndRemaining)
        case .waitingForBreak(let remaining, let naturalEndRemaining):
            return .waitingForBreak(
                remaining: remaining,
                naturalEndRemaining: naturalEndRemaining
            )
        case .waitingForFullUnlock(let remaining, let naturalEndRemaining):
            return .waitingForFullUnlock(
                remaining: remaining,
                naturalEndRemaining: naturalEndRemaining
            )
        case .breakActive(let remaining, let fullUnlockRemaining, let naturalEndRemaining):
            return .breakActive(
                remaining: remaining,
                fullUnlockRemaining: fullUnlockRemaining,
                naturalEndRemaining: naturalEndRemaining
            )
        }
    }

    func validateForPersistence() throws {
        try frozenDraft.validateForPersistence()
        guard activatedAt.timeIntervalSinceReferenceDate.isFinite,
            accumulatedElapsed.isFinite,
            accumulatedElapsed >= 0
        else {
            throw ProtectedStateError.invalid("An active block has an invalid elapsed time.")
        }
        if let anchorContinuousTime {
            guard anchorContinuousTime.isFinite, anchorContinuousTime >= 0 else {
                throw ProtectedStateError.invalid("An active block has an invalid clock checkpoint.")
            }
        }
        if let anchorBootIdentifier, anchorBootIdentifier.count > 256 {
            throw ProtectedStateError.invalid("An active block has an invalid boot identifier.")
        }
        if let pendingRequest {
            guard pendingRequest.requestedAtElapsed.isFinite,
                pendingRequest.requestedAtElapsed >= 0,
                pendingRequest.requestedAtElapsed <= accumulatedElapsed,
                pendingRequest.requestedAtWallTime.timeIntervalSinceReferenceDate.isFinite
            else {
                throw ProtectedStateError.invalid("An active block has an invalid request.")
            }
            if !frozenDraft.protectionMode.allowsBreaks, pendingRequest.kind == .breakAccess {
                throw ProtectedStateError.invalid("A Hard Pause plan contains a pending break request.")
            }
        }
        if let breakEndsAtElapsed {
            guard breakEndsAtElapsed.isFinite, breakEndsAtElapsed >= 0 else {
                throw ProtectedStateError.invalid("An active block has an invalid break.")
            }
            guard frozenDraft.protectionMode.allowsBreaks else {
                throw ProtectedStateError.invalid("A Hard Pause plan contains an active break.")
            }
        }
    }

    private mutating func accrue(to reading: ClockReading) {
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
        anchorBootIdentifier = reading.bootIdentifier
        anchorContinuousTime = reading.continuousTime
    }

    private var coreLifecycleState: PauseCoreLifecycleState {
        let corePending = pendingRequest.map { request in
            let delay =
                request.kind == .breakAccess ? frozenDraft.breakDelay : frozenDraft.fullUnlockDelay
            let readyAt = request.requestedAtElapsed + delay
            return PauseCorePendingRequest(
                kind: request.kind == .breakAccess ? .breakAccess : .fullUnlock,
                readyAt: readyAt,
                breakEndsAt: request.kind == .breakAccess
                    ? readyAt + frozenDraft.breakDuration
                    : nil
            )
        }
        return PauseCoreLifecycleState(
            isActive: true,
            naturalEndAt: frozenDraft.elapsedDuration,
            pendingRequest: corePending,
            breakEndsAt: breakEndsAtElapsed
        )
    }

    private func protectedStateError(for error: PauseCoreLifecycleError) -> ProtectedStateError {
        switch error {
        case .inactive:
            return .inactive
        case .pendingRequestExists:
            return .pendingRequestExists
        case .breakAlreadyActive:
            return .breakAlreadyActive
        case .noPendingBreakRequest:
            return .noPendingBreakRequest
        case .coreUnavailable:
            return .invalid("The protection core is unavailable.")
        }
    }
}

enum ProtectedBlockPhase: Codable, Equatable, Sendable {
    case inactive
    case active(naturalEndRemaining: TimeInterval?)
    case waitingForBreak(remaining: TimeInterval, naturalEndRemaining: TimeInterval?)
    case waitingForFullUnlock(remaining: TimeInterval, naturalEndRemaining: TimeInterval?)
    case breakActive(
        remaining: TimeInterval,
        fullUnlockRemaining: TimeInterval?,
        naturalEndRemaining: TimeInterval?
    )

    var canCancelBreak: Bool {
        if case .waitingForBreak = self { return true }
        return false
    }
}

struct ProtectedBlockRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    private(set) var revision: Int
    private(set) var draft: ProtectedBlockDraft
    private(set) var activation: ProtectedActivation?

    init(id: UUID = UUID(), revision: Int = 1, draft: ProtectedBlockDraft) {
        self.id = id
        self.revision = revision
        self.draft = draft
        activation = nil
    }

    mutating func update(_ draft: ProtectedBlockDraft) throws {
        let validated = try draft.validatedForMutation()
        if var activation {
            guard validated.name == self.draft.name,
                validated.protectionMode == self.draft.protectionMode,
                validated.breakDelay == self.draft.breakDelay,
                validated.fullUnlockDelay == self.draft.fullUnlockDelay,
                validated.breakDuration == self.draft.breakDuration,
                validated.elapsedDuration == self.draft.elapsedDuration,
                validated.rules.includesAllRules(in: self.draft.rules)
            else { throw ProtectedStateError.activeBlockIsImmutable }
            activation.addRules(from: validated)
            self.activation = activation
        }
        self.draft = validated
        revision += 1
    }

    mutating func activate(at reading: ClockReading) throws {
        guard activation == nil else { throw ProtectedStateError.activeBlockIsImmutable }
        let validated = try draft.validatedForMutation()
        draft = validated
        activation = ProtectedActivation(draft: validated, reading: reading)
        revision += 1
    }

    mutating func request(_ kind: ProtectedRequestKind, at reading: ClockReading) throws {
        guard var activation else { throw ProtectedStateError.inactive }
        do {
            try activation.request(kind, at: reading)
        } catch ProtectedStateError.inactive {
            self.activation = nil
            revision += 1
            throw ProtectedStateError.inactive
        }
        self.activation = activation
        revision += 1
    }

    mutating func cancelBreakRequest(at reading: ClockReading) throws {
        guard var activation else { throw ProtectedStateError.inactive }
        do {
            try activation.cancelBreakRequest(at: reading)
        } catch ProtectedStateError.inactive {
            self.activation = nil
            revision += 1
            throw ProtectedStateError.inactive
        }
        self.activation = activation
        revision += 1
    }

    @discardableResult
    mutating func advance(to reading: ClockReading) -> Bool {
        guard var activation else { return false }
        if activation.advance(to: reading) {
            self.activation = activation
            return true
        }
        self.activation = nil
        revision += 1
        return false
    }

    func validateForPersistence() throws {
        guard revision >= 1 else { throw ProtectedStateError.invalid("A block revision is invalid.") }
        try draft.validateForPersistence()
        try activation?.validateForPersistence()
        if let activation, activation.frozenDraft != draft {
            throw ProtectedStateError.invalid("An active block does not match its fixed draft.")
        }
    }
}

struct ProtectedLiveUpdateGate: Codable, Equatable, Sendable {
    let token: UUID
    let generation: UUID
    let successorDigest: String

    func validate() throws {
        guard successorDigest.utf8.count == 64,
            successorDigest.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
        else {
            throw ProtectedStateError.invalid("The update successor digest is invalid.")
        }
    }
}

struct ProtectedLiveUpdateCompletion: Codable, Equatable, Sendable {
    let token: UUID
    let generation: UUID
    let successorDigest: String
    let phase: ProtectedLiveUpdatePhase
}

struct ProtectedState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    private struct RestrictionInput: Encodable {
        struct Block: Encodable {
            struct Activation: Encodable {
                let accumulatedElapsed: TimeInterval
                let breakEndsAtElapsed: TimeInterval?
                let rules: ProtectedRules
            }

            let id: UUID
            let activation: Activation?
        }

        let blocks: [Block]
        let includingBreaks: Bool
    }

    let schemaVersion: Int
    private(set) var blocks: [ProtectedBlockRecord]
    private(set) var updateGateToken: UUID?
    private(set) var liveUpdateGate: ProtectedLiveUpdateGate?
    private(set) var lastLiveUpdateCompletion: ProtectedLiveUpdateCompletion?
    private(set) var lastInactiveMigrationToken: UUID?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case blocks
        case updateGateToken
        case liveUpdateGate
        case lastLiveUpdateCompletion
        case lastInactiveMigrationToken
    }

    init(blocks: [ProtectedBlockRecord] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.blocks = blocks
        updateGateToken = nil
        liveUpdateGate = nil
        lastLiveUpdateCompletion = nil
        lastInactiveMigrationToken = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        blocks = try container.decode([ProtectedBlockRecord].self, forKey: .blocks)
        updateGateToken = try container.decodeIfPresent(UUID.self, forKey: .updateGateToken)
        liveUpdateGate = try container.decodeIfPresent(ProtectedLiveUpdateGate.self, forKey: .liveUpdateGate)
        lastLiveUpdateCompletion = try container.decodeIfPresent(
            ProtectedLiveUpdateCompletion.self, forKey: .lastLiveUpdateCompletion
        )
        lastInactiveMigrationToken = try container.decodeIfPresent(
            UUID.self, forKey: .lastInactiveMigrationToken
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(blocks, forKey: .blocks)
        try container.encodeIfPresent(updateGateToken, forKey: .updateGateToken)
        try container.encodeIfPresent(liveUpdateGate, forKey: .liveUpdateGate)
        try container.encodeIfPresent(lastLiveUpdateCompletion, forKey: .lastLiveUpdateCompletion)
        try container.encodeIfPresent(lastInactiveMigrationToken, forKey: .lastInactiveMigrationToken)
    }

    mutating func prepareUpdate(token: UUID) throws {
        guard liveUpdateGate == nil else {
            throw ProtectedStateError.updateInProgress
        }
        if let updateGateToken {
            guard updateGateToken == token else { throw ProtectedStateError.updateInProgress }
            return
        }
        updateGateToken = token
    }

    mutating func cancelUpdate(token: UUID) throws {
        guard let updateGateToken else { return }
        guard updateGateToken == token else { throw ProtectedStateError.updateNotOwned }
        self.updateGateToken = nil
    }

    mutating func beginLiveUpdate(_ gate: ProtectedLiveUpdateGate) throws {
        guard updateGateToken == nil, liveUpdateGate == nil else {
            throw ProtectedStateError.updateInProgress
        }
        liveUpdateGate = gate
    }

    mutating func endLiveUpdate(token: UUID, finalized: Bool) throws {
        guard let liveUpdateGate else { throw ProtectedStateError.updateUnavailable }
        guard liveUpdateGate.token == token else { throw ProtectedStateError.updateNotOwned }
        lastLiveUpdateCompletion = ProtectedLiveUpdateCompletion(
            token: liveUpdateGate.token,
            generation: liveUpdateGate.generation,
            successorDigest: liveUpdateGate.successorDigest,
            phase: finalized ? .finalized : .cancelled
        )
        self.liveUpdateGate = nil
    }

    mutating func completeInactiveMigration(token: UUID) {
        lastInactiveMigrationToken = token
    }

    mutating func create(_ draft: ProtectedBlockDraft) throws -> ProtectedBlockRecord {
        guard blocks.count < ProtectedBlockLimits.maximumBlocks else {
            throw ProtectedStateError.blockLimitReached
        }
        let record = ProtectedBlockRecord(draft: try draft.validatedForMutation())
        var candidate = self
        candidate.blocks.append(record)
        try candidate.validateReplySize()
        self = candidate
        return record
    }

    mutating func update(id: UUID, expectedRevision: Int, draft: ProtectedBlockDraft) throws {
        let index = try checkedIndex(id: id, expectedRevision: expectedRevision)
        var candidate = self
        try candidate.blocks[index].update(draft)
        try candidate.validateReplySize()
        self = candidate
    }

    mutating func delete(id: UUID, expectedRevision: Int) throws {
        let index = try checkedIndex(id: id, expectedRevision: expectedRevision)
        guard blocks[index].activation == nil else { throw ProtectedStateError.activeBlockIsImmutable }
        blocks.remove(at: index)
    }

    mutating func activate(id: UUID, expectedRevision: Int, at reading: ClockReading) throws {
        let index = try checkedIndex(id: id, expectedRevision: expectedRevision)
        var candidate = self
        try candidate.blocks[index].activate(at: reading)
        try candidate.validateReplySize()
        self = candidate
    }

    mutating func request(_ kind: ProtectedRequestKind, id: UUID, at reading: ClockReading) throws {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            throw ProtectedStateError.blockNotFound
        }
        try blocks[index].request(kind, at: reading)
    }

    mutating func cancelBreakRequest(id: UUID, at reading: ClockReading) throws {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            throw ProtectedStateError.blockNotFound
        }
        try blocks[index].cancelBreakRequest(at: reading)
    }

    @discardableResult
    mutating func advance(to reading: ClockReading) -> Set<UUID> {
        var ended = Set<UUID>()
        for index in blocks.indices where blocks[index].activation != nil {
            if !blocks[index].advance(to: reading) { ended.insert(blocks[index].id) }
        }
        return ended
    }

    func effectiveRestrictions() -> EffectiveRestrictions {
        restrictions(includingBreaks: false)
    }

    func conservativeUpdateRestrictions() -> EffectiveRestrictions {
        restrictions(includingBreaks: true)
    }

    private func restrictions(includingBreaks: Bool) -> EffectiveRestrictions {
        let input = RestrictionInput(
            blocks: blocks.map { block in
                RestrictionInput.Block(
                    id: block.id,
                    activation: block.activation.map {
                        RestrictionInput.Block.Activation(
                            accumulatedElapsed: $0.accumulatedElapsed,
                            breakEndsAtElapsed: $0.breakEndsAtElapsed,
                            rules: $0.frozenDraft.rules
                        )
                    }
                )
            },
            includingBreaks: includingBreaks
        )
        if let result: EffectiveRestrictions = try? RustCoreBridge.call("restrictions.compose", input) {
            return EffectiveRestrictions(
                blockedDomains: result.blockedDomains.sorted(),
                blockedApplications: result.blockedApplications.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                },
                contributingBlockIDs: result.contributingBlockIDs.sorted { $0.uuidString < $1.uuidString },
                blockedURLPatterns: result.blockedURLPatterns.sorted()
            )
        }

        // A core failure must keep every active block's rules in force, including breaks.
        var domains = Set<String>()
        var urlPatterns = Set<String>()
        var applications: [String: ProtectedApplication] = [:]
        var contributingBlocks = Set<UUID>()
        for block in blocks {
            guard let activation = block.activation else { continue }
            contributingBlocks.insert(block.id)
            domains.formUnion(activation.frozenDraft.rules.allBlockedDomains)
            urlPatterns.formUnion(activation.frozenDraft.rules.blockedURLPatterns)
            for application in activation.frozenDraft.rules.blockedApplications {
                applications[application.id] = application
            }
        }
        return EffectiveRestrictions(
            blockedDomains: domains.sorted(),
            blockedApplications: applications.values.sorted {
                ($0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending)
            },
            contributingBlockIDs: contributingBlocks.sorted { $0.uuidString < $1.uuidString },
            blockedURLPatterns: urlPatterns.sorted()
        )
    }

    func snapshot(at date: Date, protection: ProtectionStatus) -> ProtectedServiceSnapshot {
        ProtectedServiceSnapshot(
            generatedAt: date,
            blocks: blocks.map {
                let phase: ProtectedBlockPhase
                if let activation = $0.activation {
                    phase =
                        liveUpdateGate == nil
                        ? activation.phase() : .active(naturalEndRemaining: nil)
                } else {
                    phase = .inactive
                }
                return ProtectedBlockSnapshot(
                    id: $0.id,
                    revision: $0.revision,
                    draft: $0.draft,
                    phase: phase
                )
            },
            effectiveRestrictions: liveUpdateGate == nil
                ? effectiveRestrictions() : conservativeUpdateRestrictions(),
            protection: protection
        )
    }

    func validateForPersistence() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProtectedStateError.invalid("The protected state format is not supported.")
        }
        let gateCount = [updateGateToken != nil, liveUpdateGate != nil]
            .filter { $0 }.count
        if gateCount > 1 {
            throw ProtectedStateError.invalid("Multiple update gates cannot be active.")
        }
        try liveUpdateGate?.validate()
        if let lastLiveUpdateCompletion {
            guard
                lastLiveUpdateCompletion.phase == .finalized
                    || lastLiveUpdateCompletion.phase == .cancelled
            else {
                throw ProtectedStateError.invalid("The update completion phase is invalid.")
            }
            try ProtectedLiveUpdateGate(
                token: UUID(),
                generation: lastLiveUpdateCompletion.generation,
                successorDigest: lastLiveUpdateCompletion.successorDigest
            ).validate()
        }
        guard blocks.count <= ProtectedBlockLimits.maximumBlocks,
            Set(blocks.map(\.id)).count == blocks.count
        else {
            throw ProtectedStateError.invalid("The protected state contains too many or duplicate blocks.")
        }
        for block in blocks { try block.validateForPersistence() }
        let encodedState = try JSONEncoder().encode(self)
        guard encodedState.count <= ProtectedServiceContract.maximumPayloadBytes else {
            throw ProtectedStateError.aggregateLimitReached
        }
        try validateReplySize()
    }

    private func checkedIndex(id: UUID, expectedRevision: Int) throws -> Int {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            throw ProtectedStateError.blockNotFound
        }
        guard blocks[index].revision == expectedRevision else {
            throw ProtectedStateError.revisionConflict
        }
        return index
    }

    private func validateReplySize() throws {
        let reply = ProtectedServiceReply.success(
            snapshot(at: Date(timeIntervalSinceReferenceDate: 0), protection: .unavailable)
        )
        let data = try JSONEncoder().encode(reply)
        let policyLimit =
            ProtectedServiceContract.maximumPayloadBytes
            - ProtectedBlockLimits.serviceStatusReplyReserve
        guard data.count <= policyLimit else {
            throw ProtectedStateError.aggregateLimitReached
        }
    }
}

struct EffectiveRestrictions: Codable, Equatable, Sendable {
    let blockedDomains: [String]
    let blockedApplications: [ProtectedApplication]
    let contributingBlockIDs: [UUID]
    let blockedURLPatterns: [String]

    init(
        blockedDomains: [String],
        blockedApplications: [ProtectedApplication],
        contributingBlockIDs: [UUID],
        blockedURLPatterns: [String] = []
    ) {
        self.blockedDomains = blockedDomains
        self.blockedApplications = blockedApplications
        self.contributingBlockIDs = contributingBlockIDs
        self.blockedURLPatterns = blockedURLPatterns
    }

    private enum CodingKeys: String, CodingKey {
        case blockedDomains
        case blockedApplications
        case contributingBlockIDs
        case blockedURLPatterns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            blockedDomains: try container.decode([String].self, forKey: .blockedDomains),
            blockedApplications: try container.decode(
                [ProtectedApplication].self,
                forKey: .blockedApplications
            ),
            contributingBlockIDs: try container.decode([UUID].self, forKey: .contributingBlockIDs),
            blockedURLPatterns: try container.decodeIfPresent(
                [String].self,
                forKey: .blockedURLPatterns
            ) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blockedDomains, forKey: .blockedDomains)
        try container.encode(blockedApplications, forKey: .blockedApplications)
        try container.encode(contributingBlockIDs, forKey: .contributingBlockIDs)
        try container.encode(blockedURLPatterns, forKey: .blockedURLPatterns)
    }
}

struct ProtectedBlockSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let revision: Int
    let draft: ProtectedBlockDraft
    let phase: ProtectedBlockPhase
}

struct ProtectionIssue: Codable, Equatable, Identifiable, Sendable {
    let code: String
    let message: String
    let blockIDs: [UUID]

    var id: String { "\(code):\(blockIDs.map(\.uuidString).joined(separator: ","))" }
}

struct ClosedApplicationNotice: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let applicationName: String
    let blockNames: [String]
    let closedAt: Date
}

struct ProtectionStatus: Codable, Equatable, Sendable {
    let serviceVersion: String
    let isEnforcing: Bool
    let lastAppliedAt: Date?
    let issues: [ProtectionIssue]
    let recentApplicationClosures: [ClosedApplicationNotice]

    init(
        serviceVersion: String,
        isEnforcing: Bool,
        lastAppliedAt: Date?,
        issues: [ProtectionIssue],
        recentApplicationClosures: [ClosedApplicationNotice]
    ) {
        self.serviceVersion = serviceVersion.utf8Prefix(maxBytes: 64)
        self.isEnforcing = isEnforcing
        self.lastAppliedAt = lastAppliedAt
        self.issues = issues.prefix(16).map {
            ProtectionIssue(
                code: $0.code.utf8Prefix(maxBytes: 64),
                message: $0.message.utf8Prefix(maxBytes: 256),
                blockIDs: Array($0.blockIDs.prefix(8))
            )
        }
        self.recentApplicationClosures = recentApplicationClosures.prefix(8).map {
            ClosedApplicationNotice(
                id: $0.id,
                applicationName: $0.applicationName.utf8Prefix(maxBytes: 120),
                blockNames: $0.blockNames.prefix(4).map { $0.utf8Prefix(maxBytes: 120) },
                closedAt: $0.closedAt
            )
        }
    }

    static let unavailable = ProtectionStatus(
        serviceVersion: "unavailable",
        isEnforcing: false,
        lastAppliedAt: nil,
        issues: [],
        recentApplicationClosures: []
    )
}

extension String {
    fileprivate func utf8Prefix(maxBytes: Int) -> String {
        guard utf8.count > maxBytes else { return self }
        let bytes = Array(utf8.prefix(maxBytes))
        for count in stride(from: bytes.count, through: 0, by: -1) {
            if let value = String(bytes: bytes.prefix(count), encoding: .utf8) {
                return value
            }
        }
        return ""
    }
}

struct ProtectedServiceSnapshot: Codable, Equatable, Sendable {
    let generatedAt: Date
    let blocks: [ProtectedBlockSnapshot]
    let effectiveRestrictions: EffectiveRestrictions
    let protection: ProtectionStatus
}

enum ProtectedStateError: LocalizedError, Equatable {
    case invalid(String)
    case blockNotFound
    case revisionConflict
    case activeBlockIsImmutable
    case inactive
    case pendingRequestExists
    case noPendingBreakRequest
    case breakAlreadyActive
    case blockLimitReached
    case aggregateLimitReached
    case updateUnavailable
    case updateInProgress
    case updateNotOwned

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .blockNotFound: return "The block no longer exists."
        case .revisionConflict: return "The block changed. Reload it and try again."
        case .activeBlockIsImmutable:
            return "An active block can only gain rules. It cannot be weakened or deleted."
        case .inactive: return "The block is not active."
        case .pendingRequestExists: return "A request is already waiting and cannot be replaced."
        case .noPendingBreakRequest: return "There is no pending break request to cancel."
        case .breakAlreadyActive: return "This block is already on a break."
        case .blockLimitReached: return "Hard Pause supports up to 128 saved blocks."
        case .aggregateLimitReached:
            return "The saved blocks contain too many rules for the protection service."
        case .updateUnavailable:
            return "The service is not healthy and inactive, so it cannot prepare for an update."
        case .updateInProgress: return "Another Hard Pause update is already in progress."
        case .updateNotOwned: return "This update request does not own the service update gate."
        }
    }
}
