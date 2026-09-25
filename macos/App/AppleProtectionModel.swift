import Combine
import Foundation

/// Credentials are transient local variables, never published view state.
@MainActor
final class AppleProtectionModel: ObservableObject {
    @Published private(set) var snapshot: AppleLockdownSnapshot?
    @Published private(set) var inspection: AppleScreenTimeInspection?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    private let service: any ProtectedServiceServing
    private let automation: any AppleScreenTimeAutomating

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
            self.inspection = nil
            self.inspection = try await self.automation.inspect()
        }
    }

    func setUp(fullUnlockDelay: TimeInterval, enablesAdultFilter: Bool, existingPasscode: String?) async {
        await perform {
            let baseline = try await self.automation.inspect()
            self.inspection = baseline
            if baseline.hasPasscode, existingPasscode?.isEmpty != false {
                throw AppleScreenTimeAutomationError.existingPasscodeRequired
            }
            let operation = try await self.service.beginAppleLockdownSetup(
                AppleLockdownSetupRequest(
                    fullUnlockDelay: fullUnlockDelay,
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
    }

    func retrySetup(existingPasscode: String?) async {
        await perform {
            let status = try await self.service.appleLockdownStatus()
            guard status.phase == .pendingSetup, let operationID = status.operationID else {
                throw AppleLockdownError.setupNotPending
            }
            let baseline = try await self.automation.inspect()
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
    }

    func requestEnd() async {
        await perform {
            self.snapshot = try await self.service.requestAppleLockdownEnd()
            self.message = "The full unlock wait has started. Protection stays on."
        }
    }

    func finishEnd() async {
        await perform {
            let operation = try await self.service.beginAppleLockdownRelease()
            self.snapshot = operation.snapshot
            try await self.automation.release(
                passcode: operation.passcode,
                restoreUnrestricted: operation.snapshot.enablesAdultFilter
                    && !operation.snapshot.filterWasAlreadyEnabled
            )
            self.snapshot = try await self.service.completeAppleLockdownRelease(operationID: operation.operationID)
            self.inspection = nil
            self.message = "Hard Pause's Screen Time code was removed. Pre-existing filters were preserved."
        }
    }

    private func verifyAndComplete(_ operation: AppleLockdownCredentialOperation) async throws {
        try await automation.verify(
            passcode: operation.passcode, requiresAdultFilter: operation.snapshot.enablesAdultFilter)
        snapshot = try await service.completeAppleLockdownSetup(operationID: operation.operationID)
        inspection = nil
        message = "The code is secured and verified on this Mac. iPhone protection is not yet verified."
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
