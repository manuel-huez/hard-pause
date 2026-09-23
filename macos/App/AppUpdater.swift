import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private weak var model: AppModel?
    private var controller: SPUStandardUpdaterController?
    private(set) var installationIsStarting = false

    var isConfigured: Bool { controller != nil }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates == true && Self.canUpdate(model)
            && !installationIsStarting
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        Task { @MainActor in
            guard
                let latest = try? await ProtectedServiceClient().list(),
                Self.isSafeToUpdate(latest),
                await hasBrowserCoverage(for: latest),
                canCheckForUpdates
            else { return }
            controller?.checkForUpdates(nil)
        }
    }

    var shouldHoldTermination: Bool {
        installationIsStarting && !Self.canUpdate(model)
    }

    func terminationWasCanceled() {
        installationIsStarting = false
    }

    func mayFinishInstallation() async -> Bool {
        guard
            installationIsStarting,
            Self.canUpdate(model),
            let latest = try? await ProtectedServiceClient().list(),
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
        guard Self.canUpdate(model) else {
            throw NSError(
                domain: "org.hardpause.app.updates",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Updates wait for healthy protection and browser worker readiness."
                ]
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
            model.setupServiceReady,
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
            && snapshot.protection.serviceVersion == ProtectedServiceContract.serviceVersion
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
