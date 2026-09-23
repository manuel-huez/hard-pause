import Darwin
import Foundation
import XCTest

final class ProtectedStateStoreTests: XCTestCase {
    func testOfflineCheckRejectsActivationAfterLivePrecheck() throws {
        var state = ProtectedState()
        let block = try state.create(serviceTestDraft(name: "Focus"))
        let store = FakeProtectedStateStore(state)

        XCTAssertNoThrow(
            try OfflineServiceMaintenance.requireSafeNormalUninstall(
                stateStore: store,
                appleLockdownStore: FakeAppleLockdownStateStore(),
                appleLockdownVault: FakeAppleLockdownVault()
            )
        )

        try state.activate(
            id: block.id,
            expectedRevision: block.revision,
            at: serviceTestReading(0)
        )
        store.persisted = state

        XCTAssertThrowsError(
            try OfflineServiceMaintenance.requireSafeNormalUninstall(
                stateStore: store,
                appleLockdownStore: FakeAppleLockdownStateStore(),
                appleLockdownVault: FakeAppleLockdownVault()
            )
        ) { error in
            guard case ServiceRuntimeError.invalidInstall(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("Focus"))
        }
    }

    func testStateRoundTripUsesPrivateFileAndRotatingBackups() throws {
        let paths = try temporaryPaths()
        let keys = FakeStateAuthenticationKeys()
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false,
            maximumBackups: 2,
            authenticationKeys: keys
        )
        var state = ProtectedState()
        _ = try state.create(serviceTestDraft(name: "One", domains: ["one.example"]))
        try store.save(state)
        _ = try state.create(serviceTestDraft(name: "Two", domains: ["two.example"]))
        try store.save(state)
        _ = try state.create(serviceTestDraft(name: "Three", domains: ["three.example"]))
        try store.save(state)
        _ = try state.create(serviceTestDraft(name: "Four", domains: ["four.example"]))
        try store.save(state)

