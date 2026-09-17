import Foundation

enum PauseCoreRequestKind: String, Codable, Equatable, Sendable {
    case breakAccess
    case fullUnlock
}

struct PauseCorePendingRequest: Equatable, Sendable {
    let kind: PauseCoreRequestKind
    let readyAt: TimeInterval
    let breakEndsAt: TimeInterval?
}

struct PauseCoreLifecycleState: Equatable, Sendable {
    var isActive: Bool
    var naturalEndAt: TimeInterval?
    var pendingRequest: PauseCorePendingRequest?
    var breakEndsAt: TimeInterval?
}

enum PauseCoreFullUnlockDuringBreak: Equatable, Sendable {
    /// macOS keeps the current break open while the full-unlock delay runs.
    case keepBreakOpen
    /// iOS restores restrictions while the full-unlock delay runs.
    case resumeBlocking
}

struct PauseCoreLifecycleProfile: Equatable, Sendable {
    let fullUnlockDuringBreak: PauseCoreFullUnlockDuringBreak

    static let macOS = PauseCoreLifecycleProfile(fullUnlockDuringBreak: .keepBreakOpen)
    static let iOS = PauseCoreLifecycleProfile(fullUnlockDuringBreak: .resumeBlocking)
}

enum PauseCoreLifecycleError: Error, Equatable, Sendable {
    case inactive
    case pendingRequestExists
    case breakAlreadyActive
    case noPendingBreakRequest
}

enum PauseCoreLifecyclePhase: Equatable, Sendable {
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

enum PauseCoreLifecycle {
    static func requestBreak(
        _ state: inout PauseCoreLifecycleState,
        at now: TimeInterval,
        delay: TimeInterval,
        duration: TimeInterval
    ) throws {
        guard state.isActive else { throw PauseCoreLifecycleError.inactive }
        guard state.pendingRequest == nil else {
            throw PauseCoreLifecycleError.pendingRequestExists
        }
        guard state.breakEndsAt == nil || now >= state.breakEndsAt! else {
            throw PauseCoreLifecycleError.breakAlreadyActive
        }
        let readyAt = now + delay
        state.pendingRequest = PauseCorePendingRequest(
            kind: .breakAccess,
            readyAt: readyAt,
            breakEndsAt: readyAt + duration
        )
        state.breakEndsAt = nil
    }

    static func requestFullUnlock(
        _ state: inout PauseCoreLifecycleState,
        at now: TimeInterval,
        delay: TimeInterval,
        profile: PauseCoreLifecycleProfile
    ) throws {
        guard state.isActive else { throw PauseCoreLifecycleError.inactive }
        guard state.pendingRequest == nil else {
            throw PauseCoreLifecycleError.pendingRequestExists
        }
        state.pendingRequest = PauseCorePendingRequest(
            kind: .fullUnlock,
            readyAt: now + delay,
            breakEndsAt: nil
        )
        if profile.fullUnlockDuringBreak == .resumeBlocking {
            state.breakEndsAt = nil
        }
    }

    static func cancelBreak(_ state: inout PauseCoreLifecycleState) throws {
        guard state.isActive else { throw PauseCoreLifecycleError.inactive }
        guard state.pendingRequest?.kind == .breakAccess else {
            throw PauseCoreLifecycleError.noPendingBreakRequest
        }
        state.pendingRequest = nil
    }

    @discardableResult
    static func reconcile(
        _ state: inout PauseCoreLifecycleState,
        at now: TimeInterval
    ) -> Bool {
        let original = state
        guard state.isActive else { return false }

        if let naturalEndAt = state.naturalEndAt, now >= naturalEndAt {
            deactivate(&state)
            return state != original
        }

        if let request = state.pendingRequest, now >= request.readyAt {
            switch request.kind {
            case .fullUnlock:
                deactivate(&state)
                return state != original
            case .breakAccess:
                state.pendingRequest = nil
                if let breakEndsAt = request.breakEndsAt, now < breakEndsAt {
                    state.breakEndsAt = breakEndsAt
                } else {
                    state.breakEndsAt = nil
                }
            }
        }

        if let breakEndsAt = state.breakEndsAt, now >= breakEndsAt {
            state.breakEndsAt = nil
        }
        return state != original
    }

    static func phase(
        of state: PauseCoreLifecycleState,
        at now: TimeInterval
    ) -> PauseCoreLifecyclePhase {
        guard state.isActive else { return .inactive }
        let naturalEndRemaining = state.naturalEndAt.map { max(0, $0 - now) }
        if let breakEndsAt = state.breakEndsAt, now < breakEndsAt {
            let fullUnlockRemaining = state.pendingRequest.flatMap { request in
                request.kind == .fullUnlock ? max(0, request.readyAt - now) : nil
            }
            return .breakActive(
                remaining: breakEndsAt - now,
                fullUnlockRemaining: fullUnlockRemaining,
                naturalEndRemaining: naturalEndRemaining
            )
        }
        if let request = state.pendingRequest {
            let remaining = max(0, request.readyAt - now)
            return request.kind == .breakAccess
                ? .waitingForBreak(
                    remaining: remaining,
                    naturalEndRemaining: naturalEndRemaining
                )
                : .waitingForFullUnlock(
                    remaining: remaining,
                    naturalEndRemaining: naturalEndRemaining
                )
        }
        return .active(naturalEndRemaining: naturalEndRemaining)
    }

    private static func deactivate(_ state: inout PauseCoreLifecycleState) {
        state.isActive = false
        state.naturalEndAt = nil
        state.pendingRequest = nil
        state.breakEndsAt = nil
    }
}
