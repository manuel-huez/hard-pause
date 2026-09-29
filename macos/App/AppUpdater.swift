import AppKit
import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private weak var model: AppModel?
    private var controller: SPUStandardUpdaterController?
    private let service = ProtectedServiceClient()
    private var approvedUpdate: ServiceFirstUpdate?
    private var installationCheck: Task<Void, Never>?
    private var installationApproval: (build: UInt64, checkedAt: ContinuousClock.Instant)?
    private var recoveryObservation: AnyCancellable?
    private var recoveryTask: Task<Void, Never>?
    private var lastRecoveryCheck = Date.distantPast
    private var successorNeedsInitialConnection = CommandLine.arguments.contains(AppUpdateRecovery.relaunchArgument)
    private var recoveryWasAttempted = false
    private var successorWasLaunched = false
    private var recoveryReplacement: AppUpdateRecovery.Replacement?
    private var recoveredApplication: NSRunningApplication?
    private var recoveryCoverage: BrowserWorkerReadiness?
    @Published private(set) var isPreparingUpdate = false
    @Published private(set) var recoveryMessage: String?
    private(set) var installationIsStarting = false
    private(set) var recoveryTerminationIsPending = false

    var isConfigured: Bool { controller != nil }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates == true && Self.canUpdate(model)
            && !installationIsStarting && !isPreparingUpdate
            && model?.isRecoveringAppAfterUpdate != true
    }

    func checkForUpdates() {
        guard canCheckForUpdates else {
            let alert = NSAlert()
            alert.messageText = "Update not ready"
            alert.informativeText =
                !isConfigured
                ? "App updates are unavailable in this build."
                : isPreparingUpdate || installationIsStarting
                    ? "An update is already in progress."
                    : "Wait for Screen Time and protection checks to finish, then try again."
            if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        isPreparingUpdate = true
        approvedUpdate = nil
        installationApproval = nil
        Task { @MainActor in
            defer {
                isPreparingUpdate = false
                recoverAfterUpdateIfNeeded()
            }
            do {
                let update = try await ServiceFirstUpdate.latest()
                try await prepareService(for: update)
                controller?.checkForUpdates(nil)
            } catch {
                if AppUpdateRecovery.currentImageWasRemoved() {
                    recoveryMessage = "The running app copy was replaced. Select Retry to check the connection."
                } else {
                    showUpdateError(error)
                }
            }
        }
    }

    var shouldHoldTermination: Bool {
        installationIsStarting && (approvedUpdate == nil || !Self.canUpdate(model))
    }

    private func cancelInstallationCheck() {
        installationCheck?.cancel()
        installationCheck = nil
        installationApproval = nil
    }

    /// Cancel the first quit so AppKit keeps running MainActor tasks during the safety check.
    func mayFinishInstallation() -> Bool {
        if let approval = installationApproval {
            installationApproval = nil
            return installationIsStarting && approvedUpdate?.build == approval.build
                && approval.checkedAt.duration(to: .now) < .seconds(5) && Self.canUpdate(model)
        }
        guard installationIsStarting, installationCheck == nil else { return false }
        installationCheck = Task { @MainActor [weak self] in
            guard let self else { return }
            let safe = await self.checkInstallationSafety()
            guard !Task.isCancelled else { return }
            self.installationCheck = nil
            guard safe, let update = self.approvedUpdate else {
                self.showUpdateError(ServiceFirstUpdate.Failure.restartNotSafe)
                return
            }
            self.installationApproval = (update.build, .now)
            NSApplication.shared.terminate(nil)
        }
        return false
    }

    private func checkInstallationSafety() async -> Bool {
        guard
            installationIsStarting,
            let approvedUpdate,
            Self.canUpdate(model),
            let status = try? await service.updateInstallationStatus(),
            status.installedAppBuild == approvedUpdate.build,
            let latest = try? await service.list(),
            latest.protection.releaseBuild == String(approvedUpdate.build),
            Self.isSafeToUpdate(latest),
            await hasBrowserCoverage(for: latest),
            await model?.replacementWorkerReady(build: approvedUpdate.build) == true,
            !Task.isCancelled, installationIsStarting, Self.canUpdate(model)
        else { return false }
        return true
    }

    func start(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        recoveryObservation = model.$serviceAvailability.sink { [weak self] availability in
            if availability == .ready, self?.successorNeedsInitialConnection == true,
                !AppUpdateRecovery.currentImageWasRemoved()
            {
                self?.successorNeedsInitialConnection = false
            }
            guard case .unavailable = availability else { return }
            Task { @MainActor [weak self] in self?.recoverAfterUpdateIfNeeded() }
        }
        guard Self.hasReleaseConfiguration else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    private func recoverAfterUpdateIfNeeded(reusing existingApplication: NSRunningApplication? = nil) {
        guard !successorNeedsInitialConnection,
            !recoveryWasAttempted || existingApplication != nil, recoveryTask == nil,
            !recoveryTerminationIsPending,
            !installationIsStarting, !isPreparingUpdate,
            model?.canRecoverAppAfterUpdate == true,
            Date().timeIntervalSince(lastRecoveryCheck) >= 60
        else { return }
        lastRecoveryCheck = Date()
        guard let replacement = AppUpdateRecovery.replacement() else { return }
        if let application = existingApplication {
            guard recoveryReplacement == replacement,
                AppUpdateRecovery.validates(application, replacement: replacement)
            else { return }
        }
        recoveryMessage =
            existingApplication == nil
            ? "The app was updated. Checking protection before restarting Hard Pause…"
            : "The updated app is running. Checking protection before closing this copy…"
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.recoveryTask = nil
                if !self.recoveryTerminationIsPending { self.model?.endAppUpdateRecovery() }
            }
            guard let coverage = await AppUpdateRecovery.browserCoverage(for: replacement),
                coverage.isFresh(), self.recoveryGuardsPass,
                AppUpdateRecovery.replacement() == replacement,
                self.model?.beginAppUpdateRecovery() == true
            else {
                self.recoveryMessage =
                    "The app was updated, but a safe restart could not be confirmed. Keep Hard Pause open and select Retry."
                return
            }
            self.recoveryWasAttempted = true
            do {
                guard self.recoveryGuardsPass, AppUpdateRecovery.replacement() == replacement else {
                    throw RecoveryFailure.unsafe
                }
                let application: NSRunningApplication
                if let existing = existingApplication {
                    application = existing
                } else {
                    application = try await AppUpdateRecovery.launch(replacement)
                }
                self.successorWasLaunched =
                    application.processIdentifier != NSRunningApplication.current.processIdentifier
                self.recoveryReplacement = replacement
                self.recoveredApplication = application
                guard self.recoveryGuardsPass,
                    AppUpdateRecovery.validates(application, replacement: replacement)
                else { throw RecoveryFailure.unsafe }
                self.recoveryMessage = "The updated app is running. Checking protection before closing this copy…"
                guard let finalCoverage = await AppUpdateRecovery.browserCoverage(for: replacement) else {
                    self.recoveryExitFailed()
                    return
                }
                self.recoveryCoverage = finalCoverage
                self.recoveryTerminationIsPending = true
                guard self.mayTerminateForRecovery() else { return }
                NSApplication.shared.terminate(nil)
            } catch {
                self.recoveryMessage =
                    "Hard Pause could not restart safely after the update. Keep the app open and select Retry to check the connection."
            }
        }
    }

    func retryRecoveryAfterUpdate() {
        guard recoveryTask == nil, !recoveryTerminationIsPending else { return }
        if let application = recoveredApplication, let replacement = recoveryReplacement {
            guard !application.isTerminated,
                AppUpdateRecovery.validates(application, replacement: replacement),
                AppUpdateRecovery.replacement() == replacement
            else {
                if application.isTerminated { successorWasLaunched = false }
                recoveryReplacement = nil
                recoveredApplication = nil
                recoveryMessage =
                    "The updated app is no longer available. Keep this app open and select Retry to check the connection."
                return
            }
            lastRecoveryCheck = .distantPast
            recoverAfterUpdateIfNeeded(reusing: application)
            return
        }
        if !successorWasLaunched {
            recoveryWasAttempted = false
        }
        lastRecoveryCheck = .distantPast
        recoverAfterUpdateIfNeeded()
    }

    private var recoveryGuardsPass: Bool {
        !Task.isCancelled && !installationIsStarting && !isPreparingUpdate
            && model?.canRecoverAppAfterUpdate == true
    }

    /// Quit must stay synchronous: AppKit's termination loop can block MainActor tasks.
    func mayTerminateForRecovery() -> Bool {
        guard recoveryTerminationIsPending,
            let replacement = recoveryReplacement, let application = recoveredApplication,
            model?.isRecoveringAppAfterUpdate == true, recoveryGuardsPass,
            recoveryCoverage?.isFresh() == true,
            AppUpdateRecovery.replacement() == replacement,
            AppUpdateRecovery.validates(application, replacement: replacement)
        else {
            recoveryExitFailed()
            return false
        }
        return true
    }

    private func recoveryExitFailed() {
        recoveryTerminationIsPending = false
        recoveryCoverage = nil
        let successorEnded = recoveredApplication?.isTerminated == true
        if successorEnded { successorWasLaunched = false }
        if let replacement = recoveryReplacement, let application = recoveredApplication,
            !AppUpdateRecovery.validates(application, replacement: replacement)
        {
            recoveryReplacement = nil
            recoveredApplication = nil
        }
        model?.endAppUpdateRecovery()
        recoveryMessage =
            successorEnded
            ? "The updated app closed. Keep this app open and select Retry to check the connection."
            : "The updated app opened, but protection could not be confirmed. Keep Hard Pause open and select Retry to check protection again."
    }

    private enum RecoveryFailure: Error { case unsafe, runningImageRemoved }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard approvedUpdate != nil, Self.canUpdate(model) else {
            throw NSError(
                domain: "org.hardpause.app.updates",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Protection must update before the app can install."
                ]
            )
        }
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate item: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        let currentBuild =
            UInt64(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        guard let approvedUpdate, approvedUpdate.build > currentBuild, approvedUpdate.matches(item) else {
            throw NSError(
                domain: "org.hardpause.app.updates",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The update changed after protection was checked."]
            )
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installationIsStarting = true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installationIsStarting = false
        cancelInstallationCheck()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard error != nil else { return }
        installationIsStarting = false
        cancelInstallationCheck()
    }

    private static func canUpdate(_ model: AppModel?) -> Bool {
        guard
            let model,
            model.serviceIsHealthy,
            !model.isBusy,
            !model.appleProtection.isBusy,
            !model.hasPendingMutation,
            !model.isInstallingService,
            let snapshot = model.snapshot
        else { return false }
        return snapshot.blocks.allSatisfy { $0.phase == .inactive }
            || model.browserWorkerReadyForHandoff
    }

    private static func isSafeToUpdate(_ snapshot: ProtectedServiceSnapshot) -> Bool {
        snapshot.protection.isEnforcing && snapshot.protection.issues.isEmpty
    }

    private func prepareService(for update: ServiceFirstUpdate) async throws {
        let currentBuild =
            UInt64(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        if update.build <= currentBuild {
            model?.setPendingBrowserWorkerBuild(nil)
            approvedUpdate = update
            return
        }
        guard let latest = try? await service.list(),
            Self.isSafeToUpdate(latest),
            await hasBrowserCoverage(for: latest)
        else { throw ServiceFirstUpdate.Failure.serviceDidNotUpdate }
        let status = try await service.updateInstallationStatus()
        if status.installedAppBuild < update.build {
            let staged = try await update.verifiedBundle()
            defer { try? FileManager.default.removeItem(at: staged.directory) }
            _ = try await service.requestManagedUpdate(bundlePath: staged.bundle.path)
            model?.setPendingBrowserWorkerBuild(update.build)
            try await waitForService(build: update.build)
        } else if status.installedAppBuild == update.build {
            model?.setPendingBrowserWorkerBuild(update.build)
        }
        guard let installed = try? await service.updateInstallationStatus(),
            installed.installedAppBuild == update.build,
            let current = try? await service.list(),
            installed.serviceVersion == current.protection.serviceVersion,
            current.protection.releaseBuild == String(update.build),
            Self.isSafeToUpdate(current),
            await hasBrowserCoverage(for: current)
        else { throw ServiceFirstUpdate.Failure.serviceDidNotUpdate }
        try await waitForReplacementWorker(build: update.build)
        approvedUpdate = update
    }

    private func waitForService(build: UInt64) async throws {
        for _ in 0..<90 {
            if AppUpdateRecovery.currentImageWasRemoved() { throw RecoveryFailure.runningImageRemoved }
            if let status = try? await service.updateInstallationStatus(),
                status.installedAppBuild == build,
                let snapshot = try? await service.list(),
                status.serviceVersion == snapshot.protection.serviceVersion,
                snapshot.protection.releaseBuild == String(build),
                Self.isSafeToUpdate(snapshot)
            {
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw ServiceFirstUpdate.Failure.serviceDidNotUpdate
    }

    private func waitForReplacementWorker(build: UInt64) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if AppUpdateRecovery.currentImageWasRemoved() { throw RecoveryFailure.runningImageRemoved }
            if await model?.replacementWorkerReady(build: build) == true { return }
            try await Task.sleep(for: .seconds(2))
        }
        let name = AppModel.replacementWorkerName(build: build)
        guard BrowserWorkerClient.installedMachServices().contains(name) else {
            throw ServiceFirstUpdate.Failure.workerMissing
        }
        if let report = await model?.replacementWorkerReadiness(build: build),
            report.browserAccess.contains(where: {
                $0.installed && $0.permission != "granted"
                    && !(report.checksPermissionsOnLaunch == true && $0.accessCanBeCheckedOnOpen)
            })
        {
            throw ServiceFirstUpdate.Failure.workerNeedsAccess
        }
        throw ServiceFirstUpdate.Failure.workerNotReady
    }

    private func showUpdateError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Hard Pause update stopped"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func hasBrowserCoverage(for snapshot: ProtectedServiceSnapshot) async -> Bool {
        if snapshot.blocks.allSatisfy({ $0.phase == .inactive }) { return true }
        return await model?.probeBrowserWorkerReadiness() == true
    }

    private static var hasReleaseConfiguration: Bool {
        #if DEBUG
            return false
        #else
            guard
                let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                let decoded = Data(base64Encoded: key),
                decoded.count == 32,
                decoded.base64EncodedString() == key,
                let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
            else { return false }
            return feed == "https://github.com/manuel-huez/hard-pause/releases/latest/download/appcast.xml"
        #endif
    }
}
