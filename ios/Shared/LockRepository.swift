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
        case resumingIntent
    }

    private let stateURL: URL?
    private let beforeWrite: (() throws -> Void)?
    private let beforeIntentWrite: (() throws -> Void)?
    private let afterIntentWrite: (() throws -> Void)?
    private let beforeIntentClear: (() throws -> Void)?

    init(
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: HardPauseConstants.appGroupIdentifier
        ),
        beforeWrite: (() throws -> Void)? = nil,
        beforeIntentWrite: (() throws -> Void)? = nil,
        afterIntentWrite: (() throws -> Void)? = nil,
        beforeIntentClear: (() throws -> Void)? = nil
    ) {
        // Keep the original path so migration and all processes coordinate one file.
        stateURL = containerURL?.appendingPathComponent("lock-state-v1.json", isDirectory: false)
        self.beforeWrite = beforeWrite
        self.beforeIntentWrite = beforeIntentWrite
        self.afterIntentWrite = afterIntentWrite
        self.beforeIntentClear = beforeIntentClear
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
        tightenBeforeCommit: (LockCollection, inout LockCollection) -> Void = { _, _ in },
        tightenOnRetirementFailure: (LockCollection) -> Void = { _ in },
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
                var storedCollection: LockCollection?
                var source: StateSource
                let intentURL = url.deletingLastPathComponent().appendingPathComponent("activation-intent-v1.json")
                let intent = try readIntent(from: intentURL)
                var resumedCandidate: LockCollection?
                if !FileManager.default.fileExists(atPath: url.path) {
                    storedCollection = try intent?.base ?? recover(.missingState)
                    source = storedCollection == nil ? .missing : .recovered
                } else {
                    do {
                        let read = try readUncoordinated(from: url)
                        storedCollection = read.collection
                        source = read.wasMigrated ? .migrated : .stored
                    } catch {
                        guard let recovered = try intent?.base ?? recover(.corruptedState) else { throw error }
                        storedCollection = recovered
                        source = .recovered
                    }
                }

                if let intent {
                    if let storedCollection, source == .stored || source == .migrated {
                        if storedCollection.revision == intent.baseRevision {
                            // Resume the saved intent, then let the runtime reconcile time.
                            source = .resumingIntent
                            resumedCandidate = intent.candidate
                        } else if storedCollection.revision < intent.candidate.revision {
                            throw LockRepositoryError.corruptedState
                        } else {
                            // Retire committed intent before another command can relax protection.
                            do {
                                try clearIntent(at: intentURL)
                            } catch {
                                tightenOnRetirementFailure(storedCollection)
                                throw error
                            }
                        }
                    }
                    if source == .recovered {
                        source = .resumingIntent
                        resumedCandidate = intent.candidate
                    }
                }

                let current = storedCollection ?? LockCollection()
                // Pending activations may already be enforced. Every precommit
                // effect must retain them, even when primary storage still has drafts.
                let enforcementBase = resumedCandidate?.activationSafetyUnion(with: current) ?? current
                var collection = resumedCandidate ?? current
                try transform(&collection)
                try prepare(enforcementBase, &collection, source)
                let needsPrimaryWrite =
                    collection != current
                    || source == .missing
                    || source == .recovered
                    || source == .migrated
                    || source == .resumingIntent
                if needsPrimaryWrite {
                    collection.revision = current.revision + 1
                    try collection.validateStoredStructure()
                    let oldActiveIDs = Set(current.activeBlocks.map(\.id))
                    let addsActivation = collection.activeBlocks.contains { !oldActiveIDs.contains($0.id) }
                    if addsActivation {
                        let plan = PauseCoreTransactionPlan(
                            requiresSchedulePrerequisite: false,
                            hasTightening: true,
                            intentFailurePolicy: .stop,
                            savesCandidate: true,
                            hasRelaxation: false
                        )
                        for stage in try plan.orderedStages {
                            switch stage {
                            case .saveIntent:
                                try writeIntent(
                                    ActivationIntent(base: current, candidate: collection),
                                    to: intentURL
                                )
                            case .applyTightening:
                                tightenBeforeCommit(enforcementBase, &collection)
                            case .saveCandidate:
                                try writeUncoordinated(collection, to: url)
                            case .clearIntent:
                                do {
                                    try clearIntent(at: intentURL)
                                } catch {
                                    tightenOnRetirementFailure(collection)
                                    throw error
                                }
                            case .prepareSchedulePrerequisite, .applyRelaxation:
                                preconditionFailure(
                                    "Activation schedules are prepared before commit; relaxation follows commit.")
                            }
                        }
                    } else {
                        try writeUncoordinated(collection, to: url)
                    }
                }

                // A stale intent must never survive a later unlock or mutation.
                if FileManager.default.fileExists(atPath: intentURL.path) {
                    do {
                        try clearIntent(at: intentURL)
                    } catch {
                        tightenOnRetirementFailure(collection)
                        throw error
                    }
                }
                if collection.enforcementNeedsRefresh == true || intent != nil {
                    do {
                        // Finish a retirement whose remove succeeded but flush failed
                        // before any retry can relax restrictions. Idle reads need no flush.
                        try DurableFile.synchronizeDirectory(url.deletingLastPathComponent())
                    } catch {
                        tightenOnRetirementFailure(collection)
                        throw error
                    }
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
            try collection.validateStoredStructure()
            return (collection, false)
        }
        if var legacyState = try? JSONDecoder().decode(LockState.self, from: data) {
            let revision = legacyState.revision
            legacyState.revision = 0
            legacyState.storeSlot = legacyState.isActive ? 0 : nil
            let collection = LockCollection(
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
            )
            try collection.validateStoredStructure()
            return (collection, true)
        }
        throw LockRepositoryError.corruptedState
    }

    private func writeUncoordinated(_ collection: LockCollection, to url: URL) throws {
        try collection.validateStoredStructure()
        try beforeWrite?()
        let data = try JSONEncoder().encode(collection)
        try DurableFile.write(data, to: url)
    }

    private struct ActivationIntent: Codable {
        var schemaVersion = 1
        var operationID = UUID()
        let base: LockCollection
        let candidate: LockCollection

        var baseRevision: Int { base.revision }
    }

    private func readIntent(from url: URL) throws -> ActivationIntent? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let intent = try JSONDecoder().decode(ActivationIntent.self, from: Data(contentsOf: url))
        guard intent.schemaVersion == 1, intent.baseRevision >= 0,
            intent.baseRevision < Int.max - 1,
            intent.candidate.revision == intent.baseRevision + 1
        else { throw LockRepositoryError.corruptedState }
        try intent.candidate.validateStoredStructure()
        try intent.base.validateStoredStructure()
        try intent.candidate.activationSafetyUnion(with: intent.base).validateStoredStructure()
        return intent
    }

    private func writeIntent(_ intent: ActivationIntent, to url: URL) throws {
        try beforeIntentWrite?()
        try DurableFile.write(JSONEncoder().encode(intent), to: url)
        try afterIntentWrite?()
    }

    private func clearIntent(at url: URL) throws {
        try beforeIntentClear?()
        try DurableFile.remove(url)
    }
}

