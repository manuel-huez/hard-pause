import XCTest

@MainActor
final class AppleProtectionModelTests: XCTestCase {
    func testRefreshRestoresLegacyAgeSettingWithoutSetupReleaseOrWebsiteChanges() async {
        let events = AppleProtectionEventLog()
        let restriction = AppleAppAgeRestriction(baseline: .eighteen)
        let snapshot = makeSnapshot(phase: .waitingForFullUnlock, appAgeRestriction: restriction)
        let service = FakeAppleProtectionService(events: events, snapshot: snapshot)
        let operationID = UUID()
        service.ageRestorationOperation = makeOperation(id: operationID, snapshot: snapshot)
        let automation = FakeAppleScreenTimeAutomation(events: events)
        let model = AppleProtectionModel(service: service, automation: automation, hasProAccess: false)

        await model.refresh()

        XCTAssertEqual(
            events.values, ["status", "begin app age restoration", "restore app age", "complete app age restoration"])
        XCTAssertEqual(automation.restoredAgeRestrictions, [restriction])
        XCTAssertEqual(service.ageRestorationProof?.operationID, operationID)
        XCTAssertEqual(service.ageRestorationProof?.verifiedAppRating, .eighteen)
        var expected = snapshot
        expected.appAgeRestriction = nil
        XCTAssertEqual(model.snapshot, expected)
        XCTAssertFalse(model.hasError)
    }

    func testFailedAgeRestorationKeepsBaselineAndDoesNotCompleteOrRepeatOnEveryRefresh() async {
        for completionFailure in [false, true] {
            let events = AppleProtectionEventLog()
            let snapshot = makeSnapshot(phase: .active, appAgeRestriction: AppleAppAgeRestriction(baseline: .unrated))
            let service = FakeAppleProtectionService(events: events, snapshot: snapshot)
            service.ageRestorationOperation = makeOperation(id: UUID(), snapshot: snapshot)
            let automation = FakeAppleScreenTimeAutomation(events: events)
            if completionFailure {
                service.ageRestorationCompletionError = AppleLockdownError.stateUnavailable
            } else {
                automation.restoreAgeError = AppleScreenTimeAutomationError.appRestrictionNotVerified
            }
            let model = AppleProtectionModel(service: service, automation: automation)

            await model.refresh()
            await model.refresh()

            XCTAssertEqual(model.snapshot, snapshot)
            XCTAssertNil(service.ageRestorationProof)
            XCTAssertEqual(events.values.filter { $0 == "restore app age" }.count, 1)
            XCTAssertTrue(model.hasError)
        }
    }

    func testSharingStopsBeforeCredentialCreationForExistingSetupOrAppleWarning() async {
        for phase in [AppleLockdownPhase.active, .inactive] {
            let events = AppleProtectionEventLog()
            let service = FakeAppleProtectionService(events: events, snapshot: makeSnapshot(phase: phase))
            let automation = FakeAppleScreenTimeAutomation(events: events)
            automation.sharingError = AppleScreenTimeAutomationError.sharingRequired
            let model = AppleProtectionModel(service: service, automation: automation)

            await model.setUp(enablesAdultFilter: false, existingPasscode: nil)

            XCTAssertNil(service.setupRequest)
            XCTAssertFalse(events.values.contains("inspect"))
            XCTAssertFalse(events.values.contains("install"))
            XCTAssertEqual(events.values.contains("enable sharing"), phase == .inactive)
            XCTAssertTrue(model.hasError)
        }
    }

    func testMalformedOriginalCodeDoesNotCreateASetupOperation() async {
        let events = AppleProtectionEventLog()
        let service = FakeAppleProtectionService(events: events, snapshot: makeSnapshot(phase: .inactive))
        let automation = FakeAppleScreenTimeAutomation(events: events)
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.setUp(enablesAdultFilter: true, existingPasscode: "123")

        XCTAssertEqual(events.values, ["status"])
        XCTAssertNil(service.setupDelay)
        XCTAssertEqual(model.snapshot?.phase, .inactive)
        XCTAssertTrue(model.hasError)
    }

