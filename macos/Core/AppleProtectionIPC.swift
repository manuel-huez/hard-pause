import Foundation

enum AppleLockdownPhase: String, Codable, Equatable, Sendable {
    case inactive
    case pendingSetup
    case active
    case waitingForFullUnlock
    case readyForRelease
    case releaseInProgress

    var hasConfirmedSystemPasscode: Bool {
        switch self {
        case .active, .waitingForFullUnlock, .readyForRelease, .releaseInProgress:
            return true
        case .inactive, .pendingSetup:
            return false
        }
    }
}

enum AppleAppAgeRating: Int, Codable, Equatable, Sendable {
    case disallowed = 0
    case four = 4
    case nine = 9
    case thirteen = 13
    case sixteen = 16
    case eighteen = 18
    case unrated = 1000
}

struct AppleAppAgeRestriction: Codable, Equatable, Sendable {
    let baseline: AppleAppAgeRating
    let applied: AppleAppAgeRating

    init(baseline: AppleAppAgeRating) {
        self.baseline = baseline
        applied = baseline.rawValue <= 16 ? baseline : .sixteen
    }

    func restorationTarget(current: AppleAppAgeRating) -> AppleAppAgeRating? {
        current == applied && baseline != applied ? baseline : nil
    }

    func validate() throws {
        guard applied == AppleAppAgeRestriction(baseline: baseline).applied else {
            throw AppleLockdownError.invalidRequest("The Screen Time app age limit is invalid.")
        }
    }
}

struct AppleAppAgeRestorationPermit: Codable, Equatable, Sendable {
    let operationID: UUID
    let writer: AppleWebsiteSyncWriter
}

struct AppleLockdownSetupRequest: Codable, Equatable, Sendable {
    // Zero links removal to the last Screen Time plan; positive values preserve older setup waits.
    let fullUnlockDelay: TimeInterval
    let enablesAdultFilter: Bool
    let filterWasAlreadyEnabled: Bool
    let shareAcrossDevicesVerified: Bool?
    var appAgeRestriction: AppleAppAgeRestriction? = nil

    func validate() throws {
        guard fullUnlockDelay.isFinite,
            fullUnlockDelay == 0 || fullUnlockDelay >= ProtectedBlockLimits.minimumDelay,
            fullUnlockDelay <= ProtectedBlockLimits.maximumDelay
        else {
            throw AppleLockdownError.invalidRequest(
                "The Screen Time protection full unlock delay is invalid."
            )
        }
        try appAgeRestriction?.validate()
    }
}

struct AppleLockdownOperationRequest: Codable, Equatable, Sendable {
    let operationID: UUID
    var verifiedAppRating: AppleAppAgeRating? = nil
    var shareAcrossDevicesVerified: Bool? = nil
}

struct AppleLockdownSnapshot: Codable, Equatable, Sendable {
    let phase: AppleLockdownPhase
    let fullUnlockDelay: TimeInterval?
    let remainingDelay: TimeInterval?
    let enablesAdultFilter: Bool
    let filterWasAlreadyEnabled: Bool
    let shareAcrossDevicesVerified: Bool?
    let mirroredDomains: [String]?
    let mirroredAllowedDomains: [String]?
    let operationID: UUID?
    var websiteSyncOperationID: UUID? = nil
    var confirmedWebsiteTargets: AppleWebsiteSyncTargets? = nil
    var appAgeRestriction: AppleAppAgeRestriction? = nil
    var keepsCodeForLegacyPlans: Bool? = nil

    var retainsCodeForLegacyPlans: Bool {
        appAgeRestriction != nil || keepsCodeForLegacyPlans == true
    }
}

struct AppleLockdownCredentialOperation: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let operationID: UUID
    let passcode: String
    let snapshot: AppleLockdownSnapshot

    var description: String {
        "AppleLockdownCredentialOperation(operationID: \(operationID), passcode: <redacted>)"
    }

    var debugDescription: String { description }
}

