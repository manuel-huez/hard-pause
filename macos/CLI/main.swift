import Darwin
import Foundation

private enum CLIError: LocalizedError {
    case usage(String)
    case invalidArgument(String)
    case connection(String)
    case service(String)
    case invalidReply
    case timedOut
    case uninstallBlocked([String])

    var errorDescription: String? {
        switch self {
        case .usage(let message), .invalidArgument(let message), .connection(let message),
            .service(let message):
            return message
        case .invalidReply: return "The Hard Pause service returned an invalid response."
        case .timedOut: return "The Hard Pause service did not respond within 5 seconds."
        case .uninstallBlocked(let names):
            return "Protection is still active for: \(names.joined(separator: ", "))."
        }
    }
}

private final class CLIReplyBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stored == nil else { return false }
        stored = result
        return true
    }

    var result: Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class ProtectedServiceCLIClient {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(
            machServiceName: ProtectedServiceContract.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: ProtectedServiceXPC.self)
        connection.activate()
    }

    deinit { connection.invalidate() }

    func list() throws -> ProtectedServiceSnapshot {
        try perform { service, reply in service.list(withReply: reply) }
    }

    func create(_ request: ProtectedCreateRequest) throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(request)
        return try perform { service, reply in service.create(payload, withReply: reply) }
    }

    func update(_ request: ProtectedUpdateRequest) throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(request)
        return try perform { service, reply in service.update(payload, withReply: reply) }
    }

    func delete(_ request: ProtectedRevisionRequest) throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(request)
        return try perform { service, reply in service.delete(payload, withReply: reply) }
    }

    func activate(_ request: ProtectedRevisionRequest) throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(request)
        return try perform { service, reply in service.activate(payload, withReply: reply) }
    }

    func requestBreak(_ request: ProtectedBlockRequest) throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(request)
        return try perform { service, reply in service.requestBreak(payload, withReply: reply) }
    }

    func requestEnd(_ request: ProtectedBlockRequest) throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(request)
        return try perform { service, reply in service.requestEnd(payload, withReply: reply) }
    }

    func prepareUpdate(_ request: ProtectedBlockRequest) throws -> ProtectedServiceSnapshot {
        try requireCurrentServiceVersion()
        let payload = try ProtectedServiceCodec.encode(request)
        return try perform { service, reply in service.prepareUpdate(payload, withReply: reply) }
    }

    func cancelUpdate(_ request: ProtectedBlockRequest) throws -> ProtectedServiceSnapshot {
        try requireCurrentServiceVersion()
        let payload = try ProtectedServiceCodec.encode(request)
        return try perform { service, reply in service.cancelUpdate(payload, withReply: reply) }
    }

    func finalizeInactiveMigration(_ request: ProtectedLiveUpdateRequest) throws -> ProtectedServiceSnapshot {
        let payload = try ProtectedServiceCodec.encode(request)
        return try perform { service, reply in
            service.finalizeInactiveMigration(payload, withReply: reply)
        }
    }

    func beginLiveUpdate(_ request: ProtectedLiveUpdateBeginRequest) throws -> ProtectedLiveUpdateStatus {
        let payload = try ProtectedServiceCodec.encode(request)
        return try performLive { service, reply in service.beginLiveUpdate(payload, withReply: reply) }
    }

    func inspectLiveUpdate(_ request: ProtectedLiveUpdateRequest) throws -> ProtectedLiveUpdateStatus {
        let payload = try ProtectedServiceCodec.encode(request)
        return try performLive { service, reply in service.inspectLiveUpdate(payload, withReply: reply) }
    }

    func cancelLiveUpdate(_ request: ProtectedLiveUpdateRequest) throws -> ProtectedLiveUpdateStatus {
        let payload = try ProtectedServiceCodec.encode(request)
        return try performLive { service, reply in service.cancelLiveUpdate(payload, withReply: reply) }
    }

    func finalizeLiveUpdate(_ request: ProtectedLiveUpdateRequest) throws -> ProtectedLiveUpdateStatus {
        let payload = try ProtectedServiceCodec.encode(request)
        return try performLive { service, reply in service.finalizeLiveUpdate(payload, withReply: reply) }
    }

    func standbyReadiness(_ request: ProtectedLiveUpdateRequest) throws -> ProtectedLiveUpdateStatus {
        try performStandby(request) { service, payload, reply in
            service.readiness(payload, withReply: reply)
        }
    }

    func retireStandby(_ request: ProtectedLiveUpdateRequest) throws -> ProtectedLiveUpdateStatus {
        try performStandby(request) { service, payload, reply in
            service.retire(payload, withReply: reply)
        }
    }

    func appleLockdownStatus() throws -> AppleLockdownSnapshot {
        let reply = try performApple { service, callback in
            service.appleLockdownStatus(withReply: callback)
        }
        guard let snapshot = reply.snapshot else { throw CLIError.invalidReply }
        return snapshot
    }

    private func requireCurrentServiceVersion() throws {
        let installedVersion = try list().protection.serviceVersion
        guard ProtectedServiceContract.supportsSafeUpdate(from: installedVersion) else {
            throw CLIError.service(
                "The installed Hard Pause service does not support safe updates."
            )
        }
    }

    private func perform(
        _ operation: (ProtectedServiceXPC, @escaping (NSData) -> Void) -> Void
    ) throws -> ProtectedServiceSnapshot {
        let box = CLIReplyBox<ProtectedServiceSnapshot>()
        let completed = DispatchSemaphore(value: 0)
        let finish: @Sendable (Result<ProtectedServiceSnapshot, Error>) -> Void = { result in
            if box.finish(result) { completed.signal() }
        }
        guard
            let service = connection.remoteObjectProxyWithErrorHandler({ error in
                finish(.failure(CLIError.connection(error.localizedDescription)))
            }) as? ProtectedServiceXPC
        else {
            throw CLIError.connection("The Hard Pause service interface is unavailable.")
        }

        operation(service) { data in
            do {
                let reply = try ProtectedServiceCodec.decode(ProtectedServiceReply.self, from: data)
                if let snapshot = reply.snapshot {
                    finish(.success(snapshot))
                } else if let error = reply.error {
                    finish(.failure(CLIError.service(error.message)))
                } else {
                    finish(.failure(CLIError.invalidReply))
                }
            } catch {
                finish(.failure(error))
            }
        }
        guard completed.wait(timeout: .now() + 5) == .success else {
            throw CLIError.timedOut
        }
        guard let result = box.result else { throw CLIError.invalidReply }
        return try result.get()
    }

    private func performApple(
        _ operation: (ProtectedServiceXPC, @escaping (NSData) -> Void) -> Void
    ) throws -> AppleLockdownServiceReply {
        let box = CLIReplyBox<AppleLockdownServiceReply>()
        let completed = DispatchSemaphore(value: 0)
        let finish: @Sendable (Result<AppleLockdownServiceReply, Error>) -> Void = { result in
            if box.finish(result) { completed.signal() }
        }
        guard
            let service = connection.remoteObjectProxyWithErrorHandler({ error in
                finish(.failure(CLIError.connection(error.localizedDescription)))
            }) as? ProtectedServiceXPC
        else {
            throw CLIError.connection("The Hard Pause service interface is unavailable.")
        }

        operation(service) { data in
            do {
                let reply = try ProtectedServiceCodec.decode(
                    AppleLockdownServiceReply.self,
                    from: data
                )
                if let error = reply.error {
                    finish(.failure(CLIError.service(error.message)))
                } else {
                    finish(.success(reply))
                }
            } catch {
                finish(.failure(error))
            }
        }
        guard completed.wait(timeout: .now() + 5) == .success else {
            throw CLIError.timedOut
        }
        guard let result = box.result else { throw CLIError.invalidReply }
        return try result.get()
    }

    private func performLive(
        _ operation: (ProtectedServiceXPC, @escaping (NSData) -> Void) -> Void
    ) throws -> ProtectedLiveUpdateStatus {
        let box = CLIReplyBox<ProtectedLiveUpdateStatus>()
        let completed = DispatchSemaphore(value: 0)
        let finish: @Sendable (Result<ProtectedLiveUpdateStatus, Error>) -> Void = { result in
            if box.finish(result) { completed.signal() }
        }
        guard
            let service = connection.remoteObjectProxyWithErrorHandler({ error in
                finish(.failure(CLIError.connection(error.localizedDescription)))
            }) as? ProtectedServiceXPC
        else {
            throw CLIError.connection("The Hard Pause service interface is unavailable.")
        }
        operation(service) { data in
            finish(Self.decodeLiveStatus(data))
        }
        guard completed.wait(timeout: .now() + 5) == .success else { throw CLIError.timedOut }
        guard let result = box.result else { throw CLIError.invalidReply }
        return try result.get()
    }

    private func performStandby(
        _ request: ProtectedLiveUpdateRequest,
        _ operation: (ProtectedStandbyXPC, NSData, @escaping (NSData) -> Void) -> Void
    ) throws -> ProtectedLiveUpdateStatus {
        let standby = NSXPCConnection(
            machServiceName: ProtectedServiceContract.standbyMachServiceName,
            options: .privileged
        )
        standby.remoteObjectInterface = NSXPCInterface(with: ProtectedStandbyXPC.self)
        standby.activate()
        defer { standby.invalidate() }
        let payload = try ProtectedServiceCodec.encode(request)
        let box = CLIReplyBox<ProtectedLiveUpdateStatus>()
        let completed = DispatchSemaphore(value: 0)
        let finish: @Sendable (Result<ProtectedLiveUpdateStatus, Error>) -> Void = { result in
            if box.finish(result) { completed.signal() }
        }
        guard
            let service = standby.remoteObjectProxyWithErrorHandler({ error in
                finish(.failure(CLIError.connection(error.localizedDescription)))
            }) as? ProtectedStandbyXPC
        else {
            throw CLIError.connection("The standby service interface is unavailable.")
        }
        operation(service, payload) { data in finish(Self.decodeLiveStatus(data)) }
        guard completed.wait(timeout: .now() + 5) == .success else { throw CLIError.timedOut }
        guard let result = box.result else { throw CLIError.invalidReply }
        return try result.get()
    }

    private static func decodeLiveStatus(_ data: NSData) -> Result<ProtectedLiveUpdateStatus, Error> {
        do {
            let reply = try ProtectedServiceCodec.decode(ProtectedLiveUpdateReply.self, from: data)
            if let status = reply.status { return .success(status) }
            if let error = reply.error { return .failure(CLIError.service(error.message)) }
            return .failure(CLIError.invalidReply)
        } catch {
            return .failure(error)
        }
    }
}

