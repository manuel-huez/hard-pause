import CryptoKit
import Darwin
import Foundation
import Security

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

final class ServiceWriterFence {
    private let descriptor: Int32

    init(
        path: String = "\(ProtectedServiceContract.supportDirectory)/state-writer.lock",
        requireRootOwnership: Bool = true
    ) throws {
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ServiceRuntimeError.invalidInstall("the state writer lock cannot be opened")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            !requireRootOwnership || (info.st_uid == 0 && (info.st_mode & 0o077) == 0),
            flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            _ = Darwin.close(descriptor)
            throw ServiceRuntimeError.invalidInstall("another state writer is active or the lock is unsafe")
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

enum ServiceCodeIdentity {
    static func candidateDigest(at path: String) throws -> String {
        var file = stat()
        var directory = stat()
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(path, &file) == 0,
            (file.st_mode & S_IFMT) == S_IFREG,
            file.st_uid == 0,
            (file.st_mode & 0o022) == 0,
            lstat(parent, &directory) == 0,
            (directory.st_mode & S_IFMT) == S_IFDIR,
            directory.st_uid == 0,
            (directory.st_mode & 0o022) == 0
        else {
            throw ServiceRuntimeError.authorizationFailed("the staged service is not root protected")
        }
        var current: SecCode?
        var currentStatic: SecStaticCode?
        var requirement: SecRequirement?
        var staged: SecStaticCode?
        guard SecCodeCopySelf([], &current) == errSecSuccess,
            let current,
            SecCodeCopyStaticCode(current, [], &currentStatic) == errSecSuccess,
            let currentStatic,
            SecCodeCopyDesignatedRequirement(currentStatic, [], &requirement) == errSecSuccess,
            let requirement,
            SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staged)
                == errSecSuccess,
            let staged,
            SecStaticCodeCheckValidity(staged, [], requirement) == errSecSuccess
        else {
            throw ServiceRuntimeError.authorizationFailed("the staged service signature does not match")
        }
        return try digest(at: path)
    }

    static func runningDigest() throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else {
            throw ServiceRuntimeError.invalidInstall("the service executable cannot be located")
        }
        return try digest(at: String(cString: buffer))
    }

