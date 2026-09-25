import AppKit
import Combine
import Foundation

struct AppleWebsiteOverwrite: Equatable, Identifiable {
    let restricted: [String]
    let allowed: [String]

    var id: String { (restricted + ["|"] + allowed).joined(separator: "\n") }
}

/// Credentials are transient local variables, never published view state.
@MainActor
final class AppleProtectionModel: ObservableObject {
    @Published private(set) var snapshot: AppleLockdownSnapshot?
    @Published private(set) var codeCheck: Bool?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var websiteSyncMessage: String?
    @Published private(set) var isSyncingWebsites = false
    @Published private(set) var nativeWebsites: AppleScreenTimeWebsites?
    @Published private(set) var pendingWebsiteOverwrite: AppleWebsiteOverwrite?
    private let service: any ProtectedServiceServing
    private let automation: any AppleScreenTimeAutomating
    private var websiteSyncRequestedWhileBusy = false

    init(service: any ProtectedServiceServing, automation: (any AppleScreenTimeAutomating)? = nil) {
        self.service = service
        self.automation = automation ?? AppleScreenTimeAutomation()
    }

    func refresh() async {
        guard !isBusy else { return }
        do { snapshot = try await service.appleLockdownStatus() } catch { message = error.localizedDescription }
    }

    func inspectSettings() async {
        await perform {
            self.codeCheck = nil
            self.codeCheck = try await self.automation.inspectCode()
        }
    }

    func setUp(enablesAdultFilter: Bool, existingPasscode: String?) async {
        await perform {
            let baseline = try await self.automation.inspect(
                checkAdultFilter: enablesAdultFilter, passcode: existingPasscode)
            self.codeCheck = baseline.hasPasscode
            if baseline.hasPasscode, existingPasscode?.isEmpty != false {
                throw AppleScreenTimeAutomationError.existingPasscodeRequired
            }
            let operation = try await self.service.beginAppleLockdownSetup(
                AppleLockdownSetupRequest(
                    fullUnlockDelay: 0,
                    enablesAdultFilter: enablesAdultFilter,
                    filterWasAlreadyEnabled: baseline.adultFilterEnabled,
                    shareAcrossDevicesVerified: nil
                )
            )
            self.snapshot = operation.snapshot
            try await self.automation.install(
                passcode: operation.passcode,
                replacing: baseline.hasPasscode ? existingPasscode : nil,
                enableAdultFilter: enablesAdultFilter
            )
            try await self.verifyAndComplete(operation)
        }
        await syncAfterSetup()
    }

    func verifySetup() async {
        await perform {
            let status = try await self.service.appleLockdownStatus()
            self.snapshot = status
            guard status.phase == .pendingSetup, let operationID = status.operationID else {
                throw AppleLockdownError.setupNotPending
            }
            let operation = try await self.service.resumeAppleLockdownSetup(operationID: operationID)
            try await self.verifyAndComplete(operation)
        }
        await syncAfterSetup()
    }

    func retrySetup(existingPasscode: String?) async {
        await perform {
            let status = try await self.service.appleLockdownStatus()
            guard status.phase == .pendingSetup, let operationID = status.operationID else {
                throw AppleLockdownError.setupNotPending
            }
            let baseline = try await self.automation.inspect(
                checkAdultFilter: status.enablesAdultFilter, passcode: existingPasscode)
            // Retry with the same saved code; replacing an existing code requires explicit input.
            if baseline.hasPasscode, existingPasscode?.isEmpty != false {
                throw AppleScreenTimeAutomationError.existingPasscodeRequired
            }
            let operation = try await self.service.resumeAppleLockdownSetup(operationID: operationID)
            try await self.automation.install(
                passcode: operation.passcode, replacing: existingPasscode,
                enableAdultFilter: status.enablesAdultFilter
            )
            try await self.verifyAndComplete(operation)
        }
        await syncAfterSetup()
    }

    func requestEnd() async {
        await perform {
            self.snapshot = try await self.service.requestAppleLockdownEnd()
            self.message = "The full unlock wait has started. Protection stays on."
        }
    }

    func finishEnd() async {
        guard !isSyncingWebsites else { return }
        await perform {
            let operation = try await self.service.beginAppleLockdownRelease()
            self.snapshot = operation.snapshot
            if operation.snapshot.mirroredDomains?.isEmpty == false
                || operation.snapshot.mirroredAllowedDomains?.isEmpty == false
            {
                try await self.removeOwnedWebsitesBeforeRelease()
            }
            try await self.automation.release(
                passcode: operation.passcode,
                restoreUnrestricted: operation.snapshot.enablesAdultFilter
                    && !operation.snapshot.filterWasAlreadyEnabled
            )
            self.snapshot = try await self.service.completeAppleLockdownRelease(operationID: operation.operationID)
            self.codeCheck = nil
            self.message = "Hard Pause's Screen Time code was removed."
        }
    }

    func syncWebsites(approving overwrite: AppleWebsiteOverwrite? = nil, presentingResult: Bool = false) async {
        guard !isBusy else { return }
        if isSyncingWebsites {
            websiteSyncRequestedWhileBusy = true
            return
        }
        isSyncingWebsites = true
        websiteSyncMessage = nil
        defer {
            isSyncingWebsites = false
            if websiteSyncRequestedWhileBusy {
                websiteSyncRequestedWhileBusy = false
                Task { await syncWebsites() }
            }
        }
        do {
            if try await reconcileWebsites(approving: overwrite) {
                websiteSyncMessage = "Screen Time websites match the active Hard Pause plans on this Mac."
            }
        } catch {
            websiteSyncMessage = error.localizedDescription
        }
        if presentingResult { NSApp.activate(ignoringOtherApps: true) }
    }