private func usage() -> String {
    """
    Usage:
      hard-pause list
      hard-pause create <request.json|->
      hard-pause update <request.json|->
      hard-pause delete <block-id> <expected-revision>
      hard-pause activate <block-id> <expected-revision>
      hard-pause break <block-id>
      hard-pause end <block-id>
      hard-pause prepare-update <token>
      hard-pause cancel-update <token>
      hard-pause begin-live-update <token> <staged-service-path>
      hard-pause inspect-live-update <token>
      hard-pause standby-readiness <token>
      hard-pause finalize-live-update <token>
      hard-pause cancel-live-update <token>
      hard-pause retire-standby <token>
      hard-pause finalize-inactive-migration <token>
      hard-pause finalize-active-legacy-migration <token>
      hard-pause can-uninstall
      hard-pause agent-guidance

    Create and update files use the ProtectedCreateRequest and ProtectedUpdateRequest JSON shapes.
    agent-guidance prints the installed guidance for AI agents.
    """
}

private func readRequest<T: Decodable>(_ type: T.Type, path: String) throws -> T {
    let maximum = ProtectedServiceContract.maximumPayloadBytes
    let data: Data
    if path == "-" {
        data = try readBounded(FileHandle.standardInput, maximumBytes: maximum)
    } else {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximum else {
            throw CLIError.invalidArgument("The request file is too large.")
        }
        data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    }
    return try ProtectedServiceCodec.decode(type, from: data as NSData)
}

