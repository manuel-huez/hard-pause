import AppKit
import Combine
import Foundation
import Security
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: ProtectedServiceSnapshot?
    @Published private(set) var serviceAvailability: ProtectedServiceAvailability = .checking
    @Published private(set) var isBusy = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasPendingMutation = false
    @Published private(set) var displayElapsed: TimeInterval = 0
    @Published private(set) var errorMessage: String?

    @Published private(set) var browserStatuses: [String: String] = [:]
    @Published private(set) var setupState: SetupState = .checking
    @Published private(set) var browserReadiness: [BrowserSetupState] = []
    @Published private(set) var connectingBrowserID: String?
    @Published private(set) var browserConnectionMessages: [String: String] = [:]
    @Published private(set) var isInstallingService = false
    @Published private(set) var startsAtLogin = false
    private let browserProtection = BrowserProtection()
    private var browserWorker = BrowserWorkerClient()
    @Published private(set) var browserWorkerReadiness: BrowserWorkerReadiness?
    var browserWorkerReadyForHandoff: Bool {
        browserWorkerReadiness?.isFresh() == true
            && browserWorkerReadiness?.readyForHandoff == true
            && !browserProtection.mayHaveLocalPauseTabs
    }
    private var lastBrowserWorkerProbe = Date.distantPast
    private var browserWorkerProbeGeneration = 0
    private var lastServiceUpdateRequest = Date.distantPast
    private var serviceUpdateRetryInterval: TimeInterval = 300
    private var isRequestingServiceUpdate = false
    @Published private(set) var adultDatabaseStatus = "Loading local adult website list…"

    func refreshAdultDatabase(force: Bool = true) async {
        await browserProtection.refreshAdultDatabase(force: force)
        adultDatabaseStatus = browserProtection.adultDatabaseStatus
    }
    private let setupProbe: (@MainActor () async -> SetupAccessState)?
    private var isCheckingSetup = false
    private var hasCheckedSetup = false

    private let service: any ProtectedServiceServing
    let appleProtection: AppleProtectionModel
    private var cancellables = Set<AnyCancellable>()
    private var secondsSinceIdleRefresh = 0
    private var browserActivity: NSObjectProtocol?
    private(set) var keepsBrowserProtectionRunning = false
    private var displayAnchor = SystemClock.read().continuousTime

    var blocks: [ProtectedBlockSnapshot] { snapshot?.blocks ?? [] }
    var activeBlocks: [ProtectedBlockSnapshot] { blocks.filter { $0.phase != .inactive } }
    var canChangeBlocks: Bool {
        setupReady && canRequestUnlock
    }
    var canRequestUnlock: Bool {
        serviceAvailability == .ready && !isBusy && !hasPendingMutation && !isInstallingService
    }
    var setupReady: Bool { setupState == .ready }
    var needsServiceUpdate: Bool {
        snapshot.map { $0.protection.serviceVersion != ProtectedServiceContract.serviceVersion } ?? false
    }
    var serviceCanUpdateWithoutApproval: Bool {
        guard let installed = Int(snapshot?.protection.serviceVersion ?? ""),
            let bundled = Int(ProtectedServiceContract.serviceVersion)
        else { return false }
        return installed >= 8 && bundled >= installed
    }
    var serviceIsHealthy: Bool {
        serviceAvailability == .ready && snapshot?.protection.isEnforcing == true
            && snapshot?.protection.issues.isEmpty == true
    }
    var setupServiceReady: Bool {
        serviceIsHealthy && snapshot?.protection.serviceVersion == ProtectedServiceContract.serviceVersion
    }
    var serviceUpdateIsOnlySetupGap: Bool {
        needsServiceUpdate && serviceIsHealthy
            && SetupReadiness.ready(
                serviceReady: true,
                access: SetupAccessState(browsers: browserReadiness, startsAtLogin: startsAtLogin)
            )
    }

    var installCommand: String? {
        guard
            let scriptURL = Bundle.main.url(
                forResource: "install-macos-service",
                withExtension: "sh"
            )
        else { return nil }
        return "sudo \(Self.shellQuote(scriptURL.path))"
    }

    init(
        service: (any ProtectedServiceServing)? = nil,
        automaticallyRefreshes: Bool = true,
        setupProbe: (@MainActor () async -> SetupAccessState)? = nil
    ) {
        let client = service ?? ProtectedServiceClient()
        self.service = client
        appleProtection = AppleProtectionModel(service: client)
        self.setupProbe = setupProbe
        guard automaticallyRefreshes else { return }
        Task {
            await refreshAdultDatabase(force: false)
            await refresh()
            await refreshSetup()
        }
        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in await self.timerFired() }
            }
            .store(in: &cancellables)
    }

    func refresh() async {
        guard !isBusy, !isRefreshing, !hasPendingMutation else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            accept(try await service.list())
            serviceAvailability = .ready
            secondsSinceIdleRefresh = 0
        } catch {
            snapshot = nil
            serviceAvailability = .unavailable(error.localizedDescription)
        }
        updateSetupState()
    }

    func create(_ draft: ProtectedBlockDraft) async -> Bool {
        await mutate { try await service.create(draft) }
    }

    /// Returns true once the plan is saved, even if starting it fails. The editor
    /// must close in that case so a retry cannot create a duplicate plan.
    func createAndActivate(_ draft: ProtectedBlockDraft) async -> Bool {
        guard await screenTimeReady(for: draft) else { return false }
        guard await adultFilterReady(for: draft.rules) else { return false }
        while isCheckingSetup {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await refresh()
        await refreshSetup()
        guard setupReady else {
            errorMessage = "Finish setup before starting a new plan."
            return false
        }
        var startWarning: String?
        var unconfirmedState = false
        let saved = await mutate {
            let validated = try draft.validatedForMutation()
            let before = try await service.list()
            let knownIDs = Set(before.blocks.map(\.id))
            let created = try await service.create(validated)
            let candidates = created.blocks.filter {
                !knownIDs.contains($0.id) && $0.draft == validated && $0.phase == .inactive
            }
            guard candidates.count == 1, let plan = candidates.first else {
                startWarning =
                    "Your plan was saved, but could not be identified safely to start it. Check Plans before trying again."
                return created
            }
            do {
                return try await service.activate(id: plan.id, expectedRevision: plan.revision)
            } catch {
                // A lost reply does not prove activation failed. Refresh if possible
                // and never claim that a potentially active plan is inactive.
                startWarning =
                    "Your plan was saved, but its start could not be confirmed. Check Plans before trying again. \(error.localizedDescription)"
                if let refreshed = try? await service.list() { return refreshed }
                unconfirmedState = true
                return created
            }
        }
        if saved, let startWarning {
            errorMessage = startWarning
            if unconfirmedState {
                snapshot = nil
                serviceAvailability = .unavailable(startWarning)
                updateSetupState()
            }
        }
        return saved
    }

    func update(
        id: UUID,
        expectedRevision: Int,
        draft: ProtectedBlockDraft
    ) async -> Bool {
        if let current = blocks.first(where: { $0.id == id }), current.phase != .inactive {
            guard await adultFilterReady(for: draft.rules) else { return false }
        }
        return await mutate {
            try await service.update(id: id, expectedRevision: expectedRevision, draft: draft)
        }
    }

    func delete(_ block: ProtectedBlockSnapshot) async -> Bool {
        await mutate {
            try await service.delete(id: block.id, expectedRevision: block.revision)
        }
    }

    func activate(_ block: ProtectedBlockSnapshot) async -> Bool {
        guard await screenTimeReady(for: block.draft) else { return false }
        guard await adultFilterReady(for: block.draft.rules) else { return false }
        while isCheckingSetup {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await refresh()
        await refreshSetup()
        guard setupReady else {
            errorMessage = "Finish setup before starting a new plan."
            return false
        }
        return await mutate {
            try await service.activate(id: block.id, expectedRevision: block.revision)
        }
    }

    private func screenTimeReady(for draft: ProtectedBlockDraft) async -> Bool {
        guard !draft.protectionMode.allowsBreaks else { return true }
        await appleProtection.refresh()
        guard appleProtection.snapshot?.phase == .active else {
            errorMessage =
                "Set up the Screen Time code before starting a Hard Pause plan. Open Screen Time protection in Settings or in the plan editor."
            return false
        }
        return true
    }

    private func adultFilterReady(for rules: ProtectedRules) async -> Bool {
        guard rules.blocksAdultWebsites else { return true }
        guard await browserProtection.hasAdultDatabase() else {
            errorMessage =
                "The adult website list must finish downloading before adult-site blocking can be enabled. Check the download in Settings."
            return false
        }
        return true
    }

    func requestBreak(for block: ProtectedBlockSnapshot) async -> Bool {
        await mutate { try await service.requestBreak(id: block.id) }
    }

    func cancelBreak(for block: ProtectedBlockSnapshot) async -> Bool {
        guard !needsServiceUpdate else {
            errorMessage = "Update Hard Pause protection before cancelling a break request."
            return false
        }
        return await mutate { try await service.cancelBreak(id: block.id) }
    }

    func requestEnd(for block: ProtectedBlockSnapshot) async -> Bool {
        let requested = await mutate { try await service.requestEnd(id: block.id) }
        if requested, !block.draft.protectionMode.allowsBreaks {
            // Start both waits together. Release still requires every plan to be inactive.
            await appleProtection.requestEnd()
            if let message = appleProtection.message,
                appleProtection.snapshot?.phase == .active || appleProtection.snapshot == nil
            {
                errorMessage = "The plan end was requested. The Screen Time wait could not start: \(message)"
            }
        }
        return requested
    }

    func chooseApplications() async -> [ProtectedApplication] {
        let panel = NSOpenPanel()
        panel.title = "Choose apps that Hard Pause will close"
        panel.prompt = "Add apps"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let response = await panel.begin()
        guard response == .OK else { return [] }
        do {
            return try panel.urls.map(Self.protectedApplication)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func copyInstallCommand() {
        guard let installCommand else {
            errorMessage = "The service installer is missing from this app build."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand, forType: .string)
    }

    func clearError() { errorMessage = nil }

    private func mutate(
        _ operation: () async throws -> ProtectedServiceSnapshot
    ) async -> Bool {
        guard serviceAvailability == .ready else {
            errorMessage = "Install and start the Hard Pause service before changing plans."
            return false
        }
        guard !isBusy, !hasPendingMutation, !isInstallingService else { return false }
        hasPendingMutation = true
        defer { hasPendingMutation = false }
        while isRefreshing {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard serviceAvailability == .ready else {
            errorMessage = "The Hard Pause service became unavailable. Check its status and try again."
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            accept(try await operation())
            serviceAvailability = .ready
            errorMessage = nil
            secondsSinceIdleRefresh = 0
            return true
        } catch {
            if let clientError = error as? ProtectedServiceClientError {
                switch clientError {
                case .unavailable(let message):
                    snapshot = nil
                    serviceAvailability = .unavailable(message)
                case .timedOut:
                    snapshot = nil
                    serviceAvailability = .unavailable(error.localizedDescription)
                case .service, .invalidReply:
                    break
                }
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func connectBrowser(_ identifier: String) async {
        guard connectingBrowserID == nil else { return }
        connectingBrowserID = identifier
        browserConnectionMessages[identifier] = nil
        defer { connectingBrowserID = nil }
        await browserProtection.requestPermission(for: identifier)
        let hadBrowserWorker = browserWorkerReadiness != nil
        if hadBrowserWorker {
            browserWorkerProbeGeneration += 1
            let generation = browserWorkerProbeGeneration
            let readiness = await browserWorker.requestPermission(for: identifier)
            if generation == browserWorkerProbeGeneration { browserWorkerReadiness = readiness }
        }
        browserStatuses = browserProtection.statuses
        adultDatabaseStatus = browserProtection.adultDatabaseStatus
        browserConnectionMessages[identifier] = browserProtection.statuses[identifier]
        if hadBrowserWorker && browserWorkerReadiness == nil {
            browserConnectionMessages[identifier] = "Hard Pause Browser Worker is unavailable."
        } else if browserWorkerReadiness?.browserAccess.first(where: { $0.identifier == identifier })?.ready == false {
            browserConnectionMessages[identifier] = "Allow Hard Pause Browser Worker to access this browser."
        }
        await refreshSetup()
    }

    /// Always asks the signed worker directly; the cached value is only for display and fallback polling.
    @discardableResult
    func probeBrowserWorkerReadiness() async -> Bool {
        lastBrowserWorkerProbe = Date()
        browserWorkerProbeGeneration += 1
        let generation = browserWorkerProbeGeneration
        var candidates = BrowserWorkerClient.installedMachServices()
        if browserWorkerReadiness != nil, !candidates.contains(browserWorker.machServiceName) {
            candidates.append(browserWorker.machServiceName)
        }
        var selected: (BrowserWorkerClient, BrowserWorkerReadiness)?
        for label in candidates {
            guard let client = BrowserWorkerClient(machServiceName: label),
                let report = await client.readiness()
            else { continue }
            if selected == nil || report.readyForHandoff {
                selected = (client, report)
            }
            if report.readyForHandoff { break }
        }
        let readiness = selected?.1
        if generation == browserWorkerProbeGeneration {
            if let selected { browserWorker = selected.0 }
            browserWorkerReadiness = readiness
        }
        if generation == browserWorkerProbeGeneration,
            readiness?.isFresh() == true, readiness?.readyForHandoff == true,
            let newPage = readiness?.pausePageURL, browserProtection.mayHaveLocalPauseTabs
        {
            _ = await browserProtection.migrateLocalPauseTabs(to: newPage)
        }
        return readiness?.isFresh() == true && readiness?.readyForHandoff == true
            && !browserProtection.mayHaveLocalPauseTabs
    }

    func enableLoginStart() {
        do {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { errorMessage = error.localizedDescription }
        Task { await refreshSetup() }
    }

    func refreshSetup() async {
        guard !isCheckingSetup else { return }
        isCheckingSetup = true
        defer { isCheckingSetup = false }
        let access: SetupAccessState
        if let setupProbe {
            access = await setupProbe()
        } else {
            // SMAppService.status performs synchronous IPC. Keep its wait off
            // the UI thread, including during trackpad momentum scrolling.
            let loginStatus = Task.detached(priority: .utility) {
                SMAppService.mainApp.status == .enabled
            }
            access = await SetupAccessState(
                browsers: browserProtection.readiness(),
                startsAtLogin: loginStatus.value)
        }
        browserReadiness = access.browsers
        startsAtLogin = access.startsAtLogin
        hasCheckedSetup = true
        updateSetupState()
    }

    func installService() async {
        guard !isInstallingService, !isRequestingServiceUpdate, !isBusy, !hasPendingMutation else {
            return
        }
        isInstallingService = true
        defer { isInstallingService = false }
        while isRefreshing {
            try? await Task.sleep(for: .milliseconds(25))
        }
        var liveUpdate = false
        var activeLegacyUpdate = false
        if serviceAvailability == .ready {
            await refresh()
            guard let snapshot else {
                errorMessage = "The protection service could not report its current state."
                return
            }
            guard let appleStatus = try? await service.appleLockdownStatus() else {
                errorMessage = "The protection service could not report Screen Time status."
                return
            }
            if snapshot.blocks.contains(where: { $0.phase != .inactive })
                || appleStatus.phase != .inactive
            {
                guard needsServiceUpdate,
                    let installedVersion = Int(snapshot.protection.serviceVersion),
                    snapshot.protection.isEnforcing,
                    snapshot.protection.issues.isEmpty
                else {
                    errorMessage = "Protection can update after all plans end or the browser worker is ready."
                    return
                }
                if installedVersion == 2 && appleStatus.phase == .inactive {
                    activeLegacyUpdate = true
                } else if installedVersion >= 8,
                    ProtectedServiceContract.liveServiceHandoffEnabled,
                    [.inactive, .active, .waitingForFullUnlock].contains(appleStatus.phase),
                    await probeBrowserWorkerReadiness()
                {
                    liveUpdate = true
                } else {
                    errorMessage = "Protection can update after all plans end or the browser worker is ready."
                    return
                }
            }
        }
        do {
            if serviceCanUpdateWithoutApproval {
                _ = try await service.requestManagedUpdate(bundlePath: Bundle.main.bundleURL.path)
                lastServiceUpdateRequest = Date()
            } else {
                try await ServiceInstaller.install(
                    updateExisting: needsServiceUpdate,
                    liveUpdate: liveUpdate,
                    activeLegacyUpdate: activeLegacyUpdate
                )
            }
            await refresh()
            await refreshSetup()
        } catch InstallerError.cancelled {
            // Cancelling the system password prompt simply leaves setup incomplete.
        } catch InstallerError.failed(let message) {
            errorMessage = message
        } catch {
            errorMessage = "Installation did not finish. Try again."
        }
    }

    private func updateSetupState() {
        guard hasCheckedSetup, serviceAvailability != .checking else {
            setupState = .checking
            return
        }
        setupState =
            SetupReadiness.ready(
                serviceReady: setupServiceReady,
                access: SetupAccessState(browsers: browserReadiness, startsAtLogin: startsAtLogin)
            ) ? .ready : .incomplete
    }

    private func timerFired() async {
        guard !isBusy, !isRefreshing else { return }
        displayElapsed = max(0, SystemClock.read().continuousTime - displayAnchor)
        secondsSinceIdleRefresh += 1
        if secondsSinceIdleRefresh >= 2 {
            await refresh()
            await refreshSetup()
        }
        if Date().timeIntervalSince(lastBrowserWorkerProbe) >= (browserWorkerReadiness == nil ? 10 : 4) {
            lastBrowserWorkerProbe = Date()
            Task { _ = await probeBrowserWorkerReadiness() }
        }
        await requestAutomaticServiceUpdateIfReady()
        if let worker = browserWorkerReadiness, worker.isFresh(), worker.readyForHandoff {
            browserStatuses = worker.browserStatuses
            return
        }
        await browserProtection.check(snapshot: snapshot) { [weak self] in self?.snapshot }
        browserStatuses = browserProtection.statuses
        adultDatabaseStatus = browserProtection.adultDatabaseStatus
    }

    private func requestAutomaticServiceUpdateIfReady() async {
        guard serviceCanUpdateWithoutApproval,
            !isRequestingServiceUpdate, !isInstallingService, !isBusy, !hasPendingMutation,
            snapshot?.protection.isEnforcing == true,
            snapshot?.protection.issues.isEmpty == true,
            Date().timeIntervalSince(lastServiceUpdateRequest) >= serviceUpdateRetryInterval
        else { return }
        guard let status = try? await service.updateInstallationStatus(),
            status.serviceVersion == snapshot?.protection.serviceVersion,
            let bundleBuildText = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            let bundleBuild = UInt64(bundleBuildText),
            bundleBuild > status.installedAppBuild
        else { return }
        guard let appleStatus = try? await service.appleLockdownStatus() else { return }
        let hasActiveBlock =
            snapshot?.blocks.contains { $0.phase != .inactive } == true
            || appleStatus.phase != .inactive
        guard
            !hasActiveBlock
                || (ProtectedServiceContract.liveServiceHandoffEnabled
                    && browserWorkerReadyForHandoff
                    && [.inactive, .active, .waitingForFullUnlock].contains(appleStatus.phase))
        else { return }
        isRequestingServiceUpdate = true
        defer { isRequestingServiceUpdate = false }
        if hasActiveBlock {
            guard await probeBrowserWorkerReadiness() else { return }
        }
        lastServiceUpdateRequest = Date()
        do {
            _ = try await service.requestManagedUpdate(bundlePath: Bundle.main.bundleURL.path)
            serviceUpdateRetryInterval = 300
        } catch {
            serviceUpdateRetryInterval = 30
            NSLog("Hard Pause automatic service update request failed: %@", error.localizedDescription)
            errorMessage = "Protection could not start its update. Use Update protection to try again."
        }
    }

    private func accept(_ nextSnapshot: ProtectedServiceSnapshot) {
        snapshot = nextSnapshot
        keepsBrowserProtectionRunning = nextSnapshot.blocks.contains {
            $0.phase != .inactive
                && (!$0.draft.rules.allBlockedDomains.isEmpty || !$0.draft.rules.blockedURLPatterns.isEmpty
                    || $0.draft.rules.blocksAdultWebsites)
        }
        if keepsBrowserProtectionRunning && browserActivity == nil {
            browserActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Check browser pages during an active Hard Pause block"
            )
        } else if !keepsBrowserProtectionRunning, let activity = browserActivity {
            ProcessInfo.processInfo.endActivity(activity)
            browserActivity = nil
        }
        displayAnchor = SystemClock.read().continuousTime
        displayElapsed = 0
    }

    private static func protectedApplication(at url: URL) throws -> ProtectedApplication {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
            throw ApplicationSelectionError.invalidBundle(url.lastPathComponent)
        }
        let name =
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent

        var staticCode: SecStaticCode?
        var result = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard result == errSecSuccess, let staticCode else {
            throw ApplicationSelectionError.cannotReadIdentity(name, result)
        }
        result = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil)
        guard result == errSecSuccess else {
            throw ApplicationSelectionError.invalidSignature(name, result)
        }
        var requirement: SecRequirement?
        result = SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement)
        guard result == errSecSuccess, let requirement else {
            throw ApplicationSelectionError.cannotReadIdentity(name, result)
        }
        var requirementText: CFString?
        result = SecRequirementCopyString(requirement, SecCSFlags(), &requirementText)
        guard result == errSecSuccess, let requirementText else {
            throw ApplicationSelectionError.cannotReadIdentity(name, result)
        }
        return ProtectedApplication(
            bundleIdentifier: identifier,
            displayName: name,
            designatedRequirement: requirementText as String
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private enum ApplicationSelectionError: LocalizedError {
    case invalidBundle(String)
    case cannotReadIdentity(String, OSStatus)
    case invalidSignature(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidBundle(let name):
            return "\(name) is not an application bundle."
        case .cannotReadIdentity(let name, let status):
            return "Hard Pause could not read the signed identity for \(name) (\(status))."
        case .invalidSignature(let name, let status):
            return "\(name) does not have a valid code signature (\(status))."
        }
    }
}