    func cancelWebsiteOverwrite() { pendingWebsiteOverwrite = nil }

    func readNativeWebsites() async {
        guard !isBusy, !isSyncingWebsites else { return }
        isSyncingWebsites = true
        websiteSyncMessage = nil
        defer { isSyncingWebsites = false }
        do {
            let passcode = try await service.beginAppleWebsiteSync().passcode
            nativeWebsites = try await automation.inspectWebsites(passcode: passcode)
        } catch {
            websiteSyncMessage = error.localizedDescription
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reconcileWebsites(approving overwrite: AppleWebsiteOverwrite? = nil) async throws -> Bool {
        let operation = try await service.beginAppleWebsiteSync()
        let current = try await automation.inspectWebsites(passcode: operation.passcode)
        nativeWebsites = current
        let requiredRestricted = Set(operation.activeDomains)
        let requiredAllowed = Set(operation.activeAllowedDomains)
        let restrictedEntries = current.restrictedEntries.map { ($0, URLPatternRule.exactDomain(from: $0)) }
        let allowedEntries = current.allowedEntries.map { ($0, URLPatternRule.exactDomain(from: $0)) }
        let removeRestricted = restrictedEntries.filter { !requiredRestricted.contains($0.1 ?? "") }.map(\.0)
        let removeAllowed = allowedEntries.filter { !requiredAllowed.contains($0.1 ?? "") }.map(\.0)
        let addRestricted = requiredRestricted.subtracting(restrictedEntries.compactMap(\.1)).sorted()
        let addAllowed = requiredAllowed.subtracting(allowedEntries.compactMap(\.1)).sorted()
        let unowned = AppleWebsiteOverwrite(
            restricted: restrictedEntries.filter {
                removeRestricted.contains($0.0)
                    && !Set(operation.mirroredDomains).contains($0.1 ?? "")
            }.map(\.0),
            allowed: allowedEntries.filter {
                removeAllowed.contains($0.0)
                    && !Set(operation.mirroredAllowedDomains).contains($0.1 ?? "")
            }.map(\.0))
        if (!unowned.restricted.isEmpty || !unowned.allowed.isEmpty) && overwrite != unowned {
            pendingWebsiteOverwrite = unowned
            websiteSyncMessage = "Confirm which existing Apple websites Hard Pause will replace."
            NSApp.activate(ignoringOtherApps: true)
            return false
        }
        pendingWebsiteOverwrite = nil
        if !addRestricted.isEmpty || !addAllowed.isEmpty {
            try await service.claimAppleWebsiteSync(domains: addRestricted, allowedDomains: addAllowed)
        }
        let updated = try await automation.updateWebsites(
            passcode: operation.passcode,
            addRestricted: addRestricted, removeRestricted: removeRestricted,
            addAllowed: addAllowed, removeAllowed: removeAllowed)
        nativeWebsites = updated
        guard updated.restricted == requiredRestricted,
            updated.allowed == requiredAllowed,
            updated.restrictedEntries.count == requiredRestricted.count,
            updated.allowedEntries.count == requiredAllowed.count
        else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
        try await service.completeAppleWebsiteSync(
            mirroredDomains: Set(operation.mirroredDomains).union(addRestricted)
                .intersection(requiredRestricted).sorted(),
            mirroredAllowedDomains: Set(operation.mirroredAllowedDomains).union(addAllowed)
                .intersection(requiredAllowed).sorted())
        snapshot = try await service.appleLockdownStatus()
        return true
    }

    private func removeOwnedWebsitesBeforeRelease() async throws {
        let operation = try await service.beginAppleWebsiteSync()
        let current = try await automation.inspectWebsites(passcode: operation.passcode)
        let ownedRestricted = Set(operation.mirroredDomains)
        let ownedAllowed = Set(operation.mirroredAllowedDomains)
        let removeRestricted = current.restrictedEntries.filter {
            URLPatternRule.exactDomain(from: $0).map(ownedRestricted.contains) == true
        }
        let removeAllowed = current.allowedEntries.filter {
            URLPatternRule.exactDomain(from: $0).map(ownedAllowed.contains) == true
        }
        let updated = try await automation.updateWebsites(
            passcode: operation.passcode, addRestricted: [], removeRestricted: removeRestricted,
            addAllowed: [], removeAllowed: removeAllowed)
        guard updated.restricted.isDisjoint(with: ownedRestricted),
            updated.allowed.isDisjoint(with: ownedAllowed)
        else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
        try await service.completeAppleWebsiteSync(mirroredDomains: [], mirroredAllowedDomains: [])
    }

    private func verifyAndComplete(_ operation: AppleLockdownCredentialOperation) async throws {
        try await automation.verify(
            passcode: operation.passcode, requiresAdultFilter: operation.snapshot.enablesAdultFilter)
        snapshot = try await service.completeAppleLockdownSetup(operationID: operation.operationID)
        codeCheck = nil
        message = "The code is secured and verified on this Mac. iPhone protection is not yet verified."
    }

    private func syncAfterSetup() async {
        if snapshot?.phase == .active && snapshot?.enablesAdultFilter == true {
            await syncWebsites()
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do { try await action() } catch {
            // These errors contain only fixed descriptions; the automation never returns native UI text.
            message = error.localizedDescription
            if let current = try? await service.appleLockdownStatus() { snapshot = current }
        }
    }
}
