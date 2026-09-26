import XCTest

@MainActor
final class AppleProtectionModelTests: XCTestCase {
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
        let model = AppleProtectionModel(service: service, automation: automation, operationLockURL: lockURL)
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
        let pending = makeSnapshot(phase: .pendingSetup, operationID: operationID)
        let active = makeSnapshot(phase: .active)
        let service = FakeAppleProtectionService(
            events: events,
            snapshot: makeSnapshot(phase: .inactive),
            setupOperation: makeOperation(id: operationID, snapshot: pending),
            completedSetupSnapshot: active
        )
        let automation = FakeAppleScreenTimeAutomation(events: events)
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.setUp(enablesAdultFilter: true, existingPasscode: nil)

        XCTAssertEqual(
            events.values,
            ["inspect", "begin setup", "install", "verify", "complete setup"]
        )
        XCTAssertEqual(service.completedSetupOperationIDs, [operationID])
        XCTAssertEqual(service.setupDelay, 0)
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
        automation.verifyError = AppleScreenTimeAutomationError.verificationRequired
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.setUp(enablesAdultFilter: false, existingPasscode: nil)

        XCTAssertEqual(
            events.values,
            ["inspect", "begin setup", "install", "verify", "status"]
        )
        XCTAssertTrue(service.completedSetupOperationIDs.isEmpty)
        XCTAssertEqual(model.snapshot, pending)
        XCTAssertEqual(model.message, AppleScreenTimeAutomationError.verificationRequired.localizedDescription)
    }

    func testRetryResumesTheSameSetupOperation() async {
        let events = AppleProtectionEventLog()
        let operationID = UUID()
        let pending = makeSnapshot(phase: .pendingSetup, operationID: operationID)
        let active = makeSnapshot(phase: .active)
        let service = FakeAppleProtectionService(
            events: events,
            snapshot: makeSnapshot(phase: .inactive),
            setupOperation: makeOperation(id: operationID, snapshot: pending),
            completedSetupSnapshot: active
        )
        let automation = FakeAppleScreenTimeAutomation(events: events)
        automation.installError = AppleScreenTimeAutomationError.unsupportedScreen
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.setUp(enablesAdultFilter: false, existingPasscode: nil)
        XCTAssertEqual(model.snapshot, pending)
        XCTAssertTrue(service.completedSetupOperationIDs.isEmpty)

        events.removeAll()
        automation.installError = nil
        automation.inspection = AppleScreenTimeInspection(
            hasPasscode: true,
            adultFilterEnabled: false
        )
        await model.retrySetup(existingPasscode: "4321")

        XCTAssertEqual(
            events.values,
            ["status", "inspect", "resume setup", "install", "verify", "complete setup"]
        )
        XCTAssertEqual(service.resumedSetupOperationIDs, [operationID])
        XCTAssertEqual(service.completedSetupOperationIDs, [operationID])
        XCTAssertEqual(automation.installReplacementWasProvided, [false, true])
        XCTAssertEqual(model.snapshot, active)
    }

    func testRetryWithExistingPasscodeRequiresAnExplicitCodeBeforeResume() async {
        let events = AppleProtectionEventLog()
        let operationID = UUID()
        let pending = makeSnapshot(phase: .pendingSetup, operationID: operationID)
        let service = FakeAppleProtectionService(
            events: events,
            snapshot: pending,
            setupOperation: makeOperation(id: operationID, snapshot: pending),
            completedSetupSnapshot: makeSnapshot(phase: .active)
        )
        let automation = FakeAppleScreenTimeAutomation(events: events)
        automation.inspection = AppleScreenTimeInspection(
            hasPasscode: true,
            adultFilterEnabled: false
        )
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.retrySetup(existingPasscode: "")

        XCTAssertEqual(events.values, ["status", "status"])
        XCTAssertTrue(service.resumedSetupOperationIDs.isEmpty)
        XCTAssertTrue(automation.installReplacementWasProvided.isEmpty)
        XCTAssertEqual(model.snapshot, pending)
        XCTAssertEqual(
            model.message,
            AppleScreenTimeAutomationError.existingPasscodeRequired.localizedDescription
        )
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
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.finishEnd()

        XCTAssertEqual(events.values, ["begin release", "release", "status"])
        XCTAssertTrue(service.completedReleaseOperationIDs.isEmpty)
        XCTAssertEqual(model.snapshot, releaseInProgress)
        XCTAssertEqual(model.message, AppleScreenTimeAutomationError.verificationRequired.localizedDescription)
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
        operationID: UUID? = nil
    ) -> AppleLockdownSnapshot {
        AppleLockdownSnapshot(
            phase: phase,
            fullUnlockDelay: phase == .inactive ? nil : 86_400,
            remainingDelay: remainingDelay,
            enablesAdultFilter: enablesAdultFilter,
            filterWasAlreadyEnabled: filterWasAlreadyEnabled,
            shareAcrossDevicesVerified: nil,
            mirroredDomains: mirroredDomains,
            mirroredAllowedDomains: [],
            operationID: operationID
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
        adultFilterEnabled: false
    )
    var installError: Error?
    var verifyError: Error?
    var releaseError: Error?
    var websites: AppleScreenTimeWebsites?
    var websiteReadError: Error?
    var onInspectWebsites: (() async -> Void)?
    private(set) var removedRestricted: [String] = []
    private(set) var installReplacementWasProvided: [Bool] = []

    init(events: AppleProtectionEventLog) {
        self.events = events
    }

    func inspectCode() async throws -> Bool {
        events.append("inspect code")
        return inspection.hasPasscode
    }

    func inspect(checkAdultFilter: Bool, passcode: String?) async throws -> AppleScreenTimeInspection {
        events.append("inspect")
        return inspection
    }

    func install(
        passcode: String,
        replacing existingPasscode: String?,
        enableAdultFilter: Bool
    ) async throws {
        events.append("install")
        installReplacementWasProvided.append(existingPasscode != nil)
        if let installError { throw installError }
    }

    func verify(passcode: String, requiresAdultFilter: Bool) async throws {
        events.append("verify")
        if let verifyError { throw verifyError }
    }

    func release(passcode: String, restoreUnrestricted: Bool) async throws {
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
    private(set) var resumedSetupOperationIDs: [UUID] = []
    private(set) var completedSetupOperationIDs: [UUID] = []
    private(set) var completedReleaseOperationIDs: [UUID] = []
    private(set) var requestEndCalls = 0
    private(set) var setupDelay: TimeInterval?

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

    func beginAppleLockdownSetup(
        _ request: AppleLockdownSetupRequest
    ) async throws -> AppleLockdownCredentialOperation {
        events.append("begin setup")
        setupDelay = request.fullUnlockDelay
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

    func completeAppleLockdownSetup(operationID: UUID) async throws -> AppleLockdownSnapshot {
        events.append("complete setup")
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
