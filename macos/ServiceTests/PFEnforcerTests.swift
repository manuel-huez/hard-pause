import Foundation
import XCTest

final class PFEnforcerTests: XCTestCase {
    func testLoadsOwnedRulesAndKillsOnlyStatesForNewLiteralDestinations() throws {
        let runner = successfulRunner()
        let tokens = FakePFTokenStore()
        let enforcer = PFEnforcer(
            runner: runner,
            tokenStore: tokens,
            executable: "/test/pfctl",
            bootIdentifier: { "boot-a" }
        )

        XCTAssertTrue(
            try enforcer.apply(
                addresses: ["2001:db8::8", "203.0.113.8"],
                blockIDs: [UUID()]
            ).isEmpty
        )

        XCTAssertEqual(tokens.token, PFEnableToken(value: "42", bootIdentifier: "boot-a"))
        XCTAssertTrue(
            runner.invocations.contains {
                $0.arguments == ["-a", PFEnforcer.anchor, "-f", "-"]
                    && String(decoding: $0.standardInput ?? Data(), as: UTF8.self)
                        == "block drop quick to 2001:db8::8\nblock drop quick to 203.0.113.8\n"
            }
        )
        XCTAssertTrue(
            runner.invocations.contains {
                $0.arguments == ["-k", "0.0.0.0/0", "-k", "203.0.113.8"]
            }
        )
        XCTAssertTrue(
            runner.invocations.contains {
                $0.arguments == ["-k", "::/0", "-k", "2001:db8::8"]
            }
        )
        XCTAssertFalse(
            runner.invocations.contains {
                $0.arguments.contains("-d") || $0.arguments == ["-F", "states"]
            }
        )
    }

    func testRepeatedApplyDoesNotKillStatesAgain() throws {
        let runner = successfulRunner()
        let enforcer = PFEnforcer(
            runner: runner,
            tokenStore: FakePFTokenStore(),
            executable: "/test/pfctl",
            bootIdentifier: { "boot-a" }
        )

        _ = try enforcer.apply(addresses: ["203.0.113.8"], blockIDs: [])
        _ = try enforcer.apply(addresses: ["203.0.113.8"], blockIDs: [])

        XCTAssertEqual(runner.invocations.filter { $0.arguments.first == "-k" }.count, 1)
    }

    func testStaleBootTokenIsDiscardedWithoutReleaseAndNewTokenIsAcquired() throws {
        let runner = successfulRunner()
        let tokens = FakePFTokenStore(PFEnableToken(value: "17", bootIdentifier: "boot-old"))
        let enforcer = PFEnforcer(
            runner: runner,
            tokenStore: tokens,
            executable: "/test/pfctl",
            bootIdentifier: { "boot-new" }
        )

        _ = try enforcer.apply(addresses: ["203.0.113.9"], blockIDs: [])

        XCTAssertEqual(tokens.saves.first!, nil)
        XCTAssertEqual(tokens.token, PFEnableToken(value: "42", bootIdentifier: "boot-new"))
        XCTAssertFalse(runner.invocations.contains { $0.arguments == ["-X", "17"] })
        XCTAssertTrue(runner.invocations.contains { $0.arguments == ["-E"] })
    }

    func testAcquiredTokenIsReleasedWhenTokenPersistenceFails() {
        let runner = successfulRunner()
        let tokens = FakePFTokenStore()
        tokens.failNonNilSave = true
        let enforcer = PFEnforcer(
            runner: runner,
            tokenStore: tokens,
            executable: "/test/pfctl",
            bootIdentifier: { "boot-a" }
        )

        XCTAssertThrowsError(try enforcer.apply(addresses: ["203.0.113.10"], blockIDs: []))
        XCTAssertTrue(runner.invocations.contains { $0.arguments == ["-X", "42"] })
        XCTAssertFalse(
            runner.invocations.contains { $0.arguments == ["-a", PFEnforcer.anchor, "-f", "-"] }
        )
    }

    func testMissingAppleDispatcherReturnsIssueWithoutEnablingPF() throws {
        let runner = FakeCommandRunner { arguments, _ in
            if arguments == ["-sr"] {
                return CommandResult(
                    status: 0,
                    standardOutput: "anchor \"third.party/*\" all\n",
                    standardError: ""
                )
            }
            return CommandResult(status: 0, standardOutput: "", standardError: "")
        }
        let blockID = UUID()
        let enforcer = PFEnforcer(
            runner: runner,
            tokenStore: FakePFTokenStore(),
            executable: "/test/pfctl",
            bootIdentifier: { "boot-a" }
        )

        let issues = try enforcer.apply(addresses: ["203.0.113.11"], blockIDs: [blockID])

        XCTAssertEqual(issues.map(\.code), ["ip_filter_unavailable"])
        XCTAssertEqual(issues.first?.blockIDs, [blockID])
        XCTAssertFalse(runner.invocations.contains { $0.arguments == ["-E"] })
    }

    func testCleanupFlushesOnlyOwnedRulesAndReleasesCurrentBootToken() throws {
        let runner = successfulRunner()
        let tokens = FakePFTokenStore(PFEnableToken(value: "22", bootIdentifier: "boot-a"))
        let enforcer = PFEnforcer(
            runner: runner,
            tokenStore: tokens,
            executable: "/test/pfctl",
            bootIdentifier: { "boot-a" }
        )

        _ = try enforcer.apply(addresses: [], blockIDs: [])

        XCTAssertEqual(
            runner.invocations.map(\.arguments),
            [["-a", PFEnforcer.anchor, "-F", "rules"], ["-X", "22"]]
        )
        XCTAssertNil(tokens.token)
    }

    func testUnknownBootLeavesPFUntouchedAndReportsUnavailable() throws {
        let runner = successfulRunner()
        let enforcer = PFEnforcer(
            runner: runner,
            tokenStore: FakePFTokenStore(),
            executable: "/test/pfctl",
            bootIdentifier: { nil }
        )

        let issues = try enforcer.apply(addresses: ["203.0.113.12"], blockIDs: [])

        XCTAssertEqual(issues.map(\.code), ["ip_filter_unavailable"])
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testRecoveryCleanupIssueFailsAfterFlushingOwnedAnchor() throws {
        let runner = successfulRunner()
        let hostsFile = FakeManagedTextFile("127.0.0.1 localhost\n")
        let packetFilter = PFEnforcer(
            runner: runner,
            tokenStore: FakePFTokenStore(PFEnableToken(value: "22", bootIdentifier: "boot-a")),
            executable: "/test/pfctl",
            bootIdentifier: { nil }
        )

        XCTAssertThrowsError(
            try OwnedRuleCleanup.run(
                hosts: HostsEnforcer(file: hostsFile),
                packetFilter: packetFilter
            )
        )
        XCTAssertEqual(runner.invocations.map(\.arguments), [["-a", PFEnforcer.anchor, "-F", "rules"]])
    }

    private func successfulRunner() -> FakeCommandRunner {
        FakeCommandRunner { arguments, _ in
            switch arguments {
            case ["-sr"]:
                return CommandResult(
                    status: 0,
                    standardOutput: "anchor \"com.apple/*\" all\n",
                    standardError: ""
                )
            case ["-E"]:
                return CommandResult(status: 0, standardOutput: "Token : 42\n", standardError: "")
            default:
                return CommandResult(status: 0, standardOutput: "", standardError: "")
            }
        }
    }
}
