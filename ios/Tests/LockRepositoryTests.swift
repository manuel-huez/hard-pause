import Foundation
import XCTest

@testable import HardPause

final class LockRepositoryTests: XCTestCase {
    func testCollectionPersistsWithRevisionAndStableBlockID() throws {
        try withRepository { repository, _ in
            let saved = try repository.transaction(transform: { collection in
                collection.blocks[0].name = "Focus"
                collection.blocks[0].draftPolicy.manualDomains = ["example.com"]
            })

            XCTAssertEqual(saved.revision, 1)
            XCTAssertEqual(try repository.load(), saved)
            XCTAssertEqual(try repository.load().blocks[0].id, saved.blocks[0].id)
        }
    }

    func testFirstTransactionPersistsStarterBlock() throws {
        try withRepository { repository, _ in
            let saved = try repository.transaction(transform: { _ in })

            XCTAssertEqual(saved.revision, 1)
            XCTAssertEqual(try repository.load().blocks[0].id, saved.blocks[0].id)
        }
    }

    func testCorruptCollectionDoesNotBecomeInactiveCollection() throws {
        try withRepository { repository, directory in
            try Data("not-json".utf8).write(
                to: directory.appendingPathComponent("lock-state-v1.json")
            )

            XCTAssertThrowsError(try repository.load()) { error in
                guard case LockRepositoryError.corruptedState = error else {
                    return XCTFail("Expected corruptedState, got \(error)")
                }
            }
        }
    }

    func testUnchangedStoredUpdateDoesNotIncrementRevision() throws {
        try withRepository { repository, _ in
            let first = try repository.transaction(transform: { _ in })
            let second = try repository.transaction(transform: { _ in })

            XCTAssertEqual(first.revision, 1)
            XCTAssertEqual(second.revision, 1)
        }
    }

    func testV1SingleStateMigratesIntoNamedCollection() throws {
        try withRepository { repository, directory in
            var legacy = LockState()
            legacy.revision = 7
            legacy.phase = .locked
            legacy.policy.manualDomains = ["example.com"]
            legacy.activatedAt = Date(timeIntervalSince1970: 1_800_000_000)
            legacy.lastEvaluationDate = legacy.activatedAt
            legacy.lastSystemUptime = 100
            legacy.lastBootIdentifier = "boot-a"
            try JSONEncoder().encode(legacy).write(
                to: directory.appendingPathComponent("lock-state-v1.json"),
                options: .atomic
            )

            let migrated = try repository.load()

            XCTAssertEqual(migrated.revision, 7)
            XCTAssertEqual(migrated.blocks.count, 1)
            XCTAssertEqual(migrated.blocks[0].name, "My pause")
            XCTAssertEqual(migrated.blocks[0].draftPolicy, legacy.policy)
            XCTAssertEqual(migrated.blocks[0].state.phase, .locked)
            XCTAssertEqual(migrated.blocks[0].id, HardPauseConstants.legacyBlockID)
            XCTAssertEqual(try repository.load().blocks[0].id, HardPauseConstants.legacyBlockID)

            let written = try repository.transaction(transform: { _ in })
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: directory.appendingPathComponent("lock-state-v1.json"))
                ) as? [String: Any]
            )
            XCTAssertEqual(written.revision, 8)
            XCTAssertNotNil(object["blocks"])
            XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        }
    }

    func testV1PolicyWithoutFullUnlockOrFixedDurationStillDecodes() throws {
        var policy = LockPolicy()
        policy.waitDuration = 14_400
        let encoded = try JSONEncoder().encode(policy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "fullUnlockDelay")
        object.removeValue(forKey: "fixedDuration")

        var decoded = try JSONDecoder().decode(
            LockPolicy.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.fullUnlockDelay)
        XCTAssertNil(decoded.fixedDuration)

        decoded.normalize()
        XCTAssertEqual(decoded.fullUnlockDelay, 14_400)
    }

    func testRecoveryRepositoryMigratesSingleV1Policy() throws {
        try withRepository { _, directory in
            var policy = LockPolicy()
            policy.manualDomains = ["example.com"]
            try JSONEncoder().encode(policy).write(
                to: directory.appendingPathComponent("recovery-policy-v1.json")
            )

            let snapshot = try XCTUnwrap(
                RecoveryPolicyRepository(containerURL: directory).load()
            )

            XCTAssertEqual(snapshot.blocks.count, 1)
            XCTAssertEqual(snapshot.blocks[0].id, HardPauseConstants.legacyBlockID)
            XCTAssertEqual(snapshot.blocks[0].name, "My pause")
            XCTAssertEqual(snapshot.blocks[0].policy, policy)
        }
    }

    func testRecoveryKeepsValidSlotsAndRepairsDuplicateOrInvalidSlots() throws {
        let ids = (0..<4).map { _ in UUID() }
        let snapshot = RecoverySnapshot(
            blocks: [
                RecoveryBlock(id: ids[0], name: "One", policy: LockPolicy(), storeSlot: 2),
                RecoveryBlock(id: ids[1], name: "Two", policy: LockPolicy(), storeSlot: 2),
                RecoveryBlock(id: ids[2], name: "Three", policy: LockPolicy(), storeSlot: 99),
                RecoveryBlock(id: ids[3], name: "Four", policy: LockPolicy()),
            ]
        )

        let restored = try snapshot.restore(
            at: Date(timeIntervalSince1970: 1_800_000_000),
            elapsedTime: ElapsedTimeReading(durationSinceBoot: 100, bootIdentifier: "boot-a")
        )

        let slots = restored.activeBlocks.compactMap(\.state.storeSlot)
        XCTAssertEqual(restored.block(id: ids[0])?.state.storeSlot, 2)
        XCTAssertEqual(Set(slots).count, 4)
        XCTAssertTrue(slots.allSatisfy { (0..<LockCollection.maximumActiveBlocks).contains($0) })
    }

    private func withRepository(
        _ body: (LockRepository, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(LockRepository(containerURL: directory), directory)
    }
}
