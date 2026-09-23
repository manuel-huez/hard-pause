import CryptoKit
import Darwin
import Foundation
import Security

protocol ProtectedStateStoring: AnyObject {
    func load() throws -> ProtectedState
    func save(_ state: ProtectedState) throws
    func savePendingCandidate(_ state: ProtectedState) throws
    func clearPendingCandidate() throws
}

enum OfflineServiceMaintenance {
    static func requireSafeNormalUninstall(
        stateStore: ProtectedStateStoring,
        appleLockdownStore: AppleLockdownStateStoring,
        appleLockdownVault: AppleLockdownCredentialVault
    ) throws {
        let state = try stateStore.load()
        let activeNames = state.blocks.compactMap { block in
            block.activation == nil ? nil : block.draft.name
        }.sorted()
        guard activeNames.isEmpty else {
            throw ServiceRuntimeError.invalidInstall(
                "protection is active for: \(activeNames.joined(separator: ", "))"
            )
        }
        let appleLockdownState = try appleLockdownStore.load()
        guard !appleLockdownState.preventsMaintenance else {
            throw ServiceRuntimeError.invalidInstall(
                "Screen Time protection setup, protection, or release is still active"
            )
        }
        guard try !appleLockdownVault.containsAnyCredential() else {
            throw ServiceRuntimeError.invalidInstall(
                "a Screen Time protection credential still exists"
            )
        }
    }
}

final class JSONProtectedStateStore: ProtectedStateStoring {
    private static let maximumPendingBytes = ProtectedServiceContract.maximumPayloadBytes + 4 * 1_024
    private static let maximumAuthenticatedBytes = 2 * maximumPendingBytes + 4 * 1_024

    private let stateURL: URL
    private let pendingStateURL: URL
    private let backupDirectory: URL
    private let requireRootOwnership: Bool
    private let maximumBackups: Int
    private let fileManager: FileManager
    private let authenticator: StateAuthenticator

    init(
        stateURL: URL = URL(fileURLWithPath: ProtectedServiceContract.statePath),
        pendingStateURL: URL = URL(
            fileURLWithPath: ProtectedServiceContract.supportDirectory
        ).appendingPathComponent("pending-state-v2.json"),
        backupDirectory: URL = URL(fileURLWithPath: ProtectedServiceContract.backupDirectory),
        requireRootOwnership: Bool = true,
        maximumBackups: Int = 8,
        authenticationKeys: any StateAuthenticationKeyStoring = SystemKeychainStateAuthenticationKeys(),
        fileManager: FileManager = .default
    ) {
        self.stateURL = stateURL
        self.pendingStateURL = pendingStateURL
        self.backupDirectory = backupDirectory
        self.requireRootOwnership = requireRootOwnership
        self.maximumBackups = maximumBackups
        authenticator = StateAuthenticator(keys: authenticationKeys)
        self.fileManager = fileManager
    }

    func load() throws -> ProtectedState {
        do {
            if fileManager.fileExists(atPath: pendingStateURL.path) {
                let pending = try readPendingTransition()
                let primary =
                    fileManager.fileExists(atPath: stateURL.path)
                    ? try readState(at: stateURL)
                    : try emptyStateIfNeverCommitted()
                if primary == pending.candidate {
                    try clearPendingCandidate()
                    return primary
                }
                guard try stateDigest(primary) == pending.baseStateDigest else {
                    throw ServiceRuntimeError.unreadableState(
                        "the pending transition does not match the primary protected state"
                    )
                }
                try save(pending.candidate)
                try clearPendingCandidate()
                return pending.candidate
            }
            guard fileManager.fileExists(atPath: stateURL.path) else {
                return try emptyStateIfNeverCommitted()
            }
            return try readState(at: stateURL)
        } catch let error as ServiceRuntimeError {
            throw error
        } catch {
            throw ServiceRuntimeError.unreadableState(error.localizedDescription)
        }
    }

    func save(_ state: ProtectedState) throws {
        do {
            try state.validateForPersistence()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            guard data.count <= ProtectedServiceContract.maximumPayloadBytes else {
                throw ProtectedStateError.aggregateLimitReached
            }
            try prepareDirectory(stateURL.deletingLastPathComponent())
            try prepareDirectory(backupDirectory)
            if fileManager.fileExists(atPath: stateURL.path) {
                _ = try readState(at: stateURL)
                let previous = try Data(contentsOf: stateURL, options: .mappedIfSafe)
                let milliseconds = Int(Date().timeIntervalSince1970 * 1_000)
                let backup = backupDirectory.appendingPathComponent(
                    "state-v2-\(milliseconds)-\(UUID().uuidString).json"
                )
                try writeAtomically(previous, to: backup)
            } else {
                _ = try emptyStateIfNeverCommitted()
            }
            try writeAtomically(try authenticator.seal(data, purpose: "primary"), to: stateURL)
            try authenticator.keys.markCommittedState()
            try pruneBackups()
        } catch let error as ProtectedStateError {
            throw error
        } catch let error as ServiceRuntimeError {
            throw error
        } catch {
            throw ServiceRuntimeError.stateWriteFailed(error.localizedDescription)
        }
    }

