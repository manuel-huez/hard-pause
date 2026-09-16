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

@MainActor
protocol ProtectedServiceServing {
    func list() async throws -> ProtectedServiceSnapshot
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
}

@MainActor
final class ProtectedServiceClient: ProtectedServiceServing {
    private var connection: NSXPCConnection?
    private var pendingCalls: [UUID: CheckedContinuation<ProtectedServiceSnapshot, Error>] = [:]

    deinit {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
    }

    func list() async throws -> ProtectedServiceSnapshot {
        try await perform { service, reply in service.list(withReply: reply) }
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
    }

    private func finish(_ id: UUID, with result: Result<ProtectedServiceSnapshot, Error>) {
        guard let continuation = pendingCalls.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }
}
