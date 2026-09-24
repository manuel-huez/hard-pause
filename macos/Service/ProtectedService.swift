import Foundation

final class ProtectedServiceEndpoint: NSObject, ProtectedServiceXPC {
    private let engine: ProtectedServiceEngine
    private let appleLockdown: AppleLockdownEngine
    private let coordinator: ProtectedServiceCoordinator
    private let runningDigest: String
    private let inactiveMigrationToken: UUID?
    private let allowsActiveLegacyMigration: Bool

    init(
        engine: ProtectedServiceEngine,
        appleLockdown: AppleLockdownEngine,
        coordinator: ProtectedServiceCoordinator,
        runningDigest: String = "",
        inactiveMigrationToken: UUID? = nil,
        allowsActiveLegacyMigration: Bool = false
    ) {
        self.engine = engine
        self.appleLockdown = appleLockdown
        self.coordinator = coordinator
        self.runningDigest = runningDigest
        self.inactiveMigrationToken = inactiveMigrationToken
        self.allowsActiveLegacyMigration = allowsActiveLegacyMigration
    }

    func list(withReply reply: @escaping (NSData) -> Void) {
        reply(encoded(.success(coordinator.perform { engine.list() })))
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

    func finalizeInactiveMigration(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedLiveUpdateRequest.self, reply: reply) { request in
            guard inactiveMigrationToken == request.token else {
                throw ProtectedStateError.updateNotOwned
            }
            if !allowsActiveLegacyMigration {
                try appleLockdown.commitInactiveMigration()
            }
            let snapshot = try engine.finalizeInactiveMigration(
                token: request.token,
                allowsActiveLegacyMigration: allowsActiveLegacyMigration
            )
            appleLockdown.unfreezeAfterLiveUpdate()
            return snapshot
        }
    }

    func beginLiveUpdate(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handleLive(request, as: ProtectedLiveUpdateBeginRequest.self, reply: reply) { request in
            guard ProtectedServiceContract.liveServiceHandoffEnabled else {
                throw ProtectedStateError.updateUnavailable
            }
            let successorDigest = try ServiceCodeIdentity.candidateDigest(at: request.successorPath)
            guard successorDigest != runningDigest else { throw ProtectedStateError.updateUnavailable }
            let appleDigest = try appleLockdown.freezeForLiveUpdate()
            do {
                if let existing = engine.liveUpdateGate() {
                    guard existing.token == request.token,
                        existing.successorDigest == successorDigest
                    else { throw ProtectedStateError.updateInProgress }
                } else {
                    try engine.beginLiveUpdate(
                        ProtectedLiveUpdateGate(
                            token: request.token,
                            generation: UUID(),
                            successorDigest: successorDigest
                        )
                    )
                }
                return try engine.liveUpdateStatus(appleStateDigest: appleDigest)
            } catch {
                if engine.liveUpdateGate() == nil { appleLockdown.unfreezeAfterLiveUpdate() }
                throw error
            }
        }
    }

    func inspectLiveUpdate(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handleLive(request, as: ProtectedLiveUpdateRequest.self, reply: reply) { request in
            guard let gate = engine.liveUpdateGate(), gate.token == request.token else {
                throw ProtectedStateError.updateNotOwned
            }
            return try engine.liveUpdateStatus(
                appleStateDigest: appleLockdown.stateDigest(),
                phase: runningDigest == gate.successorDigest ? .standbyReady : .frozen
            )
        }
    }

    func cancelLiveUpdate(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handleLive(request, as: ProtectedLiveUpdateRequest.self, reply: reply) { request in
            guard let gate = engine.liveUpdateGate(), gate.token == request.token else {
                throw ProtectedStateError.updateNotOwned
            }
            guard runningDigest != gate.successorDigest else {
                throw ProtectedStateError.updateUnavailable
            }
            try appleLockdown.checkpointForLiveUpdateFinalization()
            let appleDigest = try appleLockdown.stateDigest()
            let snapshot = try engine.endLiveUpdate(token: request.token, finalized: false)
            appleLockdown.unfreezeAfterLiveUpdate()
            return ProtectedLiveUpdateStatus(
                phase: .cancelled,
                generation: gate.generation,
                stateDigest: try engine.currentStateDigest(),
                appleStateDigest: appleDigest,
                successorDigest: gate.successorDigest,
                isEnforcing: snapshot.protection.isEnforcing,
                issues: snapshot.protection.issues
            )
        }
    }

    func finalizeLiveUpdate(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handleLive(request, as: ProtectedLiveUpdateRequest.self, reply: reply) { request in
            guard let gate = engine.liveUpdateGate(), gate.token == request.token else {
                throw ProtectedStateError.updateNotOwned
            }
            guard runningDigest == gate.successorDigest else {
                throw ProtectedStateError.updateUnavailable
            }
            try appleLockdown.checkpointForLiveUpdateFinalization()
            let appleDigest = try appleLockdown.stateDigest()
            let snapshot = try engine.endLiveUpdate(token: request.token, finalized: true)
            appleLockdown.unfreezeAfterLiveUpdate()
            return ProtectedLiveUpdateStatus(
                phase: .finalized,
                generation: gate.generation,
                stateDigest: try engine.currentStateDigest(),
                appleStateDigest: appleDigest,
                successorDigest: gate.successorDigest,
                isEnforcing: snapshot.protection.isEnforcing,
                issues: snapshot.protection.issues
            )
        }
    }

