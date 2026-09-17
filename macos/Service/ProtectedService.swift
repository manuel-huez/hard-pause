import Foundation

final class ProtectedServiceEndpoint: NSObject, ProtectedServiceXPC {
    private let engine: ProtectedServiceEngine
    private let appleLockdown: AppleLockdownEngine
    private let coordinator: ProtectedServiceCoordinator

    init(
        engine: ProtectedServiceEngine,
        appleLockdown: AppleLockdownEngine,
        coordinator: ProtectedServiceCoordinator
    ) {
        self.engine = engine
        self.appleLockdown = appleLockdown
        self.coordinator = coordinator
    }

    func list(withReply reply: @escaping (NSData) -> Void) {
        reply(encoded(.success(engine.list())))
    }

    func create(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedCreateRequest.self, reply: reply) {
            try engine.create($0)
        }
    }

    func update(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedUpdateRequest.self, reply: reply) {
            try engine.update($0)
        }
    }

    func delete(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedRevisionRequest.self, reply: reply) { request in
            try engine.delete(request)
        }
    }

    func activate(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedRevisionRequest.self, reply: reply) { request in
            try coordinator.perform {
                let readiness = appleLockdown.activationReadiness()
                guard !readiness.blocksAnyActivation else {
                    throw AppleLockdownError.releaseInProgress
                }
                return try engine.activate(
                    request,
                    appleLockdownActive: readiness.allowsLockdown
                )
            }
        }
    }

    func requestBreak(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedBlockRequest.self, reply: reply) { request in
            try engine.requestBreak(request)
        }
    }

    func cancelBreak(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedBlockRequest.self, reply: reply) { request in
            try engine.cancelBreak(request)
        }
    }

    func requestEnd(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedBlockRequest.self, reply: reply) {
            try engine.requestEnd($0)
        }
    }

    func prepareUpdate(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedBlockRequest.self, reply: reply) { request in
            try coordinator.perform {
                try appleLockdown.requireSafeMaintenance()
                return try engine.prepareUpdate(request)
            }
        }
    }

    func cancelUpdate(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedBlockRequest.self, reply: reply) {
            try engine.cancelUpdate($0)
        }
    }

    func appleLockdownStatus(withReply reply: @escaping (NSData) -> Void) {
        do {
            reply(encoded(.success(try appleLockdown.status())))
        } catch {
            reply(encoded(appleFailure(for: error)))
        }
    }

    func beginAppleLockdownSetup(
        _ request: NSData,
        withReply reply: @escaping (NSData) -> Void
    ) {
        handleApple(request, as: AppleLockdownSetupRequest.self, reply: reply) {
            .success(try appleLockdown.beginSetup($0))
        }
    }

    func resumeAppleLockdownSetup(
        _ request: NSData,
        withReply reply: @escaping (NSData) -> Void
    ) {
        handleApple(request, as: AppleLockdownOperationRequest.self, reply: reply) { request in
            .success(try appleLockdown.resumeSetup(request))
        }
    }

    func completeAppleLockdownSetup(
        _ request: NSData,
        withReply reply: @escaping (NSData) -> Void
    ) {
        handleApple(request, as: AppleLockdownOperationRequest.self, reply: reply) { request in
            .success(try appleLockdown.completeSetup(request))
        }
    }

    func confirmAppleLockdownSetupNotApplied(
        _ request: NSData,
        withReply reply: @escaping (NSData) -> Void
    ) {
        handleApple(request, as: AppleLockdownOperationRequest.self, reply: reply) {
            .success(try appleLockdown.confirmSetupNotApplied($0))
        }
    }

    func requestAppleLockdownEnd(withReply reply: @escaping (NSData) -> Void) {
        do {
            reply(encoded(.success(try appleLockdown.requestEnd())))
        } catch {
            reply(encoded(appleFailure(for: error)))
        }
    }

    func beginAppleLockdownRelease(withReply reply: @escaping (NSData) -> Void) {
        do {
            let credential = try coordinator.perform {
                let snapshot = engine.list()
                return try appleLockdown.beginRelease(
                    normalProtectionIsInactiveAndHealthy: Self.isSafeForAppleRelease(snapshot)
                )
            }
            reply(encoded(.success(credential)))
        } catch {
            reply(encoded(appleFailure(for: error)))
        }
    }

    func completeAppleLockdownRelease(
        _ request: NSData,
        withReply reply: @escaping (NSData) -> Void
    ) {
        handleApple(request, as: AppleLockdownOperationRequest.self, reply: reply) { request in
            try coordinator.perform {
                .success(try appleLockdown.completeRelease(request))
            }
        }
    }

    private func handle<Request: Decodable>(
        _ payload: NSData,
        as type: Request.Type,
        reply: @escaping (NSData) -> Void,
        operation: (Request) throws -> ProtectedServiceSnapshot
    ) {
        do {
            let request = try ProtectedServiceCodec.decode(type, from: payload)
            reply(encoded(.success(try operation(request))))
        } catch {
            reply(encoded(failure(for: error)))
        }
    }

    private func handleApple<Request: Decodable>(
        _ payload: NSData,
        as type: Request.Type,
        reply: @escaping (NSData) -> Void,
        operation: (Request) throws -> AppleLockdownServiceReply
    ) {
        do {
            let request = try ProtectedServiceCodec.decode(type, from: payload)
            reply(encoded(try operation(request)))
        } catch {
            reply(encoded(appleFailure(for: error)))
        }
    }

    private func encoded(_ value: ProtectedServiceReply) -> NSData {
        if let data = try? ProtectedServiceCodec.encode(value) { return data }
        let fallback = ProtectedServiceReply.failure(
            code: "response_too_large",
            message: "The protected state is too large to return safely."
        )
        return (try? ProtectedServiceCodec.encode(fallback)) ?? NSData()
    }

    private func encoded(_ value: AppleLockdownServiceReply) -> NSData {
        if let data = try? ProtectedServiceCodec.encode(value) { return data }
        let fallback = AppleLockdownServiceReply.failure(
            code: "response_too_large",
            message: "The Screen Time protection response is too large."
        )
        return (try? ProtectedServiceCodec.encode(fallback)) ?? NSData()
    }

    private func failure(for error: Error) -> ProtectedServiceReply {
        let code: String
        switch error {
        case ProtectedServiceCodecError.payloadTooLarge: code = "request_too_large"
        case ProtectedServiceCodecError.invalid: code = "invalid_request"
        case ProtectedStateError.invalid: code = "invalid_state"
        case ProtectedStateError.blockNotFound: code = "block_not_found"
        case ProtectedStateError.revisionConflict: code = "revision_conflict"
        case ProtectedStateError.activeBlockIsImmutable: code = "active_block_immutable"
        case ProtectedStateError.inactive: code = "block_inactive"
        case ProtectedStateError.pendingRequestExists: code = "request_pending"
        case ProtectedStateError.noPendingBreakRequest: code = "break_request_not_pending"
        case ProtectedStateError.breakAlreadyActive: code = "break_active"
        case ProtectedStateError.blockLimitReached: code = "block_limit"
        case ProtectedStateError.aggregateLimitReached: code = "aggregate_limit"
        case ProtectedStateError.updateUnavailable: code = "update_unavailable"
        case ProtectedStateError.updateInProgress: code = "update_in_progress"
        case ProtectedStateError.updateNotOwned: code = "update_not_owned"
        default: code = "service_error"
        }
        return .failure(
            code: code,
            message: error.localizedDescription.utf8ServicePrefix(maxBytes: 512)
        )
    }

    private func appleFailure(for error: Error) -> AppleLockdownServiceReply {
        let code: String
        switch error {
        case ProtectedServiceCodecError.payloadTooLarge: code = "request_too_large"
        case ProtectedServiceCodecError.invalid: code = "invalid_request"
        case AppleLockdownError.invalidRequest: code = "invalid_request"
        case AppleLockdownError.setupAlreadyPending: code = "setup_pending"
        case AppleLockdownError.setupNotPending: code = "setup_not_pending"
        case AppleLockdownError.setupCancellationUnavailable:
            code = "setup_cancellation_unavailable"
        case AppleLockdownError.operationMismatch: code = "operation_mismatch"
        case AppleLockdownError.protectionNotActive: code = "protection_inactive"
        case AppleLockdownError.releaseAlreadyRequested: code = "release_pending"
        case AppleLockdownError.releaseNotReady: code = "release_not_ready"
        case AppleLockdownError.normalProtectionActiveOrUnhealthy:
            code = "normal_protection_active"
        case AppleLockdownError.releaseInProgress: code = "release_in_progress"
        case AppleLockdownError.credentialUnavailable: code = "credential_unavailable"
        case AppleLockdownError.credentialStoreFailed: code = "credential_store_failed"
        case AppleLockdownError.stateUnavailable, AppleLockdownError.unavailable:
            code = "state_unavailable"
        default: code = "service_error"
        }
        return .failure(
            code: code,
            message: error.localizedDescription.utf8ServicePrefix(maxBytes: 512)
        )
    }

    private static func isSafeForAppleRelease(_ snapshot: ProtectedServiceSnapshot) -> Bool {
        snapshot.blocks.allSatisfy {
            if case .inactive = $0.phase { return true }
            return false
        }
            && snapshot.effectiveRestrictions.contributingBlockIDs.isEmpty
            && snapshot.protection.isEnforcing
            && snapshot.protection.lastAppliedAt != nil
            && snapshot.protection.issues.isEmpty
    }
}