    func testSetupRequiresProWithoutScreenTimeOrServiceOperations() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = AppleProtectionEventLog()
        let service = FakeAppleProtectionService(events: events, snapshot: makeSnapshot(phase: .inactive))
        let automation = FakeAppleScreenTimeAutomation(events: events)
        let model = AppleProtectionModel(
            service: service, automation: automation,
            operationLockURL: directory.appendingPathComponent("native.lock"), hasProAccess: false)

        await model.setUp(enablesAdultFilter: true, existingPasscode: nil)

        XCTAssertFalse(model.hasProAccess)
        XCTAssertEqual(events.values, [])
        XCTAssertNil(service.setupDelay)
        XCTAssertNil(model.codeCheck)
        XCTAssertEqual(model.message, "Pro access is required to set up Screen Time.")
        XCTAssertTrue(model.hasError)
    }

    func testNativeCheckCannotInterruptWebsiteSyncAcrossAppModels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("native.lock")
        let events = AppleProtectionEventLog()
        let service = FakeAppleProtectionService(events: events, snapshot: makeSnapshot(phase: .active))
        service.websiteOperation = AppleWebsiteSyncOperation(
            passcode: "1234", activeDomains: [], activeAllowedDomains: [],
            mirroredDomains: [], mirroredAllowedDomains: [])
        let automation = FakeAppleScreenTimeAutomation(events: events)
        automation.websites = AppleScreenTimeWebsites(
            restricted: [], allowed: [], restrictedEntries: [], allowedEntries: [])
        let entered = expectation(description: "Native list inspection started")
        var resume: CheckedContinuation<Void, Never>?
        automation.onInspectWebsites = {
            await withCheckedContinuation {
                resume = $0
                entered.fulfill()
            }
        }
        let model = AppleProtectionModel(
            service: service, automation: automation, operationLockURL: lockURL, hasProAccess: false)
        let second = AppleProtectionModel(service: service, automation: automation, operationLockURL: lockURL)
        let sync = Task { await model.syncWebsites() }
        await fulfillment(of: [entered], timeout: 2)

        await model.inspectSettings()
        await second.inspectSettings()
        XCTAssertEqual(model.activity, .syncingWebsites)
        XCTAssertFalse(events.values.contains("inspect code"))
        XCTAssertTrue(second.hasError)

        resume?.resume()
        let synced = await sync.value
        XCTAssertTrue(synced)
        XCTAssertNil(model.activity)
        XCTAssertFalse(model.websiteSyncNeedsRetry)
        await second.inspectSettings()
        XCTAssertTrue(events.values.contains("inspect code"))
        XCTAssertFalse(second.hasError)

        events.removeAll()
        automation.websiteReadError = AppleScreenTimeAutomationError.settingsNotResponding
        let failed = await model.syncWebsites()
        XCTAssertFalse(failed)
        await second.inspectSettings()
        XCTAssertTrue(events.values.contains("inspect code"))
        XCTAssertFalse(second.hasError)
    }

    func testCheckingExistingCodeDoesNotStartSetupOrClaimOwnership() async {
        let events = AppleProtectionEventLog()
        let service = FakeAppleProtectionService(events: events, snapshot: makeSnapshot(phase: .inactive))
        let automation = FakeAppleScreenTimeAutomation(events: events)
        automation.inspection = AppleScreenTimeInspection(
            hasPasscode: true,
            adultFilterEnabled: false
        )
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.inspectSettings()

        XCTAssertEqual(events.values, ["inspect code"])
        XCTAssertEqual(model.codeCheck, true)
        XCTAssertNil(model.message)
    }

    func testSetupBeginsProtectedOperationBeforeNativeInstallAndVerification() async {
        let events = AppleProtectionEventLog()
        let operationID = UUID()
        let pending = makeSnapshot(
            phase: .pendingSetup, operationID: operationID, shareAcrossDevicesVerified: true)
        let active = makeSnapshot(phase: .active)
        let service = FakeAppleProtectionService(
            events: events,
            snapshot: makeSnapshot(phase: .inactive),
            setupOperation: makeOperation(id: operationID, snapshot: pending),
            completedSetupSnapshot: active
        )
        let automation = FakeAppleScreenTimeAutomation(events: events)
        automation.inspection.appAgeRating = .eighteen
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.setUp(enablesAdultFilter: true, existingPasscode: nil)

        XCTAssertTrue(model.hasProAccess)
        XCTAssertEqual(
            events.values,
            ["status", "enable sharing", "inspect", "begin setup", "install", "verify", "complete setup"]
        )
        XCTAssertEqual(service.completedSetupOperationIDs, [operationID])
        XCTAssertEqual(service.setupDelay, 0)
        XCTAssertNil(service.setupRequest?.appAgeRestriction)
        XCTAssertEqual(service.setupRequest?.shareAcrossDevicesVerified, true)
        XCTAssertEqual(automation.installedAppRestrictions, [nil])
        XCTAssertNil(service.setupProof?.verifiedAppRating)
        XCTAssertEqual(service.setupProof?.shareAcrossDevicesVerified, true)
        XCTAssertEqual(model.snapshot, active)
        XCTAssertFalse(model.hasError)
    }

    func testVerificationFailureKeepsSetupPendingAndDoesNotComplete() async {
        let events = AppleProtectionEventLog()
        let operationID = UUID()
        let pending = makeSnapshot(phase: .pendingSetup, operationID: operationID)
        let service = FakeAppleProtectionService(
            events: events,
            snapshot: makeSnapshot(phase: .inactive),
            setupOperation: makeOperation(id: operationID, snapshot: pending),
            completedSetupSnapshot: makeSnapshot(phase: .active)
        )
        let automation = FakeAppleScreenTimeAutomation(events: events)
        automation.verifyErrors = [AppleScreenTimeAutomationError.verificationRequired]
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.setUp(enablesAdultFilter: false, existingPasscode: nil)

        XCTAssertEqual(
            events.values,
            ["status", "enable sharing", "inspect", "begin setup", "install", "verify", "status"]
        )
        XCTAssertTrue(service.completedSetupOperationIDs.isEmpty)
        XCTAssertEqual(model.snapshot, pending)
        XCTAssertEqual(
            model.message,
            "Could not verify Screen Time setup. "
                + AppleScreenTimeAutomationError.verificationRequired.localizedDescription
        )
    }

    func testContinueRequestsCurrentCodeThenResumesTheSameOperationWithoutProAccess() async {
        let events = AppleProtectionEventLog()
        let operationID = UUID()
        let restriction = AppleAppAgeRestriction(baseline: .eighteen)
        let pending = makeSnapshot(
            phase: .pendingSetup, operationID: operationID,
            appAgeRestriction: restriction, shareAcrossDevicesVerified: true)
        let service = FakeAppleProtectionService(
            events: events, snapshot: pending,
            setupOperation: makeOperation(id: operationID, snapshot: pending),
            completedSetupSnapshot: makeSnapshot(phase: .active))
        let automation = FakeAppleScreenTimeAutomation(events: events)
        automation.inspection = AppleScreenTimeInspection(
            hasPasscode: true, adultFilterEnabled: false, shareAcrossDevicesEnabled: true)
        automation.inspection.appAgeRating = .eighteen
        automation.verifyErrors = [AppleScreenTimeAutomationError.appRestrictionNotVerified]
        let model = AppleProtectionModel(service: service, automation: automation, hasProAccess: false)

        await model.continueSetup()
        XCTAssertTrue(model.setupNeedsCurrentCode)
        XCTAssertFalse(model.hasError)
        XCTAssertTrue(automation.installReplacementWasProvided.isEmpty)
        XCTAssertTrue(service.completedSetupOperationIDs.isEmpty)

        automation.inspection.shareAcrossDevicesEnabled = false
        await model.continueSetup(existingPasscode: "4321")
        XCTAssertTrue(model.hasError)
        XCTAssertTrue(automation.installReplacementWasProvided.isEmpty)
        XCTAssertEqual(events.values.filter { $0 == "verify" }.count, 1)

        automation.inspection.shareAcrossDevicesEnabled = true
        automation.verifyErrors = [AppleScreenTimeAutomationError.unsupportedScreen]
        await model.continueSetup(existingPasscode: "4321")
        XCTAssertEqual(model.snapshot, pending)
        XCTAssertFalse(model.setupNeedsCurrentCode)
        XCTAssertTrue(model.hasError)

        // The code may now be installed: recheck it before asking for the old code again.
        await model.continueSetup()
        XCTAssertEqual(service.resumedSetupOperationIDs, [operationID, operationID, operationID])
        XCTAssertEqual(service.completedSetupOperationIDs, [operationID])
        XCTAssertEqual(automation.installReplacementWasProvided, [true])
        XCTAssertEqual(automation.installedAppRestrictions, [restriction])
        XCTAssertEqual(events.values.filter { $0 == "verify" }.count, 3)
        XCTAssertFalse(events.values.contains("begin setup"))
        XCTAssertFalse(model.setupNeedsCurrentCode)
        XCTAssertEqual(model.snapshot?.phase, .active)
    }

    func testContinueRequiresRequestedCodeBeforeResumingInstallation() async {
        let events = AppleProtectionEventLog()
        let operationID = UUID()
        let pending = makeSnapshot(phase: .pendingSetup, operationID: operationID)
        let service = FakeAppleProtectionService(
            events: events, snapshot: pending,
            setupOperation: makeOperation(id: operationID, snapshot: pending))
        let automation = FakeAppleScreenTimeAutomation(events: events)
        automation.inspection = AppleScreenTimeInspection(
            hasPasscode: true, adultFilterEnabled: false, shareAcrossDevicesEnabled: true)
        automation.verifyErrors = [AppleScreenTimeAutomationError.verificationRequired]
        let model = AppleProtectionModel(service: service, automation: automation)
        await model.continueSetup()
        events.removeAll()

        await model.continueSetup(existingPasscode: "")

        XCTAssertEqual(events.values, ["status", "status"])
        XCTAssertEqual(service.resumedSetupOperationIDs, [operationID])
        XCTAssertTrue(automation.installReplacementWasProvided.isEmpty)
        XCTAssertEqual(model.snapshot, pending)
        XCTAssertTrue(model.setupNeedsCurrentCode)
        XCTAssertTrue(model.hasError)
    }

    func testContinueWithoutNativeCodeInstallsTheSavedOperation() async {
        let events = AppleProtectionEventLog()
        let operationID = UUID()
        let pending = makeSnapshot(phase: .pendingSetup, operationID: operationID)
        let service = FakeAppleProtectionService(
            events: events, snapshot: pending,
            setupOperation: makeOperation(id: operationID, snapshot: pending),
            completedSetupSnapshot: makeSnapshot(phase: .active))
        let automation = FakeAppleScreenTimeAutomation(events: events)
        automation.verifyErrors = [AppleScreenTimeAutomationError.verificationRequired]
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.continueSetup()

        XCTAssertEqual(automation.installReplacementWasProvided, [false])
        XCTAssertEqual(service.resumedSetupOperationIDs, [operationID, operationID])
        XCTAssertEqual(service.completedSetupOperationIDs, [operationID])
        XCTAssertFalse(events.values.contains("begin setup"))
        XCTAssertFalse(model.setupNeedsCurrentCode)
        XCTAssertEqual(model.snapshot?.phase, .active)
    }

    func testContinueCompletesAnAlreadyInstalledCodeWithoutInstallingAgain() async {
        let events = AppleProtectionEventLog()
        let operationID = UUID()
        let pending = makeSnapshot(phase: .pendingSetup, operationID: operationID)
        let service = FakeAppleProtectionService(
            events: events, snapshot: pending,
            setupOperation: makeOperation(id: operationID, snapshot: pending),
            completedSetupSnapshot: makeSnapshot(phase: .active))
        let automation = FakeAppleScreenTimeAutomation(events: events)
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.continueSetup()

        XCTAssertEqual(service.completedSetupOperationIDs, [operationID])
        XCTAssertTrue(automation.installReplacementWasProvided.isEmpty)
        XCTAssertFalse(model.setupNeedsCurrentCode)
        XCTAssertEqual(model.snapshot?.phase, .active)
    }

    func testContinueStopsOnUnknownScreenWithoutRequestingCodeOrInstalling() async {
        let events = AppleProtectionEventLog()
        let operationID = UUID()
        let pending = makeSnapshot(phase: .pendingSetup, operationID: operationID)
        let service = FakeAppleProtectionService(
            events: events, snapshot: pending,
            setupOperation: makeOperation(id: operationID, snapshot: pending))
        let automation = FakeAppleScreenTimeAutomation(events: events)
        automation.verifyErrors = [AppleScreenTimeAutomationError.unsupportedScreen]
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.continueSetup()

        XCTAssertFalse(events.values.contains("inspect code"))
        XCTAssertTrue(automation.installReplacementWasProvided.isEmpty)
        XCTAssertTrue(service.completedSetupOperationIDs.isEmpty)
        XCTAssertEqual(model.snapshot, pending)
        XCTAssertFalse(model.setupNeedsCurrentCode)
        XCTAssertTrue(model.hasError)
    }

    func testReleaseFailureDoesNotCompleteRelease() async {
        let events = AppleProtectionEventLog()
        let operationID = UUID()
        let releaseInProgress = makeSnapshot(
            phase: .releaseInProgress,
            enablesAdultFilter: true,
            filterWasAlreadyEnabled: false,
            operationID: operationID
        )
        let service = FakeAppleProtectionService(
            events: events,
            snapshot: makeSnapshot(
                phase: .readyForRelease,
                enablesAdultFilter: true,
                filterWasAlreadyEnabled: false
            ),
            releaseOperation: makeOperation(id: operationID, snapshot: releaseInProgress),
            completedReleaseSnapshot: makeSnapshot(phase: .inactive)
        )
        let automation = FakeAppleScreenTimeAutomation(events: events)
        automation.releaseError = AppleScreenTimeAutomationError.verificationRequired
        let model = AppleProtectionModel(service: service, automation: automation, hasProAccess: false)

        await model.finishEnd()

        XCTAssertEqual(events.values, ["begin release", "release", "status"])
        XCTAssertFalse(model.hasProAccess)
        XCTAssertTrue(service.completedReleaseOperationIDs.isEmpty)
        XCTAssertEqual(model.snapshot, releaseInProgress)
        XCTAssertEqual(
            model.message,
            "Could not remove the Screen Time code. "
                + AppleScreenTimeAutomationError.verificationRequired.localizedDescription
        )
    }

    func testReleaseRemovesOnlyHardPauseWebsiteEntries() async {
        let events = AppleProtectionEventLog()
        let operationID = UUID()
        let releasing = makeSnapshot(
            phase: .releaseInProgress, enablesAdultFilter: true,
            mirroredDomains: ["ours.example"], operationID: operationID)
        let service = FakeAppleProtectionService(
            events: events, snapshot: makeSnapshot(phase: .readyForRelease),
            releaseOperation: makeOperation(id: operationID, snapshot: releasing),
            completedReleaseSnapshot: makeSnapshot(phase: .inactive))
        service.websiteOperation = AppleWebsiteSyncOperation(
            passcode: "1234", activeDomains: [], activeAllowedDomains: [],
            mirroredDomains: ["ours.example"], mirroredAllowedDomains: [])
        let automation = FakeAppleScreenTimeAutomation(events: events)
        automation.websites = AppleScreenTimeWebsites(
            restricted: ["ours.example", "native.example"], allowed: [],
            restrictedEntries: ["https://ours.example", "https://native.example"], allowedEntries: [])
        let model = AppleProtectionModel(service: service, automation: automation)

        automation.websiteReadError = AppleScreenTimeAutomationError.settingsNotResponding
        await model.finishEnd()
        XCTAssertFalse(events.values.contains("claim website sync"))
        XCTAssertFalse(events.values.contains("complete website sync"))
        XCTAssertFalse(events.values.contains("release"))
        XCTAssertTrue(service.completedReleaseOperationIDs.isEmpty)

        automation.websiteReadError = nil
        await model.finishEnd()

        XCTAssertEqual(automation.removedRestricted, ["https://ours.example"])
        XCTAssertEqual(automation.websites?.restricted, ["native.example"])
        XCTAssertEqual(service.completedReleaseOperationIDs, [operationID])
    }

    func testRequestEndStartsFullUnlockWaitWithoutReleasingProtection() async {
        let events = AppleProtectionEventLog()
        let waiting = makeSnapshot(phase: .waitingForFullUnlock, remainingDelay: 86_400)
        let service = FakeAppleProtectionService(
            events: events,
            snapshot: makeSnapshot(phase: .active),
            requestedEndSnapshot: waiting
        )
        let automation = FakeAppleScreenTimeAutomation(events: events)
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.requestEnd()

        XCTAssertEqual(events.values, ["request end"])
        XCTAssertEqual(service.requestEndCalls, 1)
        XCTAssertEqual(model.snapshot, waiting)
        XCTAssertTrue(service.completedReleaseOperationIDs.isEmpty)
        XCTAssertFalse(model.hasError)
    }

    private func makeSnapshot(
        phase: AppleLockdownPhase,
        remainingDelay: TimeInterval? = nil,
        enablesAdultFilter: Bool = false,
        filterWasAlreadyEnabled: Bool = false,
        mirroredDomains: [String] = [],
        operationID: UUID? = nil, appAgeRestriction: AppleAppAgeRestriction? = nil,
        shareAcrossDevicesVerified: Bool? = nil
    ) -> AppleLockdownSnapshot {
        AppleLockdownSnapshot(
            phase: phase,
            fullUnlockDelay: phase == .inactive ? nil : 86_400,
            remainingDelay: remainingDelay,
            enablesAdultFilter: enablesAdultFilter,
            filterWasAlreadyEnabled: filterWasAlreadyEnabled,
            shareAcrossDevicesVerified: shareAcrossDevicesVerified,
            mirroredDomains: mirroredDomains,
            mirroredAllowedDomains: [],
            operationID: operationID, appAgeRestriction: appAgeRestriction
        )
    }

    private func makeOperation(
        id: UUID,
        snapshot: AppleLockdownSnapshot
    ) -> AppleLockdownCredentialOperation {
        AppleLockdownCredentialOperation(
            operationID: id,
            passcode: "1234",
            snapshot: snapshot
        )
    }
}