private func readBounded(_ handle: FileHandle, maximumBytes: Int) throws -> Data {
    var result = Data()
    while result.count <= maximumBytes,
        let chunk = try handle.read(upToCount: min(64 * 1_024, maximumBytes + 1 - result.count)),
        !chunk.isEmpty
    {
        result.append(chunk)
    }
    guard result.count <= maximumBytes else {
        throw CLIError.invalidArgument("The request input is too large.")
    }
    return result
}

private func identifier(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else {
        throw CLIError.invalidArgument("The block ID is invalid.")
    }
    return id
}

private func revision(_ value: String) throws -> Int {
    guard let revision = Int(value), revision >= 1 else {
        throw CLIError.invalidArgument("The expected revision is invalid.")
    }
    return revision
}

private func writeSnapshot(_ snapshot: ProtectedServiceSnapshot) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(snapshot)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func writeLiveStatus(_ status: ProtectedLiveUpdateStatus) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(status))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func activeBlockNames(in snapshot: ProtectedServiceSnapshot) -> [String] {
    snapshot.blocks.compactMap { block in
        if case .inactive = block.phase { return nil }
        return block.draft.name
    }
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw CLIError.usage(usage()) }
    if command == "help" || command == "--help" || command == "-h" {
        print(usage())
        return
    }
    if command == "agent-guidance" {
        guard arguments.count == 1 else { throw CLIError.usage(usage()) }
        AgentCommitmentGuidance.writeToStandardOutput()
        return
    }
    if command == "can-uninstall" {
        guard arguments.count == 1 else { throw CLIError.usage(usage()) }
        AgentCommitmentGuidance.writeToStandardError()
    }

    let client = ProtectedServiceCLIClient()
    if command == "begin-live-update" {
        guard arguments.count == 3 else { throw CLIError.usage(usage()) }
        try writeLiveStatus(
            client.beginLiveUpdate(
                ProtectedLiveUpdateBeginRequest(
                    token: try identifier(arguments[1]),
                    successorPath: arguments[2]
                )))
        return
    }
    if [
        "inspect-live-update", "standby-readiness", "finalize-live-update",
        "cancel-live-update", "retire-standby",
    ].contains(command) {
        guard arguments.count == 2 else { throw CLIError.usage(usage()) }
        let request = ProtectedLiveUpdateRequest(token: try identifier(arguments[1]))
        let status: ProtectedLiveUpdateStatus
        switch command {
        case "inspect-live-update": status = try client.inspectLiveUpdate(request)
        case "standby-readiness": status = try client.standbyReadiness(request)
        case "finalize-live-update": status = try client.finalizeLiveUpdate(request)
        case "cancel-live-update": status = try client.cancelLiveUpdate(request)
        default: status = try client.retireStandby(request)
        }
        try writeLiveStatus(status)
        return
    }
    let snapshot: ProtectedServiceSnapshot
    switch command {
    case "list":
        guard arguments.count == 1 else { throw CLIError.usage(usage()) }
        snapshot = try client.list()
    case "create":
        guard arguments.count == 2 else { throw CLIError.usage(usage()) }
        snapshot = try client.create(
            readRequest(ProtectedCreateRequest.self, path: arguments[1])
        )
    case "update":
        guard arguments.count == 2 else { throw CLIError.usage(usage()) }
        snapshot = try client.update(
            readRequest(ProtectedUpdateRequest.self, path: arguments[1])
        )
    case "delete", "activate":
        guard arguments.count == 3 else { throw CLIError.usage(usage()) }
        let request = ProtectedRevisionRequest(
            id: try identifier(arguments[1]),
            expectedRevision: try revision(arguments[2])
        )
        snapshot = command == "delete" ? try client.delete(request) : try client.activate(request)
    case "break", "end", "prepare-update", "cancel-update":
        guard arguments.count == 2 else { throw CLIError.usage(usage()) }
        let request = ProtectedBlockRequest(id: try identifier(arguments[1]))
        switch command {
        case "break": snapshot = try client.requestBreak(request)
        case "end": snapshot = try client.requestEnd(request)
        case "prepare-update": snapshot = try client.prepareUpdate(request)
        default: snapshot = try client.cancelUpdate(request)
        }
    case "finalize-inactive-migration", "finalize-active-legacy-migration":
        guard arguments.count == 2 else { throw CLIError.usage(usage()) }
        snapshot = try client.finalizeInactiveMigration(
            ProtectedLiveUpdateRequest(token: try identifier(arguments[1]))
        )
    case "can-uninstall":
        guard arguments.count == 1 else { throw CLIError.usage(usage()) }
        let current = try client.list()
        let activeNames = activeBlockNames(in: current)
        guard activeNames.isEmpty else { throw CLIError.uninstallBlocked(activeNames) }
        let appleLockdown = try client.appleLockdownStatus()
        guard appleLockdown.phase == .inactive else {
            throw CLIError.uninstallBlocked(["Screen Time protection"])
        }
        print("Hard Pause protection is inactive. The service can be removed.")
        return
    default:
        throw CLIError.usage(usage())
    }
    try writeSnapshot(snapshot)
}

do {
    try run()
} catch CLIError.uninstallBlocked(let names) {
    FileHandle.standardError.write(Data((CLIError.uninstallBlocked(names).localizedDescription + "\n").utf8))
    exit(3)
} catch CLIError.usage(let message) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(EX_USAGE)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(EX_UNAVAILABLE)
}
