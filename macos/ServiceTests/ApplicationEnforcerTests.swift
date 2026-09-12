import Darwin
import Foundation
import XCTest

final class ApplicationEnforcerTests: XCTestCase {
    func testSameBundleIdentifierWithTwoRequirementsMatchesWithoutCrash() throws {
        let first = serviceTestApplication(requirement: "req.one")
        let second = serviceTestApplication(name: "Focus second", requirement: "req.two")
        let state = try activeState(applications: [first, second])
        let process = makeAuditedProcess(pid: 101)
        let authenticator = FakeProcessAuthenticator()
        authenticator.processes = [process]
        authenticator.matchingRequirements[process.processIdentifier] = ["req.two"]
        let enforcer = ApplicationEnforcer(enrolledUID: 501, processes: authenticator)

        let outcome = enforcer.close(
            applications: [first, second],
            contributingBlockIDs: state.effectiveRestrictions().contributingBlockIDs,
            state: state,
            at: serviceTestStart
        )

        XCTAssertEqual(authenticator.terminated, [process])
        XCTAssertEqual(authenticator.requestedUserIdentifiers, [501])
        XCTAssertEqual(
            authenticator.requestedSigningIdentifierSets,
            [Set(["org.example.Focus"])]
        )
        XCTAssertTrue(outcome.issues.isEmpty)
        XCTAssertEqual(outcome.closedApplications.map(\.applicationName), ["Focus second"])
    }

    func testProcessOwnedByAnotherUserIsNeverSignaled() throws {
        let application = serviceTestApplication(requirement: "req")
        let state = try activeState(applications: [application])
        let process = makeAuditedProcess(pid: 102, uid: 502)
        let authenticator = FakeProcessAuthenticator()
        authenticator.processes = [process]
        authenticator.matchingRequirements[process.processIdentifier] = ["req"]
        let enforcer = ApplicationEnforcer(enrolledUID: 501, processes: authenticator)

        let outcome = enforcer.close(
            applications: [application],
            contributingBlockIDs: state.effectiveRestrictions().contributingBlockIDs,
            state: state,
            at: serviceTestStart
        )

        XCTAssertTrue(authenticator.terminated.isEmpty)
        XCTAssertEqual(outcome, .success)
    }

    func testIdentityMismatchReportsIssueWithoutSignaling() throws {
        let application = serviceTestApplication(requirement: "expected")
        let state = try activeState(applications: [application])
        let process = makeAuditedProcess(pid: 103)
        let authenticator = FakeProcessAuthenticator()
        authenticator.processes = [process]
        let enforcer = ApplicationEnforcer(enrolledUID: 501, processes: authenticator)

        let outcome = enforcer.close(
            applications: [application],
            contributingBlockIDs: state.effectiveRestrictions().contributingBlockIDs,
            state: state,
            at: serviceTestStart
        )

        XCTAssertTrue(authenticator.terminated.isEmpty)
        XCTAssertEqual(outcome.issues.map(\.code), ["application_identity_mismatch"])
        XCTAssertEqual(outcome.issues.first?.blockIDs, state.effectiveRestrictions().contributingBlockIDs)
    }

    func testIdentityIsRevalidatedImmediatelyBeforeAuditBoundTermination() throws {
        let application = serviceTestApplication(requirement: "expected")
        let state = try activeState(applications: [application])
        let process = makeAuditedProcess(pid: 104)
        let changed = makeAuditedProcess(pid: 104, signingIdentifier: "org.example.Other")
        let authenticator = FakeProcessAuthenticator()
        authenticator.processes = [process]
        authenticator.matchingRequirements[process.processIdentifier] = ["expected"]
        authenticator.refreshResults[process.processIdentifier] = changed
        let enforcer = ApplicationEnforcer(enrolledUID: 501, processes: authenticator)

        let outcome = enforcer.close(
            applications: [application],
            contributingBlockIDs: state.effectiveRestrictions().contributingBlockIDs,
            state: state,
            at: serviceTestStart
        )

        XCTAssertTrue(authenticator.terminated.isEmpty)
        XCTAssertEqual(outcome.issues.map(\.code), ["application_close_failed"])
        XCTAssertTrue(outcome.closedApplications.isEmpty)
    }

