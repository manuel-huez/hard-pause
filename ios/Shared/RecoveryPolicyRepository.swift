import Foundation

enum RecoveryPolicyRepositoryError: LocalizedError {
    case appGroupUnavailable
    case corruptedPolicy
    case coordinationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The recovery snapshot storage is unavailable."
        case .corruptedPolicy:
            "The saved recovery snapshot cannot be read."
        case .coordinationFailed(let error):
            "The recovery snapshot could not be coordinated: \(error.localizedDescription)"
        }
    }
}

struct RecoveryBlock: Codable, Equatable {
    let id: UUID
    let name: String
    let policy: LockPolicy
    let storeSlot: Int?

    init(id: UUID, name: String, policy: LockPolicy, storeSlot: Int? = nil) {
        self.id = id
        self.name = name
        self.policy = policy
        self.storeSlot = storeSlot
    }
}

struct RecoverySnapshot: Codable, Equatable {
    var schemaVersion = 2
    let blocks: [RecoveryBlock]

    init(blocks: [RecoveryBlock]) {
        self.blocks = blocks
    }

    init(collection: LockCollection) {
        blocks = collection.activeBlocks.map {
            RecoveryBlock(
                id: $0.id,
                name: $0.name,
                policy: $0.state.policy,
                storeSlot: $0.state.storeSlot
            )
        }
    }

    func restore(at date: Date, elapsedTime: ElapsedTimeReading) throws -> LockCollection {
        try validateStructure()
        var restoredBlocks: [LockBlock] = []
        var usedSlots: Set<Int> = []
        for recoveryBlock in blocks {
            var state = LockState()
            try LockStateMachine.activate(
                &state,
                policy: recoveryBlock.policy,
                at: date,
                elapsedTime: elapsedTime
            )
            let preferredSlot = recoveryBlock.storeSlot
            let storeSlot =
                preferredSlot.flatMap { slot in
                    (0..<LockCollection.maximumActiveBlocks).contains(slot)
                        && !usedSlots.contains(slot) ? slot : nil
                } ?? (0..<LockCollection.maximumActiveBlocks).first(where: { !usedSlots.contains($0) })!
            state.storeSlot = storeSlot
            usedSlots.insert(storeSlot)
            state.recoveryNotice = "Hard Pause restored blocking because the main pause collection could not be read."
            restoredBlocks.append(
                LockBlock(
                    id: recoveryBlock.id,
                    name: recoveryBlock.name,
                    draftPolicy: recoveryBlock.policy,
                    state: state
                )
            )
        }
        return LockCollection(blocks: restoredBlocks)
    }

    func validateStructure() throws {
        guard schemaVersion == 2,
            blocks.count <= LockCollection.maximumActiveBlocks,
            Set(blocks.map(\.id)).count == blocks.count
        else { throw RecoveryPolicyRepositoryError.corruptedPolicy }
    }
}

protocol RecoveryPolicyStoring {
    func load() throws -> RecoverySnapshot?
    func save(_ snapshot: RecoverySnapshot) throws
    func clear() throws
}

struct RecoveryPolicyRepository: RecoveryPolicyStoring {
    private let policyURL: URL?

    init(
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: HardPauseConstants.appGroupIdentifier
        )
    ) {
        // Keep the v1 path so an existing policy can be migrated without a gap.
        policyURL = containerURL?.appendingPathComponent(
            "recovery-policy-v1.json",
            isDirectory: false
        )
    }

    func load() throws -> RecoverySnapshot? {
        guard let policyURL else { throw RecoveryPolicyRepositoryError.appGroupUnavailable }
        var result: Result<RecoverySnapshot?, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: policyURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { url in
            result = Result {
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let data = try Data(contentsOf: url)
                if let snapshot = try? JSONDecoder().decode(RecoverySnapshot.self, from: data) {
                    try snapshot.validateStructure()
                    return snapshot
                }
                if let legacyPolicy = try? JSONDecoder().decode(LockPolicy.self, from: data) {
                    return RecoverySnapshot(
                        blocks: [
                            RecoveryBlock(
                                id: HardPauseConstants.legacyBlockID,
                                name: "My pause",
                                policy: legacyPolicy,
                                storeSlot: 0
                            )
                        ]
                    )
                }
                throw RecoveryPolicyRepositoryError.corruptedPolicy
            }
        }
        if let coordinationError {
            throw RecoveryPolicyRepositoryError.coordinationFailed(coordinationError)
        }
        guard let result else { throw RecoveryPolicyRepositoryError.corruptedPolicy }
        return try result.get()
    }

    func save(_ snapshot: RecoverySnapshot) throws {
        try snapshot.validateStructure()
        guard let policyURL else { throw RecoveryPolicyRepositoryError.appGroupUnavailable }
        var result: Result<Void, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: policyURL,
            options: .forReplacing,
            error: &coordinationError
        ) { url in
            result = Result {
                try DurableFile.write(JSONEncoder().encode(snapshot), to: url)
            }
        }
        if let coordinationError {
            throw RecoveryPolicyRepositoryError.coordinationFailed(coordinationError)
        }
        guard let result else { throw RecoveryPolicyRepositoryError.corruptedPolicy }
        try result.get()
    }

    func clear() throws {
        guard let policyURL else { throw RecoveryPolicyRepositoryError.appGroupUnavailable }
        guard FileManager.default.fileExists(atPath: policyURL.path) else { return }
        var result: Result<Void, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: policyURL,
            options: .forDeleting,
            error: &coordinationError
        ) { url in
            result = Result { try DurableFile.remove(url) }
        }
        if let coordinationError {
            throw RecoveryPolicyRepositoryError.coordinationFailed(coordinationError)
        }
        guard let result else { throw RecoveryPolicyRepositoryError.corruptedPolicy }
        try result.get()
    }
}