    private static func digest(at path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hash = SHA256()
        var count = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            count += chunk.count
            guard count <= 256 * 1_048_576 else {
                throw ServiceRuntimeError.invalidInstall("the service binary is too large")
            }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum ServiceUpdateMode: String {
    case inactive = "--update"
    case live = "--live-update"
}

final class PrivilegedServiceUpdateTrigger: @unchecked Sendable {
    private let engine: ProtectedServiceEngine
    private let appleLockdown: AppleLockdownEngine
    private let authorizer: ClientAuthorizer
    private let runningDigest: String
    private let queue = DispatchQueue(label: "org.hardpause.service.privileged-update")
    private let runner = ProcessCommandRunner(
        timeout: 120,
        terminationGrace: 3,
        maximumCapturedBytes: 8 * 1_024,
        maximumInputBytes: 1_024
    )
    private let updatesDirectory = URL(
        fileURLWithPath: ProtectedServiceContract.supportDirectory
    ).appendingPathComponent("service-updates", isDirectory: true)
    private let publicUpdatesDirectory = URL(
        fileURLWithPath: "/Library/PrivilegedHelperTools/HardPause"
    ).appendingPathComponent("ServiceUpdates", isDirectory: true)

    init(
        engine: ProtectedServiceEngine,
        appleLockdown: AppleLockdownEngine,
        authorizer: ClientAuthorizer,
        runningDigest: String
    ) {
        self.engine = engine
        self.appleLockdown = appleLockdown
        self.authorizer = authorizer
        self.runningDigest = runningDigest
    }

    func installationStatus() throws -> ProtectedServiceUpdateInstallationStatus {
        try requireRootDirectory(URL(fileURLWithPath: ProtectedServiceContract.supportDirectory))
        return ProtectedServiceUpdateInstallationStatus(
            installedAppBuild: try readInstalledBuild(),
            serviceVersion: ProtectedServiceContract.serviceVersion
        )
    }

    func request(
        _ request: ProtectedServiceUpdateRequest,
        reply: @escaping (ProtectedServiceUpdateReply) -> Void
    ) {
        queue.async {
            let ticket = UUID()
            do {
                let job = try self.prepare(request, ticket: ticket)
                reply(.accepted(ticket))
                self.queue.async { self.kickstart(job) }
            } catch {
                reply(.failure(error.localizedDescription, ticket: ticket))
            }
        }
    }

    private func prepare(
        _ request: ProtectedServiceUpdateRequest,
        ticket: UUID
    ) throws -> String {
        guard geteuid() == 0,
            let appRequirement = authorizer.updateCodeRequirement,
            Self.validBundlePath(request.bundlePath)
        else { throw ProtectedStateError.updateUnavailable }
        try requireConsoleUser()
        let mode = try updateMode()
        try requireRootDirectory(URL(fileURLWithPath: ProtectedServiceContract.supportDirectory))
        try makeUpdatesDirectory()
        try makePublicUpdatesDirectory()
        let baseline = try readInstalledBuild()
        try requireSourceBundle(request.bundlePath)
        let ticketText = ticket.uuidString.lowercased()
        let stage = updatesDirectory.appendingPathComponent(ticketText, isDirectory: true)
        let publicStage = publicUpdatesDirectory.appendingPathComponent(ticketText, isDirectory: true)
        let active = updatesDirectory.appendingPathComponent("active")
        var claimed = false
        var stageCreated = false
        var publicStageCreated = false
        var bootstrapStarted = false
        do {
            try claim(active, ticket: ticketText)
            claimed = true
            guard mkdir(stage.path, 0o700) == 0 else { throw ProtectedStateError.updateUnavailable }
            stageCreated = true
            try requireRootDirectory(stage)
            guard mkdir(publicStage.path, 0o755) == 0 else { throw ProtectedStateError.updateUnavailable }
            publicStageCreated = true
            guard chmod(publicStage.path, 0o755) == 0 else { throw ProtectedStateError.updateUnavailable }
            try requireRootPublicDirectory(publicStage)
            let bundle = publicStage.appendingPathComponent("HardPause.app", isDirectory: true)
            try runChecked("/usr/bin/ditto", [request.bundlePath, bundle.path])
            try runChecked("/usr/sbin/chown", ["-R", "-P", "root:wheel", bundle.path])
            try runChecked("/bin/chmod", ["-R", "-P", "a-w,a+rX", bundle.path])
            try verifyBundle(bundle, appRequirement: appRequirement, baseline: baseline)
            let label = "org.hardpause.service-update.\(ticketText)"
            try writeJob(
                at: stage,
                bundle: bundle,
                publicStage: publicStage,
                label: label,
                mode: mode,
                ticket: ticketText,
                consoleUser: try consoleUser()
            )
            bootstrapStarted = true
            try runChecked("/bin/launchctl", ["bootstrap", "system", stage.appendingPathComponent("job.plist").path])
            return label
        } catch {
            if claimed {
                if bootstrapStarted {
                    writeReceipt("bootstrap-uncertain: \(error.localizedDescription)", ticket: ticketText)
                } else if cleanupFailedPreflight(
                    stage: stageCreated ? stage : nil,
                    publicStage: publicStageCreated ? publicStage : nil,
                    marker: active,
                    ticket: ticketText
                ) {
                    writeReceipt("preflight-failed: \(error.localizedDescription)", ticket: ticketText)
                } else {
                    writeReceipt("preflight-cleanup-failed: \(error.localizedDescription)", ticket: ticketText)
                }
            }
            throw error
        }
    }

    func updateMode() throws -> ServiceUpdateMode {
        let snapshot = engine.list()
        guard snapshot.protection.isEnforcing,
            snapshot.protection.issues.isEmpty,
            snapshot.protection.lastAppliedAt != nil,
            snapshot.protection.serviceVersion == ProtectedServiceContract.serviceVersion
        else { throw ProtectedStateError.updateUnavailable }
        let apple = try appleLockdown.status()
        let activeBlock = snapshot.blocks.contains { $0.phase != .inactive }
        if !activeBlock, (try? appleLockdown.requireSafeMaintenance()) != nil {
            return .inactive
        }
        guard ProtectedServiceContract.liveServiceHandoffEnabled,
            [.inactive, .active, .waitingForFullUnlock].contains(apple.phase)
        else { throw ProtectedStateError.updateUnavailable }
        return .live
    }

    private func verifyBundle(
        _ bundle: URL,
        appRequirement: String,
        baseline: UInt64
    ) throws {
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let service = resources.appendingPathComponent("hard-pause-service")
        let cli = resources.appendingPathComponent("hard-pause")
        let worker = resources.appendingPathComponent("HardPauseBrowserWorker.app", isDirectory: true)
        let installer = resources.appendingPathComponent("install-macos-service.sh")
        for url in [bundle, bundle.appendingPathComponent("Contents", isDirectory: true), resources, worker] {
            try requireRootPublicDirectory(url, sealed: true)
        }
        for url in [service, cli] { try requireRootPublicFile(url, executable: true) }
        try requireRootPublicFile(installer)
        try requireRootPublicFile(
            worker.appendingPathComponent("Contents/MacOS/HardPauseBrowserWorker"), executable: true
        )
        try runChecked(
            "/usr/bin/codesign",
            ["--verify", "--strict", "--deep", "--all-architectures", "-R", appRequirement, bundle.path]
        )
        let info = try signedInfo(at: bundle.appendingPathComponent("Contents/Info.plist"))
        guard info.identifier == "org.hardpause.app",
            info.build > baseline,
            authorizer.updateCodeRequirement != nil
        else { throw ProtectedStateError.updateUnavailable }
        let candidateDigest = try ServiceCodeIdentity.candidateDigest(at: service.path)
        let requirements = authorizer.enrolledRequirements
        guard requirements.count >= 3 else { throw ProtectedStateError.updateUnavailable }
        try runChecked(
            "/usr/bin/codesign",
            [
                "--verify", "--strict", "--all-architectures", "-R",
                "(\(requirements[1])) and identifier \"org.hardpause.cli\"", cli.path,
            ]
        )
        try runChecked(
            "/usr/bin/codesign",
            [
                "--verify", "--strict", "--deep", "--all-architectures", "-R",
                "(\(requirements[2])) and identifier \"org.hardpause.browser-worker\"", worker.path,
            ]
        )
        guard
            try signedInfo(at: worker.appendingPathComponent("Contents/Info.plist")).identifier
                == "org.hardpause.browser-worker"
        else { throw ProtectedStateError.updateUnavailable }
        let result = try runner.run(executable: service.path, arguments: ["--service-version"], standardInput: nil)
        guard result.status == 0,
            Self.acceptsCandidate(
                version: result.standardOutput,
                digest: candidateDigest,
                runningVersion: ProtectedServiceContract.serviceVersion,
                runningDigest: runningDigest
            )
        else { throw ProtectedStateError.updateUnavailable }
    }

    static func validBundlePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.hasSuffix(".app") && path.utf8.count <= 4_096
            && !path.unicodeScalars.contains(where: { $0.value < 32 })
    }

    static func acceptsCandidate(
        version: String,
        digest: String,
        runningVersion: String,
        runningDigest: String
    ) -> Bool {
        guard let candidate = positiveInteger(version),
            let running = positiveInteger(runningVersion),
            candidate >= running
        else { return false }
        return candidate > running || digest != runningDigest
    }

    private func signedInfo(at url: URL) throws -> (identifier: String, build: UInt64) {
        try requireRootPublicFile(url)
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1_024,
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let identifier = plist["CFBundleIdentifier"] as? String,
            let buildText = plist["CFBundleVersion"] as? String,
            let build = Self.positiveInteger(buildText)
        else { throw ProtectedStateError.updateUnavailable }
        return (identifier, build)
    }

    static func positiveInteger(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.utf8.first != 48,
            trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
            let value = UInt64(trimmed), value > 0
        else { return nil }
        return value
    }

    private func readInstalledBuild() throws -> UInt64 {
        let url = URL(fileURLWithPath: ProtectedServiceContract.supportDirectory)
            .appendingPathComponent("installed-build-v1")
        try requireRootFile(url, exactMode: 0o600)
        let data = try Data(contentsOf: url)
        guard let build = Self.installedBuild(from: data)
        else { throw ProtectedStateError.updateUnavailable }
        return build
    }

    static func installedBuild(from data: Data) -> UInt64? {
        guard data.count <= 32, let text = String(data: data, encoding: .utf8) else { return nil }
        return positiveInteger(text)
    }

    private func writeJob(
        at stage: URL,
        bundle: URL,
        publicStage: URL,
        label: String,
        mode: ServiceUpdateMode,
        ticket: String,
        consoleUser: String
    ) throws {
        let active = updatesDirectory.appendingPathComponent("active")
        let receipt = updatesDirectory.appendingPathComponent("\(ticket).result")
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/bin/bash", "-c", Self.wrapper, "--", stage.path, publicStage.path,
                bundle.path, mode.rawValue, active.path, ticket, label, receipt.path,
            ],
            "EnvironmentVariables": [
                "SUDO_UID": String(authorizer.enrolledUID), "SUDO_USER": consoleUser,
            ],
            "RunAtLoad": false,
            "KeepAlive": false,
            "StandardOutPath": stage.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": stage.appendingPathComponent("stderr.log").path,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: job, format: .xml, options: 0
        )
        let path = stage.appendingPathComponent("job.plist")
        try data.write(to: path, options: .atomic)
        guard chmod(path.path, 0o600) == 0 else {
            throw ProtectedStateError.updateUnavailable
        }
        try requireRootFile(path, exactMode: 0o600)
    }

    private static let wrapper = """
        umask 077
        stage=$1; public_stage=$2; app=$3; mode=$4; marker=$5; ticket=$6; label=$7; receipt=$8
        if /bin/bash "$app/Contents/Resources/install-macos-service.sh" "$mode"; then
            if ! /bin/rm -rf -- "$public_stage"; then
                /usr/bin/printf 'cleanup-failed\\n' > "$receipt.tmp"
                /bin/mv -f "$receipt.tmp" "$receipt"
                exit 1
            fi
            if ! /bin/rm -rf -- "$stage"; then
                /usr/bin/printf 'cleanup-failed\\n' > "$receipt.tmp"
                /bin/mv -f "$receipt.tmp" "$receipt"
                exit 1
            fi
            /usr/bin/printf 'success\\n' > "$receipt.tmp"
            /bin/mv -f "$receipt.tmp" "$receipt"
            if [ "$(/bin/cat "$marker" 2>/dev/null)" = "$ticket" ]; then
                /bin/rm -f -- "$marker"
            fi
            /bin/launchctl bootout "system/$label" >/dev/null 2>&1 || true
            exit 0
        else
            result=$?
            /usr/bin/printf 'failed:%s\\n' "$result" > "$receipt.tmp"
            /bin/mv -f "$receipt.tmp" "$receipt"
            exit "$result"
        fi
        """

    private func kickstart(_ label: String) {
        do {
            try runChecked("/bin/launchctl", ["kickstart", "system/\(label)"])
        } catch {
            let ticket = String(label.dropFirst("org.hardpause.service-update.".count))
            writeReceipt("launch-failed: \(error.localizedDescription)", ticket: ticket)
        }
    }

    private func runChecked(_ executable: String, _ arguments: [String]) throws {
        let result = try runner.run(executable: executable, arguments: arguments, standardInput: nil)
        guard result.status == 0 else {
            throw ServiceRuntimeError.invalidInstall(
                "\(URL(fileURLWithPath: executable).lastPathComponent) failed with status \(result.status)"
            )
        }
    }

    private func requireConsoleUser() throws {
        var info = stat()
        guard lstat("/dev/console", &info) == 0,
            info.st_uid == authorizer.enrolledUID,
            info.st_uid > 0
        else { throw ProtectedStateError.updateUnavailable }
    }

    private func consoleUser() throws -> String {
        guard let entry = getpwuid(authorizer.enrolledUID),
            let name = entry.pointee.pw_name
        else { throw ProtectedStateError.updateUnavailable }
        let user = String(cString: name)
        guard !user.isEmpty, user != "root" else { throw ProtectedStateError.updateUnavailable }
        return user
    }

    private func requireSourceBundle(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ProtectedStateError.updateUnavailable
        }
    }

    private func makeUpdatesDirectory() throws {
        try FileManager.default.createDirectory(
            at: updatesDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try requireRootDirectory(updatesDirectory)
    }

    private func makePublicUpdatesDirectory() throws {
        try requireRootPublicDirectory(publicUpdatesDirectory.deletingLastPathComponent())
        try makePublicDirectory(publicUpdatesDirectory)
    }

    private func makePublicDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o755) == 0 {
            guard chmod(url.path, 0o755) == 0 else { throw ProtectedStateError.updateUnavailable }
        } else if errno != EEXIST {
            throw ProtectedStateError.updateUnavailable
        }
        try requireRootPublicDirectory(url)
    }

    private func requireRootPublicDirectory(_ url: URL, sealed: Bool = false) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFDIR,
            info.st_uid == 0,
            (info.st_mode & 0o022) == 0,
            (info.st_mode & 0o055) == 0o055,
            !sealed || (info.st_mode & 0o200) == 0
        else { throw ProtectedStateError.updateUnavailable }
    }

    private func requireRootPublicFile(_ url: URL, executable: Bool = false) throws {
        try requireRootFile(url)
        var info = stat()
        guard lstat(url.path, &info) == 0,
            (info.st_mode & 0o004) != 0,
            (info.st_mode & 0o200) == 0,
            !executable || (info.st_mode & 0o001) != 0
        else { throw ProtectedStateError.updateUnavailable }
    }

    private func requireRootDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFDIR,
            info.st_uid == 0,
            (info.st_mode & 0o077) == 0
        else { throw ProtectedStateError.updateUnavailable }
    }

    private func requireRootFile(_ url: URL, exactMode: mode_t? = nil) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_uid == 0,
            (info.st_mode & 0o022) == 0,
            exactMode == nil || (info.st_mode & 0o777) == exactMode
        else { throw ProtectedStateError.updateUnavailable }
    }

    private func claim(_ url: URL, ticket: String) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ProtectedStateError.updateInProgress }
        defer { _ = Darwin.close(descriptor) }
        let bytes = Array((ticket + "\n").utf8)
        let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count, fsync(descriptor) == 0 else {
            _ = Darwin.unlink(url.path)
            throw ProtectedStateError.updateUnavailable
        }
    }

    private func cleanupFailedPreflight(
        stage: URL?,
        publicStage: URL?,
        marker: URL,
        ticket: String
    ) -> Bool {
        do {
            for url in [publicStage, stage].compactMap({ $0 }) {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            let markerData = try Data(contentsOf: marker)
            guard markerData == Data((ticket + "\n").utf8) else { return false }
            try FileManager.default.removeItem(at: marker)
            return true
        } catch { return false }
    }

    private func writeReceipt(_ message: String, ticket: String) {
        let url = updatesDirectory.appendingPathComponent("\(ticket).result")
        try? Data((message + "\n").utf8).write(to: url, options: .atomic)
        _ = chmod(url.path, 0o600)
    }
}

enum ServiceStateDigest {
    static func hash<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value))
            .map { String(format: "%02x", $0) }.joined()
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