    func savePendingCandidate(_ state: ProtectedState) throws {
        do {
            try state.validateForPersistence()
            let base =
                fileManager.fileExists(atPath: stateURL.path)
                ? try readState(at: stateURL)
                : try emptyStateIfNeverCommitted()
            try base.validateForPersistence()
            let transition = PendingStateTransition(
                baseStateDigest: try stateDigest(base),
                candidate: state
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(transition)
            guard data.count <= Self.maximumPendingBytes else {
                throw ProtectedStateError.aggregateLimitReached
            }
            try prepareDirectory(pendingStateURL.deletingLastPathComponent())
            try writeAtomically(try authenticator.seal(data, purpose: "pending"), to: pendingStateURL)
        } catch let error as ProtectedStateError {
            throw error
        } catch let error as ServiceRuntimeError {
            throw error
        } catch {
            throw ServiceRuntimeError.stateWriteFailed(error.localizedDescription)
        }
    }

    func clearPendingCandidate() throws {
        guard fileManager.fileExists(atPath: pendingStateURL.path) else { return }
        do {
            try validateProtectedFile(
                at: pendingStateURL,
                maximumBytes: Self.maximumAuthenticatedBytes
            )
            try fileManager.removeItem(at: pendingStateURL)
            try syncDirectory(pendingStateURL.deletingLastPathComponent())
        } catch let error as ServiceRuntimeError {
            throw error
        } catch {
            throw ServiceRuntimeError.stateWriteFailed(error.localizedDescription)
        }
    }

    private func readState(at url: URL) throws -> ProtectedState {
        try validateProtectedFile(at: url, maximumBytes: Self.maximumAuthenticatedBytes)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let opened = try authenticator.open(data, purpose: "primary")
        guard opened.payload.count <= ProtectedServiceContract.maximumPayloadBytes else {
            throw ServiceRuntimeError.unreadableState("protected state is too large")
        }
        let state = try JSONDecoder().decode(ProtectedState.self, from: opened.payload)
        try state.validateForPersistence()
        if opened.isLegacy {
            guard state.blocks.allSatisfy({ $0.activation == nil }) else {
                throw ServiceRuntimeError.unreadableState(
                    "active legacy state needs the installed service; protection was not reset"
                )
            }
            try writeAtomically(try authenticator.seal(opened.payload, purpose: "primary"), to: url)
        }
        try authenticator.keys.markCommittedState()
        return state
    }

    private func readPendingTransition() throws -> PendingStateTransition {
        try validateProtectedFile(at: pendingStateURL, maximumBytes: Self.maximumAuthenticatedBytes)
        let data = try Data(contentsOf: pendingStateURL, options: .mappedIfSafe)
        let opened = try authenticator.open(data, purpose: "pending")
        guard opened.payload.count <= Self.maximumPendingBytes else {
            throw ServiceRuntimeError.unreadableState("pending protected state is too large")
        }
        let transition = try JSONDecoder().decode(
            PendingStateTransition.self,
            from: opened.payload
        )
        try transition.validate()
        if opened.isLegacy {
            guard transition.candidate.blocks.allSatisfy({ $0.activation == nil }) else {
                throw ServiceRuntimeError.unreadableState(
                    "active legacy transition needs the installed service; protection was not reset"
                )
            }
            try writeAtomically(
                try authenticator.seal(opened.payload, purpose: "pending"), to: pendingStateURL
            )
        }
        return transition
    }

    private func emptyStateIfNeverCommitted() throws -> ProtectedState {
        guard try !authenticator.keys.hasCommittedState() else {
            throw ServiceRuntimeError.unreadableState("the protected state is missing")
        }
        return ProtectedState()
    }

    private func stateDigest(_ state: ProtectedState) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(state)).map { String(format: "%02x", $0) }.joined()
    }

    private func validateProtectedFile(at url: URL, maximumBytes: Int) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw ServiceRuntimeError.unreadableState(String(cString: strerror(errno)))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ServiceRuntimeError.unreadableState("\(url.path) is not a regular file")
        }
        guard info.st_size >= 0, info.st_size <= maximumBytes else {
            throw ServiceRuntimeError.unreadableState("\(url.lastPathComponent) is too large")
        }
        if requireRootOwnership {
            guard info.st_uid == 0, (info.st_mode & 0o077) == 0 else {
                throw ServiceRuntimeError.unreadableState(
                    "\(url.lastPathComponent) must be root-owned and accessible only by root"
                )
            }
        }
    }

    private func prepareDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(url.path, 0o700) == 0 else {
            throw ServiceRuntimeError.stateWriteFailed(String(cString: strerror(errno)))
        }
        if requireRootOwnership, chown(url.path, 0, 0) != 0 {
            throw ServiceRuntimeError.stateWriteFailed(String(cString: strerror(errno)))
        }
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ServiceRuntimeError.stateWriteFailed(String(cString: strerror(errno)))
        }
        var succeeded = false
        defer {
            _ = Darwin.close(descriptor)
            if !succeeded { _ = unlink(temporary.path) }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(descriptor, base.advanced(by: written), rawBuffer.count - written)
                guard result > 0 else {
                    throw ServiceRuntimeError.stateWriteFailed(String(cString: strerror(errno)))
                }
                written += result
            }
        }
        guard fsync(descriptor) == 0 else {
            throw ServiceRuntimeError.stateWriteFailed(String(cString: strerror(errno)))
        }
        if requireRootOwnership, fchown(descriptor, 0, 0) != 0 {
            throw ServiceRuntimeError.stateWriteFailed(String(cString: strerror(errno)))
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw ServiceRuntimeError.stateWriteFailed(String(cString: strerror(errno)))
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw ServiceRuntimeError.stateWriteFailed(String(cString: strerror(errno)))
        }
        succeeded = true
        try syncDirectory(destination.deletingLastPathComponent())
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw ServiceRuntimeError.stateWriteFailed(String(cString: strerror(errno)))
        }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ServiceRuntimeError.stateWriteFailed(String(cString: strerror(errno)))
        }
    }

    private func pruneBackups() throws {
        let backups = try fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix("state-v2-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for backup in backups.dropFirst(maximumBackups) { try fileManager.removeItem(at: backup) }
    }
}

