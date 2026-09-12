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
