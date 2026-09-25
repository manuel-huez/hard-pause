import Foundation
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    func testActivationRechecksPermissionAndUnlockRemainsAvailable() async {
        let status = ProtectionStatus(
            serviceVersion: ProtectedServiceContract.serviceVersion, isEnforcing: true, lastAppliedAt: Date(),
            issues: [], recentApplicationClosures: [])
        let snapshot = ProtectedState().snapshot(at: Date(), protection: status)
        let service = ControlledProtectedService(snapshot: snapshot)
        var permission = BrowserPermissionState.granted
        let model = AppModel(
            service: service, automaticallyRefreshes: false,
            setupProbe: {
                SetupAccessState(
                    browsers: [
                        BrowserSetupState(id: "browser", name: "Browser", isInstalled: true, permission: permission)
                    ], startsAtLogin: true)
            })
        await model.refresh()
        await model.refreshSetup()
        XCTAssertTrue(model.setupReady)

        let block = ProtectedBlockSnapshot(
            id: UUID(), revision: 1,
            draft: ProtectedBlockDraft(
                name: "Test",
                rules: ProtectedRules(
                    blockedDomains: ["example.com"], blockedApplications: [], blocksStarterAdultSites: false),
                breakDelay: 60, fullUnlockDelay: 60, breakDuration: 60, elapsedDuration: nil),
            phase: .active(naturalEndRemaining: nil))
        permission = .denied
        let activated = await model.activate(block)
        XCTAssertFalse(activated)
        XCTAssertEqual(service.activationCalls, 0)
        XCTAssertFalse(model.canChangeBlocks)
        XCTAssertTrue(model.canRequestUnlock)
        let ended = await model.requestEnd(for: block)
        XCTAssertTrue(ended)
        XCTAssertEqual(service.endCalls, 1)

        permission = .granted
        let readyActivation = await model.activate(block)
        XCTAssertTrue(readyActivation)
        XCTAssertEqual(service.activationCalls, 1)
    }

    func testCreateSavesPlanWithoutActivatingIt() async {
        let draft = makeDraft()
        let created = makeBlock(draft: draft)
        let service = ControlledProtectedService(
            snapshot: makeSnapshot(),
            createResponse: makeSnapshot(blocks: [created])
        )
        let model = AppModel(service: service, automaticallyRefreshes: false)

        await model.refresh()
        let saved = await model.create(draft)

        XCTAssertTrue(saved)
        XCTAssertEqual(service.createCalls, 1)
        XCTAssertEqual(service.activationCalls, 0)
        XCTAssertEqual(model.blocks.map(\.id), [created.id])
    }

    func testCreateAndActivateStartsTheNewMatchingPlanDespitePreexistingPlans() async {
        let draft = makeDraft()
        let preexisting = makeBlock(revision: 3, draft: draft)
        let created = makeBlock(revision: 7, draft: draft)
        let active = makeBlock(
            id: created.id,
            revision: 8,
            draft: draft,
            phase: .active(naturalEndRemaining: nil)
        )
        let service = ControlledProtectedService(
            snapshot: makeSnapshot(blocks: [preexisting]),
            createResponse: makeSnapshot(blocks: [preexisting, created]),
            activationResponse: makeSnapshot(blocks: [preexisting, active])
        )
        let model = makeReadyModel(service: service)

        let started = await model.createAndActivate(draft)

        XCTAssertTrue(started)
        XCTAssertEqual(service.createCalls, 1)
        XCTAssertEqual(service.activationCalls, 1)
        XCTAssertEqual(service.lastActivationID, created.id)
        XCTAssertEqual(service.lastActivationRevision, created.revision)
        XCTAssertEqual(model.blocks.first(where: { $0.id == created.id })?.phase, active.phase)
    }

    func testCreateAndActivateDoesNotCreateOrStartWhenSetupIsDenied() async {
        let draft = makeDraft()
        let service = ControlledProtectedService(snapshot: makeSnapshot())
        let model = AppModel(
            service: service,
            automaticallyRefreshes: false,
            setupProbe: {
                SetupAccessState(
                    browsers: [
                        BrowserSetupState(
                            id: "browser",
                            name: "Browser",
                            isInstalled: true,
                            permission: .denied
                        )
                    ],
                    startsAtLogin: true
                )
            }
        )

        let started = await model.createAndActivate(draft)

        XCTAssertFalse(started)
        XCTAssertEqual(service.createCalls, 0)
        XCTAssertEqual(service.activationCalls, 0)
        XCTAssertEqual(model.errorMessage, "Finish setup before starting a new plan.")
    }

    func testHardPausePreflightDoesNotCreateOrActivateWithoutActiveScreenTimeProtection() async {
        for phase in [AppleLockdownPhase.inactive, .pendingSetup] {
            let operationID = phase == .pendingSetup ? UUID() : nil
            let service = ControlledProtectedService(
                snapshot: makeSnapshot(),
                appleSnapshot: makeAppleSnapshot(phase: phase, operationID: operationID)
            )
            let model = makeReadyModel(service: service)

            let started = await model.createAndActivate(
                makeDraft(protectionMode: .lockdown)
            )

            XCTAssertFalse(started, "phase=\(phase)")
            XCTAssertEqual(service.appleStatusCalls, 1, "phase=\(phase)")
            XCTAssertEqual(service.createCalls, 0, "phase=\(phase)")
            XCTAssertEqual(service.activationCalls, 0, "phase=\(phase)")
            XCTAssertEqual(
                model.errorMessage,
                "Set up the Screen Time code before starting a Hard Pause plan. Open Screen Time protection in Settings."
            )
        }
    }

    func testHardPauseRequestEndStartsPlanAndScreenTimeWaits() async {
        let draft = makeDraft(protectionMode: .lockdown)
        let id = UUID()
        let active = makeBlock(
            id: id,
            revision: 2,
            draft: draft,
            phase: .active(naturalEndRemaining: nil)
        )
        let waiting = makeBlock(
            id: id,
            revision: 3,
            draft: draft,
            phase: .waitingForFullUnlock(remaining: 60, naturalEndRemaining: nil)
        )
        let appleWaiting = makeAppleSnapshot(
            phase: .waitingForFullUnlock,
            remainingDelay: 86_400
        )
        let service = ControlledProtectedService(
            snapshot: makeSnapshot(blocks: [active]),
            endResponse: makeSnapshot(blocks: [waiting]),
            appleSnapshot: makeAppleSnapshot(phase: .active),
            appleEndResponse: appleWaiting
        )
        let model = AppModel(service: service, automaticallyRefreshes: false)
        await model.refresh()

        let ended = await model.requestEnd(for: active)

        XCTAssertTrue(ended)
        XCTAssertEqual(service.endCalls, 1)
        XCTAssertEqual(service.appleEndCalls, 1)
        XCTAssertEqual(model.blocks, [waiting])
        XCTAssertEqual(model.appleProtection.snapshot, appleWaiting)
        XCTAssertNil(model.errorMessage)
    }

    func testCreateAndActivateKeepsSavedPlanAndShowsWarningWhenActivationFails() async {
        let draft = makeDraft()
        let created = makeBlock(draft: draft)
        let service = ControlledProtectedService(
            snapshot: makeSnapshot(),
            createResponse: makeSnapshot(blocks: [created]),
            activationError: .failed
        )
        let model = makeReadyModel(service: service)

        let started = await model.createAndActivate(draft)

        XCTAssertTrue(started)
        XCTAssertEqual(service.createCalls, 1)
        XCTAssertEqual(service.activationCalls, 1)
        XCTAssertEqual(model.blocks, [created])
        XCTAssertEqual(
            model.errorMessage,
            "Your plan was saved, but its start could not be confirmed. Check Plans before trying again. Activation failed."
        )
    }

    func testCreateAndActivateKeepsSavedPlanWhenActivationAndStateCheckFail() async {
        let draft = makeDraft()
        let created = makeBlock(draft: draft)
        let service = ControlledProtectedService(
            snapshot: makeSnapshot(),
            createResponse: makeSnapshot(blocks: [created]),
            activationError: .failed,
            failsNextListAfterActivation: true
        )
        let model = makeReadyModel(service: service)

        let started = await model.createAndActivate(draft)

        XCTAssertTrue(started)
        XCTAssertEqual(service.createCalls, 1)
        XCTAssertEqual(service.activationCalls, 1)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(
            model.serviceAvailability,
            .unavailable(
                "Your plan was saved, but its start could not be confirmed. Check Plans before trying again. Activation failed."
            )
        )
    }

    func testCreateAndActivateDoesNotStartWhenMultipleNewPlansMatch() async {
        let draft = makeDraft()
        let first = makeBlock(draft: draft)
        let second = makeBlock(draft: draft)
        let service = ControlledProtectedService(
            snapshot: makeSnapshot(),
            createResponse: makeSnapshot(blocks: [first, second])
        )
        let model = makeReadyModel(service: service)

        let started = await model.createAndActivate(draft)

        XCTAssertTrue(started)
        XCTAssertEqual(service.createCalls, 1)
        XCTAssertEqual(service.activationCalls, 0)
        XCTAssertEqual(
            model.errorMessage,
            "Your plan was saved, but could not be identified safely to start it. Check Plans before trying again."
        )
    }

    func testSetupRequiresServiceLoginAndEveryInstalledBrowser() {
        let granted = BrowserSetupState(id: "a", name: "A", isInstalled: true, permission: .granted)
        let missing = BrowserSetupState(id: "b", name: "B", isInstalled: false, permission: .unavailable)
        XCTAssertTrue(
            SetupReadiness.ready(
                serviceReady: true, access: SetupAccessState(browsers: [granted, missing], startsAtLogin: true)))
        for permission in [BrowserPermissionState.unknown, .denied, .unavailable] {
            let blocked = BrowserSetupState(id: "c", name: "C", isInstalled: true, permission: permission)
            XCTAssertFalse(
                SetupReadiness.ready(
                    serviceReady: true, access: SetupAccessState(browsers: [granted, blocked], startsAtLogin: true)))
        }
        XCTAssertFalse(
            SetupReadiness.ready(
                serviceReady: false, access: SetupAccessState(browsers: [granted], startsAtLogin: true)))
        XCTAssertFalse(
            SetupReadiness.ready(
                serviceReady: true, access: SetupAccessState(browsers: [granted], startsAtLogin: false)))
    }

    func testPreviouslyApprovedClosedBrowserKeepsSetupComplete() {
        let closed = BrowserSetupState(
            id: "com.apple.Safari", name: "Safari", isInstalled: true, permission: .previouslyGranted)
        XCTAssertTrue(
            SetupReadiness.ready(
                serviceReady: true, access: SetupAccessState(browsers: [closed], startsAtLogin: true)))
        for permission in [BrowserPermissionState.denied, .unknown] {
            let unapproved = BrowserSetupState(
                id: closed.id, name: closed.name, isInstalled: true, permission: permission)
            XCTAssertFalse(
                SetupReadiness.ready(
                    serviceReady: true, access: SetupAccessState(browsers: [unapproved], startsAtLogin: true)))
        }
    }

    func testInstallerQuotesPathsAsDataAtBothBoundaries() {
        XCTAssertEqual(ServiceInstaller.shellQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(ServiceInstaller.appleScriptQuote("a\\b\"c"), "\"a\\\\b\\\"c\"")
        XCTAssertEqual(ServiceInstaller.shellQuote("$(touch nope)`nope`"), "'$(touch nope)`nope`'")
    }

    func testInstallationRejectsConcurrentMutationsBeforeItsStateCheckFinishes() async {
        let active = makeBlock(draft: makeDraft(), phase: .active(naturalEndRemaining: nil))
        let service = ControlledProtectedService(snapshot: makeSnapshot(blocks: [active]))
        let model = AppModel(service: service, automaticallyRefreshes: false)
        await model.refresh()
        service.suspendNextList()
        let installation = Task { await model.installService() }
        while !model.isRefreshing { await Task.yield() }

        XCTAssertTrue(model.isInstallingService)
        let saved = await model.create(makeDraft())
        XCTAssertFalse(saved)
        XCTAssertEqual(service.createCalls, 0)
        await model.installService()

        service.resumeList()
        await installation.value
        XCTAssertFalse(model.isInstallingService)
        XCTAssertNotNil(model.errorMessage)
    }

    func testRefreshKeepsKnownStateWhileNextServiceCheckIsPending() async throws {
        let expected = ProtectedState().snapshot(
            at: Date(timeIntervalSince1970: 100),
            protection: .unavailable
        )
        let service = ControlledProtectedService(snapshot: expected)
        let model = AppModel(service: service, automaticallyRefreshes: false)

        await model.refresh()
        XCTAssertEqual(model.snapshot, expected)
        XCTAssertEqual(model.serviceAvailability, .ready)

        service.suspendNextList()
        let refresh = Task { await model.refresh() }
        while !model.isRefreshing { await Task.yield() }

        XCTAssertEqual(model.snapshot, expected)
        XCTAssertEqual(model.serviceAvailability, .ready)

        service.resumeList()
        await refresh.value
        XCTAssertEqual(model.snapshot, expected)
        XCTAssertEqual(model.serviceAvailability, .ready)
    }

    func testCancelBreakUsesServiceAndAcceptsActiveSnapshot() async {
        let draft = makeDraft()
        let id = UUID()
        let waiting = makeBlock(
            id: id,
            revision: 3,
            draft: draft,
            phase: .waitingForBreak(remaining: 45, naturalEndRemaining: nil)
        )
        let active = makeBlock(
            id: id,
            revision: 4,
            draft: draft,
            phase: .active(naturalEndRemaining: nil)
        )
        let service = ControlledProtectedService(
            snapshot: makeSnapshot(blocks: [waiting]),
            cancelBreakResponse: makeSnapshot(blocks: [active])
        )
        let model = AppModel(service: service, automaticallyRefreshes: false)
        await model.refresh()

        let cancelled = await model.cancelBreak(for: waiting)

        XCTAssertTrue(cancelled)
        XCTAssertEqual(service.cancelBreakCalls, 1)
        XCTAssertEqual(service.lastCancelledBreakID, id)
        XCTAssertEqual(model.blocks, [active])
    }

    func testCancelBreakDoesNotCallOlderServiceInterface() async {
        let draft = makeDraft()
        let waiting = makeBlock(
            draft: draft,
            phase: .waitingForBreak(remaining: 45, naturalEndRemaining: nil)
        )
        let service = ControlledProtectedService(
            snapshot: makeSnapshot(blocks: [waiting], serviceVersion: "2")
        )
        let model = AppModel(service: service, automaticallyRefreshes: false)
        await model.refresh()

        let cancelled = await model.cancelBreak(for: waiting)

        XCTAssertFalse(cancelled)
        XCTAssertEqual(service.cancelBreakCalls, 0)
        XCTAssertEqual(
            model.errorMessage,
            "Update Hard Pause protection before cancelling a break request."
        )
    }

    private func makeDraft(
        name: String = "Test",
        protectionMode: ProtectionMode = .softLock
    ) -> ProtectedBlockDraft {
        ProtectedBlockDraft(
            name: name,
            rules: ProtectedRules(
                blockedDomains: ["example.com"],
                blockedApplications: [],
                blocksStarterAdultSites: false
            ),
            protectionMode: protectionMode,
            breakDelay: 60,
            fullUnlockDelay: 60,
            breakDuration: 60,
            elapsedDuration: nil
        )
    }

    private func makeBlock(
        id: UUID = UUID(),
        revision: Int = 1,
        draft: ProtectedBlockDraft,
        phase: ProtectedBlockPhase = .inactive
    ) -> ProtectedBlockSnapshot {
        ProtectedBlockSnapshot(id: id, revision: revision, draft: draft, phase: phase)
    }

    private func makeSnapshot(
        blocks: [ProtectedBlockSnapshot] = [],
        serviceVersion: String = ProtectedServiceContract.serviceVersion
    ) -> ProtectedServiceSnapshot {
        ProtectedServiceSnapshot(
            generatedAt: Date(timeIntervalSince1970: 100),
            blocks: blocks,
            effectiveRestrictions: EffectiveRestrictions(
                blockedDomains: [],
                blockedApplications: [],
                contributingBlockIDs: []
            ),
            protection: ProtectionStatus(
                serviceVersion: serviceVersion,
                isEnforcing: true,
                lastAppliedAt: Date(timeIntervalSince1970: 100),
                issues: [],
                recentApplicationClosures: []
            )
        )
    }

    private func makeAppleSnapshot(
        phase: AppleLockdownPhase,
        remainingDelay: TimeInterval? = nil,
        operationID: UUID? = nil
    ) -> AppleLockdownSnapshot {
        AppleLockdownSnapshot(
            phase: phase,
            fullUnlockDelay: phase == .inactive ? nil : 86_400,
            remainingDelay: remainingDelay,
            enablesAdultFilter: false,
            filterWasAlreadyEnabled: false,
            shareAcrossDevicesVerified: nil,
            mirroredDomains: [],
            mirroredAllowedDomains: [],
            operationID: operationID
        )
    }

    private func makeReadyModel(service: ControlledProtectedService) -> AppModel {
        AppModel(
            service: service,
            automaticallyRefreshes: false,
            setupProbe: {
                SetupAccessState(
                    browsers: [
                        BrowserSetupState(
                            id: "browser",
                            name: "Browser",
                            isInstalled: true,
                            permission: .granted
                        )
                    ],
                    startsAtLogin: true
                )
            }
        )
    }
}

