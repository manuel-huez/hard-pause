import CryptoKit
import Darwin
import Foundation
import Security

protocol ProtectedStateStoring: AnyObject {
    func load() throws -> ProtectedState
    func loadReadOnly(requireCurrentFormat: Bool) throws -> ProtectedState
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
        let state = try stateStore.loadReadOnly(requireCurrentFormat: false)
        let activeNames = state.blocks.compactMap { block in
            block.activation == nil ? nil : block.draft.name
        }.sorted()
        guard activeNames.isEmpty else {
            throw ServiceRuntimeError.invalidInstall(
                "protection is active for: \(activeNames.joined(separator: ", "))"
            )
        }
        guard state.updateGateToken == nil, state.liveUpdateGate == nil else {
            throw ServiceRuntimeError.invalidInstall("a service update is in progress")
        }
        let appleLockdownState = try appleLockdownStore.loadReadOnly(requireCurrentFormat: false)
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
    private let allowActiveLegacyMigration: Bool

    init(
        stateURL: URL = URL(fileURLWithPath: ProtectedServiceContract.statePath),
        pendingStateURL: URL = URL(
            fileURLWithPath: ProtectedServiceContract.supportDirectory
        ).appendingPathComponent("pending-state-v2.json"),
        backupDirectory: URL = URL(fileURLWithPath: ProtectedServiceContract.backupDirectory),
        requireRootOwnership: Bool = true,
        maximumBackups: Int = 8,
        authenticationKeys: any StateAuthenticationKeyStoring = SystemKeychainStateAuthenticationKeys(),
        fileManager: FileManager = .default,
        allowActiveLegacyMigration: Bool = false
    ) {
        self.stateURL = stateURL
        self.pendingStateURL = pendingStateURL
        self.backupDirectory = backupDirectory
        self.requireRootOwnership = requireRootOwnership
        self.maximumBackups = maximumBackups
        authenticator = StateAuthenticator(keys: authenticationKeys)
        self.fileManager = fileManager
        self.allowActiveLegacyMigration = allowActiveLegacyMigration
    }