@MainActor
private final class AppleProtectionEventLog {
    private(set) var values: [String] = []

    func append(_ value: String) { values.append(value) }
    func removeAll() { values.removeAll() }
}

@MainActor
private final class FakeAppleScreenTimeAutomation: AppleScreenTimeAutomating {
    let events: AppleProtectionEventLog
    var inspection = AppleScreenTimeInspection(
        hasPasscode: false,
        adultFilterEnabled: false, shareAcrossDevicesEnabled: true
    )
    var sharingError: Error?
    var installError: Error?
    var verifyErrors: [Error] = []
    var releaseError: Error?
    var restoreAgeError: Error?
    private(set) var restoredAgeRestrictions: [AppleAppAgeRestriction] = []
    var websites: AppleScreenTimeWebsites?
    var websiteReadError: Error?
    var onInspectWebsites: (() async -> Void)?
    private(set) var removedRestricted: [String] = []
    private(set) var installReplacementWasProvided: [Bool] = []
    private(set) var installedAppRestrictions: [AppleAppAgeRestriction?] = []

    init(events: AppleProtectionEventLog) {
        self.events = events
    }

    func inspectCode() async throws -> Bool {
        events.append("inspect code")
        return inspection.hasPasscode
    }

    func enableSharing(passcode: String?) async throws {
        events.append("enable sharing")
        if let sharingError { throw sharingError }
    }

