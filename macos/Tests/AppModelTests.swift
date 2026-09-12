import Foundation
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    func testActivationRechecksPermissionAndUnlockRemainsAvailable() async {
        let status = ProtectionStatus(
            serviceVersion: "1", isEnforcing: true, lastAppliedAt: Date(), issues: [], recentApplicationClosures: [])
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

    func testInstallerQuotesPathsAsDataAtBothBoundaries() {
        XCTAssertEqual(ServiceInstaller.shellQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(ServiceInstaller.appleScriptQuote("a\\b\"c"), "\"a\\\\b\\\"c\"")
        XCTAssertEqual(ServiceInstaller.shellQuote("$(touch nope)`nope`"), "'$(touch nope)`nope`'")
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
}

@MainActor
private final class ControlledProtectedService: ProtectedServiceServing {
    private(set) var activationCalls = 0
    private(set) var endCalls = 0
    private let snapshot: ProtectedServiceSnapshot
    private var shouldSuspendList = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(snapshot: ProtectedServiceSnapshot) {
        self.snapshot = snapshot
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
        return snapshot
    }

    func create(_ draft: ProtectedBlockDraft) async throws -> ProtectedServiceSnapshot {
        snapshot
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
        return snapshot
    }

    func requestBreak(id: UUID) async throws -> ProtectedServiceSnapshot {
        snapshot
    }

    func requestEnd(id: UUID) async throws -> ProtectedServiceSnapshot {
        endCalls += 1
        return snapshot
    }
}
