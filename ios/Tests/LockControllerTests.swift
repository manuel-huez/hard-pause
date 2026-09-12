import FamilyControls
import Foundation
import XCTest

@testable import HardPause

@MainActor
final class LockControllerTests: XCTestCase {
    func testActivationRechecksCurrentAuthorization() throws {
        try withController { controller, repository, setAuthorization in
            XCTAssertTrue(controller.canActivate)
            setAuthorization(.denied)

            controller.activate()

            XCTAssertFalse(try repository.load().hasActiveBlocks)
            XCTAssertFalse(controller.collection.hasActiveBlocks)
            XCTAssertNotNil(controller.errorMessage)
        }
    }

    func testCreateSelectRenameAndDeleteInactiveBlock() throws {
        try withController { controller, repository, _ in
            let originalID = try XCTUnwrap(controller.selectedBlockID)
            controller.createBlock()
            let createdID = try XCTUnwrap(controller.selectedBlockID)
            XCTAssertNotEqual(createdID, originalID)

            controller.draftName = "Deep work"
            XCTAssertEqual(try repository.load().block(id: createdID)?.name, "Deep work")

            controller.deleteSelectedBlock()
            XCTAssertNil(try repository.load().block(id: createdID))
            XCTAssertEqual(controller.selectedBlockID, originalID)
        }
    }

    func testDraftChangesDoNotModifyActiveSnapshot() throws {
        try withController { controller, repository, _ in
            controller.draftName = "Study"
            controller.draftPolicy.waitDuration = 14_400
            controller.activate()
            let id = try XCTUnwrap(controller.selectedBlockID)
            let active = try XCTUnwrap(repository.load().block(id: id))

            controller.draftName = "Changed"
            controller.draftPolicy.waitDuration = 86_400

            let stored = try XCTUnwrap(repository.load().block(id: id))
            XCTAssertEqual(stored.name, "Study")
            XCTAssertEqual(stored.draftPolicy.waitDuration, 14_400)
            XCTAssertEqual(stored.state.policy, active.state.policy)
        }
    }

    func testPersistentRefreshErrorAlertsOnlyOnceUntilRecovery() throws {
        try withController(corruptState: true) { controller, _, _ in
            XCTAssertNotNil(controller.persistentErrorMessage)
            XCTAssertNotNil(controller.errorMessage)

            controller.errorMessage = nil
            controller.refresh()

            XCTAssertNotNil(controller.persistentErrorMessage)
            XCTAssertNil(controller.errorMessage)
        }
    }

    func testInitializationRecoversAggregateSnapshot() throws {
        var firstPolicy = LockPolicy()
        firstPolicy.manualDomains = ["one.example.com"]
        var secondPolicy = LockPolicy()
        secondPolicy.manualDomains = ["two.example.com"]
        let firstID = UUID()
        let secondID = UUID()
        let snapshot = RecoverySnapshot(
            blocks: [
                RecoveryBlock(id: firstID, name: "One", policy: firstPolicy),
                RecoveryBlock(id: secondID, name: "Two", policy: secondPolicy),
            ]
        )

        try withController(recoverySnapshot: snapshot) { controller, repository, _ in
            XCTAssertEqual(Set(controller.collection.activeBlocks.map(\.id)), Set([firstID, secondID]))
            XCTAssertEqual(try repository.load(), controller.collection)
            XCTAssertNil(controller.persistentErrorMessage)
        }
    }

    private func withController(
        corruptState: Bool = false,
        recoverySnapshot: RecoverySnapshot? = nil,
        _ body: (
            LockController,
            LockRepository,
            (AuthorizationStatus) -> Void
        ) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if corruptState {
            try Data("not-json".utf8).write(
                to: directory.appendingPathComponent("lock-state-v1.json")
            )
        }

        let repository = LockRepository(containerURL: directory)
        let recoveryPolicies = RecoveryPolicyRepository(containerURL: directory)
        if let recoverySnapshot {
            try recoveryPolicies.save(recoverySnapshot)
        }
        let runtime = LocalLockRuntime(
            repository: repository,
            restrictions: ControllerTestRestrictions(),
            scheduler: ControllerTestScheduler(),
            recoveryPolicies: recoveryPolicies
        )
        var authorizationStatus = AuthorizationStatus.approved
        let controller = LockController(
            runtime: runtime,
            authorizationStatusProvider: { authorizationStatus }
        )

        try body(controller, repository) { authorizationStatus = $0 }
    }
}

private struct ControllerTestRestrictions: RestrictionApplying {
    func apply(_ collection: LockCollection) {}
}

private final class ControllerTestScheduler: TransitionScheduling {
    private var intervals: [UUID: DateInterval] = [:]

    func ensureSchedules(for collection: LockCollection) throws {
        intervals = Dictionary(
            uniqueKeysWithValues: collection.blocks.compactMap { block in
                TransitionScheduleProjection.registeredInterval(for: block.state).map {
                    (block.id, $0)
                }
            })
    }

    func hasSchedule(for block: LockBlock) -> Bool {
        let expected = TransitionScheduleProjection.registeredInterval(for: block.state)
        return expected != nil && intervals[block.id] == expected
    }
}
