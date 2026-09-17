import Darwin
import Foundation

protocol AppleLockdownStateStoring: AnyObject {
    func load() throws -> AppleLockdownState
    func save(_ state: AppleLockdownState) throws
}

final class JSONAppleLockdownStateStore: AppleLockdownStateStoring {
    private static let maximumBytes = 32 * 1_024

    private let stateURL: URL
    private let requireRootOwnership: Bool
    private let fileManager: FileManager

    init(
        stateURL: URL = URL(fileURLWithPath: ProtectedServiceContract.appleLockdownStatePath),
        requireRootOwnership: Bool = true,
        fileManager: FileManager = .default
    ) {
        self.stateURL = stateURL
        self.requireRootOwnership = requireRootOwnership
        self.fileManager = fileManager
    }

    func load() throws -> AppleLockdownState {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return AppleLockdownState()
        }
        do {
            try validateProtectedFile()
            let data = try Data(contentsOf: stateURL, options: .mappedIfSafe)
            let state = try JSONDecoder().decode(AppleLockdownState.self, from: data)
            try state.validateForPersistence()
            return state
        } catch let error as ServiceRuntimeError {
            throw error
        } catch {
            throw ServiceRuntimeError.unreadableState(
                "the Apple Lockdown state is invalid"
            )
        }
    }

    func save(_ state: AppleLockdownState) throws {
        do {
            try state.validateForPersistence()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            guard data.count <= Self.maximumBytes else {
                throw AppleLockdownError.stateUnavailable
            }
            try prepareDirectory()
            try writeAtomically(data)
        } catch let error as ServiceRuntimeError {
            throw error
        } catch let error as AppleLockdownError {
            throw error
        } catch {
            throw ServiceRuntimeError.stateWriteFailed(
                "the Apple Lockdown state could not be saved"
            )
        }
    }

    private func validateProtectedFile() throws {
        var info = stat()
        guard lstat(stateURL.path, &info) == 0 else {
            throw ServiceRuntimeError.unreadableState(
                "the Apple Lockdown state cannot be inspected"
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ServiceRuntimeError.unreadableState(
                "the Apple Lockdown state is not a regular file"
            )
        }
        guard info.st_size > 0, info.st_size <= Self.maximumBytes else {
            throw ServiceRuntimeError.unreadableState(
                "the Apple Lockdown state has an invalid size"
            )
        }
        if requireRootOwnership {
            guard info.st_uid == 0, (info.st_mode & 0o077) == 0 else {
                throw ServiceRuntimeError.unreadableState(
                    "the Apple Lockdown state must be root-only"
                )
            }
        }
    }

    private func prepareDirectory() throws {
        let directory = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw ServiceRuntimeError.stateWriteFailed(
                "the Apple Lockdown state directory could not be protected"
            )
        }
        if requireRootOwnership, chown(directory.path, 0, 0) != 0 {
            throw ServiceRuntimeError.stateWriteFailed(
                "the Apple Lockdown state directory has invalid ownership"
            )
        }
    }

    private func writeAtomically(_ data: Data) throws {
        let temporary = stateURL.deletingLastPathComponent().appendingPathComponent(
            ".\(stateURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ServiceRuntimeError.stateWriteFailed(
                "the Apple Lockdown state file could not be created"
            )
        }
        var succeeded = false
        defer {
            _ = Darwin.close(descriptor)
            if !succeeded { _ = unlink(temporary.path) }
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    buffer.count - written
                )
                guard result > 0 else {
                    throw ServiceRuntimeError.stateWriteFailed(
                        "the Apple Lockdown state file could not be written"
                    )
                }
                written += result
            }
        }
        guard fsync(descriptor) == 0 else {
            throw ServiceRuntimeError.stateWriteFailed(
                "the Apple Lockdown state file could not be synchronized"
            )
        }
        if requireRootOwnership, fchown(descriptor, 0, 0) != 0 {
            throw ServiceRuntimeError.stateWriteFailed(
                "the Apple Lockdown state file has invalid ownership"
            )
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw ServiceRuntimeError.stateWriteFailed(
                "the Apple Lockdown state file could not be protected"
            )
        }
        guard rename(temporary.path, stateURL.path) == 0 else {
            throw ServiceRuntimeError.stateWriteFailed(
                "the Apple Lockdown state file could not be installed"
            )
        }
        succeeded = true
        try syncDirectory()
    }

    private func syncDirectory() throws {
        let directory = stateURL.deletingLastPathComponent()
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw ServiceRuntimeError.stateWriteFailed(
                "the Apple Lockdown state directory cannot be opened"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ServiceRuntimeError.stateWriteFailed(
                "the Apple Lockdown state directory could not be synchronized"
            )
        }
    }
}
