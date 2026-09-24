import Foundation
import XCTest

final class ProtectedBlockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testInactiveBlockCanBeUpdatedAndDeletedWithCurrentRevision() throws {
        var state = ProtectedState()
        let created = try state.create(makeDraft(name: "Study", domains: ["www.example.com"]))

        try state.update(
            id: created.id,
            expectedRevision: created.revision,
            draft: makeDraft(name: "Deep work", domains: ["docs.example.com"])
        )

        let updated = try XCTUnwrap(state.blocks.first)
        XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(updated.draft.name, "Deep work")
        try state.delete(id: updated.id, expectedRevision: updated.revision)
        XCTAssertTrue(state.blocks.isEmpty)
    }

    func testActiveBlockKeepsFixedRulesAndCannotBeUpdatedOrDeleted() throws {
        var state = ProtectedState()
        let created = try state.create(makeDraft(name: "Work", domains: ["example.com"]))
        try state.activate(id: created.id, expectedRevision: created.revision, at: reading(0))
        let active = try XCTUnwrap(state.blocks.first)

        XCTAssertThrowsError(
            try state.update(
                id: active.id,
                expectedRevision: active.revision,
                draft: makeDraft(name: "Changed", domains: ["other.example"])
            )
        ) { error in
            XCTAssertEqual(error as? ProtectedStateError, .activeBlockIsImmutable)
        }
        XCTAssertThrowsError(try state.delete(id: active.id, expectedRevision: active.revision)) { error in
            XCTAssertEqual(error as? ProtectedStateError, .activeBlockIsImmutable)
        }
        XCTAssertEqual(state.blocks.first?.activation?.frozenDraft, active.draft)
    }

    func testActiveBlockCanGainRulesWithoutChangingItsCommitment() throws {
        var state = ProtectedState()
        let original = makeDraft(
            domains: ["example.com"],
            applications: [makeApplication("org.example.old", name: "Old")]
        )
        let created = try state.create(original)
        try state.activate(id: created.id, expectedRevision: created.revision, at: reading(0))
        let active = try XCTUnwrap(state.blocks.first)
        let addedRules = original.rules.adding(
            domains: ["new.example"],
            urlPatterns: ["*.new.example"],
            applications: [makeApplication("org.example.new", name: "New")],
            adultWebsites: true
        )
        let strengthened = ProtectedBlockDraft(
            name: original.name,
            rules: addedRules,
            protectionMode: original.protectionMode,
            breakDelay: original.breakDelay,
            fullUnlockDelay: original.fullUnlockDelay,
            breakDuration: original.breakDuration,
            elapsedDuration: original.elapsedDuration
        )

        try state.update(id: active.id, expectedRevision: active.revision, draft: strengthened)

        let updated = try XCTUnwrap(state.blocks.first)
        XCTAssertEqual(updated.activation?.frozenDraft, strengthened)
        XCTAssertEqual(updated.draft, strengthened)
        XCTAssertEqual(updated.revision, active.revision + 1)
        XCTAssertEqual(
            Set(state.effectiveRestrictions().blockedDomains),
            Set(["example.com", "new.example", "www.new.example"])
        )
        XCTAssertEqual(state.effectiveRestrictions().blockedApplications.count, 2)
        try state.validateForPersistence()

        XCTAssertThrowsError(
            try state.update(id: updated.id, expectedRevision: updated.revision, draft: original)
        ) { error in
            XCTAssertEqual(error as? ProtectedStateError, .activeBlockIsImmutable)
        }
        let shorterWait = ProtectedBlockDraft(
            name: strengthened.name,
            rules: strengthened.rules,
            protectionMode: strengthened.protectionMode,
            breakDelay: strengthened.breakDelay,
            fullUnlockDelay: 60,
            breakDuration: strengthened.breakDuration,
            elapsedDuration: strengthened.elapsedDuration
        )
        XCTAssertThrowsError(
            try state.update(id: updated.id, expectedRevision: updated.revision, draft: shorterWait)
        ) { error in
            XCTAssertEqual(error as? ProtectedStateError, .activeBlockIsImmutable)
        }
        XCTAssertEqual(state.blocks.first, updated)
    }

    func testLegacyDraftWithoutProtectionModeDefaultsToSoftLock() throws {
        let draft = makeDraft()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any]
        )
        object.removeValue(forKey: "protectionMode")

        let restored = try JSONDecoder().decode(
            ProtectedBlockDraft.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(restored.protectionMode, .softLock)
        XCTAssertEqual(restored.breakDelay, draft.breakDelay)
        XCTAssertEqual(restored.elapsedDuration, draft.elapsedDuration)
    }

    func testPresentMalformedProtectionModeIsRejected() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(makeDraft())) as? [String: Any]
        )
        object["protectionMode"] = "strict"

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ProtectedBlockDraft.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testProtectionModePersistsThroughRoundTrip() throws {
        let draft = makeDraft(protectionMode: .lockdown)

        let restored = try JSONDecoder().decode(
            ProtectedBlockDraft.self,
            from: JSONEncoder().encode(draft)
        )

        XCTAssertEqual(restored, draft)
        XCTAssertEqual(restored.protectionMode, .lockdown)
    }

    func testLockdownRejectsFixedDurationAndBreakRequests() throws {
        XCTAssertThrowsError(
            try makeDraft(protectionMode: .lockdown, elapsedDuration: 3_600).validatedForMutation()
        ) { error in
            XCTAssertEqual(
                error as? ProtectedStateError,
                .invalid("A Hard Pause plan cannot end automatically.")
            )
        }

        var state = ProtectedState()
        let block = try state.create(makeDraft(protectionMode: .lockdown))
        try state.activate(id: block.id, expectedRevision: block.revision, at: reading(0))

        XCTAssertThrowsError(try state.request(.breakAccess, id: block.id, at: reading(0))) { error in
            XCTAssertEqual(
                error as? ProtectedStateError,
                .invalid("Hard Pause plans do not allow breaks.")
            )
        }
    }

    func testLockdownFullUnlockUsesConfiguredDelay() throws {
        var state = ProtectedState()
        let block = try state.create(
            makeDraft(protectionMode: .lockdown, fullUnlockDelay: 180)
        )
        try state.activate(id: block.id, expectedRevision: block.revision, at: reading(0))
        try state.request(.fullUnlock, id: block.id, at: reading(0))

        XCTAssertTrue(state.advance(to: reading(179)).isEmpty)
        XCTAssertNotNil(state.blocks.first?.activation)
        XCTAssertEqual(state.advance(to: reading(180)), Set([block.id]))
        XCTAssertNil(state.blocks.first?.activation)
    }

    func testPersistenceRejectsLockdownWithPendingOrActiveBreak() throws {
        var pendingState = ProtectedState()
        let pendingBlock = try pendingState.create(makeDraft())
        try pendingState.activate(
            id: pendingBlock.id,
            expectedRevision: pendingBlock.revision,
            at: reading(0)
        )
        try pendingState.request(.breakAccess, id: pendingBlock.id, at: reading(0))
        let pendingLockdown = try decodeState(
            replacingProtectionModeWith: .lockdown,
            in: pendingState
        )
        XCTAssertThrowsError(try pendingLockdown.validateForPersistence()) { error in
            XCTAssertEqual(
                error as? ProtectedStateError,
                .invalid("A Hard Pause plan contains a pending break request.")
            )
        }

        var breakState = pendingState
        breakState.advance(to: reading(60))
        let activeBreakLockdown = try decodeState(
            replacingProtectionModeWith: .lockdown,
            in: breakState
        )
        XCTAssertThrowsError(try activeBreakLockdown.validateForPersistence()) { error in
            XCTAssertEqual(
                error as? ProtectedStateError,
                .invalid("A Hard Pause plan contains an active break.")
            )
        }
    }

    func testOverlappingBlocksKeepSharedRestrictionDuringOneBlocksBreak() throws {
        let app = makeApplication("org.example.chat", name: "Chat")
        var state = ProtectedState()
        let first = try state.create(
            makeDraft(
                name: "First",
                domains: ["shared.example", "first.example"],
                applications: [app],
                breakDelay: 60,
                breakDuration: 180
            )
        )
        let second = try state.create(
            makeDraft(
                name: "Second",
                domains: ["shared.example", "second.example"],
                applications: [app]
            )
        )
        try state.activate(id: first.id, expectedRevision: first.revision, at: reading(0))
        try state.activate(id: second.id, expectedRevision: second.revision, at: reading(0))

        var restrictions = state.effectiveRestrictions()
        XCTAssertEqual(
            Set(restrictions.blockedDomains),
            Set(["first.example", "second.example", "shared.example"])
        )
        XCTAssertEqual(restrictions.blockedApplications, [app])

        try state.request(.breakAccess, id: first.id, at: reading(0))
        state.advance(to: reading(60))
        restrictions = state.effectiveRestrictions()
        XCTAssertEqual(Set(restrictions.blockedDomains), Set(["second.example", "shared.example"]))
        XCTAssertEqual(restrictions.blockedApplications, [app])
        XCTAssertEqual(restrictions.contributingBlockIDs, [second.id])
    }

    func testNaturalDurationEndsBlockBeforePendingFullUnlock() throws {
        var state = ProtectedState()
        let block = try state.create(
            makeDraft(
                fullUnlockDelay: 300,
                elapsedDuration: 120
            )
        )
        try state.activate(id: block.id, expectedRevision: block.revision, at: reading(0))
        try state.request(.fullUnlock, id: block.id, at: reading(0))

        XCTAssertTrue(state.advance(to: reading(119)).isEmpty)
        XCTAssertNotNil(state.blocks.first?.activation)
        XCTAssertEqual(state.advance(to: reading(120)), Set([block.id]))
        XCTAssertNil(state.blocks.first?.activation)
        XCTAssertTrue(state.effectiveRestrictions().blockedDomains.isEmpty)
    }

    func testNaturalDurationEndsBlockDuringBreak() throws {
        var state = ProtectedState()
        let block = try state.create(
            makeDraft(breakDelay: 60, breakDuration: 300, elapsedDuration: 120)
        )
        try state.activate(id: block.id, expectedRevision: block.revision, at: reading(0))
        try state.request(.breakAccess, id: block.id, at: reading(0))

        state.advance(to: reading(60))
        XCTAssertTrue(state.effectiveRestrictions().blockedDomains.isEmpty)
        XCTAssertEqual(state.advance(to: reading(120)), Set([block.id]))
        XCTAssertNil(state.blocks.first?.activation)
    }

    func testBreakAndFullUnlockUseSeparateDelays() throws {
        var breakState = ProtectedState()
        let breakBlock = try breakState.create(makeDraft(breakDelay: 60, fullUnlockDelay: 180))
        try breakState.activate(
            id: breakBlock.id,
            expectedRevision: breakBlock.revision,
            at: reading(0)
        )
        try breakState.request(.breakAccess, id: breakBlock.id, at: reading(0))
        breakState.advance(to: reading(60))
        XCTAssertTrue(breakState.blocks.first?.activation?.phase().isBreakActive == true)

        var endState = ProtectedState()
        let endBlock = try endState.create(makeDraft(breakDelay: 60, fullUnlockDelay: 180))
        try endState.activate(id: endBlock.id, expectedRevision: endBlock.revision, at: reading(0))
        try endState.request(.fullUnlock, id: endBlock.id, at: reading(0))
        endState.advance(to: reading(60))
        XCTAssertNotNil(endState.blocks.first?.activation)
        XCTAssertEqual(endState.advance(to: reading(180)), Set([endBlock.id]))
    }

    func testFullUnlockRequestKeepsCurrentBreakOpenOnMacOS() throws {
        var state = ProtectedState()
        let block = try state.create(
            makeDraft(breakDelay: 60, fullUnlockDelay: 180, breakDuration: 300)
        )
        try state.activate(id: block.id, expectedRevision: block.revision, at: reading(0))
        try state.request(.breakAccess, id: block.id, at: reading(0))
        state.advance(to: reading(60))

        try state.request(.fullUnlock, id: block.id, at: reading(90))

        XCTAssertEqual(
            state.blocks.first?.activation?.phase(),
            .breakActive(
                remaining: 270,
                fullUnlockRemaining: 180,
                naturalEndRemaining: nil
            )
        )
        XCTAssertTrue(state.effectiveRestrictions().blockedDomains.isEmpty)
        XCTAssertEqual(state.advance(to: reading(270)), Set([block.id]))
    }

    func testSharedCoreMatchesLegacyMacLifecycleTrace() throws {
        let draft = makeDraft(
            breakDelay: 60,
            fullUnlockDelay: 180,
            breakDuration: 150,
            elapsedDuration: 600
        )
        var shared = ProtectedActivation(draft: draft, reading: reading(0))
        var legacy = LegacyMacLifecycle()

        try shared.request(.breakAccess, at: reading(0))
        legacy.request(.breakAccess, at: 0)
        for elapsed in [30.0, 60.0] {
            XCTAssertEqual(shared.advance(to: reading(elapsed)), legacy.advance(to: elapsed, draft: draft))
            XCTAssertEqual(shared.phase(), legacy.phase(draft: draft))
        }

        try shared.request(.fullUnlock, at: reading(90))
        _ = legacy.advance(to: 90, draft: draft)
        legacy.request(.fullUnlock, at: 90)
        XCTAssertEqual(shared.phase(), legacy.phase(draft: draft))

        for elapsed in [120.0, 209.0, 210.0, 269.0, 270.0] {
            let sharedIsActive = shared.advance(to: reading(elapsed))
            let legacyIsActive = legacy.advance(to: elapsed, draft: draft)
            XCTAssertEqual(sharedIsActive, legacyIsActive, "elapsed=\(elapsed)")
            XCTAssertEqual(shared.accumulatedElapsed, legacy.accumulatedElapsed)
            if sharedIsActive {
                XCTAssertEqual(shared.phase(), legacy.phase(draft: draft), "elapsed=\(elapsed)")
            }
        }
    }

    func testPendingRequestCannotBeReplaced() throws {
        var state = ProtectedState()
        let block = try state.create(makeDraft())
        try state.activate(id: block.id, expectedRevision: block.revision, at: reading(0))
        try state.request(.breakAccess, id: block.id, at: reading(0))
        let pending = state.blocks.first?.activation?.pendingRequest

        XCTAssertThrowsError(try state.request(.fullUnlock, id: block.id, at: reading(30))) { error in
            XCTAssertEqual(error as? ProtectedStateError, .pendingRequestExists)
        }
        XCTAssertEqual(state.blocks.first?.activation?.pendingRequest, pending)
    }

    func testPendingBreakCanBeCancelledWithoutRelaxingProtectionOrNaturalEnd() throws {
        var state = ProtectedState()
        let block = try state.create(makeDraft(elapsedDuration: 300))
        try state.activate(id: block.id, expectedRevision: block.revision, at: reading(0))
        try state.request(.breakAccess, id: block.id, at: reading(0))

        try state.cancelBreakRequest(id: block.id, at: reading(30))

        let cancelled = try XCTUnwrap(state.blocks.first)
        XCTAssertEqual(cancelled.revision, 4)
        XCTAssertNil(cancelled.activation?.pendingRequest)
        XCTAssertEqual(cancelled.activation?.phase(), .active(naturalEndRemaining: 270))
        XCTAssertEqual(state.effectiveRestrictions().blockedDomains, ["example.com"])
        XCTAssertEqual(state.effectiveRestrictions().contributingBlockIDs, [block.id])
    }

    func testCancelBreakRejectsMissingRequestAndPreservesPendingFullUnlock() throws {
        var state = ProtectedState()
        let block = try state.create(makeDraft(fullUnlockDelay: 180))
        try state.activate(id: block.id, expectedRevision: block.revision, at: reading(0))

        XCTAssertThrowsError(try state.cancelBreakRequest(id: block.id, at: reading(30))) { error in
            XCTAssertEqual(error as? ProtectedStateError, .noPendingBreakRequest)
        }

        try state.request(.fullUnlock, id: block.id, at: reading(0))
        let pendingUnlock = state.blocks.first?.activation?.pendingRequest
        XCTAssertThrowsError(try state.cancelBreakRequest(id: block.id, at: reading(30))) { error in
            XCTAssertEqual(error as? ProtectedStateError, .noPendingBreakRequest)
        }
        XCTAssertEqual(state.blocks.first?.activation?.pendingRequest, pendingUnlock)
        XCTAssertEqual(
            state.blocks.first?.activation?.phase(),
            .waitingForFullUnlock(remaining: 180, naturalEndRemaining: nil)
        )
    }

    func testOnlyWaitingForBreakPhaseCanCancelBreak() {
        XCTAssertTrue(
            ProtectedBlockPhase.waitingForBreak(remaining: 30, naturalEndRemaining: nil).canCancelBreak
        )
        XCTAssertFalse(ProtectedBlockPhase.active(naturalEndRemaining: nil).canCancelBreak)
        XCTAssertFalse(
            ProtectedBlockPhase.waitingForFullUnlock(
                remaining: 30,
                naturalEndRemaining: nil
            ).canCancelBreak
        )
        XCTAssertFalse(
            ProtectedBlockPhase.breakActive(
                remaining: 30,
                fullUnlockRemaining: nil,
                naturalEndRemaining: nil
            ).canCancelBreak
        )
        XCTAssertFalse(ProtectedBlockPhase.inactive.canCancelBreak)
    }

    func testRebootDoesNotAddUnverifiedElapsedTime() throws {
        var state = ProtectedState()
        let block = try state.create(makeDraft(fullUnlockDelay: 180))
        try state.activate(id: block.id, expectedRevision: block.revision, at: reading(0))
        try state.request(.fullUnlock, id: block.id, at: reading(0))
        state.advance(to: reading(60))

        state.advance(to: reading(10_000, continuousTime: 20, bootIdentifier: "boot-b"))
        XCTAssertEqual(state.blocks.first?.activation?.accumulatedElapsed, 60)
        XCTAssertNotNil(state.blocks.first?.activation)

        XCTAssertEqual(
            state.advance(to: reading(10_120, continuousTime: 140, bootIdentifier: "boot-b")),
            Set([block.id])
        )
    }

    func testProtectedStateRoundTripRetainsIndependentActiveBlocks() throws {
        var state = ProtectedState()
        let first = try state.create(makeDraft(name: "First", domains: ["one.example"]))
        let second = try state.create(makeDraft(name: "Second", domains: ["two.example"]))
        try state.activate(id: first.id, expectedRevision: first.revision, at: reading(0))
        try state.activate(id: second.id, expectedRevision: second.revision, at: reading(0))
        state.advance(to: reading(45))

        let encoded = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(ProtectedState.self, from: encoded)
        try restored.validateForPersistence()
        XCTAssertEqual(restored, state)
        XCTAssertEqual(Set(restored.effectiveRestrictions().contributingBlockIDs), Set([first.id, second.id]))
    }

    func testNewApplicationRuleRequiresSignedIdentity() {
        let legacyApplication = ProtectedApplication(
            bundleIdentifier: "org.example.legacy",
            displayName: "Legacy",
            designatedRequirement: nil
        )
        let draft = makeDraft(applications: [legacyApplication])

        XCTAssertThrowsError(try draft.validatedForMutation()) { error in
            XCTAssertEqual(
                error as? ProtectedStateError,
                .invalid("Choose the application again so Hard Pause can save its signed identity.")
            )
        }
    }

    func testDomainRulesPreserveExactHostAndAcceptLiteralAddresses() {
        XCTAssertEqual(DomainRule.normalize(" HTTPS://WWW.Example.COM/path "), "www.example.com")
        XCTAssertNil(DomainRule.normalize("*.example.com"))
        XCTAssertEqual(DomainRule.normalize("203.0.113.10"), "203.0.113.10")
        XCTAssertEqual(DomainRule.normalize("2001:db8::1"), "2001:db8::1")
        XCTAssertEqual(DomainRule.normalize("https://[2001:db8::1]/path"), "2001:db8::1")
        XCTAssertTrue(DomainRule.isLiteralIPAddress("203.0.113.10"))
        XCTAssertTrue(DomainRule.isLiteralIPAddress("2001:db8::1"))
        XCTAssertFalse(DomainRule.isLiteralIPAddress("example.com"))
    }

    func testUnicodeRulesPreserveComposedStoredHosts() throws {
        XCTAssertEqual(DomainRule.normalize("e\u{301}.example"), "é.example")
        XCTAssertEqual(DomainRule.normalize("क\u{93F}.example"), "कि.example")
        XCTAssertEqual(DomainRule.normalize("क्ष.example"), "क्ष.example")
        XCTAssertEqual(URLPatternRule.normalize("e\u{301}.example/read"), "é.example/read")
        let rules = ProtectedRules(
            blockedDomains: ["e\u{301}.example", "क\u{93F}.example"],
            blockedApplications: [], blocksStarterAdultSites: false
        )
        XCTAssertEqual(rules.blockedDomains, ["é.example", "कि.example"])
        try rules.validateForPersistence()
    }

    func testURLPatternNormalizationAndExactDomainClassification() {
        XCTAssertEqual(
            URLPatternRule.normalize(" HTTPS://*.Example.COM:0443/r/Focus/ "),
            "https://*.example.com:443/r/Focus"
        )
        XCTAssertEqual(URLPatternRule.exactDomain(from: "https://Example.COM/"), "example.com")
        XCTAssertEqual(URLPatternRule.exactDomain(from: "[2001:db8::1]"), "2001:db8::1")
        XCTAssertNil(URLPatternRule.exactDomain(from: "example.com/r/focus"))
        XCTAssertNil(URLPatternRule.exactDomain(from: "example.com?mode=focus"))
        XCTAssertNil(URLPatternRule.exactDomain(from: "example.com:8443"))
        XCTAssertNil(URLPatternRule.exactDomain(from: "*.example.com"))
    }

    func testURLPatternMatchesExactAndWildcardHostsAtLabelBoundaries() throws {
        XCTAssertTrue(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://example.com:8443/anywhere?value=1")),
                pattern: "example.com"
            )
        )
        XCTAssertFalse(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://sub.example.com")),
                pattern: "example.com"
            )
        )
        XCTAssertTrue(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://deep.sub.example.com/path")),
                pattern: "*.example.com"
            )
        )
        XCTAssertFalse(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://example.com")),
                pattern: "*.example.com"
            )
        )
        XCTAssertFalse(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://evil-example.com")),
                pattern: "*.example.com"
            )
        )
        XCTAssertTrue(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://catalog.example.xxx")),
                pattern: "*.xxx"
            )
        )
        XCTAssertFalse(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://example.xxx.invalid")),
                pattern: "*.xxx"
            )
        )
    }

    func testURLPatternPathUsesSegmentBoundaryAndIgnoresUnspecifiedPortAndQuery() throws {
        let pattern = "reddit.com/r/focus"
        XCTAssertTrue(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://reddit.com:8443/r/focus?sort=new")),
                pattern: pattern
            )
        )
        XCTAssertTrue(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://reddit.com/r/focus/comments/1?sort=new")),
                pattern: pattern
            )
        )
        XCTAssertFalse(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://reddit.com/r/focused")),
                pattern: pattern
            )
        )
        XCTAssertFalse(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://www.reddit.com/r/focus")),
                pattern: pattern
            )
        )
        XCTAssertTrue(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://reddit.com/r/focus")),
                pattern: "reddit.com:443/r/focus"
            )
        )
        XCTAssertFalse(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://reddit.com:8443/r/focus")),
                pattern: "reddit.com:443/r/focus"
            )
        )
    }

    func testURLPatternGlobTreatsNonStarCharactersLiterally() throws {
        let literalPattern = "example.com/v1.0+copy(1)/*"
        XCTAssertTrue(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://example.com/v1.0+copy(1)/file")),
                pattern: literalPattern
            )
        )
        XCTAssertFalse(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://example.com/v1X0copy1/file")),
                pattern: literalPattern
            )
        )
        XCTAssertTrue(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://example.com/search?term=a.b+value")),
                pattern: "example.com/search?term=a.b+*"
            )
        )
        XCTAssertFalse(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://example.com/search?term=aXb+value")),
                pattern: "example.com/search?term=a.b+*"
            )
        )
    }

    func testURLPatternRejectsMalformedInputs() {
        for input in [
            "", "*", "*.", "foo.*.example", "https://", "://example.com",
            "user@example.com", "example.com:0", "example.com:65536", "example.com/a b",
            "example.com\\path",
        ] {
            XCTAssertNil(URLPatternRule.normalize(input), input)
        }
    }

    func testWildcardRulesIncludeCommonHostCoverage() throws {
        let rules = ProtectedRules(
            blockedDomains: [],
            blockedApplications: [],
            blocksStarterAdultSites: false,
            blockedURLPatterns: [" *.Example.COM ", "example.com/r/focus", "*.example.com"]
        )

        try rules.validateForPersistence()
        XCTAssertEqual(
            rules.blockedURLPatterns,
            ["*.example.com", "example.com/r/focus"]
        )
        XCTAssertEqual(rules.allBlockedDomains, ["www.example.com"])
    }

    func testNetworkAliasesDoNotBroadenScopedPatterns() {
        for pattern in [
            "https://*.example.com", "*.example.com:443", "*.example.com/videos",
            "*.example.com/*", "example.com", "*.xxx",
        ] {
            XCTAssertEqual(URLPatternRule.networkDomains(from: pattern), [], pattern)
        }
        XCTAssertEqual(URLPatternRule.networkDomains(from: "*.example.com"), ["www.example.com"])
    }

    func testNetworkAliasesAreDeduplicatedAndPersistedAsExactRules() throws {
        let rules = ProtectedRules(
            blockedDomains: ["example.com", "www.example.com"], blockedApplications: [],
            blocksStarterAdultSites: false, blockedURLPatterns: ["*.example.com", "*.example.com"]
        )
        XCTAssertEqual(rules.blockedDomains, ["example.com", "www.example.com"])
        let decoded = try JSONDecoder().decode(ProtectedRules.self, from: JSONEncoder().encode(rules))
        XCTAssertEqual(decoded, rules)
    }

    func testProtectedRulesDecodeLegacyDataWithoutURLPatterns() throws {
        let legacy = Data(
            #"{"blockedDomains":["example.com"],"blockedApplications":[],"blockedAdultDomains":[]}"#.utf8
        )

        let rules = try JSONDecoder().decode(ProtectedRules.self, from: legacy)

        XCTAssertEqual(rules.blockedDomains, ["example.com"])
        XCTAssertTrue(rules.blockedURLPatterns.isEmpty)
        try rules.validateForPersistence()
    }

    func testProtectedRulesValidationRejectsMalformedOrDuplicateURLPatterns() {
        for patterns in [["foo.*.example"], ["*.example.com", "*.example.com"]] {
            let rules = ProtectedRules(
                blockedDomains: [],
                blockedApplications: [],
                blockedAdultDomains: [],
                adultRulesVersion: nil,
                blockedURLPatterns: patterns
            )

            XCTAssertThrowsError(try rules.validateForPersistence()) { error in
                XCTAssertEqual(
                    error as? ProtectedStateError,
                    .invalid("The block contains an invalid or duplicate URL pattern.")
                )
            }
        }
    }

    func testEffectiveRestrictionsMergeAndDeduplicateURLPatterns() throws {
        var state = ProtectedState()
        let first = try state.create(
            makeDraft(
                name: "First",
                domains: ["one.example"],
                urlPatterns: ["*.example.com", "example.com/r/focus"]
            )
        )
        let second = try state.create(
            makeDraft(
                name: "Second",
                domains: ["two.example"],
                urlPatterns: ["*.example.com", "*.xxx"]
            )
        )
        try state.activate(id: first.id, expectedRevision: first.revision, at: reading(0))
        try state.activate(id: second.id, expectedRevision: second.revision, at: reading(0))

        let restrictions = state.effectiveRestrictions()
        XCTAssertEqual(restrictions.blockedDomains, ["one.example", "two.example", "www.example.com"])
        XCTAssertEqual(
            restrictions.blockedURLPatterns,
            ["*.example.com", "*.xxx", "example.com/r/focus"]
        )
    }

    func testAdultStarterRulesContainExactBareAndWWWHosts() {
        for bareDomain in ["pornhub.com", "xvideos.com", "xnxx.com", "redtube.com", "youporn.com"] {
            XCTAssertTrue(StarterAdultRules.domains.contains(bareDomain))
            XCTAssertTrue(StarterAdultRules.domains.contains("www.\(bareDomain)"))
        }
    }

    func testRevisionConflictDoesNotApplyStaleUpdate() throws {
        var state = ProtectedState()
        let created = try state.create(makeDraft(name: "Original"))
        try state.update(
            id: created.id,
            expectedRevision: created.revision,
            draft: makeDraft(name: "Current")
        )

        XCTAssertThrowsError(
            try state.update(
                id: created.id,
                expectedRevision: created.revision,
                draft: makeDraft(name: "Stale")
            )
        ) { error in
            XCTAssertEqual(error as? ProtectedStateError, .revisionConflict)
        }
        XCTAssertEqual(state.blocks.first?.draft.name, "Current")
    }

    func testAggregateReplyLimitRejectsSecondIndividuallyValidDraftWithoutChangingState() throws {
        let domains = (0..<9_000).map { index in
            String(format: "site%05d", index) + String(repeating: "a", count: 44) + ".example"
        }
        let firstDraft = makeDraft(name: "First", domains: domains)
        let secondDraft = makeDraft(name: "Second", domains: domains.map { "b\($0.dropFirst())" })
        XCTAssertLessThan(
            try ProtectedServiceCodec.encode(ProtectedCreateRequest(draft: firstDraft)).length,
            ProtectedServiceContract.maximumPayloadBytes
        )
        XCTAssertLessThan(
            try ProtectedServiceCodec.encode(ProtectedCreateRequest(draft: secondDraft)).length,
            ProtectedServiceContract.maximumPayloadBytes
        )

        var state = ProtectedState()
        _ = try state.create(firstDraft)
        let acceptedState = state
        XCTAssertThrowsError(try state.create(secondDraft)) { error in
            XCTAssertEqual(error as? ProtectedStateError, .aggregateLimitReached)
        }
        XCTAssertEqual(state, acceptedState)
    }

    private func reading(
        _ elapsed: TimeInterval,
        continuousTime: TimeInterval? = nil,
        bootIdentifier: String? = "boot-a"
    ) -> ClockReading {
        ClockReading(
            wallTime: start.addingTimeInterval(elapsed),
            continuousTime: continuousTime ?? 100 + elapsed,
            bootIdentifier: bootIdentifier
        )
    }

    private func makeApplication(_ identifier: String, name: String) -> ProtectedApplication {
        ProtectedApplication(
            bundleIdentifier: identifier,
            displayName: name,
            designatedRequirement: "identifier \"\(identifier)\" and anchor apple generic"
        )
    }

    private func makeDraft(
        name: String = "Focus",
        domains: [String] = ["example.com"],
        urlPatterns: [String] = [],
        applications: [ProtectedApplication] = [],
        protectionMode: ProtectionMode = .softLock,
        breakDelay: TimeInterval = 60,
        fullUnlockDelay: TimeInterval = 180,
        breakDuration: TimeInterval = 60,
        elapsedDuration: TimeInterval? = nil
    ) -> ProtectedBlockDraft {
        ProtectedBlockDraft(
            name: name,
            rules: ProtectedRules(
                blockedDomains: domains,
                blockedApplications: applications,
                blocksStarterAdultSites: false,
                blockedURLPatterns: urlPatterns
            ),
            protectionMode: protectionMode,
            breakDelay: breakDelay,
            fullUnlockDelay: fullUnlockDelay,
            breakDuration: breakDuration,
            elapsedDuration: elapsedDuration
        )
    }

    private func decodeState(
        replacingProtectionModeWith mode: ProtectionMode,
        in state: ProtectedState
    ) throws -> ProtectedState {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        var blocks = try XCTUnwrap(object["blocks"] as? [[String: Any]])
        var block = try XCTUnwrap(blocks.first)
        var draft = try XCTUnwrap(block["draft"] as? [String: Any])
        draft["protectionMode"] = mode.rawValue
        block["draft"] = draft
        var activation = try XCTUnwrap(block["activation"] as? [String: Any])
        var frozenDraft = try XCTUnwrap(activation["frozenDraft"] as? [String: Any])
        frozenDraft["protectionMode"] = mode.rawValue
        activation["frozenDraft"] = frozenDraft
        block["activation"] = activation
        blocks[0] = block
        object["blocks"] = blocks
        return try JSONDecoder().decode(
            ProtectedState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}

extension ProtectedBlockPhase {
    fileprivate var isBreakActive: Bool {
        if case .breakActive = self { return true }
        return false
    }
}

private struct LegacyMacLifecycle {
    var accumulatedElapsed: TimeInterval = 0
    var pendingRequest: (kind: ProtectedRequestKind, requestedAt: TimeInterval)?
    var breakEndsAtElapsed: TimeInterval?

    mutating func request(_ kind: ProtectedRequestKind, at elapsed: TimeInterval) {
        pendingRequest = (kind, elapsed)
    }

    mutating func advance(to elapsed: TimeInterval, draft: ProtectedBlockDraft) -> Bool {
        accumulatedElapsed = elapsed
        if let duration = draft.elapsedDuration, accumulatedElapsed >= duration {
            return false
        }
        if let request = pendingRequest {
            let delay = request.kind == .breakAccess ? draft.breakDelay : draft.fullUnlockDelay
            let readyAt = request.requestedAt + delay
            if accumulatedElapsed >= readyAt {
                if request.kind == .fullUnlock { return false }
                pendingRequest = nil
                breakEndsAtElapsed = readyAt + draft.breakDuration
            }
        }
        if let breakEndsAtElapsed, accumulatedElapsed >= breakEndsAtElapsed {
            self.breakEndsAtElapsed = nil
        }
        return true
    }

    func phase(draft: ProtectedBlockDraft) -> ProtectedBlockPhase {
        let naturalEndRemaining = draft.elapsedDuration.map { max(0, $0 - accumulatedElapsed) }
        if let breakEndsAtElapsed, accumulatedElapsed < breakEndsAtElapsed {
            let fullUnlockRemaining = pendingRequest.flatMap { request in
                request.kind == .fullUnlock
                    ? max(0, request.requestedAt + draft.fullUnlockDelay - accumulatedElapsed)
                    : nil
            }
            return .breakActive(
                remaining: breakEndsAtElapsed - accumulatedElapsed,
                fullUnlockRemaining: fullUnlockRemaining,
                naturalEndRemaining: naturalEndRemaining
            )
        }
        if let pendingRequest {
            let delay =
                pendingRequest.kind == .breakAccess ? draft.breakDelay : draft.fullUnlockDelay
            let remaining = max(0, pendingRequest.requestedAt + delay - accumulatedElapsed)
            return pendingRequest.kind == .breakAccess
                ? .waitingForBreak(remaining: remaining, naturalEndRemaining: naturalEndRemaining)
                : .waitingForFullUnlock(
                    remaining: remaining,
                    naturalEndRemaining: naturalEndRemaining
                )
        }
        return .active(naturalEndRemaining: naturalEndRemaining)
    }
}
