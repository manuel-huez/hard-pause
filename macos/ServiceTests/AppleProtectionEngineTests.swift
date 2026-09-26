import Darwin
import Foundation
import XCTest

final class AppleProtectionEngineTests: XCTestCase {
    func testInactiveAppleStateKeepsItsPreviousHandoffDigest() throws {
        XCTAssertEqual(
            try ServiceStateDigest.hash(AppleLockdownState()),
            "901204822ac837c3a7453cfe8782cfc3fdf2c45278b140ce4feac1dcd6e74d44")
    }

    func testActiveVersionTenStateKeepsItsHandoffDigestWithoutWebsitePermit() throws {
        let data = Data(
            #"{"accumulatedElapsed":0,"configuration":{"enablesAdultFilter":true,"filterWasAlreadyEnabled":false,"fullUnlockDelay":60},"credentialID":"00000000-0000-0000-0000-000000000123","hasUsedPlan":false,"phase":"active","schemaVersion":1}"#
                .utf8)
        let state = try JSONDecoder().decode(AppleLockdownState.self, from: data)
        try state.validateForPersistence()

        XCTAssertNil(state.pendingWebsiteSync)
        XCTAssertEqual(
            try ServiceStateDigest.hash(state),
            "070e9118d155ca57d4e81fd43e747b4ea6abbb9a7694dd2654259ac9780ceaab")
    }

    func testNativeWriterFingerprintDistinguishesProcessBirthAtTheSamePID() throws {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_start_tvsec > 0 else {
            return XCTFail("The test process must expose its birth time.")
        }
        let current = AppleWebsiteSyncWriter(
            processID: getpid(), startedAtSeconds: info.pbi_start_tvsec, startedAtMicroseconds: info.pbi_start_tvusec)
        let previous = AppleWebsiteSyncWriter(
            processID: current.processID, startedAtSeconds: current.startedAtSeconds - 1,
            startedAtMicroseconds: current.startedAtMicroseconds)

        XCTAssertTrue(try AppleWebsiteSyncProcess.isRunning(current))
        XCTAssertFalse(try AppleWebsiteSyncProcess.isRunning(previous))
    }

    func testWebsitePermitSurvivesRestartAndRequiresExactNativeProof() throws {
        let store = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let clock = FakeServiceClock(serviceTestReading(0))
        let engine = try configuredEngine(store: store, vault: vault, clock: clock)
        let targets = AppleWebsiteSyncTargets(restricted: ["example.com"], allowed: ["safe.example"])
        let savedCount = store.saved.count
        XCTAssertNil(try engine.websiteSyncOperation(targets: targets).operationID)
        XCTAssertEqual(store.saved.count, savedCount)
        let claim = AppleWebsiteSyncClaim(
            domains: targets.restricted, allowedDomains: targets.allowed,
            expectedDomains: targets.restricted, expectedAllowedDomains: targets.allowed)
        store.saveFailures = 1
        XCTAssertThrowsError(try engine.prepareWebsiteSync(claim, targets: targets, writer: websiteWriter))
        XCTAssertNil(store.persisted.pendingWebsiteSync)
        XCTAssertNil(store.persisted.mirroredDomains)

        let permit = try engine.prepareWebsiteSync(claim, targets: targets, writer: websiteWriter)
        let operationID = try XCTUnwrap(permit.operationID)
        XCTAssertEqual(store.persisted.mirroredDomains, targets.restricted)
        XCTAssertEqual(store.persisted.mirroredAllowedDomains, targets.allowed)
        try store.persisted.validateForPersistence()
        let restarted = try AppleLockdownEngine(stateStore: store, credentialVault: vault, clock: clock)
        let resumed = try restarted.websiteSyncOperation(targets: AppleWebsiteSyncTargets(blocks: []))
        XCTAssertEqual(resumed, permit)
        XCTAssertEqual(try restarted.status().websiteSyncOperationID, operationID)
        XCTAssertThrowsError(
            try restarted.completeWebsiteSync(
                AppleWebsiteSyncCompletion(
                    operationID: operationID, verifiedDomains: [], verifiedAllowedDomains: [],
                    mirroredDomains: targets.restricted, mirroredAllowedDomains: targets.allowed),
                writer: websiteWriter))
        XCTAssertThrowsError(
            try restarted.completeWebsiteSync(
                AppleWebsiteSyncCompletion(
                    operationID: operationID, verifiedDomains: targets.restricted,
                    verifiedAllowedDomains: targets.allowed,
                    mirroredDomains: [], mirroredAllowedDomains: []), writer: websiteWriter))
        let completion = AppleWebsiteSyncCompletion(
            operationID: operationID, verifiedDomains: targets.restricted, verifiedAllowedDomains: targets.allowed,
            mirroredDomains: targets.restricted, mirroredAllowedDomains: targets.allowed)
        store.saveFailures = 1
        XCTAssertThrowsError(try restarted.completeWebsiteSync(completion, writer: websiteWriter))
        XCTAssertEqual(store.persisted.pendingWebsiteSync?.operationID, operationID)
        XCTAssertTrue(restarted.activationReadiness().blocksAnyActivation)
        try restarted.completeWebsiteSync(completion, writer: websiteWriter)
        XCTAssertNil(try restarted.status().websiteSyncOperationID)
        XCTAssertFalse(restarted.activationReadiness().blocksAnyActivation)
    }

