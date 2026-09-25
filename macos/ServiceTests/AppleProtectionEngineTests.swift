import Foundation
import XCTest

final class AppleProtectionEngineTests: XCTestCase {
    func testWebsiteSyncCannotForgetAnActiveWebsite() throws {
        let store = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let engine = try configuredEngine(
            store: store, vault: vault, clock: FakeServiceClock(serviceTestReading(0)))

        XCTAssertEqual(try engine.websiteSyncCredential().passcode, "4820")
        try engine.claimMirroredDomains(
            ["example.com"], required: ["example.com"],
            allowed: ["safe.example"], requiredAllowed: ["safe.example"])
        XCTAssertEqual(store.persisted.mirroredDomains, ["example.com"])
        try engine.recordMirroredDomains(
            ["example.com"], required: ["example.com"],
            allowed: ["safe.example"], requiredAllowed: ["safe.example"])
        XCTAssertThrowsError(
            try engine.recordMirroredDomains(
                [], required: ["example.com"], allowed: [], requiredAllowed: ["safe.example"]))

        let restarted = try AppleLockdownEngine(
            stateStore: store,
            credentialVault: vault,
            clock: FakeServiceClock(serviceTestReading(0)))
        XCTAssertEqual(try restarted.websiteSyncCredential().mirroredDomains, ["example.com"])
        XCTAssertEqual(try restarted.websiteSyncCredential().mirroredAllowedDomains, ["safe.example"])
    }

    func testLiveFreezeStopsAppleCheckpointAndRequestsUntilFinalization() throws {
        let store = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try configuredEngine(store: store, vault: vault, clock: clock)
        _ = try engine.requestEnd()
        _ = try engine.freezeForLiveUpdate()
        let savedCount = store.saved.count
        clock.reading = serviceTestReading(65)

        XCTAssertEqual(try engine.status().phase, .waitingForFullUnlock)
        XCTAssertEqual(store.saved.count, savedCount)
        XCTAssertThrowsError(try engine.requestEnd()) {
            XCTAssertEqual($0 as? ProtectedStateError, .updateInProgress)
        }
        try engine.checkpointForLiveUpdateFinalization()
        XCTAssertGreaterThan(store.saved.count, savedCount)
        engine.unfreezeAfterLiveUpdate()
    }

    func testSetupPersistsIntentAndReadsCredentialBackBeforeReturning() throws {
        let events = TestEventLog()
        let store = FakeAppleLockdownStateStore(events: events)
        let vault = FakeAppleLockdownVault(events: events)
        let engine = try AppleLockdownEngine(
            stateStore: store,
            credentialVault: vault,
            passcodeGenerator: FakeAppleLockdownPasscodeGenerator(["4820"]),
            clock: FakeServiceClock(serviceTestReading(0))
        )

        let operation = try engine.beginSetup(setupRequest())

        XCTAssertEqual(operation.passcode, "4820")
        XCTAssertEqual(operation.snapshot.phase, .pendingSetup)
        XCTAssertEqual(
            events.values,
            [
                "save-apple-state:provisioningSetup",
                "read-credential",
                "save-credential",
                "read-credential",
                "save-apple-state:pendingSetup",
            ]
        )
        let encodedState = try JSONEncoder().encode(store.persisted)
        XCTAssertFalse(String(decoding: encodedState, as: UTF8.self).contains("4820"))
        let encodedSnapshot = try JSONEncoder().encode(operation.snapshot)
        XCTAssertFalse(String(decoding: encodedSnapshot, as: UTF8.self).contains("4820"))
    }

    func testSetupDoesNotCreateCredentialBeforeDurableIntent() throws {
        let store = FakeAppleLockdownStateStore()
        store.saveFailures = 1
        let vault = FakeAppleLockdownVault()
        let engine = try AppleLockdownEngine(
            stateStore: store,
            credentialVault: vault,
            passcodeGenerator: FakeAppleLockdownPasscodeGenerator(),
            clock: FakeServiceClock(serviceTestReading(0))
        )

        XCTAssertThrowsError(try engine.beginSetup(setupRequest()))
        XCTAssertTrue(vault.values.isEmpty)
        XCTAssertEqual(store.persisted.phase, .inactive)
    }

