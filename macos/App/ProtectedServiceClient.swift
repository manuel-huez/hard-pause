import Foundation

enum ProtectedServiceAvailability: Equatable {
    case checking
    case unavailable(String)
    case ready
}

enum ProtectedServiceClientError: LocalizedError {
    case unavailable(String)
    case service(String)
    case invalidReply
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .service(let message): return message
        case .invalidReply: return "The Hard Pause service returned an invalid response."
        case .timedOut: return "The Hard Pause service did not respond."
        }
    }
}

private final class OneShotReplyBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(with: result)
    }
}

@MainActor
protocol ProtectedServiceServing {
    func list() async throws -> ProtectedServiceSnapshot
    func updateInstallationStatus() async throws -> ProtectedServiceUpdateInstallationStatus
    func requestManagedUpdate(bundlePath: String) async throws -> UUID
    func create(_ draft: ProtectedBlockDraft) async throws -> ProtectedServiceSnapshot
    func update(
        id: UUID,
        expectedRevision: Int,
        draft: ProtectedBlockDraft
    ) async throws -> ProtectedServiceSnapshot
    func delete(id: UUID, expectedRevision: Int) async throws -> ProtectedServiceSnapshot
    func activate(id: UUID, expectedRevision: Int) async throws -> ProtectedServiceSnapshot
    func requestBreak(id: UUID) async throws -> ProtectedServiceSnapshot
    func cancelBreak(id: UUID) async throws -> ProtectedServiceSnapshot
    func requestEnd(id: UUID) async throws -> ProtectedServiceSnapshot
    func appleLockdownStatus() async throws -> AppleLockdownSnapshot
    func beginAppleLockdownSetup(
        _ request: AppleLockdownSetupRequest
    ) async throws -> AppleLockdownCredentialOperation
    func resumeAppleLockdownSetup(
        operationID: UUID
    ) async throws -> AppleLockdownCredentialOperation
    func completeAppleLockdownSetup(operationID: UUID) async throws -> AppleLockdownSnapshot
    func confirmAppleLockdownSetupNotApplied(
        operationID: UUID
    ) async throws -> AppleLockdownSnapshot
    func requestAppleLockdownEnd() async throws -> AppleLockdownSnapshot
    func beginAppleLockdownRelease() async throws -> AppleLockdownCredentialOperation
    func completeAppleLockdownRelease(operationID: UUID) async throws -> AppleLockdownSnapshot
}

extension ProtectedServiceServing {
    func updateInstallationStatus() async throws -> ProtectedServiceUpdateInstallationStatus {
        throw ProtectedServiceClientError.unavailable("Automatic protection updates are unavailable.")
    }

    func requestManagedUpdate(bundlePath: String) async throws -> UUID {
        throw ProtectedServiceClientError.unavailable("Automatic protection updates are unavailable.")
    }

    func appleLockdownStatus() async throws -> AppleLockdownSnapshot {
        throw ProtectedServiceClientError.unavailable(
            "Screen Time protection is unavailable in this service client."
        )
    }

    func beginAppleLockdownSetup(
        _ request: AppleLockdownSetupRequest
    ) async throws -> AppleLockdownCredentialOperation {
        throw ProtectedServiceClientError.unavailable(
            "Screen Time protection is unavailable in this service client."
        )
    }

    func resumeAppleLockdownSetup(
        operationID: UUID
    ) async throws -> AppleLockdownCredentialOperation {
        throw ProtectedServiceClientError.unavailable(
            "Screen Time protection is unavailable in this service client."
        )
    }

    func completeAppleLockdownSetup(operationID: UUID) async throws -> AppleLockdownSnapshot {
        throw ProtectedServiceClientError.unavailable(
            "Screen Time protection is unavailable in this service client."
        )
    }

    func confirmAppleLockdownSetupNotApplied(
        operationID: UUID
    ) async throws -> AppleLockdownSnapshot {
        throw ProtectedServiceClientError.unavailable(
            "Screen Time protection is unavailable in this service client."
        )
    }

    func requestAppleLockdownEnd() async throws -> AppleLockdownSnapshot {
        throw ProtectedServiceClientError.unavailable(
            "Screen Time protection is unavailable in this service client."
        )
    }

    func beginAppleLockdownRelease() async throws -> AppleLockdownCredentialOperation {
        throw ProtectedServiceClientError.unavailable(
            "Screen Time protection is unavailable in this service client."
        )
    }

    func completeAppleLockdownRelease(operationID: UUID) async throws -> AppleLockdownSnapshot {
        throw ProtectedServiceClientError.unavailable(
            "Screen Time protection is unavailable in this service client."
        )
    }
}