    func testWebsitePermitCannotBeSharedWithAnotherRunningApp() throws {
        let store = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let clock = FakeServiceClock(serviceTestReading(0))
        _ = try configuredEngine(store: store, vault: vault, clock: clock)
        var oldWriterIsRunning = true
        var writerProbeFails = false
        let engine = try AppleLockdownEngine(
            stateStore: store, credentialVault: vault, clock: clock,
            websiteSyncWriterIsRunning: { _ in
                if writerProbeFails { throw AppleLockdownError.websiteSyncWriterUnavailable }
                return oldWriterIsRunning
            })
        let targets = AppleWebsiteSyncTargets(restricted: ["example.com"], allowed: [])
        let claim = AppleWebsiteSyncClaim(
            domains: targets.restricted, allowedDomains: [],
            expectedDomains: targets.restricted, expectedAllowedDomains: [])
        let permit = try engine.prepareWebsiteSync(claim, targets: targets, writer: websiteWriter)
        let operationID = try XCTUnwrap(permit.operationID)
        // The same PID with another birth time is another app process.
        let newWriter = AppleWebsiteSyncWriter(
            processID: websiteWriter.processID, startedAtSeconds: websiteWriter.startedAtSeconds + 1,
            startedAtMicroseconds: 0)
        XCTAssertThrowsError(try engine.prepareWebsiteSync(claim, targets: targets, writer: newWriter)) {
            XCTAssertEqual($0 as? AppleLockdownError, .websiteSyncOwnedByAnotherApp)
        }
        writerProbeFails = true
        XCTAssertThrowsError(try engine.prepareWebsiteSync(claim, targets: targets, writer: newWriter))
        XCTAssertEqual(store.persisted.pendingWebsiteSync?.writer, websiteWriter)
        writerProbeFails = false
        oldWriterIsRunning = false
        let resumed = try engine.prepareWebsiteSync(claim, targets: targets, writer: newWriter)
        let newOperationID = try XCTUnwrap(resumed.operationID)
        XCTAssertNotEqual(newOperationID, operationID)
        let delayedCompletion = AppleWebsiteSyncCompletion(
            operationID: operationID, verifiedDomains: targets.restricted, verifiedAllowedDomains: [],
            mirroredDomains: targets.restricted, mirroredAllowedDomains: [])
        XCTAssertThrowsError(try engine.completeWebsiteSync(delayedCompletion, writer: newWriter))
        let completion = AppleWebsiteSyncCompletion(
            operationID: newOperationID, verifiedDomains: targets.restricted, verifiedAllowedDomains: [],
            mirroredDomains: targets.restricted, mirroredAllowedDomains: [])
        XCTAssertThrowsError(try engine.completeWebsiteSync(completion, writer: websiteWriter)) {
            XCTAssertEqual($0 as? AppleLockdownError, .operationMismatch)
        }
        try engine.completeWebsiteSync(completion, writer: newWriter)
        XCTAssertNil(store.persisted.pendingWebsiteSync)
    }