    func testClosureNoticeRequiresConfirmedTermination() throws {
        let application = serviceTestApplication(requirement: "expected")
        let state = try activeState(applications: [application])
        let process = makeAuditedProcess(pid: 105)
        let authenticator = FakeProcessAuthenticator()
        authenticator.processes = [process]
        authenticator.matchingRequirements[process.processIdentifier] = ["expected"]
        authenticator.terminateResult = false
        let enforcer = ApplicationEnforcer(enrolledUID: 501, processes: authenticator)

        let outcome = enforcer.close(
            applications: [application],
            contributingBlockIDs: state.effectiveRestrictions().contributingBlockIDs,
            state: state,
            at: serviceTestStart
        )

        XCTAssertEqual(authenticator.terminated, [process])
        XCTAssertEqual(outcome.issues.map(\.code), ["application_close_failed"])
        XCTAssertTrue(outcome.closedApplications.isEmpty)
    }

    func testSystemAuthenticatorFindsAndTerminatesHarmlessSignedBackgroundApp() throws {
        let fixture = try makeSignedBackgroundProbe()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.root) }
        let process = Process()
        process.executableURL = fixture.executable
        process.arguments = ["10"]
        try process.run()
        addTeardownBlock {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let authenticator = SystemRunningProcessAuthenticator()
        XCTAssertFalse(
            authenticator.runningProcesses(
                effectiveUserIdentifier: geteuid(),
                matchingSigningIdentifiers: ["org.example.Unrelated"]
            ).contains { $0.processIdentifier == process.processIdentifier }
        )
        var audited: AuditedRunningProcess?
        let deadline = Date().addingTimeInterval(3)
        repeat {
            audited = authenticator.runningProcesses(
                effectiveUserIdentifier: geteuid(),
                matchingSigningIdentifiers: ["org.hardpause.tests.background-probe"]
            ).first {
                $0.processIdentifier == process.processIdentifier
            }
            if audited == nil { Thread.sleep(forTimeInterval: 0.05) }
        } while audited == nil && Date() < deadline

        let found = try XCTUnwrap(audited)
        XCTAssertEqual(found.effectiveUserIdentifier, geteuid())
        XCTAssertEqual(
            URL(fileURLWithPath: found.executablePath).resolvingSymlinksInPath(),
            fixture.executable.resolvingSymlinksInPath()
        )
        XCTAssertEqual(found.signingIdentifier, "org.hardpause.tests.background-probe")
        XCTAssertTrue(authenticator.terminate(found))
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
    }

    private func activeState(applications: [ProtectedApplication]) throws -> ProtectedState {
        var state = ProtectedState()
        let block = try state.create(
            serviceTestDraft(domains: [], applications: applications)
        )
        try state.activate(id: block.id, expectedRevision: block.revision, at: serviceTestReading(0))
        return state
    }

    private func makeSignedBackgroundProbe() throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = root.appendingPathComponent("HarmlessProbe.app")
        let contents = bundle.appendingPathComponent("Contents")
        let executableDirectory = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executable = executableDirectory.appendingPathComponent("HarmlessProbe")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let entitlements = root.appendingPathComponent("probe-entitlements.plist")
        let entitlementValues = ["com.apple.security.get-task-allow": true]
        let entitlementData = try PropertyListSerialization.data(
            fromPropertyList: entitlementValues,
            format: .xml,
            options: 0
        )
        try entitlementData.write(to: entitlements)
        let info: [String: Any] = [
            "CFBundleExecutable": "HarmlessProbe",
            "CFBundleIdentifier": "org.hardpause.tests.background-probe",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "LSBackgroundOnly": true,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = [
            "--force", "--sign", "-", "--identifier", "org.hardpause.tests.background-probe",
            "--timestamp=none", "--entitlements", entitlements.path, bundle.path,
        ]
        let errors = Pipe()
        codesign.standardError = errors
        try codesign.run()
        codesign.waitUntilExit()
        XCTAssertEqual(
            codesign.terminationStatus,
            0,
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
        return (root, executable)
    }
}