        XCTAssertEqual(try store.load(), state)
        let encrypted = try Data(contentsOf: paths.state)
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("one.example"))
        let opened = try StateAuthenticator(keys: keys).open(encrypted, purpose: "primary")
        XCTAssertEqual(
            try JSONDecoder().decode(ProtectedState.self, from: opened.payload),
            state
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.state.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let backups = try FileManager.default.contentsOfDirectory(atPath: paths.backups.path)
        XCTAssertEqual(backups.filter { $0.hasPrefix("state-v2-") }.count, 2)
    }

    func testOfflineCheckRejectsPendingScreenTimeSetup() throws {
        var appleState = AppleLockdownState()
        try appleState.beginSetup(
            AppleLockdownSetupRequest(
                fullUnlockDelay: 60,
                enablesAdultFilter: false,
                filterWasAlreadyEnabled: true,
                shareAcrossDevicesVerified: nil
            )
        )

        XCTAssertThrowsError(
            try OfflineServiceMaintenance.requireSafeNormalUninstall(
                stateStore: FakeProtectedStateStore(),
                appleLockdownStore: FakeAppleLockdownStateStore(appleState),
                appleLockdownVault: FakeAppleLockdownVault()
            )
        ) { error in
            guard case ServiceRuntimeError.invalidInstall(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("Screen Time protection"))
        }
    }

    func testOfflineCheckRejectsOrphanedScreenTimeCredential() throws {
        let vault = FakeAppleLockdownVault()
        vault.values[UUID()] = "4820"

        XCTAssertThrowsError(
            try OfflineServiceMaintenance.requireSafeNormalUninstall(
                stateStore: FakeProtectedStateStore(),
                appleLockdownStore: FakeAppleLockdownStateStore(),
                appleLockdownVault: vault
            )
        ) { error in
            guard case ServiceRuntimeError.invalidInstall(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("credential"))
        }
    }

    func testAppleLockdownStateRoundTripUsesPrivateFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("apple-lockdown-state-v1.json")
        let store = JSONAppleLockdownStateStore(
            stateURL: url,
            requireRootOwnership: false,
            authenticationKeys: FakeStateAuthenticationKeys()
        )
        var state = AppleLockdownState()
        try state.beginSetup(
            AppleLockdownSetupRequest(
                fullUnlockDelay: 3_600,
                enablesAdultFilter: true,
                filterWasAlreadyEnabled: false,
                shareAcrossDevicesVerified: false
            )
        )
        try state.markSetupCredentialReady()

        try store.save(state)

        XCTAssertEqual(try store.load(), state)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        var changed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        changed["ciphertext"] = Data(repeating: 0, count: 32).base64EncodedString()
        try JSONSerialization.data(withJSONObject: changed).write(to: url)
        XCTAssertThrowsError(try store.load()) { error in
            guard case ServiceRuntimeError.unreadableState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAppleLockdownStateSymbolicLinkIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let state = root.appendingPathComponent("apple-lockdown-state-v1.json")
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: target)
        let store = JSONAppleLockdownStateStore(
            stateURL: state,
            requireRootOwnership: false,
            authenticationKeys: FakeStateAuthenticationKeys()
        )

        XCTAssertThrowsError(try store.load()) { error in
            guard case ServiceRuntimeError.unreadableState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testActiveLegacyAppleLockdownStateIsNotSilentlyMigrated() throws {
        let paths = try temporaryPaths()
        let url = paths.root.appendingPathComponent("apple-lockdown-state-v1.json")
        let store = JSONAppleLockdownStateStore(
            stateURL: url,
            requireRootOwnership: false,
            authenticationKeys: FakeStateAuthenticationKeys()
        )
        var state = AppleLockdownState()
        try state.beginSetup(
            AppleLockdownSetupRequest(
                fullUnlockDelay: 3_600,
                enablesAdultFilter: true,
                filterWasAlreadyEnabled: false,
                shareAcrossDevicesVerified: false
            )
        )
        let legacy = try JSONEncoder().encode(state)
        try legacy.write(to: url)

        XCTAssertThrowsError(try store.load()) { error in
            guard case ServiceRuntimeError.unreadableState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), legacy)
    }

    func testPendingCandidateWithoutPrimaryIsPromotedAndCleared() throws {
        let paths = try temporaryPaths()
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false,
            authenticationKeys: FakeStateAuthenticationKeys()
        )
        var pending = ProtectedState()
        _ = try pending.create(serviceTestDraft())
        try store.savePendingCandidate(pending)

        XCTAssertEqual(try store.load(), pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.state.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pending.path))
    }

    func testMatchingPendingCandidateIsClearedWithoutOverwritingPrimary() throws {
        let paths = try temporaryPaths()
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false,
            authenticationKeys: FakeStateAuthenticationKeys()
        )
        var state = ProtectedState()
        _ = try state.create(serviceTestDraft())
        try store.save(state)
        try store.savePendingCandidate(state)

        XCTAssertEqual(try store.load(), state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pending.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.backups.path).isEmpty)
    }

    func testOlderEncryptedPrimaryCannotBeRestored() throws {
        let paths = try temporaryPaths()
        let keys = FakeStateAuthenticationKeys()
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false,
            authenticationKeys: keys
        )
        var oldState = ProtectedState()
        _ = try oldState.create(serviceTestDraft(name: "Old"))
        try store.save(oldState)
        let oldFile = try Data(contentsOf: paths.state)
        var newerState = oldState
        _ = try newerState.create(serviceTestDraft(name: "New", domains: ["new.example"]))
        try store.save(newerState)
        try oldFile.write(to: paths.state)

        XCTAssertThrowsError(try store.load()) { error in
            guard case ServiceRuntimeError.unreadableState(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("Keychain anchor"))
        }
    }

    func testMissingAnchoredPendingStateIsRejected() throws {
        let paths = try temporaryPaths()
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false,
            authenticationKeys: FakeStateAuthenticationKeys()
        )
        var state = ProtectedState()
        _ = try state.create(serviceTestDraft())
        try store.save(state)
        _ = try state.create(serviceTestDraft(name: "Additional"))
        try store.savePendingCandidate(state)
        try FileManager.default.removeItem(at: paths.pending)

        XCTAssertThrowsError(try store.load()) { error in
            guard case ServiceRuntimeError.unreadableState(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("pending protected state is missing"))
        }
    }

    func testChangedStatePayloadAndMissingStateAreRejectedAfterCommit() throws {
        let paths = try temporaryPaths()
        let keys = FakeStateAuthenticationKeys()
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false,
            authenticationKeys: keys
        )
        var state = ProtectedState()
        _ = try state.create(serviceTestDraft())
        try store.save(state)

        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: paths.state)) as? [String: Any]
        )
        envelope["ciphertext"] = Data(repeating: 0, count: 32).base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: paths.state)
        XCTAssertThrowsError(try store.load()) { error in
            guard case ServiceRuntimeError.unreadableState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try FileManager.default.removeItem(at: paths.state)
        XCTAssertThrowsError(try store.load()) { error in
            guard case ServiceRuntimeError.unreadableState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testOnlyInactiveLegacyStateCanBeAuthenticatedOnLoad() throws {
        let paths = try temporaryPaths()
        let keys = FakeStateAuthenticationKeys()
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false,
            authenticationKeys: keys
        )
        var state = ProtectedState()
        let block = try state.create(serviceTestDraft())
        try JSONEncoder().encode(state).write(to: paths.state)
        XCTAssertEqual(try store.load(), state)
        XCTAssertTrue(keys.committed)
        XCTAssertFalse(
            try StateAuthenticator(keys: keys).open(
                Data(contentsOf: paths.state), purpose: "primary"
            ).isLegacy)

        let activePaths = try temporaryPaths()
        let activeStore = JSONProtectedStateStore(
            stateURL: activePaths.state,
            pendingStateURL: activePaths.pending,
            backupDirectory: activePaths.backups,
            requireRootOwnership: false,
            authenticationKeys: FakeStateAuthenticationKeys()
        )
        try state.activate(id: block.id, expectedRevision: block.revision, at: serviceTestReading(0))
        let legacy = try JSONEncoder().encode(state)
        try legacy.write(to: activePaths.state)
        XCTAssertThrowsError(try activeStore.load()) { error in
            guard case ServiceRuntimeError.unreadableState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: activePaths.state), legacy)
    }

    func testPendingCandidateReplaysAfterCrashBeforePrimarySave() throws {
        let paths = try temporaryPaths()
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false,
            authenticationKeys: FakeStateAuthenticationKeys()
        )
        var base = ProtectedState()
        _ = try base.create(serviceTestDraft(name: "Base", domains: ["base.example"]))
        try store.save(base)
        var candidate = base
        _ = try candidate.create(serviceTestDraft(name: "Candidate", domains: ["candidate.example"]))
        try store.savePendingCandidate(candidate)

        XCTAssertEqual(try store.load(), candidate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pending.path))
    }

    func testPendingCandidateUsesDurablePrimaryWhenMemoryHasAdvanced() throws {
        let paths = try temporaryPaths()
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false,
            authenticationKeys: FakeStateAuthenticationKeys()
        )
        var persisted = ProtectedState()
        let block = try persisted.create(serviceTestDraft())
        try persisted.activate(
            id: block.id,
            expectedRevision: block.revision,
            at: serviceTestReading(0)
        )
        try store.save(persisted)

        var candidate = persisted
        _ = candidate.advance(to: serviceTestReading(10))
        try candidate.request(.fullUnlock, id: block.id, at: serviceTestReading(10))
        XCTAssertNotEqual(candidate, persisted)

        try store.savePendingCandidate(candidate)

        XCTAssertEqual(try store.load(), candidate)
    }

    func testStateSymbolicLinkIsRejected() throws {
        let paths = try temporaryPaths()
        let target = paths.root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: paths.state, withDestinationURL: target)
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false,
            authenticationKeys: FakeStateAuthenticationKeys()
        )

        XCTAssertThrowsError(try store.load()) { error in
            guard case ServiceRuntimeError.unreadableState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func temporaryPaths() throws -> (
        root: URL,
        state: URL,
        pending: URL,
        backups: URL
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (
            root,
            root.appendingPathComponent("state-v2.json"),
            root.appendingPathComponent("pending-state-v2.json"),
            root.appendingPathComponent("backups")
        )
    }
}

private final class FakeStateAuthenticationKeys: StateAuthenticationKeyStoring {
    var key: Data?
    var committed = false
    var anchor: StateCommitAnchor?

    func existingKey() throws -> Data? { key }

    func keyForWrite() throws -> Data {
        if let key { return key }
        let generated = Data(repeating: 7, count: 32)
        key = generated
        return generated
    }

    func hasCommittedState() throws -> Bool { committed || anchor != nil }

    func markCommittedState() throws { committed = true }

    func readAnchor() throws -> StateCommitAnchor? { anchor }

    func saveAnchor(_ anchor: StateCommitAnchor) throws { self.anchor = anchor }
}
