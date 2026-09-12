import Foundation

enum LockRepositoryError: LocalizedError {
    case appGroupUnavailable
    case missingState
    case corruptedState
    case coordinationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared app-group container is unavailable. Check signing and App Group setup."
        case .missingState:
            "The saved pause collection is missing."
        case .corruptedState:
            "The saved pause collection cannot be read. Existing restrictions were left unchanged."
        case .coordinationFailed(let error):
            "The pause collection could not be coordinated: \(error.localizedDescription)"
        }
    }
}

struct LockRepository {
    enum StateSource: Equatable {
        case stored
        case missing
        case recovered
        case migrated
    }

    private let stateURL: URL?
    private let beforeWrite: (() throws -> Void)?

    init(
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: HardPauseConstants.appGroupIdentifier
        ),
        beforeWrite: (() throws -> Void)? = nil
    ) {
        // Keep the original path so migration and all processes coordinate one file.
        stateURL = containerURL?.appendingPathComponent("lock-state-v1.json", isDirectory: false)
        self.beforeWrite = beforeWrite
    }

    func load() throws -> LockCollection {
        guard let stateURL else { throw LockRepositoryError.appGroupUnavailable }
        var result: Result<LockCollection, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: stateURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { url in
            result = Result { try readUncoordinated(from: url).collection }
        }
        if let coordinationError {
            throw LockRepositoryError.coordinationFailed(coordinationError)
        }
        guard let result else { throw LockRepositoryError.corruptedState }
        return try result.get()
    }

    func transaction(
        recover: (LockRepositoryError) throws -> LockCollection? = { _ in nil },
        transform: (inout LockCollection) throws -> Void,
        prepare: (LockCollection, inout LockCollection, StateSource) throws -> Void = { _, _, _ in },
        afterCommit: (LockCollection, inout LockCollection, StateSource) -> Void = { _, _, _ in }
    ) throws -> LockCollection {
        guard let stateURL else { throw LockRepositoryError.appGroupUnavailable }
        var result: Result<LockCollection, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: stateURL,
            options: .forReplacing,
            error: &coordinationError
        ) { url in
            result = Result {
                let storedCollection: LockCollection?
                let source: StateSource
                if !FileManager.default.fileExists(atPath: url.path) {
                    storedCollection = try recover(.missingState)
                    source = storedCollection == nil ? .missing : .recovered
                } else {
                    do {
                        let read = try readUncoordinated(from: url)
                        storedCollection = read.collection
                        source = read.wasMigrated ? .migrated : .stored
                    } catch {
                        guard let recovered = try recover(.corruptedState) else { throw error }
                        storedCollection = recovered
                        source = .recovered
                    }
                }

                let current = storedCollection ?? LockCollection()
                var collection = current
                try transform(&collection)
                try prepare(current, &collection, source)
                let needsPrimaryWrite =
                    collection != current
                    || source == .missing
                    || source == .recovered
                    || source == .migrated
                if needsPrimaryWrite {
                    collection.revision = current.revision + 1
                    try writeUncoordinated(collection, to: url)
                }

                var finalCollection = collection
                afterCommit(current, &finalCollection, source)
                if finalCollection != collection {
                    if !needsPrimaryWrite {
                        finalCollection.revision = current.revision + 1
                    }
                    try writeUncoordinated(finalCollection, to: url)
                }
                return finalCollection
            }
        }
        if let coordinationError {
            throw LockRepositoryError.coordinationFailed(coordinationError)
        }
        guard let result else { throw LockRepositoryError.corruptedState }
        return try result.get()
    }

    private func readUncoordinated(from url: URL) throws -> (collection: LockCollection, wasMigrated: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (LockCollection(), false)
        }
        let data = try Data(contentsOf: url)
        if let collection = try? JSONDecoder().decode(LockCollection.self, from: data) {
            return (collection, false)
        }
        if var legacyState = try? JSONDecoder().decode(LockState.self, from: data) {
            let revision = legacyState.revision
            legacyState.revision = 0
            legacyState.storeSlot = legacyState.isActive ? 0 : nil
            return (
                LockCollection(
                    revision: revision,
                    blocks: [
                        LockBlock(
                            id: HardPauseConstants.legacyBlockID,
                            name: "My pause",
                            draftPolicy: legacyState.policy,
                            state: legacyState
                        )
                    ],
                    enforcementNeedsRefresh: legacyState.enforcementNeedsRefresh
                ),
                true
            )
        }
        throw LockRepositoryError.corruptedState
    }

    private func writeUncoordinated(_ collection: LockCollection, to url: URL) throws {
        try beforeWrite?()
        let data = try JSONEncoder().encode(collection)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