    func testWebsitePermitRejectsStaleTargetsAndGatesCommitmentChanges() throws {
        let clock = FakeServiceClock(serviceTestReading(0))
        let protectedEngine = try ProtectedServiceEngine(
            stateStore: FakeProtectedStateStore(), enforcer: FakeProtectionEnforcer(), clock: clock)
        let store = FakeAppleLockdownStateStore()
        let apple = try configuredEngine(store: store, vault: FakeAppleLockdownVault(), clock: clock)
        let coordinator = ProtectedServiceCoordinator()
        let endpoint = ProtectedServiceEndpoint(engine: protectedEngine, appleLockdown: apple, coordinator: coordinator)
        let updates = try websiteEndpoint(engine: protectedEngine, apple: apple, coordinator: coordinator)
        let first = try XCTUnwrap(
            protectedEngine.create(ProtectedCreateRequest(draft: serviceTestDraft())).blocks.first)
        _ = try protectedEngine.activate(ProtectedRevisionRequest(id: first.id, expectedRevision: first.revision))
        var inspection: AppleWebsiteSyncReply?
        updates.inspectWebsiteSync {
            inspection = try? ProtectedServiceCodec.decode(AppleWebsiteSyncReply.self, from: $0)
        }
        let before = try XCTUnwrap(inspection?.operation)
        let second = try XCTUnwrap(
            protectedEngine.create(
                ProtectedCreateRequest(draft: serviceTestDraft(name: "Second", domains: ["second.example"]))
            ).blocks.last)
        _ = try protectedEngine.activate(ProtectedRevisionRequest(id: second.id, expectedRevision: second.revision))
        let stale = try ProtectedServiceCodec.encode(
            AppleWebsiteSyncClaim(
                domains: [], allowedDomains: [], expectedDomains: before.activeDomains,
                expectedAllowedDomains: before.activeAllowedDomains))
        var staleReply: AppleWebsiteSyncReply?
        updates.claimWebsiteSync(stale) {
            staleReply = try? ProtectedServiceCodec.decode(AppleWebsiteSyncReply.self, from: $0)
        }
        XCTAssertNil(staleReply?.operation)
        XCTAssertNil(store.persisted.pendingWebsiteSync)

        let targets = AppleWebsiteSyncTargets(blocks: protectedEngine.list().blocks)
        let claim = try ProtectedServiceCodec.encode(
            AppleWebsiteSyncClaim(
                domains: targets.restricted, allowedDomains: targets.allowed,
                expectedDomains: targets.restricted, expectedAllowedDomains: targets.allowed))
        var claimed: AppleWebsiteSyncReply?
        updates.claimWebsiteSync(claim) {
            claimed = try? ProtectedServiceCodec.decode(AppleWebsiteSyncReply.self, from: $0)
        }
        let operationID = try XCTUnwrap(claimed?.operation?.operationID)
        let third = try XCTUnwrap(
            protectedEngine.create(
                ProtectedCreateRequest(draft: serviceTestDraft(name: "Third", domains: ["third.example"]))
            ).blocks.last)
        let activation = try ProtectedServiceCodec.encode(
            ProtectedRevisionRequest(id: third.id, expectedRevision: third.revision))
        var activationReply: ProtectedServiceReply?
        endpoint.activate(activation) {
            activationReply = try? ProtectedServiceCodec.decode(ProtectedServiceReply.self, from: $0)
        }
        XCTAssertEqual(activationReply?.error?.code, "website_sync_pending")
        let update = try ProtectedServiceCodec.encode(
            ProtectedUpdateRequest(
                id: third.id, expectedRevision: third.revision, draft: third.draft))
        var updateReply: ProtectedServiceReply?
        endpoint.update(update) {
            updateReply = try? ProtectedServiceCodec.decode(ProtectedServiceReply.self, from: $0)
        }
        XCTAssertEqual(updateReply?.error?.code, "website_sync_pending")
        XCTAssertThrowsError(try apple.freezeForLiveUpdate()) {
            XCTAssertEqual($0 as? AppleLockdownError, .websiteSyncPending)
        }
        XCTAssertThrowsError(try apple.beginRelease(normalProtectionIsInactiveAndHealthy: true)) {
            XCTAssertEqual($0 as? AppleLockdownError, .websiteSyncPending)
        }
        let breakRequest = try ProtectedServiceCodec.encode(ProtectedBlockRequest(id: first.id))
        var breakReply: ProtectedServiceReply?
        endpoint.requestBreak(breakRequest) {
            breakReply = try? ProtectedServiceCodec.decode(ProtectedServiceReply.self, from: $0)
        }
        XCTAssertNil(breakReply?.error)
        endpoint.cancelBreak(breakRequest) {
            breakReply = try? ProtectedServiceCodec.decode(ProtectedServiceReply.self, from: $0)
        }
        XCTAssertNil(breakReply?.error)
        endpoint.requestBreak(breakRequest) { _ in }
        clock.reading = serviceTestReading(60)
        let duringBreak = protectedEngine.list()
        guard case .breakActive = duringBreak.blocks.first(where: { $0.id == first.id })?.phase else {
            return XCTFail("The first plan must reach its break.")
        }
        XCTAssertEqual(AppleWebsiteSyncTargets(blocks: duringBreak.blocks), targets)
        let completion = try ProtectedServiceCodec.encode(
            AppleWebsiteSyncCompletion(
                operationID: operationID, verifiedDomains: targets.restricted, verifiedAllowedDomains: targets.allowed,
                mirroredDomains: targets.restricted, mirroredAllowedDomains: targets.allowed))
        var completed: AppleLockdownServiceReply?
        updates.completeWebsiteSync(completion) {
            completed = try? ProtectedServiceCodec.decode(AppleLockdownServiceReply.self, from: $0)
        }
        XCTAssertNil(completed?.error)
        endpoint.activate(activation) {
            activationReply = try? ProtectedServiceCodec.decode(ProtectedServiceReply.self, from: $0)
        }
        XCTAssertNil(activationReply?.error)
    }

