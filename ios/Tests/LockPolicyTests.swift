import XCTest

@testable import HardPause

final class LockPolicyTests: XCTestCase {
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