final class ProtectedServiceCoordinator: @unchecked Sendable {
    private let lock = NSLock()

    func perform<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

final class ProtectedServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let engine: ProtectedServiceEngine
    private let appleLockdown: AppleLockdownEngine
    private let coordinator: ProtectedServiceCoordinator
    private let authorizer: ClientAuthorizer

    init(
        engine: ProtectedServiceEngine,
        appleLockdown: AppleLockdownEngine,
        authorizer: ClientAuthorizer
    ) {
        self.engine = engine
        self.appleLockdown = appleLockdown
        coordinator = ProtectedServiceCoordinator()
        self.authorizer = authorizer
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard authorizer.configure(newConnection) else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: ProtectedServiceXPC.self)
        newConnection.exportedObject = ProtectedServiceEndpoint(
            engine: engine,
            appleLockdown: appleLockdown,
            coordinator: coordinator
        )
        newConnection.activate()
        return true
    }
}

extension String {
    fileprivate func utf8ServicePrefix(maxBytes: Int) -> String {
        guard utf8.count > maxBytes else { return self }
        let bytes = Array(utf8.prefix(maxBytes))
        for count in stride(from: bytes.count, through: 0, by: -1) {
            if let value = String(bytes: bytes.prefix(count), encoding: .utf8) { return value }
        }
        return ""
    }
}