    func inspect(checkAdultFilter: Bool, checkAdultApps: Bool, passcode: String?) async throws
        -> AppleScreenTimeInspection
    {
        events.append("inspect")
        return inspection
    }

    func install(
        passcode: String,
        replacing existingPasscode: String?,
        enableAdultFilter: Bool, appAgeRestriction: AppleAppAgeRestriction?
    ) async throws {
        events.append("install")
        installReplacementWasProvided.append(existingPasscode != nil)
        installedAppRestrictions.append(appAgeRestriction)
        if let installError { throw installError }
    }

    func verify(
        passcode: String, requiresAdultFilter: Bool, appAgeRestriction: AppleAppAgeRestriction?, requiresSharing: Bool
    ) async throws -> AppleScreenTimeInspection {
        events.append("verify")
        if !verifyErrors.isEmpty { throw verifyErrors.removeFirst() }
        return AppleScreenTimeInspection(
            hasPasscode: true, adultFilterEnabled: requiresAdultFilter,
            appAgeRating: appAgeRestriction?.baseline, shareAcrossDevicesEnabled: true)
    }

    func restoreAppAge(passcode: String, restriction: AppleAppAgeRestriction) async throws -> AppleAppAgeRating {
        events.append("restore app age")
        if let restoreAgeError { throw restoreAgeError }
        restoredAgeRestrictions.append(restriction)
        return restriction.baseline
    }

