import AppKit
import Combine
import Darwin
import Foundation

struct AppleWebsiteOverwrite: Equatable, Identifiable {
    let restricted: [String]
    let allowed: [String]

    var id: String { (restricted + ["|"] + allowed).joined(separator: "\n") }
}

/// Credentials are transient local variables, never published view state.
@MainActor
final class AppleProtectionModel: ObservableObject {
    enum Activity: Equatable {
        case checking, settingCode, verifyingCode, removingCode, syncingWebsites

        var label: String {
            switch self {
            case .checking: return "Checking Screen Time…"
            case .settingCode: return "Setting the private code…"
            case .verifyingCode: return "Verifying the code…"
            case .removingCode: return "Removing the code…"
            case .syncingWebsites: return "Syncing websites…"
            }
        }
    }

    @Published private(set) var snapshot: AppleLockdownSnapshot?
    @Published private(set) var codeCheck: Bool?
    @Published private(set) var activity: Activity?
    @Published private(set) var message: String?
    @Published private(set) var hasError = false
    @Published private(set) var websiteSyncMessage: String?
    @Published private(set) var websiteSyncNeedsRetry = false
    @Published private(set) var nativeWebsites: AppleScreenTimeWebsites?
    @Published private(set) var pendingWebsiteOverwrite: AppleWebsiteOverwrite?
    private let service: any ProtectedServiceServing
    private let automation: any AppleScreenTimeAutomating
    private let operationLockURL: URL
    private var websiteSyncRequestedWhileBusy = false
    private var statusUnavailable = false

    var isBusy: Bool { activity != nil }
    var isSyncingWebsites: Bool { activity == .syncingWebsites }

    init(
        service: any ProtectedServiceServing, automation: (any AppleScreenTimeAutomating)? = nil,
        operationLockURL: URL? = nil
    ) {
        self.service = service
        self.automation = automation ?? AppleScreenTimeAutomation()
        self.operationLockURL =
            operationLockURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HardPause/screen-time-operation.lock")
    }

    func refresh() async {
        guard !isBusy else { return }
        do {
            snapshot = try await service.appleLockdownStatus()
            if statusUnavailable {
                message = nil
                hasError = false
                statusUnavailable = false
            }
        } catch {
            statusUnavailable = true
            hasError = true
            message = error.localizedDescription
        }
    }

    func inspectSettings() async {
        await perform(.checking) {
            self.codeCheck = nil
            self.codeCheck = try await self.automation.inspectCode()
        }
    }

