import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private weak var model: AppModel?
    private var controller: SPUStandardUpdaterController?
    private var snapshotSubscription: AnyCancellable?
    private var recoveringGate = false
    private(set) var installationIsStarting = false
    private static let updateGateKey = "HardPauseAppUpdateGateToken"

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
        Task { await recoverPendingGate() }
    }

    func mayFinishInstallation() async -> Bool {
        guard
            installationIsStarting,
            Self.canUpdate(model),
            let latest = try? await ProtectedServiceClient().list(),
            Self.isSafeToUpdate(latest)
        else { return false }
        let token = UUID()
        let defaults = UserDefaults.standard
        defaults.set(token.uuidString, forKey: Self.updateGateKey)
        guard defaults.synchronize() else {
            defaults.removeObject(forKey: Self.updateGateKey)
            return false
        }
        do {
            let gated = try await ProtectedServiceClient().prepareUpdate(id: token)
            guard Self.isSafeToUpdate(gated), Self.canUpdate(model) else {
                installationIsStarting = false
                await recoverPendingGate()
                return false
            }
            return true
        } catch {
            installationIsStarting = false
            await recoverPendingGate()
            return false
        }
    }

    func start(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        snapshotSubscription = model.$snapshot.sink { [weak self] _ in
            Task { @MainActor in await self?.recoverPendingGate() }
        }
        Task { await recoverPendingGate() }
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
                userInfo: [NSLocalizedDescriptionKey: "Updates wait until all Hard Pause plans are inactive and protection is available."]
            )
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installationIsStarting = true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installationIsStarting = false
        Task { await recoverPendingGate() }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard error != nil else { return }
        installationIsStarting = false
        Task { await recoverPendingGate() }
    }

    private func recoverPendingGate() async {
        guard !installationIsStarting, !recoveringGate,
              let value = UserDefaults.standard.string(forKey: Self.updateGateKey),
              let token = UUID(uuidString: value)
        else { return }
        recoveringGate = true
        defer { recoveringGate = false }
        guard (try? await ProtectedServiceClient().cancelUpdate(id: token)) != nil else { return }
        UserDefaults.standard.removeObject(forKey: Self.updateGateKey)
    }

    private static func canUpdate(_ model: AppModel?) -> Bool {
        guard
            let model,
            model.setupServiceReady,
            let snapshot = model.snapshot
        else { return false }
        return snapshot.blocks.allSatisfy { $0.phase == .inactive }
    }

    private static func isSafeToUpdate(_ snapshot: ProtectedServiceSnapshot) -> Bool {
        snapshot.protection.isEnforcing && snapshot.protection.issues.isEmpty
            && snapshot.protection.serviceVersion == ProtectedServiceContract.serviceVersion
            && snapshot.blocks.allSatisfy { $0.phase == .inactive }
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