    func load() throws -> ProtectedState {
        do {
            if fileManager.fileExists(atPath: pendingStateURL.path) {
                let (pending, legacyPending) = try readPendingTransition()
                let pendingDigest = try stateDigest(pending.candidate)
                let anchor = try authenticator.keys.readAnchor()
                let primary =
                    fileManager.fileExists(atPath: stateURL.path)
                    ? try readState(at: stateURL)
                    : try emptyStateIfNeverCommitted(allowPending: true)
                if primary == pending.candidate {
                    guard
                        anchor?.pendingDigest == pendingDigest
                            || anchor?.currentDigest == pendingDigest || legacyPending
                    else {
                        throw ServiceRuntimeError.unreadableState(
                            "the pending transition is not anchored"
                        )
                    }
                    try authenticator.keys.saveAnchor(
                        StateCommitAnchor(currentDigest: pendingDigest, pendingDigest: nil)
                    )
                    try clearPendingCandidate()
                    return primary
                }
                if anchor?.pendingDigest != pendingDigest && !legacyPending {
                    guard anchor?.pendingDigest == nil else {
                        throw ServiceRuntimeError.unreadableState(
                            "the pending transition does not match the Keychain anchor"
                        )
                    }
                    // The journal was written, but its Keychain commit was interrupted.
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
            if try authenticator.keys.readAnchor()?.pendingDigest != nil {
                throw ServiceRuntimeError.unreadableState("the pending protected state is missing")
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

    func loadReadOnly(requireCurrentFormat: Bool) throws -> ProtectedState {
        guard !fileManager.fileExists(atPath: pendingStateURL.path) else {
            throw ServiceRuntimeError.unreadableState(
                "a pending protected transition must be recovered by the current service"
            )
        }
        guard try authenticator.keys.readAnchor()?.pendingDigest == nil else {
            throw ServiceRuntimeError.unreadableState("the pending protected state is missing")
        }
        guard fileManager.fileExists(atPath: stateURL.path) else {
            guard !requireCurrentFormat else {
                throw ServiceRuntimeError.unreadableState("the protected state is missing")
            }
            return try emptyStateIfNeverCommitted()
        }
        return try readState(
            at: stateURL,
            readOnly: true,
            requireCurrentFormat: requireCurrentFormat
        )
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
            let digest = try stateDigest(state)
            if allowActiveLegacyMigration,
                try authenticator.keys.readAnchor() == nil,
                fileManager.fileExists(atPath: stateURL.path)
            {
                let previous = try Data(contentsOf: stateURL, options: .mappedIfSafe)
                if try authenticator.open(previous, purpose: "primary").isLegacy {
                    _ = try readState(at: stateURL, readOnly: true)
                    try prepareDirectory(backupDirectory)
                    let backup = backupDirectory.appendingPathComponent(
                        "state-v2-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString).json"
                    )
                    try writeAtomically(previous, to: backup)
                    try writeAtomically(try authenticator.seal(data, purpose: "primary"), to: stateURL)
                    try authenticator.keys.saveAnchor(
                        StateCommitAnchor(currentDigest: digest, pendingDigest: nil)
                    )
                    try authenticator.keys.markCommittedState()
                    try pruneBackups()
                    return
                }
            }
            if try authenticator.keys.readAnchor()?.pendingDigest != digest {
                try savePendingCandidate(state)
            } else {
                guard fileManager.fileExists(atPath: pendingStateURL.path),
                    try stateDigest(readPendingTransition().0.candidate) == digest
                else {
                    throw ServiceRuntimeError.unreadableState(
                        "the anchored pending protected state is missing or invalid"
                    )
                }
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
                _ = try emptyStateIfNeverCommitted(allowPending: true)
            }
            try writeAtomically(try authenticator.seal(data, purpose: "primary"), to: stateURL)
            try authenticator.keys.saveAnchor(
                StateCommitAnchor(currentDigest: digest, pendingDigest: nil)
            )
            try authenticator.keys.markCommittedState()
            try clearPendingCandidate()
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
            let baseDigest = try stateDigest(base)
            let anchor = try authenticator.keys.readAnchor()
            guard anchor == nil || anchor?.currentDigest == baseDigest else {
                throw ServiceRuntimeError.unreadableState(
                    "the primary protected state does not match the Keychain anchor"
                )
            }
            let transition = PendingStateTransition(
                baseStateDigest: baseDigest,
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
            try authenticator.keys.saveAnchor(
                StateCommitAnchor(
                    currentDigest: fileManager.fileExists(atPath: stateURL.path) ? baseDigest : nil,
                    pendingDigest: try stateDigest(state)
                )
            )
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

    private func readState(
        at url: URL,
        readOnly: Bool = false,
        requireCurrentFormat: Bool = false
    ) throws -> ProtectedState {
        try validateProtectedFile(at: url, maximumBytes: Self.maximumAuthenticatedBytes)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let opened = try authenticator.open(data, purpose: "primary")
        guard opened.payload.count <= ProtectedServiceContract.maximumPayloadBytes else {
            throw ServiceRuntimeError.unreadableState("protected state is too large")
        }
        let state = try JSONDecoder().decode(ProtectedState.self, from: opened.payload)
        try state.validateForPersistence()
        let digest = try stateDigest(state)
        let anchor = try authenticator.keys.readAnchor()
        if requireCurrentFormat {
            guard !opened.isLegacy,
                anchor?.currentDigest == digest,
                anchor?.pendingDigest == nil
            else {
                throw ServiceRuntimeError.unreadableState(
                    "the protected state is not ready for a read-only handoff"
                )
            }
        }
        if let anchor {
            guard digest == anchor.currentDigest || digest == anchor.pendingDigest else {
                throw ServiceRuntimeError.unreadableState(
                    "the primary protected state does not match the Keychain anchor"
                )
            }
        }
        if opened.isLegacy {
            guard allowActiveLegacyMigration || state.blocks.allSatisfy({ $0.activation == nil }) else {
                throw ServiceRuntimeError.unreadableState(
                    "active legacy state needs the installed service; protection was not reset"
                )
            }
            if !readOnly && !allowActiveLegacyMigration {
                try writeAtomically(try authenticator.seal(opened.payload, purpose: "primary"), to: url)
            }
        }
        if anchor == nil {
            guard allowActiveLegacyMigration || state.blocks.allSatisfy({ $0.activation == nil }) else {
                throw ServiceRuntimeError.unreadableState(
                    "active state has no Keychain anchor"
                )
            }
            if !readOnly && (!allowActiveLegacyMigration || !opened.isLegacy) {
                try authenticator.keys.saveAnchor(
                    StateCommitAnchor(currentDigest: digest, pendingDigest: nil)
                )
            }
        }
        if !readOnly { try authenticator.keys.markCommittedState() }
        return state
    }

    private func readPendingTransition() throws -> (PendingStateTransition, Bool) {
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
        return (transition, opened.isLegacy)
    }

    private func emptyStateIfNeverCommitted(allowPending: Bool = false) throws -> ProtectedState {
        if allowPending, let anchor = try authenticator.keys.readAnchor(),
            anchor.currentDigest == nil, anchor.pendingDigest != nil
        {
            return ProtectedState()
        }
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
