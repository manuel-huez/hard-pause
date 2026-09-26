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

struct AppleLockdownSetupRequest: Codable, Equatable, Sendable {
    // Zero links removal to the last Screen Time plan; positive values preserve older setup waits.
    let fullUnlockDelay: TimeInterval
    let enablesAdultFilter: Bool
    let filterWasAlreadyEnabled: Bool
    let shareAcrossDevicesVerified: Bool?

    func validate() throws {
        guard fullUnlockDelay.isFinite,
            fullUnlockDelay == 0 || fullUnlockDelay >= ProtectedBlockLimits.minimumDelay,
            fullUnlockDelay <= ProtectedBlockLimits.maximumDelay
        else {
            throw AppleLockdownError.invalidRequest(
                "The Screen Time protection full unlock delay is invalid."
            )
        }
    }
}

struct AppleLockdownOperationRequest: Codable, Equatable, Sendable {
    let operationID: UUID
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

    static func usesScreenTime(_ block: ProtectedBlockSnapshot, websitesEnabled: Bool) -> Bool {
        guard block.phase != .inactive else { return false }
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
        self.restricted = restricted.sorted()
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
