import AppKit
import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private weak var model: AppModel?
    private var controller: SPUStandardUpdaterController?
    private let service = ProtectedServiceClient()
    private var approvedUpdate: ServiceFirstUpdate?
    @Published private(set) var isPreparingUpdate = false
    private(set) var installationIsStarting = false

    var isConfigured: Bool { controller != nil }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates == true && Self.canUpdate(model)
            && !installationIsStarting && !isPreparingUpdate
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        isPreparingUpdate = true
        approvedUpdate = nil
        Task { @MainActor in
            defer { isPreparingUpdate = false }
            do {
                let update = try await ServiceFirstUpdate.latest()
                try await prepareService(for: update)
                controller?.checkForUpdates(nil)
            } catch {
                showUpdateError(error)
            }
        }
    }

    var shouldHoldTermination: Bool {
        installationIsStarting && (approvedUpdate == nil || !Self.canUpdate(model))
    }

    func terminationWasCanceled() {
        installationIsStarting = false
    }

    func mayFinishInstallation() async -> Bool {
        guard
            installationIsStarting,
            let approvedUpdate,
            Self.canUpdate(model),
            let status = try? await service.updateInstallationStatus(),
            status.installedAppBuild >= approvedUpdate.build,
            let latest = try? await service.list(),
            Self.isSafeToUpdate(latest),
            await hasBrowserCoverage(for: latest)
        else { return false }
        return true
    }

    func start(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        guard Self.hasReleaseConfiguration else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

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
        guard let approvedUpdate, approvedUpdate.matches(item) else {
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
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard error != nil else { return }
        installationIsStarting = false
    }

    private static func canUpdate(_ model: AppModel?) -> Bool {
        guard
            let model,
            model.serviceIsHealthy,
            !model.isBusy,
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
        guard let latest = try? await service.list(),
            Self.isSafeToUpdate(latest),
            await hasBrowserCoverage(for: latest)
        else { throw ServiceFirstUpdate.Failure.serviceDidNotUpdate }
        let currentBuild =
            UInt64(
                Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        let status = try await service.updateInstallationStatus()
        if update.build > currentBuild && status.installedAppBuild < update.build {
            let staged = try await update.verifiedBundle()
            defer { try? FileManager.default.removeItem(at: staged.directory) }
            _ = try await service.requestManagedUpdate(bundlePath: staged.bundle.path)
            try await waitForService(build: update.build)
        }
        guard let installed = try? await service.updateInstallationStatus(),
            installed.installedAppBuild >= min(update.build, currentBuild),
            let current = try? await service.list(),
            installed.serviceVersion == current.protection.serviceVersion,
            Self.isSafeToUpdate(current),
            await hasBrowserCoverage(for: current)
        else { throw ServiceFirstUpdate.Failure.serviceDidNotUpdate }
        approvedUpdate = update
    }

    private func waitForService(build: UInt64) async throws {
        for _ in 0..<90 {
            if let status = try? await service.updateInstallationStatus(),
                status.installedAppBuild >= build,
                let snapshot = try? await service.list(),
                status.serviceVersion == snapshot.protection.serviceVersion,
                Self.isSafeToUpdate(snapshot)
            {
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw ServiceFirstUpdate.Failure.serviceDidNotUpdate
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