extension LockCollection {
    func activationSafetyUnion(with base: LockCollection) -> LockCollection {
        var projection = base
        let existingIDs = Set(base.activeBlocks.map(\.id))
        for var block in activeBlocks where !existingIDs.contains(block.id) {
            // An uncommitted break projection may not open a pending activation.
            if block.state.phase == .breakActive { block.state.phase = .locked }
            if let index = projection.blocks.firstIndex(where: { $0.id == block.id }) {
                projection.blocks[index] = block
            } else {
                projection.blocks.append(block)
            }
        }
        return projection
    }

    func validateStoredStructure() throws {
        let activeSlots = activeBlocks.compactMap(\.state.storeSlot)
        guard schemaVersion == 2, revision >= 0, revision < Int.max,
            Set(blocks.map(\.id)).count == blocks.count,
            activeBlocks.count <= Self.maximumActiveBlocks,
            activeSlots.count == activeBlocks.count,
            Set(activeSlots).count == activeSlots.count,
            activeSlots.allSatisfy({ (0..<Self.maximumActiveBlocks).contains($0) }),
            blocks.filter({ !$0.state.isActive }).allSatisfy({ $0.state.storeSlot == nil })
        else { throw LockRepositoryError.corruptedState }
        for block in blocks {
            try block.draftPolicy.validateDurations()
            if block.state.isActive { try block.state.policy.validateDurations() }
        }
    }
}
