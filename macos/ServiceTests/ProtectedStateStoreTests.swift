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
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false,
            maximumBackups: 2
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
            requireRootOwnership: false
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
            requireRootOwnership: false
        )

        XCTAssertThrowsError(try store.load()) { error in
            guard case ServiceRuntimeError.unreadableState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPendingCandidateWithoutPrimaryIsPromotedAndCleared() throws {
        let paths = try temporaryPaths()
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false
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
            requireRootOwnership: false
        )
        var state = ProtectedState()
        _ = try state.create(serviceTestDraft())
        try store.save(state)
        try store.savePendingCandidate(state)

        XCTAssertEqual(try store.load(), state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pending.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.backups.path).isEmpty)
    }

    func testStalePendingCandidateCannotOverwriteNewerPrimary() throws {
        let paths = try temporaryPaths()
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false
        )
        var oldState = ProtectedState()
        _ = try oldState.create(serviceTestDraft(name: "Old"))
        try store.save(oldState)
        var pendingState = oldState
        _ = try pendingState.create(serviceTestDraft(name: "Pending", domains: ["pending.example"]))
        try store.savePendingCandidate(pendingState)
        var newerState = oldState
        _ = try newerState.create(serviceTestDraft(name: "New", domains: ["new.example"]))
        try store.save(newerState)

        XCTAssertThrowsError(try store.load()) { error in
            guard case ServiceRuntimeError.unreadableState(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("pending transition"))
            XCTAssertTrue(message.contains("primary protected state"))
        }
        XCTAssertEqual(
            try JSONDecoder().decode(ProtectedState.self, from: Data(contentsOf: paths.state)),
            newerState
        )
    }

    func testPendingCandidateReplaysAfterCrashBeforePrimarySave() throws {
        let paths = try temporaryPaths()
        let store = JSONProtectedStateStore(
            stateURL: paths.state,
            pendingStateURL: paths.pending,
            backupDirectory: paths.backups,
            requireRootOwnership: false
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
            requireRootOwnership: false
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
            requireRootOwnership: false
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