struct AppleLockdownServiceReply: Codable, Equatable, Sendable {
    let snapshot: AppleLockdownSnapshot?
    let credential: AppleLockdownCredentialOperation?
    let error: ProtectedServiceErrorPayload?

    static func success(_ snapshot: AppleLockdownSnapshot) -> AppleLockdownServiceReply {
        AppleLockdownServiceReply(snapshot: snapshot, credential: nil, error: nil)
    }

    static func success(
        _ credential: AppleLockdownCredentialOperation
    ) -> AppleLockdownServiceReply {
        AppleLockdownServiceReply(
            snapshot: credential.snapshot,
            credential: credential,
            error: nil
        )
    }

    static func failure(code: String, message: String) -> AppleLockdownServiceReply {
        AppleLockdownServiceReply(
            snapshot: nil,
            credential: nil,
            error: ProtectedServiceErrorPayload(code: code, message: message)
        )
    }
}

struct AppleWebsiteSyncOperation: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let operationID: UUID?
    let passcode: String
    let activeDomains: [String]
    let activeAllowedDomains: [String]
    let mirroredDomains: [String]
    let mirroredAllowedDomains: [String]

    init(
        operationID: UUID? = nil, passcode: String,
        activeDomains: [String], activeAllowedDomains: [String],
        mirroredDomains: [String], mirroredAllowedDomains: [String]
    ) {
        self.operationID = operationID
        self.passcode = passcode
        self.activeDomains = activeDomains
        self.activeAllowedDomains = activeAllowedDomains
        self.mirroredDomains = mirroredDomains
        self.mirroredAllowedDomains = mirroredAllowedDomains
    }

    var description: String { "AppleWebsiteSyncOperation(passcode: <redacted>)" }
    var debugDescription: String { description }
}

struct AppleWebsiteSyncReply: Codable, Equatable, Sendable {
    let operation: AppleWebsiteSyncOperation?
    let error: ProtectedServiceErrorPayload?
}

struct AppleWebsiteSyncCompletion: Codable, Equatable, Sendable {
    let operationID: UUID
    let verifiedDomains: [String]
    let verifiedAllowedDomains: [String]
    let mirroredDomains: [String]
    let mirroredAllowedDomains: [String]
}

struct AppleWebsiteSyncClaim: Codable, Equatable, Sendable {
    let domains: [String]
    let allowedDomains: [String]
    let expectedDomains: [String]
    let expectedAllowedDomains: [String]
}

struct AppleWebsiteSyncPermit: Codable, Equatable, Sendable {
    let operationID: UUID
    let targets: AppleWebsiteSyncTargets
    let writer: AppleWebsiteSyncWriter
}

struct AppleWebsiteSyncWriter: Codable, Equatable, Sendable {
    let processID: Int32
    let startedAtSeconds: UInt64
    let startedAtMicroseconds: UInt64
}

struct AppleWebsiteSyncTargets: Codable, Equatable, Sendable {
    let restricted: [String]
    let allowed: [String]

    init(restricted: [String], allowed: [String]) {
        self.restricted = restricted
        self.allowed = allowed
    }

    static func usesScreenTime(
        _ block: ProtectedBlockSnapshot, websitesEnabled: Bool, keepsCodeForLegacyPlans: Bool = false
    ) -> Bool {
        guard block.phase != .inactive else { return false }
        if keepsCodeForLegacyPlans { return true }
        if !block.draft.protectionMode.allowsBreaks { return true }
        let rules = block.draft.rules
        return websitesEnabled
            && (rules.blocksAdultWebsites || !rules.allBlockedDomains.isEmpty
                || !rules.blockedURLPatterns.isEmpty)
    }

