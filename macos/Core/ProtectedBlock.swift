import Foundation

enum ProtectedBlockLimits {
    static let maximumBlocks = 128
    static let maximumDomains = 10_000
    static let maximumApplications = 1_000
    static let maximumNameLength = 120
    static let maximumRequirementLength = 16_384
    static let maximumURLPatternLength = 4_096
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

    var blocksStarterAdultSites: Bool { !blockedAdultDomains.isEmpty }
    var allBlockedDomains: [String] { blockedDomains + blockedAdultDomains }

    init(
        blockedDomains: [String],
        blockedApplications: [ProtectedApplication],
        blocksStarterAdultSites: Bool,
        blockedURLPatterns: [String] = []
    ) {
        var seenDomains = Set<String>()
        self.blockedDomains = blockedDomains.compactMap(DomainRule.normalize).filter {
            seenDomains.insert($0).inserted
        }
        var seenApplications = Set<String>()
        self.blockedApplications = blockedApplications.filter {
            seenApplications.insert($0.id).inserted
        }
        blockedAdultDomains = blocksStarterAdultSites ? StarterAdultRules.domains : []
        adultRulesVersion = blocksStarterAdultSites ? StarterAdultRules.version : nil
        var seenPatterns = Set<String>()
        self.blockedURLPatterns = blockedURLPatterns.compactMap(URLPatternRule.normalize).filter {
            seenPatterns.insert($0).inserted
        }
    }

    init(
        blockedDomains: [String],
        blockedApplications: [ProtectedApplication],
        blockedAdultDomains: [String],
        adultRulesVersion: Int?,
        blockedURLPatterns: [String] = []
    ) {
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
            ) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blockedDomains, forKey: .blockedDomains)
        try container.encode(blockedApplications, forKey: .blockedApplications)
        try container.encode(blockedAdultDomains, forKey: .blockedAdultDomains)
        try container.encodeIfPresent(adultRulesVersion, forKey: .adultRulesVersion)
        try container.encode(blockedURLPatterns, forKey: .blockedURLPatterns)
    }

    func validateForPersistence(allowLegacyApplicationIdentity: Bool = false) throws {
        guard
            blockedDomains.count + blockedAdultDomains.count + blockedURLPatterns.count
                <= ProtectedBlockLimits.maximumDomains,
            blockedApplications.count <= ProtectedBlockLimits.maximumApplications
        else {
            throw ProtectedStateError.invalid("The block has too many rules.")
        }
        guard
            !blockedDomains.isEmpty || !blockedAdultDomains.isEmpty
                || !blockedApplications.isEmpty || !blockedURLPatterns.isEmpty
        else {
            throw ProtectedStateError.invalid("Add at least one website or application.")
        }
        let domains = blockedDomains + blockedAdultDomains
        guard domains.allSatisfy({ DomainRule.normalize($0) == $0 && $0.count <= 253 }),
            Set(blockedDomains).count == blockedDomains.count,
            Set(blockedAdultDomains).count == blockedAdultDomains.count
        else {
            throw ProtectedStateError.invalid("The block contains an invalid or duplicate domain.")
        }
        guard
            blockedURLPatterns.allSatisfy({
                $0.count <= ProtectedBlockLimits.maximumURLPatternLength
                    && URLPatternRule.normalize($0) == $0
            }), Set(blockedURLPatterns).count == blockedURLPatterns.count
        else {
            throw ProtectedStateError.invalid("The block contains an invalid or duplicate URL pattern.")
        }
        guard
            (blockedAdultDomains.isEmpty && adultRulesVersion == nil)
                || (!blockedAdultDomains.isEmpty && adultRulesVersion != nil)
        else {
            throw ProtectedStateError.invalid("The adult website rules are inconsistent.")
        }
        guard Set(blockedApplications.map(\.id)).count == blockedApplications.count else {
            throw ProtectedStateError.invalid("The block contains a duplicate application.")
        }
        for application in blockedApplications {
            guard !application.bundleIdentifier.isEmpty,
                application.bundleIdentifier.count <= 512,
                !application.displayName.isEmpty,
                application.displayName.count <= 512
            else {
                throw ProtectedStateError.invalid("The block contains an invalid application.")
            }
            if let requirement = application.designatedRequirement {
                guard !requirement.isEmpty,
                    requirement.count <= ProtectedBlockLimits.maximumRequirementLength
                else {
                    throw ProtectedStateError.invalid("An application identity is invalid.")
                }
            } else if !allowLegacyApplicationIdentity {
                throw ProtectedStateError.invalid(
                    "Choose the application again so Hard Pause can save its signed identity."
                )
            }
        }
    }
}

