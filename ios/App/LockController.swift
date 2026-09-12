import FamilyControls
import Foundation
import SwiftUI

@MainActor
final class LockController: ObservableObject {
    @Published private(set) var collection = LockCollection()
    @Published var selectedBlockID: UUID? {
        didSet { loadSelectedDraft() }
    }
    @Published var draftName = "" {
        didSet { saveDraftIfAllowed() }
    }
    @Published var draftPolicy = LockPolicy() {
        didSet { saveDraftIfAllowed() }
    }
    @Published private(set) var authorizationStatus: AuthorizationStatus
    @Published private(set) var isRequestingAuthorization = false
    @Published private(set) var isReady = false
    @Published private(set) var persistentErrorMessage: String?
    @Published var errorMessage: String?

    private let runtime: LocalLockRuntime
    private let authorizationStatusProvider: () -> AuthorizationStatus
    private var isLoading = true
    private var lastRefreshErrorMessage: String?

    convenience init() {
        let repository = LockRepository()
        self.init(
            runtime: LocalLockRuntime(repository: repository),
            authorizationStatusProvider: { AuthorizationCenter.shared.authorizationStatus }
        )
    }

    init(
        runtime: LocalLockRuntime,
        authorizationStatusProvider: @escaping () -> AuthorizationStatus
    ) {
        self.runtime = runtime
        self.authorizationStatusProvider = authorizationStatusProvider
        authorizationStatus = authorizationStatusProvider()
        do {
            collection = try runtime.reconcile()
            selectedBlockID = collection.activeBlocks.first?.id ?? collection.blocks.first?.id
            loadSelectedDraft()
        } catch {
            recordPersistentError(error)
        }
        isLoading = false
        isReady = true
    }

    var blocks: [LockBlock] { collection.blocks }
    var selectedBlock: LockBlock? { selectedBlockID.flatMap(collection.block) }
    var state: LockState { selectedBlock?.state ?? LockState() }
    var activeBlockCount: Int { collection.activeBlocks.count }

    var canActivate: Bool {
        authorizationStatus == .approved
            && selectedBlock != nil
            && !state.isActive
            && !LockBlock.normalizedName(draftName).isEmpty
            && activeBlockCount < LockCollection.maximumActiveBlocks
            && draftPolicy.hasBlockingTarget
            && (try? draftPolicy.validateManagedSettingsLimits()) != nil
    }

    func start() {
        refresh()
    }

    func refresh() {
        authorizationStatus = authorizationStatusProvider()
        do {
            collection = try runtime.reconcile()
            repairSelection()
            loadSelectedDraft()
            persistentErrorMessage = nil
            lastRefreshErrorMessage = nil
        } catch {
            recordPersistentError(error)
        }
    }