    init(blocks: [ProtectedBlockSnapshot]) {
        var restricted = Set<String>()
        var allowed = Set<String>()
        var activeRules: [ProtectedRules] = []
        for block in blocks {
            // Native Screen Time settings stay in force through temporary breaks.
            guard block.phase != .inactive else { continue }
            let rules = block.draft.rules
            activeRules.append(rules)
            restricted.formUnion(Set(rules.blockedDomains).subtracting(rules.allowedDomains))
            allowed.formUnion(
                rules.allowedDomains.filter { domain in
                    Self.blocks(domain, with: rules)
                })
        }
        // Apple's parent-domain entries also cover their subdomains.
        self.restricted = restricted.filter { domain in
            !restricted.contains { domain.hasSuffix(".\($0)") }
        }.sorted()
        self.allowed = Set(
            allowed.filter { domain in
                !restricted.contains(where: {
                    $0 == domain || $0.hasSuffix(".\(domain)") || domain.hasSuffix(".\($0)")
                })
                    && !activeRules.contains { rules in
                        !rules.allowedDomains.contains(domain) && Self.blocks(domain, with: rules)
                    }
            }
        ).subtracting(restricted).sorted()
    }

    private static func blocks(_ domain: String, with rules: ProtectedRules) -> Bool {
        if rules.blocksAdultWebsites || rules.allBlockedDomains.contains(domain) { return true }
        return rules.blockedURLPatterns.contains { pattern in
            guard let parsed = ProtectedPolicy.parseURLPattern(pattern) else { return true }
            return domain == parsed.host || parsed.subdomains && domain.hasSuffix(".\(parsed.host)")
        }
    }
}

enum AppleLockdownError: LocalizedError, Equatable {
    case invalidRequest(String)
    case unavailable
    case setupAlreadyPending
    case setupNotPending
    case setupCancellationUnavailable
    case operationMismatch
    case protectionNotActive
    case releaseAlreadyRequested
    case releaseNotReady
    case normalProtectionActiveOrUnhealthy
    case releaseInProgress
    case credentialUnavailable
    case credentialStoreFailed
    case stateUnavailable
    case websiteSyncPending
    case appAgeRestorationPending
    case websiteSyncTargetsChanged
    case websiteSyncWriterUnavailable
    case websiteSyncOwnedByAnotherApp

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): return message
        case .unavailable: return "Screen Time protection is not configured."
        case .setupAlreadyPending: return "Screen Time protection setup is already in progress."
        case .setupNotPending: return "Screen Time protection setup is not pending."
        case .setupCancellationUnavailable:
            return "Screen Time protection setup cannot be cancelled after a credential is created."
        case .operationMismatch: return "The Screen Time protection operation is no longer current."
        case .protectionNotActive: return "Screen Time protection is not active."
        case .releaseAlreadyRequested: return "Screen Time protection release is already in progress."
        case .releaseNotReady: return "The Screen Time protection full unlock delay has not finished."
        case .normalProtectionActiveOrUnhealthy:
            return "A plan still uses Screen Time or protection is not healthy."
        case .releaseInProgress:
            return "Screen Time protection release must finish before protection can change."
        case .credentialUnavailable:
            return "The Screen Time protection credential is unavailable. Protection was not changed."
        case .credentialStoreFailed:
            return "The Screen Time protection credential could not be saved safely."
        case .stateUnavailable:
            return "The Screen Time protection state is unavailable."
        case .appAgeRestorationPending:
            return "Finish or retry the Screen Time app age setting update before changing protection."
        case .websiteSyncPending:
            return
                "Finish or retry Screen Time website sync before changing a plan, removing the code, or updating protection."
        case .websiteSyncTargetsChanged:
            return "Plans changed while Screen Time websites were being checked. Retry website sync."
        case .websiteSyncWriterUnavailable:
            return "Hard Pause could not confirm the app that is syncing Screen Time. Keep one copy open and retry."
        case .websiteSyncOwnedByAnotherApp:
            return "Another copy of Hard Pause is syncing Screen Time. Finish sync in that copy before you retry."
        }
    }
}