    func release(
        passcode: String, restoreUnrestricted: Bool, appAgeRestriction: AppleAppAgeRestriction?
    ) async throws {
        events.append("release")
        if let releaseError { throw releaseError }
    }

    func inspectWebsites(passcode: String) async throws -> AppleScreenTimeWebsites {
        events.append("inspect websites")
        if let websiteReadError { throw websiteReadError }
        await onInspectWebsites?()
        guard let websites else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
        return websites
    }

    func updateWebsites(
        passcode: String, addRestricted: [String], removeRestricted: [String],
        addAllowed: [String], removeAllowed: [String]
    ) async throws -> AppleScreenTimeWebsites {
        events.append("update websites")
        removedRestricted = removeRestricted
        guard let current = websites else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
        let restrictedEntries = current.restrictedEntries.filter { !removeRestricted.contains($0) }
        let updated = AppleScreenTimeWebsites(
            restricted: Set(restrictedEntries.compactMap { URLPatternRule.exactDomain(from: $0) }),
            allowed: current.allowed,
            restrictedEntries: restrictedEntries, allowedEntries: current.allowedEntries)
        websites = updated
        return updated
    }
}

@MainActor
private final class FakeAppleProtectionService: ProtectedServiceServing {
    let events: AppleProtectionEventLog
    var snapshot: AppleLockdownSnapshot
    var setupOperation: AppleLockdownCredentialOperation?
    var releaseOperation: AppleLockdownCredentialOperation?
    var completedSetupSnapshot: AppleLockdownSnapshot?
    var requestedEndSnapshot: AppleLockdownSnapshot?
    var completedReleaseSnapshot: AppleLockdownSnapshot?
    var websiteOperation: AppleWebsiteSyncOperation?
    var ageRestorationOperation: AppleLockdownCredentialOperation?
    var ageRestorationCompletionError: Error?
    private(set) var ageRestorationProof: AppleLockdownOperationRequest?
    private(set) var resumedSetupOperationIDs: [UUID] = []
    private(set) var completedSetupOperationIDs: [UUID] = []
    private(set) var completedReleaseOperationIDs: [UUID] = []
    private(set) var requestEndCalls = 0
    private(set) var setupDelay: TimeInterval?
    private(set) var setupRequest: AppleLockdownSetupRequest?
    private(set) var setupProof: AppleLockdownOperationRequest?