    func testReleaseCleanupPermitResumesWithoutRemovingUnownedWebsites() throws {
        let store = FakeAppleLockdownStateStore()
        let clock = FakeServiceClock(serviceTestReading(0))
        let apple = try configuredEngine(store: store, vault: FakeAppleLockdownVault(), clock: clock)
        let targets = AppleWebsiteSyncTargets(restricted: ["example.com"], allowed: [])
        let first = try apple.prepareWebsiteSync(
            AppleWebsiteSyncClaim(
                domains: targets.restricted, allowedDomains: [], expectedDomains: targets.restricted,
                expectedAllowedDomains: []), targets: targets, writer: websiteWriter)
        try apple.completeWebsiteSync(
            AppleWebsiteSyncCompletion(
                operationID: XCTUnwrap(first.operationID), verifiedDomains: targets.restricted,
                verifiedAllowedDomains: [], mirroredDomains: targets.restricted, mirroredAllowedDomains: []),
            writer: websiteWriter)
        _ = try apple.requestEnd()
        clock.reading = serviceTestReading(60)
        let release = try apple.beginRelease(normalProtectionIsInactiveAndHealthy: true)
        let emptyTargets = AppleWebsiteSyncTargets(blocks: [])
        let cleanup = try apple.prepareWebsiteSync(
            AppleWebsiteSyncClaim(
                domains: [], allowedDomains: [], expectedDomains: [], expectedAllowedDomains: []),
            targets: emptyTargets, writer: websiteWriter)
        XCTAssertEqual(
            try apple.beginRelease(normalProtectionIsInactiveAndHealthy: true).operationID, release.operationID)
        let releaseCompletion = AppleLockdownOperationRequest(operationID: release.operationID)
        XCTAssertThrowsError(try apple.completeRelease(releaseCompletion)) {
            XCTAssertEqual($0 as? AppleLockdownError, .websiteSyncPending)
        }
        let cleanupID = try XCTUnwrap(cleanup.operationID)
        XCTAssertThrowsError(
            try apple.completeWebsiteSync(
                AppleWebsiteSyncCompletion(
                    operationID: cleanupID, verifiedDomains: ["example.com", "user.example"],
                    verifiedAllowedDomains: [],
                    mirroredDomains: [], mirroredAllowedDomains: []), writer: websiteWriter))
        try apple.completeWebsiteSync(
            AppleWebsiteSyncCompletion(
                operationID: cleanupID, verifiedDomains: ["user.example"],
                verifiedAllowedDomains: ["user-allow.example"],
                mirroredDomains: [], mirroredAllowedDomains: []), writer: websiteWriter)
        XCTAssertNil(store.persisted.pendingWebsiteSync)
        XCTAssertEqual(try apple.completeRelease(releaseCompletion).phase, .inactive)
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

    func testUnusedZeroDelaySetupCanBeRemovedButDependentPlanPreventsRemoval() throws {
        let clock = FakeServiceClock(serviceTestReading(0))
        let protectedEngine = try ProtectedServiceEngine(
            stateStore: FakeProtectedStateStore(),
            enforcer: FakeProtectionEnforcer(),
            clock: clock
        )
        let appleStore = FakeAppleLockdownStateStore()
        let vault = FakeAppleLockdownVault()
        let appleEngine = try AppleLockdownEngine(
            stateStore: appleStore,
            credentialVault: vault,
            passcodeGenerator: FakeAppleLockdownPasscodeGenerator(["4820", "7361"]),
            clock: clock
        )
        let endpoint = ProtectedServiceEndpoint(
            engine: protectedEngine,
            appleLockdown: appleEngine,
            coordinator: ProtectedServiceCoordinator()
        )
        let zeroDelaySetup = AppleLockdownSetupRequest(
            fullUnlockDelay: 0,
            enablesAdultFilter: true,
            filterWasAlreadyEnabled: false,
            shareAcrossDevicesVerified: nil
        )

        let unusedSetup = try appleEngine.beginSetup(zeroDelaySetup)
        _ = try appleEngine.completeSetup(
            AppleLockdownOperationRequest(operationID: unusedSetup.operationID)
        )
        var endReply: AppleLockdownServiceReply?
        endpoint.requestAppleLockdownEnd { data in
            endReply = try? ProtectedServiceCodec.decode(AppleLockdownServiceReply.self, from: data)
        }
        XCTAssertNil(endReply?.error)
        XCTAssertEqual(try appleEngine.status().phase, .readyForRelease)

        var releaseReply: AppleLockdownServiceReply?
        endpoint.beginAppleLockdownRelease { data in
            releaseReply = try? ProtectedServiceCodec.decode(AppleLockdownServiceReply.self, from: data)
        }
        let release = try XCTUnwrap(releaseReply?.credential)
        let completion = try ProtectedServiceCodec.encode(
            AppleLockdownOperationRequest(operationID: release.operationID)
        )
        var completionReply: AppleLockdownServiceReply?
        endpoint.completeAppleLockdownRelease(completion) { data in
            completionReply = try? ProtectedServiceCodec.decode(
                AppleLockdownServiceReply.self, from: data)
        }
        XCTAssertNil(completionReply?.error)
        XCTAssertEqual(completionReply?.snapshot?.phase, .inactive)
        XCTAssertTrue(vault.values.isEmpty)

        let dependentSetup = try appleEngine.beginSetup(zeroDelaySetup)
        _ = try appleEngine.completeSetup(
            AppleLockdownOperationRequest(operationID: dependentSetup.operationID)
        )
        let block = try XCTUnwrap(
            protectedEngine.create(
                ProtectedCreateRequest(draft: serviceTestDraft(protectionMode: .lockdown))
            ).blocks.first
        )
        let activation = try ProtectedServiceCodec.encode(
            ProtectedRevisionRequest(id: block.id, expectedRevision: block.revision)
        )
        var activationReply: ProtectedServiceReply?
        endpoint.activate(activation) { data in
            activationReply = try? ProtectedServiceCodec.decode(ProtectedServiceReply.self, from: data)
        }
        XCTAssertNil(activationReply?.error)

        var dependentEndReply: AppleLockdownServiceReply?
        endpoint.requestAppleLockdownEnd { data in
            dependentEndReply = try? ProtectedServiceCodec.decode(
                AppleLockdownServiceReply.self, from: data)
        }
        XCTAssertEqual(dependentEndReply?.error?.code, "invalid_request")
        XCTAssertEqual(try appleEngine.status().phase, .active)

        var guardedReleaseReply: AppleLockdownServiceReply?
        endpoint.beginAppleLockdownRelease { data in
            guardedReleaseReply = try? ProtectedServiceCodec.decode(
                AppleLockdownServiceReply.self, from: data)
        }
        XCTAssertEqual(guardedReleaseReply?.error?.code, "normal_protection_active")
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

    private var websiteWriter: AppleWebsiteSyncWriter {
        AppleWebsiteSyncWriter(processID: 123, startedAtSeconds: 1_700_000_000, startedAtMicroseconds: 0)
    }

    private func websiteEndpoint(
        engine: ProtectedServiceEngine, apple: AppleLockdownEngine, coordinator: ProtectedServiceCoordinator
    ) throws -> ProtectedServiceUpdateEndpoint {
        let authorizer = try ClientAuthorizer(
            enrollment: ProtectedServiceEnrollment(
                enrolledUID: 501,
                approvedClientRequirements: [
                    #"identifier "org.hardpause.app""#, #"identifier "org.hardpause.cli""#,
                    #"identifier "org.hardpause.browser-worker""#,
                ]))
        let trigger = PrivilegedServiceUpdateTrigger(
            engine: engine, appleLockdown: apple, authorizer: authorizer, runningDigest: "test")
        return ProtectedServiceUpdateEndpoint(
            trigger: trigger, engine: engine, appleLockdown: apple, coordinator: coordinator,
            websiteSyncWriter: { self.websiteWriter })
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