@MainActor
private final class ControlledProtectedService: ProtectedServiceServing {
    private(set) var activationCalls = 0
    private(set) var createCalls = 0
    private(set) var cancelBreakCalls = 0
    private(set) var endCalls = 0
    private(set) var appleStatusCalls = 0
    private(set) var appleEndCalls = 0
    private(set) var lastActivationID: UUID?
    private(set) var lastActivationRevision: Int?
    private(set) var lastCancelledBreakID: UUID?
    private var snapshot: ProtectedServiceSnapshot
    private let createResponse: ProtectedServiceSnapshot?
    private let activationResponse: ProtectedServiceSnapshot?
    private let cancelBreakResponse: ProtectedServiceSnapshot?
    private let endResponse: ProtectedServiceSnapshot?
    private var appleSnapshot: AppleLockdownSnapshot?
    private let appleEndResponse: AppleLockdownSnapshot?
    private let activationError: ControlledServiceError?
    private let failsNextListAfterActivation: Bool
    private var shouldFailNextList = false
    private var shouldSuspendList = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        snapshot: ProtectedServiceSnapshot,
        createResponse: ProtectedServiceSnapshot? = nil,
        activationResponse: ProtectedServiceSnapshot? = nil,
        cancelBreakResponse: ProtectedServiceSnapshot? = nil,
        endResponse: ProtectedServiceSnapshot? = nil,
        appleSnapshot: AppleLockdownSnapshot? = nil,
        appleEndResponse: AppleLockdownSnapshot? = nil,
        activationError: ControlledServiceError? = nil,
        failsNextListAfterActivation: Bool = false
    ) {
        self.snapshot = snapshot
        self.createResponse = createResponse
        self.activationResponse = activationResponse
        self.cancelBreakResponse = cancelBreakResponse
        self.endResponse = endResponse
        self.appleSnapshot = appleSnapshot
        self.appleEndResponse = appleEndResponse
        self.activationError = activationError
        self.failsNextListAfterActivation = failsNextListAfterActivation
    }

    func suspendNextList() {
        shouldSuspendList = true
    }

    func resumeList() {
        continuation?.resume()
        continuation = nil
    }

    func list() async throws -> ProtectedServiceSnapshot {
        if shouldSuspendList {
            shouldSuspendList = false
            await withCheckedContinuation { continuation = $0 }
        }
        if shouldFailNextList {
            shouldFailNextList = false
            throw ControlledServiceError.listFailed
        }
        return snapshot
    }

    func create(_ draft: ProtectedBlockDraft) async throws -> ProtectedServiceSnapshot {
        createCalls += 1
        if let createResponse {
            snapshot = createResponse
        }
        return snapshot
    }

    func update(
        id: UUID,
        expectedRevision: Int,
        draft: ProtectedBlockDraft
    ) async throws -> ProtectedServiceSnapshot {
        snapshot
    }

    func delete(id: UUID, expectedRevision: Int) async throws -> ProtectedServiceSnapshot {
        snapshot
    }

    func activate(id: UUID, expectedRevision: Int) async throws -> ProtectedServiceSnapshot {
        activationCalls += 1
        lastActivationID = id
        lastActivationRevision = expectedRevision
        if let activationError {
            shouldFailNextList = failsNextListAfterActivation
            throw activationError
        }
        if let activationResponse {
            snapshot = activationResponse
        }
        return snapshot
    }

    func requestBreak(id: UUID) async throws -> ProtectedServiceSnapshot {
        snapshot
    }

    func cancelBreak(id: UUID) async throws -> ProtectedServiceSnapshot {
        cancelBreakCalls += 1
        lastCancelledBreakID = id
        if let cancelBreakResponse {
            snapshot = cancelBreakResponse
        }
        return snapshot
    }

    func requestEnd(id: UUID) async throws -> ProtectedServiceSnapshot {
        endCalls += 1
        if let endResponse { snapshot = endResponse }
        return snapshot
    }

    func appleLockdownStatus() async throws -> AppleLockdownSnapshot {
        appleStatusCalls += 1
        guard let appleSnapshot else { throw AppleLockdownError.unavailable }
        return appleSnapshot
    }

    func requestAppleLockdownEnd() async throws -> AppleLockdownSnapshot {
        appleEndCalls += 1
        guard let appleEndResponse else { throw AppleLockdownError.unavailable }
        appleSnapshot = appleEndResponse
        return appleEndResponse
    }
}

private enum ControlledServiceError: LocalizedError {
    case failed
    case listFailed

    var errorDescription: String? {
        switch self {
        case .failed: return "Activation failed."
        case .listFailed: return "State check failed."
        }
    }
}
