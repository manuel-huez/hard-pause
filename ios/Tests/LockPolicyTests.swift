import ManagedSettings
import XCTest

@testable import HardPause

final class LockPolicyTests: XCTestCase {
    func testLegacyPolicyDefaultsToPauseAndSelectedModePersists() throws {
        let encoded = try JSONEncoder().encode(LockPolicy())
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "protectionMode")

        let decodedLegacy = try JSONDecoder().decode(
            LockPolicy.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertEqual(decodedLegacy.protectionMode, .softLock)

        var hardPause = LockPolicy()
        hardPause.protectionMode = .lockdown
        let decodedHardPause = try JSONDecoder().decode(
            LockPolicy.self,
            from: JSONEncoder().encode(hardPause)
        )
        XCTAssertEqual(decodedHardPause.protectionMode, .lockdown)
    }

    func testMalformedPresentModeDoesNotFallBackToPause() throws {
        let encoded = try JSONEncoder().encode(LockPolicy())
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for malformedMode: Any in ["strict", NSNull()] {
            var object = base
            object["protectionMode"] = malformedMode
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    LockPolicy.self,
                    from: JSONSerialization.data(withJSONObject: object)
                )
            )
        }
    }

    func testNewPolicyPreventsRemovalWithoutChangingSavedOptOut() throws {
        XCTAssertTrue(LockPolicy().preventsAppRemoval)
        var saved = LockPolicy()
        saved.preventsAppRemoval = false
        let decoded = try JSONDecoder().decode(LockPolicy.self, from: JSONEncoder().encode(saved))
        XCTAssertFalse(decoded.preventsAppRemoval)
    }

    func testNewManualEntriesDoNotSilentlyBroadenURLRules() {
        for value in [
            "example.com/path", "https://example.com?q=one", "example.com#part", "*.example.com", "example.com:8443",
            "https://user@example.com", "ftp://example.com", "bad..example.com", "-bad.example.com",
        ] {
            XCTAssertNil(LockPolicy.newManualDomain(value), value)
        }
        XCTAssertEqual(LockPolicy.newManualDomain(" https://www.Example.com/ "), "example.com")
        XCTAssertEqual(LockPolicy.newManualDomain("sub.example.com"), "sub.example.com")
        // Previously saved input keeps its original interpretation.
        XCTAssertEqual(LockPolicy.normalizedDomain("https://www.example.com/path"), "example.com")
    }

    func testNonfiniteDurationsAreRejected() {
        for duration in [Double.nan, Double.infinity, -Double.infinity, -1] {
            var policy = LockPolicy()
            policy.waitDuration = duration
            XCTAssertThrowsError(try policy.validateDurations())
            policy = LockPolicy()
            policy.breakDuration = duration
            XCTAssertThrowsError(try policy.validateDurations())
            policy = LockPolicy()
            policy.fullUnlockDelay = duration
            XCTAssertThrowsError(try policy.validateDurations())
            policy = LockPolicy()
            policy.fixedDuration = duration
            XCTAssertThrowsError(try policy.validateDurations())
        }
    }

    func testFiftyManualAndSelectedDomainsAreAccepted() throws {
        XCTAssertNoThrow(
            try LockPolicy.validateManagedSettingsDomainCounts(manual: 50, selected: 50)
        )
    }

    func testFiftyOneManualDomainsAreRejectedBeforeActivation() throws {
        var policy = LockPolicy()
        policy.manualDomains = (0...50).map { "example\($0).com" }
        var state = LockState()

        XCTAssertThrowsError(
            try LockStateMachine.activate(
                &state,
                policy: policy,
                at: Date(timeIntervalSince1970: 1_800_000_000),
                elapsedTime: reading
            )
        ) { error in
            XCTAssertEqual(error as? LockStateError, .tooManyManualDomains)
        }
        XCTAssertEqual(state, LockState())
    }

    func testFiftyOneSelectedDomainsAreRejected() {
        XCTAssertThrowsError(
            try LockPolicy.validateManagedSettingsDomainCounts(manual: 0, selected: 51)
        ) { error in
            XCTAssertEqual(error as? LockStateError, .tooManySelectedWebDomains)
        }
    }

    private var reading: ElapsedTimeReading {
        ElapsedTimeReading(durationSinceBoot: 100, bootIdentifier: "boot-a")
    }
}

final class ManagedRestrictionProjectionTests: XCTestCase {
    func testAutomaticAdultFilterIncludesManualDomains() {
        var policy = LockPolicy()
        policy.manualDomains = ["example.com", "blocked.test"]
        let state = activeState(policy: policy)

        XCTAssertEqual(
            ManagedRestrictionStoreBackend.projectedWebContentFilter(for: state),
            .auto([
                WebDomain(domain: "example.com"),
                WebDomain(domain: "blocked.test"),
            ])
        )
    }

    func testManualDomainsUseSpecificFilterWhenAutomaticFilteringIsOff() {
        var policy = LockPolicy()
        policy.blocksAdultWebsites = false
        policy.manualDomains = ["example.com"]

        XCTAssertEqual(
            ManagedRestrictionStoreBackend.projectedWebContentFilter(for: activeState(policy: policy)),
            .specific([WebDomain(domain: "example.com")])
        )
    }

    func testNoWebRulesProjectsNoFilter() {
        var policy = LockPolicy()
        policy.blocksAdultWebsites = false

        XCTAssertNil(
            ManagedRestrictionStoreBackend.projectedWebContentFilter(for: activeState(policy: policy))
        )
    }

    func testBreakAndInactiveStatesProjectNoFilter() {
        var breakState = activeState(policy: LockPolicy())
        breakState.phase = .breakActive

        XCTAssertNil(ManagedRestrictionStoreBackend.projectedWebContentFilter(for: breakState))
        XCTAssertNil(ManagedRestrictionStoreBackend.projectedWebContentFilter(for: LockState()))
        XCTAssertNil(ManagedRestrictionStoreBackend.projectedWebContentFilter(for: nil))
    }

    private func activeState(policy: LockPolicy) -> LockState {
        var state = LockState()
        state.phase = .locked
        state.policy = policy
        return state
    }
}
