import Foundation

final class ProtectedServiceEndpoint: NSObject, ProtectedServiceXPC {
    private let engine: ProtectedServiceEngine

    init(engine: ProtectedServiceEngine) {
        self.engine = engine
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
        handle(request, as: ProtectedRevisionRequest.self, reply: reply) {
            try engine.delete($0)
        }
    }

    func activate(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedRevisionRequest.self, reply: reply) {
            try engine.activate($0)
        }
    }

    func requestBreak(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedBlockRequest.self, reply: reply) {
            try engine.requestBreak($0)
        }
    }

    func cancelBreak(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedBlockRequest.self, reply: reply) {
            try engine.cancelBreak($0)
        }
    }

    func requestEnd(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedBlockRequest.self, reply: reply) {
            try engine.requestEnd($0)
        }
    }

    func prepareUpdate(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedBlockRequest.self, reply: reply) {
            try engine.prepareUpdate($0)
        }
    }

    func cancelUpdate(_ request: NSData, withReply reply: @escaping (NSData) -> Void) {
        handle(request, as: ProtectedBlockRequest.self, reply: reply) {
            try engine.cancelUpdate($0)
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

    private func encoded(_ value: ProtectedServiceReply) -> NSData {
        if let data = try? ProtectedServiceCodec.encode(value) { return data }
        let fallback = ProtectedServiceReply.failure(
            code: "response_too_large",
            message: "The protected state is too large to return safely."
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
}

final class ProtectedServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let engine: ProtectedServiceEngine
    private let authorizer: ClientAuthorizer

    init(engine: ProtectedServiceEngine, authorizer: ClientAuthorizer) {
        self.engine = engine
        self.authorizer = authorizer
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard authorizer.configure(newConnection) else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: ProtectedServiceXPC.self)
        newConnection.exportedObject = ProtectedServiceEndpoint(engine: engine)
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