    init(
        events: AppleProtectionEventLog,
        snapshot: AppleLockdownSnapshot,
        setupOperation: AppleLockdownCredentialOperation? = nil,
        releaseOperation: AppleLockdownCredentialOperation? = nil,
        completedSetupSnapshot: AppleLockdownSnapshot? = nil,
        requestedEndSnapshot: AppleLockdownSnapshot? = nil,
        completedReleaseSnapshot: AppleLockdownSnapshot? = nil
    ) {
        self.events = events
        self.snapshot = snapshot
        self.setupOperation = setupOperation
        self.releaseOperation = releaseOperation
        self.completedSetupSnapshot = completedSetupSnapshot
        self.requestedEndSnapshot = requestedEndSnapshot
        self.completedReleaseSnapshot = completedReleaseSnapshot
    }

    func appleLockdownStatus() async throws -> AppleLockdownSnapshot {
        events.append("status")
        return snapshot
    }

    func beginAppleAppAgeRestoration() async throws -> AppleLockdownCredentialOperation {
        events.append("begin app age restoration")
        return try required(ageRestorationOperation)
    }

    func completeAppleAppAgeRestoration(operationID: UUID, verifiedAppRating: AppleAppAgeRating) async throws
        -> AppleLockdownSnapshot
    {
        events.append("complete app age restoration")
        if let ageRestorationCompletionError { throw ageRestorationCompletionError }
        ageRestorationProof = AppleLockdownOperationRequest(
            operationID: operationID, verifiedAppRating: verifiedAppRating)
        snapshot.appAgeRestriction = nil
        return snapshot
    }

