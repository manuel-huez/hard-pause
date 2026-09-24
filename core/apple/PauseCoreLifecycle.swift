import Foundation

enum PauseCoreRequestKind: String, Codable, Equatable, Sendable {
    case breakAccess
    case fullUnlock
}

struct PauseCorePendingRequest: Codable, Equatable, Sendable {
    let kind: PauseCoreRequestKind
    let readyAt: TimeInterval
    let breakEndsAt: TimeInterval?
}

struct PauseCoreLifecycleState: Codable, Equatable, Sendable {
    var isActive: Bool
    var naturalEndAt: TimeInterval?
    var pendingRequest: PauseCorePendingRequest?
    var breakEndsAt: TimeInterval?
}

enum PauseCoreFullUnlockDuringBreak: Equatable, Sendable {
    case keepBreakOpen
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
    case coreUnavailable
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
    private struct At: Encodable {
        let state: PauseCoreLifecycleState
        let now: TimeInterval
    }

    private struct BreakRequest: Encodable {
        let state: PauseCoreLifecycleState
        let now: TimeInterval
        let delay: TimeInterval
        let duration: TimeInterval
    }

    private struct UnlockRequest: Encodable {
        let state: PauseCoreLifecycleState
        let now: TimeInterval
        let delay: TimeInterval
        let profile: String
    }

    private struct Mutation: Decodable {
        let state: PauseCoreLifecycleState
        let changed: Bool?
    }

    private struct Phase: Decodable {
        let kind: String
        let remaining: TimeInterval?
        let fullUnlockRemaining: TimeInterval?
        let naturalEndRemaining: TimeInterval?

        var value: PauseCoreLifecyclePhase? {
            switch kind {
            case "inactive": .inactive
            case "active": .active(naturalEndRemaining: naturalEndRemaining)
            case "waitingForBreak":
                remaining.map { .waitingForBreak(remaining: $0, naturalEndRemaining: naturalEndRemaining) }
            case "waitingForFullUnlock":
                remaining.map { .waitingForFullUnlock(remaining: $0, naturalEndRemaining: naturalEndRemaining) }
            case "breakActive":
                remaining.map {
                    .breakActive(
                        remaining: $0,
                        fullUnlockRemaining: fullUnlockRemaining,
                        naturalEndRemaining: naturalEndRemaining
                    )
                }
            default: nil
            }
        }
    }

    static func requestBreak(
        _ state: inout PauseCoreLifecycleState,
        at now: TimeInterval,
        delay: TimeInterval,
        duration: TimeInterval
    ) throws {
        state = try mutate(
            "lifecycle.request_break",
            BreakRequest(state: state, now: now, delay: delay, duration: duration)
        ).state
    }

    static func requestFullUnlock(
        _ state: inout PauseCoreLifecycleState,
        at now: TimeInterval,
        delay: TimeInterval,
        profile: PauseCoreLifecycleProfile
    ) throws {
        state = try mutate(
            "lifecycle.request_full_unlock",
            UnlockRequest(
                state: state,
                now: now,
                delay: delay,
                profile: profile.fullUnlockDuringBreak == .keepBreakOpen ? "macOS" : "iOS"
            )
        ).state
    }

    static func cancelBreak(_ state: inout PauseCoreLifecycleState) throws {
        state = try mutate("lifecycle.cancel_break", At(state: state, now: 0)).state
    }

    @discardableResult
    static func reconcile(_ state: inout PauseCoreLifecycleState, at now: TimeInterval) -> Bool {
        guard let result = try? mutate("lifecycle.reconcile", At(state: state, now: now)) else {
            return false
        }
        state = result.state
        return result.changed == true
    }

    static func phase(of state: PauseCoreLifecycleState, at now: TimeInterval) -> PauseCoreLifecyclePhase {
        let phase: Phase? = try? RustCoreBridge.call("lifecycle.phase", At(state: state, now: now))
        if let value = phase?.value { return value }
        return state.isActive ? .active(naturalEndRemaining: nil) : .inactive
    }

    private static func mutate<Arguments: Encodable>(
        _ operation: String,
        _ arguments: Arguments
    ) throws -> Mutation {
        do {
            return try RustCoreBridge.call(operation, arguments)
        } catch RustCoreBridge.Failure.rejected(let code) {
            switch code {
            case "inactive": throw PauseCoreLifecycleError.inactive
            case "pending_request_exists": throw PauseCoreLifecycleError.pendingRequestExists
            case "break_already_active": throw PauseCoreLifecycleError.breakAlreadyActive
            case "no_pending_break_request": throw PauseCoreLifecycleError.noPendingBreakRequest
            default: throw PauseCoreLifecycleError.coreUnavailable
            }
        } catch {
            throw PauseCoreLifecycleError.coreUnavailable
        }
    }
}