    func appleLockdownStatus(withReply reply: @escaping (NSData) -> Void) {
        do {
            reply(encoded(.success(try coordinator.perform { try appleLockdown.status() })))
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
            reply(encoded(.success(try coordinator.perform { try appleLockdown.requestEnd() })))
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
            reply(encoded(.success(try coordinator.perform { try operation(request) })))
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
            reply(encoded(try coordinator.perform { try operation(request) }))
        } catch {
            reply(encoded(appleFailure(for: error)))
        }
    }

    private func handleLive<Request: Decodable>(
        _ payload: NSData,
        as type: Request.Type,
        reply: @escaping (NSData) -> Void,
        operation: (Request) throws -> ProtectedLiveUpdateStatus
    ) {
        do {
            let request = try ProtectedServiceCodec.decode(type, from: payload)
            reply(encoded(.success(try coordinator.perform { try operation(request) })))
        } catch {
            let failure = failure(for: error)
            reply(
                encoded(
                    ProtectedLiveUpdateReply(
                        status: nil,
                        error: failure.error
                    )))
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

    private func encoded(_ value: ProtectedLiveUpdateReply) -> NSData {
        (try? ProtectedServiceCodec.encode(value)) ?? NSData()
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
    private let lock = NSRecursiveLock()

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
    private let runningDigest: String
    private let inactiveMigrationToken: UUID?
    private let allowsActiveLegacyMigration: Bool

    init(
        engine: ProtectedServiceEngine,
        appleLockdown: AppleLockdownEngine,
        authorizer: ClientAuthorizer,
        runningDigest: String = "",
        inactiveMigrationToken: UUID? = nil,
        allowsActiveLegacyMigration: Bool = false
    ) {
        self.engine = engine
        self.appleLockdown = appleLockdown
        coordinator = ProtectedServiceCoordinator()
        self.authorizer = authorizer
        self.runningDigest = runningDigest
        self.inactiveMigrationToken = inactiveMigrationToken
        self.allowsActiveLegacyMigration = allowsActiveLegacyMigration
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
            coordinator: coordinator,
            runningDigest: runningDigest,
            inactiveMigrationToken: inactiveMigrationToken,
            allowsActiveLegacyMigration: allowsActiveLegacyMigration
        )
        newConnection.activate()
        return true
    }
}

final class ProtectedStandbyEndpoint: NSObject, ProtectedStandbyXPC {
    private let engine: ProtectedStandbyEngine

    init(engine: ProtectedStandbyEngine) { self.engine = engine }

    func list(withReply reply: @escaping (NSData) -> Void) {
        reply(
            (try? ProtectedServiceCodec.encode(
                ProtectedServiceReply.success(engine.list())
            )) ?? NSData())
    }

    func readiness(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        respond(request, reply: reply) { try engine.readiness(token: $0.token) }
    }

    func retire(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        respond(request, reply: reply) { try engine.retire(token: $0.token) }
    }

    private func respond(
        _ request: NSData,
        reply: @escaping (NSData) -> Void,
        operation: (ProtectedLiveUpdateRequest) throws -> ProtectedLiveUpdateStatus
    ) {
        let response: ProtectedLiveUpdateReply
        do {
            let decoded = try ProtectedServiceCodec.decode(ProtectedLiveUpdateRequest.self, from: request)
            response = .success(try operation(decoded))
        } catch {
            response = .failure(
                code: "standby_unavailable",
                message: error.localizedDescription.utf8ServicePrefix(maxBytes: 512)
            )
        }
        reply((try? ProtectedServiceCodec.encode(response)) ?? NSData())
    }
}

final class ProtectedStandbyListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let engine: ProtectedStandbyEngine
    private let authorizer: ClientAuthorizer

    init(engine: ProtectedStandbyEngine, authorizer: ClientAuthorizer) {
        self.engine = engine
        self.authorizer = authorizer
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard authorizer.configure(newConnection) else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: ProtectedStandbyXPC.self)
        newConnection.exportedObject = ProtectedStandbyEndpoint(engine: engine)
        newConnection.activate()
        return true
    }
}

final class ProtectedServiceUpdateEndpoint: NSObject, ProtectedServiceUpdateXPC {
    private let trigger: PrivilegedServiceUpdateTrigger

    init(trigger: PrivilegedServiceUpdateTrigger) { self.trigger = trigger }

    func installationStatus(withReply reply: @escaping (NSData) -> Void) {
        let response: ProtectedServiceUpdateInstallationReply
        do {
            response = ProtectedServiceUpdateInstallationReply(
                status: try trigger.installationStatus(), error: nil
            )
        } catch {
            response = ProtectedServiceUpdateInstallationReply(
                status: nil,
                error: ProtectedServiceErrorPayload(
                    code: "update_unavailable", message: error.localizedDescription
                )
            )
        }
        reply((try? ProtectedServiceCodec.encode(response)) ?? NSData())
    }

    func requestUpdate(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        do {
            let decoded = try ProtectedServiceCodec.decode(ProtectedServiceUpdateRequest.self, from: request)
            trigger.request(decoded) { result in
                reply((try? ProtectedServiceCodec.encode(result)) ?? NSData())
            }
        } catch {
            reply(
                (try? ProtectedServiceCodec.encode(
                    ProtectedServiceUpdateReply.failure(error.localizedDescription)
                )) ?? NSData())
        }
    }
}

final class ProtectedServiceUpdateListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let trigger: PrivilegedServiceUpdateTrigger
    private let authorizer: ClientAuthorizer

    init(trigger: PrivilegedServiceUpdateTrigger, authorizer: ClientAuthorizer) {
        self.trigger = trigger
        self.authorizer = authorizer
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard authorizer.configureUpdate(newConnection) else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: ProtectedServiceUpdateXPC.self)
        newConnection.exportedObject = ProtectedServiceUpdateEndpoint(trigger: trigger)
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
