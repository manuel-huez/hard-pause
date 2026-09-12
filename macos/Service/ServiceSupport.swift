import Foundation

protocol ServiceClock: Sendable {
    func read() -> ClockReading
}

struct SystemServiceClock: ServiceClock {
    func read() -> ClockReading { SystemClock.read() }
}

struct CommandResult: Equatable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String], standardInput: Data?) throws -> CommandResult
}

struct ProcessCommandRunner: CommandRunning {
    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let maximumCapturedBytes: Int
    private let maximumInputBytes: Int

    init(
        timeout: TimeInterval = 10,
        terminationGrace: TimeInterval = 1,
        maximumCapturedBytes: Int = 4 * 1_024 * 1_024,
        maximumInputBytes: Int = ProtectedServiceContract.maximumPayloadBytes
    ) {
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.maximumCapturedBytes = maximumCapturedBytes
        self.maximumInputBytes = maximumInputBytes
    }

    func run(executable: String, arguments: [String], standardInput: Data? = nil) throws -> CommandResult {
        guard timeout > 0,
            terminationGrace > 0,
            maximumCapturedBytes > 0,
            maximumInputBytes > 0
        else {
            throw ServiceRuntimeError.invalidInstall("the command runner limits are invalid")
        }
        if let standardInput, standardInput.count > maximumInputBytes {
            throw ServiceRuntimeError.commandInputTooLarge(executable)
        }

        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error

        let input: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            input = pipe
        } else {
            input = nil
        }

        let outputCapture = BoundedCommandOutput(maximumBytes: maximumCapturedBytes)
        let errorCapture = BoundedCommandOutput(maximumBytes: maximumCapturedBytes)
        let ioGroup = DispatchGroup()
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        try process.run()
        drain(output.fileHandleForReading, into: outputCapture, group: ioGroup)
        drain(error.fileHandleForReading, into: errorCapture, group: ioGroup)
        if let standardInput, let input {
            ioGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    try? input.fileHandleForWriting.close()
                    ioGroup.leave()
                }
                do {
                    try input.fileHandleForWriting.write(contentsOf: standardInput)
                } catch {
                    outputCapture.recordIOError(error)
                }
            }
        }

        guard terminated.wait(timeout: .now() + timeout) == .success else {
            try? input?.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            if terminated.wait(timeout: .now() + terminationGrace) == .timedOut,
                process.isRunning
            {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + terminationGrace)
            }
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
            _ = ioGroup.wait(timeout: .now() + terminationGrace)
            throw ServiceRuntimeError.commandTimedOut(executable)
        }

        guard ioGroup.wait(timeout: .now() + terminationGrace) == .success else {
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
            throw ServiceRuntimeError.commandIOFailed(executable)
        }
        if let ioError = outputCapture.ioError ?? errorCapture.ioError {
            throw ServiceRuntimeError.commandIOFailed("\(executable): \(ioError.localizedDescription)")
        }
        guard !outputCapture.didOverflow, !errorCapture.didOverflow else {
            throw ServiceRuntimeError.commandOutputTooLarge(executable)
        }

        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputCapture.data, as: UTF8.self),
            standardError: String(decoding: errorCapture.data, as: UTF8.self)
        )
    }

    private func drain(
        _ handle: FileHandle,
        into capture: BoundedCommandOutput,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? handle.close()
                group.leave()
            }
            do {
                while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    capture.append(chunk)
                }
            } catch {
                capture.recordIOError(error)
            }
        }
    }
}

private final class BoundedCommandOutput: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var stored = Data()
    private var overflowed = false
    private var storedIOError: Error?

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        stored.reserveCapacity(min(maximumBytes, 64 * 1_024))
    }

    var data: Data { withLock { stored } }
    var didOverflow: Bool { withLock { overflowed } }
    var ioError: Error? { withLock { storedIOError } }

    func append(_ data: Data) {
        withLock {
            let remaining = maximumBytes - stored.count
            if remaining > 0 { stored.append(data.prefix(remaining)) }
            if data.count > remaining { overflowed = true }
        }
    }

    func recordIOError(_ error: Error) {
        withLock {
            if storedIOError == nil { storedIOError = error }
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

enum ServiceRuntimeError: LocalizedError, Equatable {
    case invalidInstall(String)
    case unreadableState(String)
    case stateWriteFailed(String)
    case enforcementFailed(String)
    case authorizationFailed(String)
    case commandTimedOut(String)
    case commandOutputTooLarge(String)
    case commandInputTooLarge(String)
    case commandIOFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInstall(let message): return "The Hard Pause service installation is invalid: \(message)"
        case .unreadableState(let message): return "The protected state cannot be read: \(message)"
        case .stateWriteFailed(let message): return "The protected state cannot be saved: \(message)"
        case .enforcementFailed(let message): return "Hard Pause cannot apply protection: \(message)"
        case .authorizationFailed(let message): return "The client is not authorized: \(message)"
        case .commandTimedOut(let executable): return "The command timed out: \(executable)"
        case .commandOutputTooLarge(let executable):
            return "The command produced too much output: \(executable)"
        case .commandInputTooLarge(let executable): return "The command input is too large: \(executable)"
        case .commandIOFailed(let detail): return "The command I/O failed: \(detail)"
        }
    }
}

extension EffectiveRestrictions {
    func union(_ other: EffectiveRestrictions) -> EffectiveRestrictions {
        var applications = Dictionary(uniqueKeysWithValues: blockedApplications.map { ($0.id, $0) })
        for application in other.blockedApplications { applications[application.id] = application }
        return EffectiveRestrictions(
            blockedDomains: Array(Set(blockedDomains).union(other.blockedDomains)).sorted(),
            blockedApplications: applications.values.sorted { $0.id < $1.id },
            contributingBlockIDs: Array(Set(contributingBlockIDs).union(other.contributingBlockIDs))
                .sorted { $0.uuidString < $1.uuidString },
            blockedURLPatterns: Array(Set(blockedURLPatterns).union(other.blockedURLPatterns)).sorted()
        )
    }
}