    func testPendingSetupResumesWithSameCredentialAfterRestart() throws {
        let store = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let clock = FakeServiceClock(serviceTestReading(0))
        let first = try AppleLockdownEngine(
            stateStore: store,
            credentialVault: vault,
            passcodeGenerator: FakeAppleLockdownPasscodeGenerator(["4820"]),
            clock: clock
        )
        let initial = try first.beginSetup(setupRequest())
        let restarted = try AppleLockdownEngine(
            stateStore: store,
            credentialVault: vault,
            passcodeGenerator: FakeAppleLockdownPasscodeGenerator(["9999"]),
            clock: clock
        )

        let resumed = try restarted.resumeSetup(
            AppleLockdownOperationRequest(operationID: initial.operationID)
        )

        XCTAssertEqual(resumed.passcode, "4820")
        XCTAssertEqual(resumed.operationID, initial.operationID)
    }

    func testSetupCannotCompleteAfterCredentialDisappears() throws {
        let store = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let engine = try AppleLockdownEngine(
            stateStore: store,
            credentialVault: vault,
            passcodeGenerator: FakeAppleLockdownPasscodeGenerator(["4820"]),
            clock: FakeServiceClock(serviceTestReading(0))
        )
        let setup = try engine.beginSetup(setupRequest())
        vault.values.removeAll()

        XCTAssertThrowsError(
            try engine.completeSetup(
                AppleLockdownOperationRequest(operationID: setup.operationID)
            )
        ) { error in
            XCTAssertEqual(error as? AppleLockdownError, .credentialUnavailable)
        }
        XCTAssertEqual(store.persisted.phase, .pendingSetup)
    }

    func testPendingSetupCannotDeleteCredentialThroughCancellationEndpoint() throws {
        let store = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let engine = try AppleLockdownEngine(
            stateStore: store,
            credentialVault: vault,
            passcodeGenerator: FakeAppleLockdownPasscodeGenerator(["4820"]),
            clock: FakeServiceClock(serviceTestReading(0))
        )
        let setup = try engine.beginSetup(setupRequest())

        XCTAssertThrowsError(
            try engine.confirmSetupNotApplied(
                AppleLockdownOperationRequest(operationID: setup.operationID)
            )
        ) { error in
            XCTAssertEqual(error as? AppleLockdownError, .setupCancellationUnavailable)
        }
        XCTAssertEqual(store.persisted.phase, .pendingSetup)
        XCTAssertEqual(vault.values.values.first, "4820")
    }

    func testReleaseNeedsVerifiedElapsedTimeAndInactiveHealthyNormalProtection() throws {
        let store = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try configuredEngine(store: store, vault: vault, clock: clock)
        _ = try engine.requestEnd()

        clock.reading = serviceTestReading(120, boot: "boot-b")
        XCTAssertEqual(try engine.status().remainingDelay, 60)
        clock.reading = serviceTestReading(180, boot: "boot-b")
        XCTAssertEqual(try engine.status().phase, .readyForRelease)

        XCTAssertThrowsError(
            try engine.beginRelease(normalProtectionIsInactiveAndHealthy: false)
        ) { error in
            XCTAssertEqual(
                error as? AppleLockdownError,
                .normalProtectionActiveOrUnhealthy
            )
        }
        XCTAssertEqual(store.persisted.phase, .waitingForFullUnlock)

        let release = try engine.beginRelease(normalProtectionIsInactiveAndHealthy: true)
        XCTAssertEqual(release.passcode, "4820")
        XCTAssertEqual(release.snapshot.phase, .releaseInProgress)
        XCTAssertFalse(vault.values.isEmpty)

        let completed = try engine.completeRelease(
            AppleLockdownOperationRequest(operationID: release.operationID)
        )
        XCTAssertEqual(completed.phase, .inactive)
        XCTAssertTrue(vault.values.isEmpty)
    }

    func testBlockLinkedCodeWaitsForFirstPlanThenReleasesAfterLastPlan() throws {
        let store = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try AppleLockdownEngine(
            stateStore: store, credentialVault: vault,
            passcodeGenerator: FakeAppleLockdownPasscodeGenerator(["4820"]), clock: clock)
        let setup = try engine.beginSetup(
            AppleLockdownSetupRequest(
                fullUnlockDelay: 0, enablesAdultFilter: true,
                filterWasAlreadyEnabled: false, shareAcrossDevicesVerified: nil))
        _ = try engine.completeSetup(AppleLockdownOperationRequest(operationID: setup.operationID))

        try engine.reconcilePlanUse(hasDependentPlans: false)
        XCTAssertEqual(try engine.status().phase, .active)
        try engine.reconcilePlanUse(hasDependentPlans: true)
        XCTAssertEqual(store.persisted.hasUsedPlan, true)

        let restarted = try AppleLockdownEngine(stateStore: store, credentialVault: vault, clock: clock)
        try restarted.reconcilePlanUse(hasDependentPlans: true)
        XCTAssertEqual(try restarted.status().phase, .active)
        try restarted.reconcilePlanUse(hasDependentPlans: false)
        XCTAssertEqual(try restarted.status().phase, .readyForRelease)
        XCTAssertThrowsError(try restarted.beginRelease(normalProtectionIsInactiveAndHealthy: false))
        XCTAssertEqual(
            try restarted.beginRelease(normalProtectionIsInactiveAndHealthy: true).passcode,
            "4820")
    }