@MainActor
final class ProtectedServiceClient: ProtectedServiceServing {
    private var connection: NSXPCConnection?
    private var pendingCalls: [UUID: CheckedContinuation<ProtectedServiceSnapshot, Error>] = [:]
    private var pendingAppleCalls: [UUID: CheckedContinuation<AppleLockdownServiceReply, Error>] = [:]

    deinit {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
    }

    func list() async throws -> ProtectedServiceSnapshot {
        try await perform { service, reply in service.list(withReply: reply) }
    }

    func listStandby() async throws -> ProtectedServiceSnapshot {
        let standby = NSXPCConnection(
            machServiceName: ProtectedServiceContract.standbyMachServiceName,
            options: .privileged
        )
        standby.remoteObjectInterface = NSXPCInterface(with: ProtectedStandbyXPC.self)
        standby.activate()
        defer { standby.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let box = OneShotReplyBox(continuation)
            guard
                let service = standby.remoteObjectProxyWithErrorHandler({ error in
                    box.finish(.failure(error))
                }) as? ProtectedStandbyXPC
            else {
                box.finish(.failure(ProtectedServiceClientError.invalidReply))
                return
            }
            service.list { data in
                do {
                    let reply = try ProtectedServiceCodec.decode(
                        ProtectedServiceReply.self, from: data
                    )
                    if let snapshot = reply.snapshot {
                        box.finish(.success(snapshot))
                    } else if let error = reply.error {
                        box.finish(.failure(ProtectedServiceClientError.service(error.message)))
                    } else {
                        box.finish(.failure(ProtectedServiceClientError.invalidReply))
                    }
                } catch {
                    box.finish(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                box.finish(.failure(ProtectedServiceClientError.timedOut))
            }
        }
    }

    func requestManagedUpdate(bundlePath: String) async throws -> UUID {
        let payload = try ProtectedServiceCodec.encode(
            ProtectedServiceUpdateRequest(bundlePath: bundlePath)
        )
        let connection = NSXPCConnection(
            machServiceName: ProtectedServiceContract.updateMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: ProtectedServiceUpdateXPC.self)
        connection.activate()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let box = OneShotReplyBox(continuation)
            guard
                let service = connection.remoteObjectProxyWithErrorHandler({ error in
                    box.finish(.failure(error))
                }) as? ProtectedServiceUpdateXPC
            else {
                box.finish(.failure(ProtectedServiceClientError.invalidReply))
                return
            }
            service.requestUpdate(payload) { data in
                do {
                    let reply = try ProtectedServiceCodec.decode(
                        ProtectedServiceUpdateReply.self, from: data
                    )
                    if let error = reply.error {
                        box.finish(.failure(ProtectedServiceClientError.service(error.message)))
                    } else if let ticket = reply.ticket {
                        box.finish(.success(ticket))
                    } else {
                        box.finish(.failure(ProtectedServiceClientError.invalidReply))
                    }
                } catch {
                    box.finish(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(45))
                box.finish(.failure(ProtectedServiceClientError.timedOut))
            }
        }
    }

    func updateInstallationStatus() async throws -> ProtectedServiceUpdateInstallationStatus {
        let connection = NSXPCConnection(
            machServiceName: ProtectedServiceContract.updateMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: ProtectedServiceUpdateXPC.self)
        connection.activate()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let box = OneShotReplyBox(continuation)
            guard
                let service = connection.remoteObjectProxyWithErrorHandler({ error in
                    box.finish(.failure(error))
                }) as? ProtectedServiceUpdateXPC
            else {
                box.finish(.failure(ProtectedServiceClientError.invalidReply))
                return
            }
            service.installationStatus { data in
                do {
                    let reply = try ProtectedServiceCodec.decode(
                        ProtectedServiceUpdateInstallationReply.self, from: data
                    )
                    if let error = reply.error {
                        box.finish(.failure(ProtectedServiceClientError.service(error.message)))
                    } else if let status = reply.status {
                        box.finish(.success(status))
                    } else {
                        box.finish(.failure(ProtectedServiceClientError.invalidReply))
                    }
                } catch {
                    box.finish(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                box.finish(.failure(ProtectedServiceClientError.timedOut))
            }
        }
    }

    func create(_ draft: ProtectedBlockDraft) async throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(ProtectedCreateRequest(draft: draft))
        return try await perform { service, reply in service.create(payload, withReply: reply) }
    }

    func update(
        id: UUID,
        expectedRevision: Int,
        draft: ProtectedBlockDraft
    ) async throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(
            ProtectedUpdateRequest(id: id, expectedRevision: expectedRevision, draft: draft)
        )
        return try await perform { service, reply in service.update(payload, withReply: reply) }
    }

    func delete(id: UUID, expectedRevision: Int) async throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(
            ProtectedRevisionRequest(id: id, expectedRevision: expectedRevision)
        )
        return try await perform { service, reply in service.delete(payload, withReply: reply) }
    }