    func requestAuthorization() async {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        defer {
            isRequestingAuthorization = false
            authorizationStatus = authorizationStatusProvider()
        }
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createBlock() {
        do {
            var newBlock = LockBlock(name: nextBlockName())
            newBlock.draftPolicy.blocksAdultWebsites = true
            collection = try runtime.mutate { collection in
                collection.blocks.append(newBlock)
            }
            selectedBlockID = newBlock.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelectedBlock() {
        guard let selectedBlockID else { return }
        do {
            collection = try runtime.mutate { collection in
                let index = try collection.index(of: selectedBlockID)
                guard !collection.blocks[index].state.isActive else {
                    throw LockCollectionError.activeBlockCannotBeEdited
                }
                collection.blocks.remove(at: index)
            }
            self.selectedBlockID = collection.activeBlocks.first?.id ?? collection.blocks.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectBlock(_ id: UUID) {
        guard collection.block(id: id) != nil else { return }
        selectedBlockID = id
    }

    func activate() {
        authorizationStatus = authorizationStatusProvider()
        guard authorizationStatus == .approved else {
            errorMessage = "Screen Time access is no longer approved. Allow access before starting this pause."
            return
        }
        guard let selectedBlockID else {
            errorMessage = LockCollectionError.blockNotFound.localizedDescription
            return
        }
        do {
            let date = Date()
            let elapsedTime = ElapsedTimeClock.current
            collection = try runtime.mutate(wallClockNow: date, elapsedTime: elapsedTime) { candidate in
                try Self.updateInactiveBlock(
                    in: &candidate,
                    blockID: selectedBlockID,
                    name: draftName,
                    policy: draftPolicy
                )
                try LockCollectionStateMachine.activate(
                    &candidate,
                    blockID: selectedBlockID,
                    at: date,
                    elapsedTime: elapsedTime
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestBreak() {
        mutateSelectedState { collection, blockID, date, elapsedTime in
            try LockCollectionStateMachine.requestBreak(
                &collection,
                blockID: blockID,
                at: date,
                elapsedTime: elapsedTime
            )
        }
    }

    func requestFullUnlock() {
        mutateSelectedState { collection, blockID, date, elapsedTime in
            try LockCollectionStateMachine.requestEnd(
                &collection,
                blockID: blockID,
                at: date,
                elapsedTime: elapsedTime
            )
        }
    }

    func addManualDomain(_ input: String) -> Bool {
        guard let domain = LockPolicy.normalizedDomain(input) else {
            errorMessage = "Enter a domain such as example.com."
            return false
        }
        guard !draftPolicy.manualDomains.contains(domain) else { return true }
        guard draftPolicy.manualDomains.count < LockPolicy.maximumManagedWebDomains else {
            errorMessage = "You can add no more than 50 website domains."
            return false
        }
        draftPolicy.manualDomains.append(domain)
        draftPolicy.manualDomains.sort()
        return true
    }

    func removeManualDomain(_ domain: String) {
        draftPolicy.manualDomains.removeAll { $0 == domain }
    }

    private func mutateSelectedState(
        _ mutation: (
            inout LockCollection,
            UUID,
            Date,
            ElapsedTimeReading
        ) throws -> Void
    ) {
        guard let selectedBlockID else {
            errorMessage = LockCollectionError.blockNotFound.localizedDescription
            return
        }
        do {
            let date = Date()
            let elapsedTime = ElapsedTimeClock.current
            collection = try runtime.mutate(wallClockNow: date, elapsedTime: elapsedTime) { candidate in
                try mutation(&candidate, selectedBlockID, date, elapsedTime)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveDraftIfAllowed() {
        guard !isLoading, let selectedBlockID else { return }
        guard !state.isActive else { return }
        let name = LockBlock.normalizedName(draftName)
        guard !name.isEmpty else { return }
        do {
            collection = try runtime.mutate { current in
                try Self.updateInactiveBlock(
                    in: &current,
                    blockID: selectedBlockID,
                    name: name,
                    policy: draftPolicy
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func updateInactiveBlock(
        in collection: inout LockCollection,
        blockID: UUID,
        name: String,
        policy: LockPolicy
    ) throws {
        let index = try collection.index(of: blockID)
        guard !collection.blocks[index].state.isActive else {
            throw LockCollectionError.activeBlockCannotBeEdited
        }
        let normalizedName = LockBlock.normalizedName(name)
        guard !normalizedName.isEmpty else { throw LockCollectionError.invalidName }
        collection.blocks[index].name = normalizedName
        collection.blocks[index].draftPolicy = policy
    }

    private func loadSelectedDraft() {
        guard !isLoading || selectedBlockID != nil, let block = selectedBlock else { return }
        isLoading = true
        draftName = block.name
        draftPolicy = block.draftPolicy
        isLoading = false
    }

    private func repairSelection() {
        if let selectedBlockID, collection.block(id: selectedBlockID) != nil { return }
        selectedBlockID = collection.activeBlocks.first?.id ?? collection.blocks.first?.id
    }

    private func nextBlockName() -> String {
        let existing = Set(collection.blocks.map(\.name))
        if !existing.contains("New pause") { return "New pause" }
        var number = 2
        while existing.contains("New pause \(number)") { number += 1 }
        return "New pause \(number)"
    }

    private func recordPersistentError(_ error: Error) {
        let message = error.localizedDescription
        persistentErrorMessage = message
        guard message != lastRefreshErrorMessage else { return }
        lastRefreshErrorMessage = message
        errorMessage = message
    }
}
