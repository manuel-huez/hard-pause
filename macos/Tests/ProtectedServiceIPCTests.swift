import Foundation
import XCTest

final class ProtectedServiceIPCTests: XCTestCase {
    func testReplyRoundTripPreservesSnapshot() throws {
        let snapshot = ProtectedState().snapshot(
            at: Date(timeIntervalSince1970: 100),
            protection: .unavailable
        )
        let encoded = try ProtectedServiceCodec.encode(ProtectedServiceReply.success(snapshot))
        let decoded = try ProtectedServiceCodec.decode(ProtectedServiceReply.self, from: encoded)

        XCTAssertEqual(decoded, .success(snapshot))
    }

    func testDecoderRejectsPayloadOverLimitBeforeParsing() {
        let data = Data(count: ProtectedServiceContract.maximumPayloadBytes + 1) as NSData

        XCTAssertThrowsError(try ProtectedServiceCodec.decode(ProtectedServiceReply.self, from: data)) {
            error in
            XCTAssertEqual(error as? ProtectedServiceCodecError, .payloadTooLarge)
        }
    }

    func testEnrollmentRequiresUniquePinnedClientRequirements() {
        let invalid = ProtectedServiceEnrollment(
            enrolledUID: 501,
            approvedClientRequirements: ["identifier \"org.hardpause.app\"", "identifier \"org.hardpause.app\""]
        )

        XCTAssertThrowsError(try invalid.validate())
    }

    func testEnrollmentRejectsRootAsInteractiveUser() {
        let invalid = ProtectedServiceEnrollment(
            enrolledUID: 0,
            approvedClientRequirements: ["identifier \"org.hardpause.app\""]
        )

        XCTAssertThrowsError(try invalid.validate())
    }

    func testProtectionStatusIsBoundedForServiceReplies() {
        let issues = (0..<30).map { index in
            ProtectionIssue(
                code: String(repeating: "c", count: 100),
                message: String(repeating: "m", count: 500),
                blockIDs: (0..<20).map { _ in UUID() }
            )
        }
        let closures = (0..<20).map { _ in
            ClosedApplicationNotice(
                id: UUID(),
                applicationName: String(repeating: "a", count: 300),
                blockNames: (0..<20).map { _ in String(repeating: "b", count: 300) },
                closedAt: Date()
            )
        }

        let status = ProtectionStatus(
            serviceVersion: String(repeating: "v", count: 100),
            isEnforcing: false,
            lastAppliedAt: nil,
            issues: issues,
            recentApplicationClosures: closures
        )

        XCTAssertEqual(status.serviceVersion.count, 64)
        XCTAssertEqual(status.issues.count, 16)
        XCTAssertEqual(status.issues.first?.message.count, 256)
        XCTAssertEqual(status.issues.first?.blockIDs.count, 8)
        XCTAssertEqual(status.recentApplicationClosures.count, 8)
        XCTAssertEqual(status.recentApplicationClosures.first?.blockNames.count, 4)
    }

    func testProtectionStatusBoundsCombiningTextByUTF8Bytes() {
        let combiningMessage = String(repeating: "e\u{301}", count: 500)
        let status = ProtectionStatus(
            serviceVersion: combiningMessage,
            isEnforcing: false,
            lastAppliedAt: nil,
            issues: [ProtectionIssue(code: combiningMessage, message: combiningMessage, blockIDs: [])],
            recentApplicationClosures: []
        )

        XCTAssertLessThanOrEqual(status.serviceVersion.utf8.count, 64)
        XCTAssertLessThanOrEqual(status.issues[0].code.utf8.count, 64)
        XCTAssertLessThanOrEqual(status.issues[0].message.utf8.count, 256)
    }

    func testAppleLockdownSnapshotContainsNoCredentialField() throws {
        let snapshot = AppleLockdownSnapshot(
            phase: .pendingSetup,
            fullUnlockDelay: 3_600,
            remainingDelay: nil,
            enablesAdultFilter: true,
            filterWasAlreadyEnabled: false,
            shareAcrossDevicesVerified: nil,
            operationID: UUID()
        )

        let encoded = try ProtectedServiceCodec.encode(snapshot) as Data
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(text.contains("passcode"))
        XCTAssertFalse(text.contains("credential"))
    }

    func testAppleLockdownCredentialDescriptionRedactsPasscode() {
        let snapshot = AppleLockdownSnapshot(
            phase: .pendingSetup,
            fullUnlockDelay: 3_600,
            remainingDelay: nil,
            enablesAdultFilter: false,
            filterWasAlreadyEnabled: false,
            shareAcrossDevicesVerified: false,
            operationID: UUID()
        )
        let operation = AppleLockdownCredentialOperation(
            operationID: snapshot.operationID!,
            passcode: "4820",
            snapshot: snapshot
        )

        XCTAssertFalse(String(describing: operation).contains("4820"))
        XCTAssertTrue(String(describing: operation).contains("<redacted>"))
    }

    func testSafeUpdateVersionsAllowV4MigrationAndRejectUnknownVersions() {
        XCTAssertTrue(ProtectedServiceContract.supportsSafeUpdate(from: "4"))
        XCTAssertTrue(
            ProtectedServiceContract.supportsSafeUpdate(
                from: ProtectedServiceContract.serviceVersion
            )
        )
        XCTAssertFalse(ProtectedServiceContract.supportsSafeUpdate(from: "3"))
        XCTAssertFalse(ProtectedServiceContract.supportsSafeUpdate(from: ""))
    }
}