    func activate(id: UUID, expectedRevision: Int) async throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(
            ProtectedRevisionRequest(id: id, expectedRevision: expectedRevision)
        )
        return try await perform { service, reply in service.activate(payload, withReply: reply) }
    }

    func requestBreak(id: UUID) async throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(ProtectedBlockRequest(id: id))
        return try await perform { service, reply in service.requestBreak(payload, withReply: reply) }
    }

    func cancelBreak(id: UUID) async throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(ProtectedBlockRequest(id: id))
        return try await perform { service, reply in service.cancelBreak(payload, withReply: reply) }
    }

    func requestEnd(id: UUID) async throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(ProtectedBlockRequest(id: id))
        return try await perform { service, reply in service.requestEnd(payload, withReply: reply) }
    }

    func prepareUpdate(id: UUID) async throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(ProtectedBlockRequest(id: id))
        return try await perform { service, reply in service.prepareUpdate(payload, withReply: reply) }
    }

    func cancelUpdate(id: UUID) async throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(ProtectedBlockRequest(id: id))
        return try await perform { service, reply in service.cancelUpdate(payload, withReply: reply) }
    }

    func appleLockdownStatus() async throws -> AppleLockdownSnapshot {
        let reply = try await performApple { service, callback in
            service.appleLockdownStatus(withReply: callback)
        }
        return try appleSnapshot(from: reply)
    }

    func beginAppleLockdownSetup(
        _ request: AppleLockdownSetupRequest
    ) async throws -> AppleLockdownCredentialOperation {
        let payload = try ProtectedServiceCodec.encode(request)
        let reply = try await performApple { service, callback in
            service.beginAppleLockdownSetup(payload, withReply: callback)
        }
        return try appleCredential(from: reply)
    }

    func resumeAppleLockdownSetup(
        operationID: UUID
    ) async throws -> AppleLockdownCredentialOperation {
        let payload = try ProtectedServiceCodec.encode(
            AppleLockdownOperationRequest(operationID: operationID)
        )
        let reply = try await performApple { service, callback in
            service.resumeAppleLockdownSetup(payload, withReply: callback)
        }
        return try appleCredential(from: reply)
    }

    func completeAppleLockdownSetup(operationID: UUID) async throws -> AppleLockdownSnapshot {
        let payload = try ProtectedServiceCodec.encode(
            AppleLockdownOperationRequest(operationID: operationID)
        )
        let reply = try await performApple { service, callback in
            service.completeAppleLockdownSetup(payload, withReply: callback)
        }
        return try appleSnapshot(from: reply)
    }

    func confirmAppleLockdownSetupNotApplied(
        operationID: UUID
    ) async throws -> AppleLockdownSnapshot {
        let payload = try ProtectedServiceCodec.encode(
            AppleLockdownOperationRequest(operationID: operationID)
        )
        let reply = try await performApple { service, callback in
            service.confirmAppleLockdownSetupNotApplied(payload, withReply: callback)
        }
        return try appleSnapshot(from: reply)
    }

    func requestAppleLockdownEnd() async throws -> AppleLockdownSnapshot {
        let reply = try await performApple { service, callback in
            service.requestAppleLockdownEnd(withReply: callback)
        }
        return try appleSnapshot(from: reply)
    }

    func beginAppleLockdownRelease() async throws -> AppleLockdownCredentialOperation {
        let reply = try await performApple { service, callback in
            service.beginAppleLockdownRelease(withReply: callback)
        }
        return try appleCredential(from: reply)
    }

    func completeAppleLockdownRelease(operationID: UUID) async throws -> AppleLockdownSnapshot {
        let payload = try ProtectedServiceCodec.encode(
            AppleLockdownOperationRequest(operationID: operationID)
        )
        let reply = try await performApple { service, callback in
            service.completeAppleLockdownRelease(payload, withReply: callback)
        }
        return try appleSnapshot(from: reply)
    }

    private func perform(
        _ invoke: @escaping (ProtectedServiceXPC, @escaping (NSData) -> Void) -> Void
    ) async throws -> ProtectedServiceSnapshot {
        let connection = activeConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let callID = UUID()
            pendingCalls[callID] = continuation

            guard
                let service = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                    Task { @MainActor in
                        self?.finish(callID, with: .failure(error))
                    }
                }) as? ProtectedServiceXPC
            else {
                finish(
                    callID,
                    with: .failure(
                        ProtectedServiceClientError.unavailable(
                            "The Hard Pause service interface is unavailable."
                        )
                    )
                )
                return
            }

            invoke(service) { [weak self] data in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        let reply = try ProtectedServiceCodec.decode(ProtectedServiceReply.self, from: data)
                        if let error = reply.error {
                            self.finish(
                                callID,
                                with: .failure(ProtectedServiceClientError.service(error.message))
                            )
                        } else if let snapshot = reply.snapshot {
                            self.finish(callID, with: .success(snapshot))
                        } else {
                            self.finish(callID, with: .failure(ProtectedServiceClientError.invalidReply))
                        }
                    } catch {
                        self.finish(callID, with: .failure(error))
                    }
                }
            }

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.finish(callID, with: .failure(ProtectedServiceClientError.timedOut))
            }
        }
    }

    private func performApple(
        _ invoke: @escaping (ProtectedServiceXPC, @escaping (NSData) -> Void) -> Void
    ) async throws -> AppleLockdownServiceReply {
        let connection = activeConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let callID = UUID()
            pendingAppleCalls[callID] = continuation

            guard
                let service = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                    Task { @MainActor in
                        self?.finishApple(callID, with: .failure(error))
                    }
                }) as? ProtectedServiceXPC
            else {
                finishApple(
                    callID,
                    with: .failure(
                        ProtectedServiceClientError.unavailable(
                            "The Hard Pause service interface is unavailable."
                        )
                    )
                )
                return
            }

            invoke(service) { [weak self] data in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        let reply = try ProtectedServiceCodec.decode(
                            AppleLockdownServiceReply.self,
                            from: data
                        )
                        if let error = reply.error {
                            self.finishApple(
                                callID,
                                with: .failure(ProtectedServiceClientError.service(error.message))
                            )
                        } else {
                            self.finishApple(callID, with: .success(reply))
                        }
                    } catch {
                        self.finishApple(callID, with: .failure(error))
                    }
                }
            }

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.finishApple(
                    callID,
                    with: .failure(ProtectedServiceClientError.timedOut)
                )
            }
        }
    }

    private func appleSnapshot(
        from reply: AppleLockdownServiceReply
    ) throws -> AppleLockdownSnapshot {
        guard let snapshot = reply.snapshot else {
            throw ProtectedServiceClientError.invalidReply
        }
        return snapshot
    }

    private func appleCredential(
        from reply: AppleLockdownServiceReply
    ) throws -> AppleLockdownCredentialOperation {
        guard let credential = reply.credential else {
            throw ProtectedServiceClientError.invalidReply
        }
        return credential
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let next = NSXPCConnection(
            machServiceName: ProtectedServiceContract.machServiceName,
            options: .privileged
        )
        next.remoteObjectInterface = NSXPCInterface(with: ProtectedServiceXPC.self)
        next.interruptionHandler = { [weak self, weak next] in
            Task { @MainActor in
                self?.connectionFailed(next, message: "The Hard Pause service connection was interrupted.")
            }
        }
        next.invalidationHandler = { [weak self, weak next] in
            Task { @MainActor in
                self?.connectionFailed(next, message: "The Hard Pause service is not installed or is not running.")
            }
        }
        next.resume()
        connection = next
        return next
    }

    private func connectionFailed(_ failedConnection: NSXPCConnection?, message: String) {
        guard connection === failedConnection else { return }
        failedConnection?.interruptionHandler = nil
        failedConnection?.invalidationHandler = nil
        failedConnection?.invalidate()
        connection = nil
        let pending = pendingCalls
        pendingCalls.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: ProtectedServiceClientError.unavailable(message))
        }
        let pendingApple = pendingAppleCalls
        pendingAppleCalls.removeAll()
        for continuation in pendingApple.values {
            continuation.resume(throwing: ProtectedServiceClientError.unavailable(message))
        }
    }

    private func finish(_ id: UUID, with result: Result<ProtectedServiceSnapshot, Error>) {
        guard let continuation = pendingCalls.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func finishApple(
        _ id: UUID,
        with result: Result<AppleLockdownServiceReply, Error>
    ) {
        guard let continuation = pendingAppleCalls.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }
}