private struct PendingStateTransition: Codable {
    let schemaVersion: Int
    let baseStateDigest: String
    let candidate: ProtectedState

    init(baseStateDigest: String, candidate: ProtectedState) {
        schemaVersion = 1
        self.baseStateDigest = baseStateDigest
        self.candidate = candidate
    }

    func validate() throws {
        guard schemaVersion == 1,
            baseStateDigest.count == 64,
            baseStateDigest.allSatisfy({ $0.isHexDigit })
        else {
            throw ServiceRuntimeError.unreadableState("the pending transition metadata is invalid")
        }
        try candidate.validateForPersistence()
    }
}

struct ProtectedEnrollmentLoader {
    let url: URL
    let requireRootOwnership: Bool

    init(
        url: URL = URL(fileURLWithPath: ProtectedServiceContract.enrollmentPath),
        requireRootOwnership: Bool = true
    ) {
        self.url = url
        self.requireRootOwnership = requireRootOwnership
    }

    func load() throws -> ProtectedServiceEnrollment {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ServiceRuntimeError.invalidInstall("the enrollment file is missing or is not regular")
        }
        guard info.st_size > 0, info.st_size <= 128 * 1_024 else {
            throw ServiceRuntimeError.invalidInstall("the enrollment file has an invalid size")
        }
        if requireRootOwnership, info.st_uid != 0 || (info.st_mode & 0o077) != 0 {
            throw ServiceRuntimeError.invalidInstall("the enrollment file must be root-only")
        }
        do {
            let enrollment = try JSONDecoder().decode(
                ProtectedServiceEnrollment.self,
                from: Data(contentsOf: url, options: .mappedIfSafe)
            )
            try enrollment.validate()
            for expression in enrollment.approvedClientRequirements {
                var requirement: SecRequirement?
                let status = SecRequirementCreateWithString(expression as CFString, [], &requirement)
                guard status == errSecSuccess, requirement != nil else {
                    throw ServiceRuntimeError.invalidInstall("a client code requirement is invalid")
                }
            }
            return enrollment
        } catch let error as ServiceRuntimeError {
            throw error
        } catch {
            throw ServiceRuntimeError.invalidInstall(error.localizedDescription)
        }
    }
}