    func testExistingCodeStateKeepsItsSavedWaitWhenNewFieldIsMissing() throws {
        let store = FakeAppleLockdownStateStore()
        let engine = try configuredEngine(
            store: store, vault: FakeAppleLockdownVault(),
            clock: FakeServiceClock(serviceTestReading(0)))
        let data = try JSONEncoder().encode(store.persisted)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "hasUsedPlan")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(AppleLockdownState.self, from: oldData)

        try restored.validateForPersistence()
        XCTAssertNil(restored.hasUsedPlan)
        XCTAssertEqual(restored.snapshot().fullUnlockDelay, 60)
        XCTAssertEqual(try engine.status().phase, .active)
    }

    func testUnverifiedNativeReleaseKeepsCredential() throws {
        let store = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try configuredEngine(store: store, vault: vault, clock: clock)
        _ = try engine.requestEnd()
        clock.reading = serviceTestReading(60)

        _ = try engine.beginRelease(normalProtectionIsInactiveAndHealthy: true)

        XCTAssertEqual(store.persisted.phase, .releaseInProgress)
        XCTAssertFalse(vault.values.isEmpty)
        XCTAssertThrowsError(try engine.requireSafeMaintenance())
    }

    func testReleaseCleanupFailureKeepsDurableRecoveryStateAndCredential() throws {
        let store = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try configuredEngine(store: store, vault: vault, clock: clock)
        _ = try engine.requestEnd()
        clock.reading = serviceTestReading(60)
        let release = try engine.beginRelease(normalProtectionIsInactiveAndHealthy: true)
        vault.deleteFailures = 1

        XCTAssertThrowsError(
            try engine.completeRelease(
                AppleLockdownOperationRequest(operationID: release.operationID)
            )
        )
        XCTAssertEqual(store.persisted.phase, .completingRelease)
        XCTAssertFalse(vault.values.isEmpty)

        XCTAssertEqual(try engine.status().phase, .inactive)
        XCTAssertTrue(vault.values.isEmpty)
    }

    func testLockdownPlanActivationRequiresConfirmedScreenTimeProtection() throws {
        let stateStore = FakeProtectedStateStore()
        let protectedEngine = try ProtectedServiceEngine(
            stateStore: stateStore,
            enforcer: FakeProtectionEnforcer(),
            clock: FakeServiceClock(serviceTestReading(0))
        )
        let snapshot = try protectedEngine.create(
            ProtectedCreateRequest(
                draft: serviceTestDraft(protectionMode: .lockdown)
            )
        )
        let block = try XCTUnwrap(snapshot.blocks.first)
        let request = ProtectedRevisionRequest(id: block.id, expectedRevision: block.revision)

        XCTAssertThrowsError(try protectedEngine.activate(request)) { error in
            XCTAssertEqual(error as? AppleLockdownError, .protectionNotActive)
        }
        XCTAssertNoThrow(
            try protectedEngine.activate(request, appleLockdownActive: true)
        )
    }

    func testEndpointBlocksNewActivationAfterReleaseCredentialIsAuthorized() throws {
        let normalClock = FakeServiceClock(serviceTestReading(0))
        let protectedEngine = try ProtectedServiceEngine(
            stateStore: FakeProtectedStateStore(),
            enforcer: FakeProtectionEnforcer(),
            clock: normalClock
        )
        let created = try protectedEngine.create(
            ProtectedCreateRequest(draft: serviceTestDraft())
        )
        let block = try XCTUnwrap(created.blocks.first)
        let appleStore = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let appleClock = FakeServiceClock(serviceTestReading(0))
        let appleEngine = try configuredEngine(
            store: appleStore,
            vault: vault,
            clock: appleClock
        )
        _ = try appleEngine.requestEnd()
        appleClock.reading = serviceTestReading(60)
        let endpoint = ProtectedServiceEndpoint(
            engine: protectedEngine,
            appleLockdown: appleEngine,
            coordinator: ProtectedServiceCoordinator()
        )
        var releaseReply: AppleLockdownServiceReply?
        endpoint.beginAppleLockdownRelease { data in
            releaseReply = try? ProtectedServiceCodec.decode(
                AppleLockdownServiceReply.self,
                from: data
            )
        }
        XCTAssertNotNil(releaseReply?.credential)

        let activation = try ProtectedServiceCodec.encode(
            ProtectedRevisionRequest(id: block.id, expectedRevision: block.revision)
        )
        var activationReply: ProtectedServiceReply?
        endpoint.activate(activation) { data in
            activationReply = try? ProtectedServiceCodec.decode(
                ProtectedServiceReply.self,
                from: data
            )
        }

        XCTAssertNil(activationReply?.snapshot)
        XCTAssertEqual(activationReply?.error?.message, AppleLockdownError.releaseInProgress.localizedDescription)
        XCTAssertTrue(
            protectedEngine.list().blocks.allSatisfy {
                if case .inactive = $0.phase { return true }
                return false
            }
        )
    }

    func testEndpointReleasesAfterLastScreenTimePlanDespiteUnrelatedAppPlan() throws {
        let clock = FakeServiceClock(serviceTestReading(0))
        let protectedEngine = try ProtectedServiceEngine(
            stateStore: FakeProtectedStateStore(), enforcer: FakeProtectionEnforcer(), clock: clock)
        let appleStore = FakeAppleLockdownStateStore()
        let appleEngine = try AppleLockdownEngine(
            stateStore: appleStore, credentialVault: FakeAppleLockdownVault(),
            passcodeGenerator: FakeAppleLockdownPasscodeGenerator(["4820"]), clock: clock)
        let setup = try appleEngine.beginSetup(
            AppleLockdownSetupRequest(
                fullUnlockDelay: 0, enablesAdultFilter: true,
                filterWasAlreadyEnabled: false, shareAcrossDevicesVerified: nil))
        _ = try appleEngine.completeSetup(AppleLockdownOperationRequest(operationID: setup.operationID))
        let endpoint = ProtectedServiceEndpoint(
            engine: protectedEngine, appleLockdown: appleEngine,
            coordinator: ProtectedServiceCoordinator())

        let lockdown = try XCTUnwrap(
            protectedEngine.create(
                ProtectedCreateRequest(
                    draft: serviceTestDraft(
                        name: "Lockdown", domains: ["lockdown.example"], protectionMode: .lockdown))
            )
            .blocks.last)
        let website = try XCTUnwrap(
            protectedEngine.create(
                ProtectedCreateRequest(draft: serviceTestDraft(name: "Website"))
            )
            .blocks.last)
        let appOnly = try XCTUnwrap(
            protectedEngine.create(
                ProtectedCreateRequest(
                    draft: serviceTestDraft(
                        name: "App", domains: [], applications: [serviceTestApplication()]))
            )
            .blocks.last)
        for block in [lockdown, website, appOnly] {
            _ = try protectedEngine.activate(
                ProtectedRevisionRequest(id: block.id, expectedRevision: block.revision),
                appleLockdownActive: true)
        }
        endpoint.list { _ in }
        XCTAssertEqual(appleStore.persisted.hasUsedPlan, true)

        _ = try protectedEngine.requestEnd(ProtectedBlockRequest(id: lockdown.id))
        clock.reading = serviceTestReading(180)
        endpoint.list { _ in }
        XCTAssertEqual(try appleEngine.status().phase, .active)

        _ = try protectedEngine.requestEnd(ProtectedBlockRequest(id: website.id))
        clock.reading = serviceTestReading(360)
        endpoint.list { _ in }
        XCTAssertEqual(try appleEngine.status().phase, .readyForRelease)
        XCTAssertNotEqual(protectedEngine.list().blocks.first(where: { $0.id == appOnly.id })?.phase, .inactive)

        var releaseReply: AppleLockdownServiceReply?
        endpoint.beginAppleLockdownRelease { data in
            releaseReply = try? ProtectedServiceCodec.decode(AppleLockdownServiceReply.self, from: data)
        }
        XCTAssertNotNil(releaseReply?.credential)
    }

    private func configuredEngine(
        store: FakeAppleLockdownStateStore,
        vault: FakeAppleLockdownVault,
        clock: FakeServiceClock
    ) throws -> AppleLockdownEngine {
        let engine = try AppleLockdownEngine(
            stateStore: store,
            credentialVault: vault,
            passcodeGenerator: FakeAppleLockdownPasscodeGenerator(["4820"]),
            clock: clock
        )
        let setup = try engine.beginSetup(setupRequest())
        _ = try engine.completeSetup(
            AppleLockdownOperationRequest(operationID: setup.operationID)
        )
        return engine
    }

    private func setupRequest() -> AppleLockdownSetupRequest {
        AppleLockdownSetupRequest(
            fullUnlockDelay: 60,
            enablesAdultFilter: true,
            filterWasAlreadyEnabled: false,
            shareAcrossDevicesVerified: nil
        )
    }
}