struct ProtectedBlockDraft: Codable, Equatable, Sendable {
    let name: String
    let rules: ProtectedRules
    let breakDelay: TimeInterval
    let fullUnlockDelay: TimeInterval
    let breakDuration: TimeInterval
    let elapsedDuration: TimeInterval?

    func validatedForMutation() throws -> ProtectedBlockDraft {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= ProtectedBlockLimits.maximumNameLength else {
            throw ProtectedStateError.invalid("Enter a block name with 120 characters or fewer.")
        }
        try rules.validateForPersistence(allowLegacyApplicationIdentity: false)
        try Self.validateDuration(breakDelay, label: "break delay")
        try Self.validateDuration(fullUnlockDelay, label: "full unlock delay")
        try Self.validateDuration(breakDuration, label: "break duration")
        if let elapsedDuration {
            try Self.validateDuration(elapsedDuration, label: "fixed duration")
        }
        return ProtectedBlockDraft(
            name: cleanName,
            rules: rules,
            breakDelay: breakDelay,
            fullUnlockDelay: fullUnlockDelay,
            breakDuration: breakDuration,
            elapsedDuration: elapsedDuration
        )
    }

    func validateForPersistence(allowLegacyApplicationIdentity: Bool = false) throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanName == name, !name.isEmpty, name.count <= ProtectedBlockLimits.maximumNameLength else {
            throw ProtectedStateError.invalid("A saved block name is invalid.")
        }
        try rules.validateForPersistence(allowLegacyApplicationIdentity: allowLegacyApplicationIdentity)
        try Self.validateDuration(breakDelay, label: "break delay")
        try Self.validateDuration(fullUnlockDelay, label: "full unlock delay")
        try Self.validateDuration(breakDuration, label: "break duration")
        if let elapsedDuration {
            try Self.validateDuration(elapsedDuration, label: "fixed duration")
        }
    }

    private static func validateDuration(_ duration: TimeInterval, label: String) throws {
        guard duration.isFinite,
            duration >= ProtectedBlockLimits.minimumDelay,
            duration <= ProtectedBlockLimits.maximumDelay
        else {
            throw ProtectedStateError.invalid("The \(label) is outside the supported range.")
        }
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
    let frozenDraft: ProtectedBlockDraft
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

    var restrictionsAreActive: Bool {
        guard let breakEndsAtElapsed else { return true }
        return accumulatedElapsed >= breakEndsAtElapsed
    }

    mutating func request(_ kind: ProtectedRequestKind, at reading: ClockReading) throws {
        guard advance(to: reading) else { throw ProtectedStateError.inactive }
        guard pendingRequest == nil else { throw ProtectedStateError.pendingRequestExists }
        if kind == .breakAccess, !restrictionsAreActive {
            throw ProtectedStateError.breakAlreadyActive
        }
        pendingRequest = ProtectedPendingRequest(
            kind: kind,
            requestedAtElapsed: accumulatedElapsed,
            requestedAtWallTime: reading.wallTime
        )
    }

    @discardableResult
    mutating func advance(to reading: ClockReading) -> Bool {
        accrue(to: reading)
        if let duration = frozenDraft.elapsedDuration, accumulatedElapsed >= duration {
            return false
        }
        if let request = pendingRequest {
            let delay = request.kind == .breakAccess ? frozenDraft.breakDelay : frozenDraft.fullUnlockDelay
            let readyAt = request.requestedAtElapsed + delay
            if accumulatedElapsed >= readyAt {
                if request.kind == .fullUnlock { return false }
                pendingRequest = nil
                breakEndsAtElapsed = readyAt + frozenDraft.breakDuration
            }
        }
        if let breakEndsAtElapsed, accumulatedElapsed >= breakEndsAtElapsed {
            self.breakEndsAtElapsed = nil
        }
        return true
    }

    func phase() -> ProtectedBlockPhase {
        let naturalEndRemaining = frozenDraft.elapsedDuration.map { max(0, $0 - accumulatedElapsed) }
        if let breakEndsAtElapsed, accumulatedElapsed < breakEndsAtElapsed {
            let unlockRemaining: TimeInterval?
            if let pendingRequest, pendingRequest.kind == .fullUnlock {
                unlockRemaining = max(
                    0,
                    pendingRequest.requestedAtElapsed + frozenDraft.fullUnlockDelay - accumulatedElapsed
                )
            } else {
                unlockRemaining = nil
            }
            return .breakActive(
                remaining: breakEndsAtElapsed - accumulatedElapsed,
                fullUnlockRemaining: unlockRemaining,
                naturalEndRemaining: naturalEndRemaining
            )
        }
        if let pendingRequest {
            let delay =
                pendingRequest.kind == .breakAccess ? frozenDraft.breakDelay : frozenDraft.fullUnlockDelay
            let remaining = max(0, pendingRequest.requestedAtElapsed + delay - accumulatedElapsed)
            return pendingRequest.kind == .breakAccess
                ? .waitingForBreak(remaining: remaining, naturalEndRemaining: naturalEndRemaining)
                : .waitingForFullUnlock(remaining: remaining, naturalEndRemaining: naturalEndRemaining)
        }
        return .active(naturalEndRemaining: naturalEndRemaining)
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
        }
        if let breakEndsAtElapsed {
            guard breakEndsAtElapsed.isFinite, breakEndsAtElapsed >= 0 else {
                throw ProtectedStateError.invalid("An active block has an invalid break.")
            }
        }
    }

    private mutating func accrue(to reading: ClockReading) {
        if let previousBoot = anchorBootIdentifier,
            let currentBoot = reading.bootIdentifier,
            previousBoot == currentBoot,
            let previousContinuous = anchorContinuousTime,
            reading.continuousTime >= previousContinuous
        {
            accumulatedElapsed += reading.continuousTime - previousContinuous
        }
        // A reboot or unknown clock adds no elapsed time. This cannot grant access early.
        anchorBootIdentifier = reading.bootIdentifier
        anchorContinuousTime = reading.continuousTime
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
        guard activation == nil else { throw ProtectedStateError.activeBlockIsImmutable }
        self.draft = try draft.validatedForMutation()
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

struct ProtectedState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    private(set) var blocks: [ProtectedBlockRecord]

    init(blocks: [ProtectedBlockRecord] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.blocks = blocks
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

    @discardableResult
    mutating func advance(to reading: ClockReading) -> Set<UUID> {
        var ended = Set<UUID>()
        for index in blocks.indices where blocks[index].activation != nil {
            if !blocks[index].advance(to: reading) { ended.insert(blocks[index].id) }
        }
        return ended
    }

    func effectiveRestrictions() -> EffectiveRestrictions {
        var domains = Set<String>()
        var urlPatterns = Set<String>()
        var applications: [String: ProtectedApplication] = [:]
        var contributingBlocks = Set<UUID>()
        for block in blocks {
            guard let activation = block.activation, activation.restrictionsAreActive else { continue }
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
                ProtectedBlockSnapshot(
                    id: $0.id,
                    revision: $0.revision,
                    draft: $0.draft,
                    phase: $0.activation?.phase() ?? .inactive
                )
            },
            effectiveRestrictions: effectiveRestrictions(),
            protection: protection
        )
    }

    func validateForPersistence() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProtectedStateError.invalid("The protected state format is not supported.")
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
    case breakAlreadyActive
    case blockLimitReached
    case aggregateLimitReached

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .blockNotFound: return "The block no longer exists."
        case .revisionConflict: return "The block changed. Reload it and try again."
        case .activeBlockIsImmutable: return "An active block cannot be changed or deleted."
        case .inactive: return "The block is not active."
        case .pendingRequestExists: return "A request is already waiting and cannot be replaced."
        case .breakAlreadyActive: return "This block is already on a break."
        case .blockLimitReached: return "Hard Pause supports up to 128 saved blocks."
        case .aggregateLimitReached:
            return "The saved blocks contain too many rules for the protection service."
        }
    }
}
