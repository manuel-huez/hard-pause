import Foundation
import XCTest

final class ClientAuthorizerTests: XCTestCase {
    func testAcceptsOnlyEnrolledEffectiveUserIdentifier() throws {
        let authorizer = try ClientAuthorizer(enrollment: validEnrollment(uid: 501))

        XCTAssertTrue(authorizer.accepts(effectiveUserIdentifier: 501))
        XCTAssertFalse(authorizer.accepts(effectiveUserIdentifier: 0))
        XCTAssertFalse(authorizer.accepts(effectiveUserIdentifier: 502))
    }

    func testRejectsRootEnrollment() {
        let enrollment = ProtectedServiceEnrollment(
            enrolledUID: 0,
            approvedClientRequirements: [#"identifier "org.hardpause.app""#]
        )

        XCTAssertThrowsError(try ClientAuthorizer(enrollment: enrollment)) { error in
            guard case ProtectedServiceCodecError.invalid(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("must not be root"))
        }
    }

    func testRejectsEnrollmentWithoutApprovedClientRequirements() {
        let enrollment = ProtectedServiceEnrollment(
            enrolledUID: 501,
            approvedClientRequirements: []
        )

        XCTAssertThrowsError(try ClientAuthorizer(enrollment: enrollment)) { error in
            guard case ProtectedServiceCodecError.invalid(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("requirements are invalid"))
        }
    }

    func testRejectsMalformedCodeSigningRequirement() {
        let enrollment = ProtectedServiceEnrollment(
            enrolledUID: 501,
            approvedClientRequirements: ["("]
        )

        XCTAssertThrowsError(try ClientAuthorizer(enrollment: enrollment)) { error in
            guard case ServiceRuntimeError.invalidInstall(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("combined client code requirement is invalid"))
        }
    }

    func testCombinesApprovedRequirementsWithoutChangingTheirMeaning() throws {
        let requirements = [
            #"identifier "org.hardpause.app""#,
            #"identifier "org.hardpause.cli""#,
        ]

        let authorizer = try ClientAuthorizer(
            enrollment: ProtectedServiceEnrollment(
                enrolledUID: 501,
                approvedClientRequirements: requirements
            )
        )

        XCTAssertEqual(
            authorizer.combinedCodeRequirement,
            requirements.map { "(\($0))" }.joined(separator: " or ")
        )
        XCTAssertNil(authorizer.updateCodeRequirement)
    }

    func testUpdateChannelRequiresEnrolledGUIIdentity() throws {
        let gui = #"anchor apple generic and identifier "org.hardpause.app""#
        let authorizer = try ClientAuthorizer(
            enrollment: ProtectedServiceEnrollment(
                enrolledUID: 501,
                approvedClientRequirements: [
                    gui,
                    #"identifier "org.hardpause.cli""#,
                    #"identifier "org.hardpause.browser-worker""#,
                ]
            )
        )

        XCTAssertEqual(
            authorizer.updateCodeRequirement,
            "(\(gui)) and identifier \"org.hardpause.app\""
        )
        XCTAssertFalse(authorizer.updateCodeRequirement?.contains(" or ") == true)
        XCTAssertFalse(authorizer.updateCodeRequirement?.contains("org.hardpause.cli") == true)
        XCTAssertFalse(authorizer.updateCodeRequirement?.contains("org.hardpause.browser-worker") == true)
    }

    func testPrivilegedUpdateModeFailsClosedForActiveProtectionUntilHandoffIsEnabled() throws {
        var state = ProtectedState()
        let block = try state.create(serviceTestDraft())
        try state.activate(
            id: block.id,
            expectedRevision: block.revision,
            at: serviceTestReading(0)
        )
        let authorizer = try ClientAuthorizer(
            enrollment: ProtectedServiceEnrollment(
                enrolledUID: 501,
                approvedClientRequirements: [
                    #"identifier "org.hardpause.app""#,
                    #"identifier "org.hardpause.cli""#,
                    #"identifier "org.hardpause.browser-worker""#,
                ]
            ))
        let apple = try AppleLockdownEngine(
            stateStore: FakeAppleLockdownStateStore(),
            credentialVault: FakeAppleLockdownVault()
        )
        let active = try PrivilegedServiceUpdateTrigger(
            engine: ProtectedServiceEngine(
                stateStore: FakeProtectedStateStore(state),
                enforcer: FakeProtectionEnforcer(),
                clock: FakeServiceClock(serviceTestReading(0))
            ),
            appleLockdown: apple,
            authorizer: authorizer,
            runningDigest: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(try active.updateMode()) {
            XCTAssertEqual($0 as? ProtectedStateError, .updateUnavailable)
        }

        let inactive = try PrivilegedServiceUpdateTrigger(
            engine: ProtectedServiceEngine(
                stateStore: FakeProtectedStateStore(),
                enforcer: FakeProtectionEnforcer(),
                clock: FakeServiceClock(serviceTestReading(0))
            ),
            appleLockdown: apple,
            authorizer: authorizer,
            runningDigest: String(repeating: "a", count: 64)
        )
        XCTAssertEqual(try inactive.updateMode(), .inactive)
    }

    func testInstalledBuildNumberParserRejectsAmbiguousValues() {
        XCTAssertEqual(PrivilegedServiceUpdateTrigger.positiveInteger("42\n"), 42)
        for value in ["", "0", "042", "-1", "+1", "1.2", "999999999999999999999999"] {
            XCTAssertNil(PrivilegedServiceUpdateTrigger.positiveInteger(value))
        }
        XCTAssertEqual(PrivilegedServiceUpdateTrigger.installedBuild(from: Data("42\n".utf8)), 42)
        XCTAssertNil(PrivilegedServiceUpdateTrigger.installedBuild(from: Data(repeating: 48, count: 33)))
        XCTAssertNil(PrivilegedServiceUpdateTrigger.installedBuild(from: Data([0x34, 0xff])))
    }

    func testUpdateCandidateRejectsDowngradeAndSameBinary() {
        let digest = String(repeating: "a", count: 64)
        XCTAssertFalse(
            PrivilegedServiceUpdateTrigger.acceptsCandidate(
                version: "7\n", digest: "different", runningVersion: "8", runningDigest: digest
            ))
        XCTAssertFalse(
            PrivilegedServiceUpdateTrigger.acceptsCandidate(
                version: "8\n", digest: digest, runningVersion: "8", runningDigest: digest
            ))
        XCTAssertTrue(
            PrivilegedServiceUpdateTrigger.acceptsCandidate(
                version: "8\n", digest: "different", runningVersion: "8", runningDigest: digest
            ))
        XCTAssertTrue(
            PrivilegedServiceUpdateTrigger.acceptsCandidate(
                version: "9\n", digest: digest, runningVersion: "8", runningDigest: digest
            ))
    }

    func testUpdateRequestRejectsInvalidBundlePaths() {
        XCTAssertTrue(PrivilegedServiceUpdateTrigger.validBundlePath("/Applications/HardPause.app"))
        for path in [
            "HardPause.app",
            "/Applications/HardPause",
            "/Applications/HardPause.app\n",
            "/Applications/HardPause\u{0}.app",
            "/" + String(repeating: "a", count: 4_096) + ".app",
        ] {
            XCTAssertFalse(PrivilegedServiceUpdateTrigger.validBundlePath(path))
        }
    }

    func testPrivilegedUpdateModeRejectsUnhealthyEnforcementAndAppleState() throws {
        let authorizer = try ClientAuthorizer(
            enrollment: ProtectedServiceEnrollment(
                enrolledUID: 501,
                approvedClientRequirements: [
                    #"identifier "org.hardpause.app""#,
                    #"identifier "org.hardpause.cli""#,
                    #"identifier "org.hardpause.browser-worker""#,
                ]
            ))
        let enforcer = FakeProtectionEnforcer()
        enforcer.outcome = EnforcementOutcome(
            issues: [ProtectionIssue(code: "pf_failed", message: "injected", blockIDs: [])],
            closedApplications: []
        )
        let vault = FakeAppleLockdownVault()
        let apple = try AppleLockdownEngine(
            stateStore: FakeAppleLockdownStateStore(), credentialVault: vault
        )
        let unhealthy = PrivilegedServiceUpdateTrigger(
            engine: try ProtectedServiceEngine(
                stateStore: FakeProtectedStateStore(), enforcer: enforcer,
                clock: FakeServiceClock(serviceTestReading(0))
            ),
            appleLockdown: apple, authorizer: authorizer,
            runningDigest: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(try unhealthy.updateMode()) {
            XCTAssertEqual($0 as? ProtectedStateError, .updateUnavailable)
        }

        vault.values[UUID()] = "test-only"
        let unhealthyApple = PrivilegedServiceUpdateTrigger(
            engine: try ProtectedServiceEngine(
                stateStore: FakeProtectedStateStore(), enforcer: FakeProtectionEnforcer(),
                clock: FakeServiceClock(serviceTestReading(0))
            ),
            appleLockdown: apple, authorizer: authorizer,
            runningDigest: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(try unhealthyApple.updateMode()) {
            XCTAssertEqual($0 as? AppleLockdownError, .stateUnavailable)
        }
    }

    // A real NSXPCConnection integration test is still required to prove that
    // configure(_:) rejects a process whose code signature does not match.
    private func validEnrollment(uid: UInt32) -> ProtectedServiceEnrollment {
        ProtectedServiceEnrollment(
            enrolledUID: uid,
            approvedClientRequirements: [#"identifier "org.hardpause.app""#]
        )
    }
}