    func beginAppleLockdownSetup(
        _ request: AppleLockdownSetupRequest
    ) async throws -> AppleLockdownCredentialOperation {
        events.append("begin setup")
        setupDelay = request.fullUnlockDelay
        setupRequest = request
        let operation = try required(setupOperation)
        snapshot = operation.snapshot
        return operation
    }

    func resumeAppleLockdownSetup(
        operationID: UUID
    ) async throws -> AppleLockdownCredentialOperation {
        events.append("resume setup")
        resumedSetupOperationIDs.append(operationID)
        let operation = try required(setupOperation)
        guard operation.operationID == operationID else { throw AppleLockdownError.operationMismatch }
        return operation
    }

    func completeAppleLockdownSetup(
        operationID: UUID, verifiedAppRating: AppleAppAgeRating?, shareAcrossDevicesVerified: Bool?
    ) async throws -> AppleLockdownSnapshot {
        events.append("complete setup")
        setupProof = AppleLockdownOperationRequest(
            operationID: operationID, verifiedAppRating: verifiedAppRating,
            shareAcrossDevicesVerified: shareAcrossDevicesVerified)
        completedSetupOperationIDs.append(operationID)
        snapshot = try required(completedSetupSnapshot)
        return snapshot
    }

    func requestAppleLockdownEnd() async throws -> AppleLockdownSnapshot {
        events.append("request end")
        requestEndCalls += 1
        snapshot = try required(requestedEndSnapshot)
        return snapshot
    }

