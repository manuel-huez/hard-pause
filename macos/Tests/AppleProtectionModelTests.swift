import XCTest

@MainActor
final class AppleProtectionModelTests: XCTestCase {
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

        await model.setUp(fullUnlockDelay: 86_400, enablesAdultFilter: true, existingPasscode: nil)

        XCTAssertEqual(
            events.values,
            ["inspect", "begin setup", "install", "verify", "complete setup"]
        )
        XCTAssertEqual(service.completedSetupOperationIDs, [operationID])
        XCTAssertEqual(model.snapshot, active)
        XCTAssertEqual(
            model.message,
            "The code is secured and verified on this Mac. iPhone protection is not yet verified."
        )
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

        await model.setUp(fullUnlockDelay: 86_400, enablesAdultFilter: false, existingPasscode: nil)

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

        await model.setUp(fullUnlockDelay: 86_400, enablesAdultFilter: false, existingPasscode: nil)
        XCTAssertEqual(model.snapshot, pending)
        XCTAssertTrue(service.completedSetupOperationIDs.isEmpty)

        events.removeAll()
        automation.installError = nil
        automation.inspection = AppleScreenTimeInspection(
            hasPasscode: true,
            sharesAcrossDevices: false,
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
            sharesAcrossDevices: false,
            adultFilterEnabled: false
        )
        let model = AppleProtectionModel(service: service, automation: automation)

        await model.retrySetup(existingPasscode: "")

        XCTAssertEqual(events.values, ["status", "inspect", "status"])
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
        XCTAssertEqual(model.message, "The full unlock wait has started. Protection stays on.")
    }

    private func makeSnapshot(
        phase: AppleLockdownPhase,
        remainingDelay: TimeInterval? = nil,
        enablesAdultFilter: Bool = false,
        filterWasAlreadyEnabled: Bool = false,
        operationID: UUID? = nil
    ) -> AppleLockdownSnapshot {
        AppleLockdownSnapshot(
            phase: phase,
            fullUnlockDelay: phase == .inactive ? nil : 86_400,
            remainingDelay: remainingDelay,
            enablesAdultFilter: enablesAdultFilter,
            filterWasAlreadyEnabled: filterWasAlreadyEnabled,
            shareAcrossDevicesVerified: nil,
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
        sharesAcrossDevices: false,
        adultFilterEnabled: false
    )
    var installError: Error?
    var verifyError: Error?
    var releaseError: Error?
    private(set) var installReplacementWasProvided: [Bool] = []

    init(events: AppleProtectionEventLog) {
        self.events = events
    }

    func inspect() async throws -> AppleScreenTimeInspection {
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
    private(set) var resumedSetupOperationIDs: [UUID] = []
    private(set) var completedSetupOperationIDs: [UUID] = []
    private(set) var completedReleaseOperationIDs: [UUID] = []
    private(set) var requestEndCalls = 0

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
