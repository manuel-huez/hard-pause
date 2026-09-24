import Darwin
import Foundation

/// A live, signed XPC reply is required before the app delegates browser checks.
@MainActor
final class BrowserWorkerClient {
    let machServiceName: String

    init() { machServiceName = BrowserWorkerIdentity.machService }

    init?(machServiceName: String) {
        guard BrowserWorkerIdentity.acceptsMachService(machServiceName) else { return nil }
        self.machServiceName = machServiceName
    }

    /// Root-owned LaunchAgent files name candidates; only signed XPC replies establish trust.
    static func installedMachServices() -> [String] {
        let directory = "/Library/LaunchAgents"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var labels: [String] = []
        for name in names where name.hasSuffix(".plist") {
            let label = String(name.dropLast(6))
            guard BrowserWorkerIdentity.acceptsMachService(label) else { continue }
            let path = directory + "/" + name
            var metadata = stat()
            guard lstat(path, &metadata) == 0,
                metadata.st_uid == 0, metadata.st_gid == 0,
                metadata.st_mode & 0o170000 == 0o100000,
                metadata.st_mode & 0o777 == 0o644,
                metadata.st_size <= 16_384,
                let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                plist["Label"] as? String == label,
                let machServices = plist["MachServices"] as? [String: Any],
                machServices[label] != nil
            else { continue }
            labels.append(label)
        }
        return labels.sorted { version($0) > version($1) }
    }

    private static func version(_ name: String) -> Int {
        Int(name.dropFirst(BrowserWorkerIdentity.machService.count + 2)) ?? 0
    }

    func readiness() async -> BrowserWorkerReadiness? {
        let reply: BrowserWorkerReply? = await call { $0.readiness($1, withReply: $2) }
        guard let reply, reply.readiness.isFresh() else { return nil }
        return reply.readiness
    }

    func requestPermission(for identifier: String) async -> BrowserWorkerReadiness? {
        guard ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox"].contains(identifier) else {
            return nil
        }
        let reply: BrowserWorkerReply? = await call {
            $0.requestPermission(identifier as NSString, challenge: $1, withReply: $2)
        }
        guard let reply, reply.readiness.isFresh() else { return nil }
        return reply.readiness
    }

    func migratePausePages(to newPage: URL) async -> Bool {
        guard BrowserWorkerIdentity.isLocalPausePage(newPage) else { return false }
        let reply: BrowserWorkerMigrationReply? = await call {
            $0.migratePausePages(newPage.absoluteString as NSString, challenge: $1, withReply: $2)
        }
        return reply?.migrated == true
    }

    private func call<Reply: BrowserWorkerChallengeReply>(
        _ send: @escaping (BrowserWorkerXPC, NSString, @escaping (NSData) -> Void) -> Void
    ) async -> Reply? {
        let challenge = UUID().uuidString
        let connection = NSXPCConnection(machServiceName: machServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BrowserWorkerXPC.self)
        connection.setCodeSigningRequirement(BrowserWorkerIdentity.workerRequirement)
        let response: Data? = await withCheckedContinuation { continuation in
            let completion = BrowserWorkerCallCompletion(continuation, connection: connection)
            connection.interruptionHandler = { completion.finish(nil) }
            connection.invalidationHandler = { completion.finish(nil) }
            connection.activate()
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { _ in completion.finish(nil) }
                as? BrowserWorkerXPC
            if let proxy {
                send(proxy, challenge as NSString) { completion.finish($0 as Data) }
            } else {
                completion.finish(nil)
            }
            // Primary and standby service checks may each need their five-second timeout.
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                completion.finish(nil)
            }
        }
        guard let response,
            let reply = try? JSONDecoder().decode(Reply.self, from: response),
            reply.challenge == challenge
        else { return nil }
        return reply
    }
}

private final class BrowserWorkerCallCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var connection: NSXPCConnection?

    init(_ continuation: CheckedContinuation<Data?, Never>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish(_ data: Data?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let activeConnection = connection
        connection = nil
        lock.unlock()
        activeConnection?.invalidate()
        pending?.resume(returning: data)
    }
}
