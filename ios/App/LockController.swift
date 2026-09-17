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
        var policy = LockPolicy()
        policy.blocksAdultWebsites = true
        policy.preventsAppRemoval = true
        _ = createBlock(name: nextBlockName(), policy: policy, activate: false)
    }

    @discardableResult
    func createBlock(name: String, policy: LockPolicy, activate: Bool) -> UUID? {
        if let message = draftValidationMessage(name: name, policy: policy, activating: activate) {
            errorMessage = message
            return nil
        }
        if activate {
            authorizationStatus = authorizationStatusProvider()
            guard authorizationStatus == .approved else {
                errorMessage = "Screen Time access is no longer approved. Allow access before starting this plan."
                return nil
            }
        }

        let newBlock = LockBlock(name: name, draftPolicy: policy)
        do {
            let date = Date()
            let elapsedTime = ElapsedTimeClock.current
            collection = try runtime.mutate(wallClockNow: date, elapsedTime: elapsedTime) { collection in
                collection.blocks.append(newBlock)
                if activate {
                    try LockCollectionStateMachine.activate(
                        &collection,
                        blockID: newBlock.id,
                        at: date,
                        elapsedTime: elapsedTime
                    )
                }
            }
            selectedBlockID = newBlock.id
            return newBlock.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func updateBlock(id: UUID, name: String, policy: LockPolicy) -> Bool {
        if let message = draftValidationMessage(name: name, policy: policy, activating: false) {
            errorMessage = message
            return false
        }
        do {
            collection = try runtime.mutate { collection in
                try Self.updateInactiveBlock(
                    in: &collection,
                    blockID: id,
                    name: name,
                    policy: policy
                )
            }
            selectedBlockID = id
            loadSelectedDraft()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteSelectedBlock() {
        guard let selectedBlockID else { return }
        deleteBlock(id: selectedBlockID)
    }

    func deleteBlock(id: UUID) {
        do {
            collection = try runtime.mutate { collection in
                let index = try collection.index(of: id)
                guard !collection.blocks[index].state.isActive else {
                    throw LockCollectionError.activeBlockCannotBeEdited
                }
                collection.blocks.remove(at: index)
            }
            if selectedBlockID == id {
                selectedBlockID = collection.activeBlocks.first?.id ?? collection.blocks.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectBlock(_ id: UUID) {
        guard collection.block(id: id) != nil else { return }
        selectedBlockID = id
    }

    func activate() {
        guard let selectedBlockID else {
            errorMessage = LockCollectionError.blockNotFound.localizedDescription
            return
        }
        activate(blockID: selectedBlockID)
    }

    func activate(blockID: UUID) {
        authorizationStatus = authorizationStatusProvider()
        guard authorizationStatus == .approved else {
            errorMessage = "Screen Time access is no longer approved. Allow access before starting this plan."
            return
        }
        guard let block = collection.block(id: blockID) else {
            errorMessage = LockCollectionError.blockNotFound.localizedDescription
            return
        }
        do {
            let date = Date()
            let elapsedTime = ElapsedTimeClock.current
            collection = try runtime.mutate(wallClockNow: date, elapsedTime: elapsedTime) { candidate in
                try Self.updateInactiveBlock(
                    in: &candidate,
                    blockID: blockID,
                    name: block.name,
                    policy: block.draftPolicy
                )
                try LockCollectionStateMachine.activate(
                    &candidate,
                    blockID: blockID,
                    at: date,
                    elapsedTime: elapsedTime
                )
            }
            selectedBlockID = blockID
            loadSelectedDraft()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestBreak() {
        guard let selectedBlockID else {
            errorMessage = LockCollectionError.blockNotFound.localizedDescription
            return
        }
        requestBreak(blockID: selectedBlockID)
    }

    func requestBreak(blockID: UUID) {
        mutateSelectedState(
            { collection, blockID, date, elapsedTime in
                try LockCollectionStateMachine.requestBreak(
                    &collection,
                    blockID: blockID,
                    at: date,
                    elapsedTime: elapsedTime
                )
            }, blockID: blockID)
    }

    func cancelBreakRequest(blockID: UUID) {
        mutateSelectedState(
            { collection, blockID, date, elapsedTime in
                try LockCollectionStateMachine.cancelBreak(
                    &collection,
                    blockID: blockID,
                    at: date,
                    elapsedTime: elapsedTime
                )
            }, blockID: blockID)
    }

    func requestFullUnlock() {
        guard let selectedBlockID else {
            errorMessage = LockCollectionError.blockNotFound.localizedDescription
            return
        }
        requestFullUnlock(blockID: selectedBlockID)
    }

    func requestFullUnlock(blockID: UUID) {
        mutateSelectedState(
            { collection, blockID, date, elapsedTime in
                try LockCollectionStateMachine.requestEnd(
                    &collection,
                    blockID: blockID,
                    at: date,
                    elapsedTime: elapsedTime
                )
            }, blockID: blockID)
    }

    func addManualDomain(_ input: String) -> Bool {
        guard let domain = LockPolicy.newManualDomain(input) else {
            errorMessage =
                "Enter a whole domain such as example.com. Paths, ports, query text, and wildcards are not supported."
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
        ) throws -> Void,
        blockID: UUID? = nil
    ) {
        guard let targetBlockID = blockID ?? selectedBlockID else {
            errorMessage = LockCollectionError.blockNotFound.localizedDescription
            return
        }
        do {
            let date = Date()
            let elapsedTime = ElapsedTimeClock.current
            collection = try runtime.mutate(wallClockNow: date, elapsedTime: elapsedTime) { candidate in
                try mutation(&candidate, targetBlockID, date, elapsedTime)
            }
            selectedBlockID = targetBlockID
            loadSelectedDraft()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func draftValidationMessage(
        name: String,
        policy: LockPolicy,
        activating: Bool
    ) -> String? {
        guard !LockBlock.normalizedName(name).isEmpty else {
            return "Enter a name for this plan."
        }
        do {
            try policy.validateDurations()
        } catch {
            return error.localizedDescription
        }
        guard policy.hasBlockingTarget else {
            return "Choose an app or website, or turn on the adult website filter."
        }
        do {
            try policy.validateManagedSettingsLimits()
        } catch {
            return error.localizedDescription
        }
        if activating, activeBlockCount >= LockCollection.maximumActiveBlocks {
            return LockCollectionError.maximumActiveBlocks.localizedDescription
        }
        return nil
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
        try policy.validateDurations()
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