    func beginAppleLockdownRelease() async throws -> AppleLockdownCredentialOperation {
        events.append("begin release")
        let operation = try required(releaseOperation)
        snapshot = operation.snapshot
        return operation
    }

    func completeAppleLockdownRelease(operationID: UUID) async throws -> AppleLockdownSnapshot {
        events.append("complete release")
        completedReleaseOperationIDs.append(operationID)
        snapshot = try required(completedReleaseSnapshot)
        return snapshot
    }

    func beginAppleWebsiteSync() async throws -> AppleWebsiteSyncOperation {
        guard let websiteOperation else { throw AppleLockdownError.protectionNotActive }
        events.append("begin website sync")
        return websiteOperation
    }

    func completeAppleWebsiteSync(
        operationID: UUID, verifiedDomains: [String], verifiedAllowedDomains: [String],
        mirroredDomains: [String], mirroredAllowedDomains: [String]
    ) async throws {
        events.append("complete website sync")
    }

    func claimAppleWebsiteSync(
        domains: [String], allowedDomains: [String], expectedDomains: [String], expectedAllowedDomains: [String]
    ) async throws -> AppleWebsiteSyncOperation {
        events.append("claim website sync")
        let operation = try required(websiteOperation)
        return AppleWebsiteSyncOperation(
            operationID: operation.operationID ?? UUID(),
            passcode: operation.passcode, activeDomains: operation.activeDomains,
            activeAllowedDomains: operation.activeAllowedDomains,
            mirroredDomains: Array(Set(operation.mirroredDomains).union(domains)),
            mirroredAllowedDomains: Array(Set(operation.mirroredAllowedDomains).union(allowedDomains)))
    }

    func list() async throws -> ProtectedServiceSnapshot { protectedSnapshot }
    func create(_ draft: ProtectedBlockDraft) async throws -> ProtectedServiceSnapshot { protectedSnapshot }
    func update(
        id: UUID,
        expectedRevision: Int,
        draft: ProtectedBlockDraft
    ) async throws -> ProtectedServiceSnapshot { protectedSnapshot }
    func delete(id: UUID, expectedRevision: Int) async throws -> ProtectedServiceSnapshot {
        protectedSnapshot
    }
    func activate(id: UUID, expectedRevision: Int) async throws -> ProtectedServiceSnapshot {
        protectedSnapshot
    }
    func requestBreak(id: UUID) async throws -> ProtectedServiceSnapshot { protectedSnapshot }
    func cancelBreak(id: UUID) async throws -> ProtectedServiceSnapshot { protectedSnapshot }
    func requestEnd(id: UUID) async throws -> ProtectedServiceSnapshot { protectedSnapshot }

    private var protectedSnapshot: ProtectedServiceSnapshot {
        ProtectedState().snapshot(
            at: Date(timeIntervalSince1970: 0),
            protection: .unavailable
        )
    }

    private func required<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw AppleLockdownError.stateUnavailable }
        return value
    }
}