    func setUp(enablesAdultFilter: Bool, existingPasscode: String?) async {
        guard !isBusy else { return }
        await perform(.checking) {
            if let existingPasscode, !AppleScreenTimeAutomation.validCode(existingPasscode) {
                throw AppleScreenTimeAutomationError.existingPasscodeRequired
            }
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
            self.activity = .settingCode
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
        guard !isBusy else { return }
        await perform(.verifyingCode) {
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
        guard !isBusy else { return }
        await perform(.checking) {
            let status = try await self.service.appleLockdownStatus()
            guard status.phase == .pendingSetup, let operationID = status.operationID else {
                throw AppleLockdownError.setupNotPending
            }
            if let existingPasscode, !AppleScreenTimeAutomation.validCode(existingPasscode) {
                throw AppleScreenTimeAutomationError.existingPasscodeRequired
            }
            let baseline = try await self.automation.inspect(
                checkAdultFilter: status.enablesAdultFilter, passcode: existingPasscode)
            // Retry with the same saved code; replacing an existing code requires explicit input.
            if baseline.hasPasscode, existingPasscode?.isEmpty != false {
                throw AppleScreenTimeAutomationError.existingPasscodeRequired
            }
            let operation = try await self.service.resumeAppleLockdownSetup(operationID: operationID)
            self.activity = .settingCode
            try await self.automation.install(
                passcode: operation.passcode, replacing: existingPasscode,
                enableAdultFilter: status.enablesAdultFilter
            )
            try await self.verifyAndComplete(operation)
        }
        await syncAfterSetup()
    }

    func requestEnd() async {
        await perform(.checking) {
            self.snapshot = try await self.service.requestAppleLockdownEnd()
            self.message =
                self.snapshot?.fullUnlockDelay == 0
                ? nil : "The wait has started. Protection stays on until it finishes."
        }
    }

    func finishEnd() async {
        await perform(.removingCode) {
            let operation = try await self.service.beginAppleLockdownRelease()
            self.snapshot = operation.snapshot
            if operation.snapshot.mirroredDomains?.isEmpty == false
                || operation.snapshot.mirroredAllowedDomains?.isEmpty == false
                || operation.snapshot.websiteSyncOperationID != nil
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
            self.websiteSyncMessage = nil
            self.websiteSyncNeedsRetry = false
            self.nativeWebsites = nil
            self.message = "Hard Pause's Screen Time code was removed."
        }
    }

    @discardableResult
    func syncWebsites(approving overwrite: AppleWebsiteOverwrite? = nil, presentingResult: Bool = false) async -> Bool {
        if isSyncingWebsites {
            websiteSyncRequestedWhileBusy = true
            return false
        }
        guard !isBusy else { return false }
        activity = .syncingWebsites
        websiteSyncMessage = nil
        websiteSyncNeedsRetry = false
        defer {
            activity = nil
            if websiteSyncRequestedWhileBusy {
                websiteSyncRequestedWhileBusy = false
                Task { await syncWebsites() }
            }
        }
        var synced = false
        do {
            synced = try await withNativeOperation {
                try await self.reconcileWebsites(approving: overwrite)
            }
        } catch {
            websiteSyncMessage = error.localizedDescription
            websiteSyncNeedsRetry = true
        }
        if presentingResult { NSApp?.activate(ignoringOtherApps: true) }
        return synced
    }

    func cancelWebsiteOverwrite() {
        guard pendingWebsiteOverwrite != nil else { return }
        pendingWebsiteOverwrite = nil
        websiteSyncMessage = "Apple’s existing entries were kept. Review website sync when you are ready."
    }

    private func reconcileWebsites(approving overwrite: AppleWebsiteOverwrite? = nil) async throws -> Bool {
        let operation = try await service.beginAppleWebsiteSync()
        let current = try await automation.inspectWebsites(passcode: operation.passcode)
        nativeWebsites = current
        let requiredRestricted = Set(operation.activeDomains)
        let requiredAllowed = Set(operation.activeAllowedDomains)
        let ownedRestricted = Set(operation.mirroredDomains)
        let ownedAllowed = Set(operation.mirroredAllowedDomains)
        let restrictedEntries = current.restrictedEntries.map { ($0, URLPatternRule.exactDomain(from: $0)) }
        let allowedEntries = current.allowedEntries.map { ($0, URLPatternRule.exactDomain(from: $0)) }
        let removeRestricted = restrictedEntries.filter { !requiredRestricted.contains($0.1 ?? "") }.map(\.0)
        let removeAllowed = allowedEntries.filter { !requiredAllowed.contains($0.1 ?? "") }.map(\.0)
        let addRestricted = requiredRestricted.subtracting(restrictedEntries.compactMap(\.1)).sorted()
        let addAllowed = requiredAllowed.subtracting(allowedEntries.compactMap(\.1)).sorted()
        let unowned = AppleWebsiteOverwrite(
            restricted: restrictedEntries.filter {
                removeRestricted.contains($0.0)
                    && !ownedRestricted.contains($0.1 ?? "")
            }.map(\.0),
            allowed: allowedEntries.filter {
                removeAllowed.contains($0.0)
                    && !ownedAllowed.contains($0.1 ?? "")
            }.map(\.0))
        if (!unowned.restricted.isEmpty || !unowned.allowed.isEmpty) && overwrite != unowned {
            pendingWebsiteOverwrite = unowned
            NSApp?.activate(ignoringOtherApps: true)
            return false
        }
        pendingWebsiteOverwrite = nil
        let permitted = try await service.claimAppleWebsiteSync(
            domains: addRestricted, allowedDomains: addAllowed,
            expectedDomains: operation.activeDomains, expectedAllowedDomains: operation.activeAllowedDomains)
        guard let operationID = permitted.operationID else { throw AppleLockdownError.operationMismatch }
        let updated = try await automation.updateWebsites(
            passcode: permitted.passcode,
            addRestricted: addRestricted, removeRestricted: removeRestricted,
            addAllowed: addAllowed, removeAllowed: removeAllowed)
        nativeWebsites = updated
        guard updated.restricted == requiredRestricted,
            updated.allowed == requiredAllowed,
            updated.restrictedEntries.count == requiredRestricted.count,
            updated.allowedEntries.count == requiredAllowed.count
        else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
        try await service.completeAppleWebsiteSync(
            operationID: operationID,
            verifiedDomains: updated.restricted.sorted(), verifiedAllowedDomains: updated.allowed.sorted(),
            mirroredDomains: Set(permitted.mirroredDomains).intersection(requiredRestricted).sorted(),
            mirroredAllowedDomains: Set(permitted.mirroredAllowedDomains).intersection(requiredAllowed).sorted())
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
        let permitted = try await service.claimAppleWebsiteSync(
            domains: [], allowedDomains: [], expectedDomains: [], expectedAllowedDomains: [])
        guard let operationID = permitted.operationID else { throw AppleLockdownError.operationMismatch }
        let updated = try await automation.updateWebsites(
            passcode: permitted.passcode, addRestricted: [], removeRestricted: removeRestricted,
            addAllowed: [], removeAllowed: removeAllowed)
        guard updated.restricted.isDisjoint(with: ownedRestricted),
            updated.allowed.isDisjoint(with: ownedAllowed)
        else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
        try await service.completeAppleWebsiteSync(
            operationID: operationID,
            verifiedDomains: updated.restricted.sorted(), verifiedAllowedDomains: updated.allowed.sorted(),
            mirroredDomains: [], mirroredAllowedDomains: [])
    }

    private func verifyAndComplete(_ operation: AppleLockdownCredentialOperation) async throws {
        activity = .verifyingCode
        try await automation.verify(
            passcode: operation.passcode, requiresAdultFilter: operation.snapshot.enablesAdultFilter)
        snapshot = try await service.completeAppleLockdownSetup(operationID: operation.operationID)
        codeCheck = nil
        message = "Screen Time is ready."
    }

    private func syncAfterSetup() async {
        if snapshot?.phase == .active && snapshot?.enablesAdultFilter == true {
            await syncWebsites(presentingResult: true)
        }
    }

    private func perform(_ activity: Activity, _ action: () async throws -> Void) async {
        guard !isBusy else { return }
        self.activity = activity
        message = nil
        hasError = false
        defer {
            self.activity = nil
            NSApp?.activate(ignoringOtherApps: true)
        }
        do { try await withNativeOperation(action) } catch {
            // These errors contain only fixed descriptions; the automation never returns native UI text.
            message = error.localizedDescription
            hasError = true
            if let current = try? await service.appleLockdownStatus() { snapshot = current }
        }
    }

    private func withNativeOperation<T>(_ action: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(
            at: operationLockURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(operationLockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AppleScreenTimeAutomationError.operationInProgress }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
            (info.st_mode & 0o777) == 0o600, flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else { throw AppleScreenTimeAutomationError.operationInProgress }
        // Never unlink this file: all app copies must lock the same inode.
        defer { _ = flock(descriptor, LOCK_UN) }
        return try await action()
    }
}
