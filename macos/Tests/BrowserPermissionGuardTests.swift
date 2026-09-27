import AppKit
import Darwin
import Foundation
import XCTest

@MainActor
final class BrowserPermissionGuardTests: XCTestCase {
    func testRepeatedDenialClosesOnlyTheSameAuditedBrowsersAndRetainsStatus() async {
        let fixture = Fixture()
        let chrome = fixture.process
        let safari = browser(pid: 102, identifier: "com.apple.Safari")
        let firefox = browser(pid: 104, identifier: "org.mozilla.firefox")
        fixture.authenticator.running = [
            chrome, safari, browser(pid: 103, identifier: "org.example.Other"), firefox,
        ]
        let permission: (AuditedRunningProcess) async -> OSStatus = {
            $0 == safari ? noErr : OSStatus(errAEEventNotPermitted)
        }
        for time in [0.0, 1, 3, 7, 15, 23, 30] {
            fixture.time = time
            let result = await fixture.guard.check(
                active: true, permission: permission, currentRules: { true }, otherWorkerAccess: { _ in false })
            XCTAssertTrue(result.isEmpty)
        }
        fixture.time = 31
        let result = await fixture.guard.check(
            active: true, permission: permission, currentRules: { true }, otherWorkerAccess: { _ in false })
        let identifiers: Set<String> = [chrome.signingIdentifier, firefox.signingIdentifier]
        XCTAssertEqual(result, identifiers)
        XCTAssertEqual(fixture.authenticator.terminated, [chrome, firefox])
        fixture.authenticator.running = [safari]
        _ = await fixture.check(status: noErr)
        XCTAssertEqual(fixture.guard.blockedBrowsers, identifiers)
        fixture.authenticator.running = [chrome, firefox]
        _ = await fixture.check(status: noErr)
        XCTAssertTrue(fixture.guard.blockedBrowsers.isEmpty)
    }

    func testGrantAndTransientPermissionErrorsRestartTheWait() async {
        let fixture = Fixture()
        for status in [noErr, OSStatus(procNotFound), OSStatus(errAEEventWouldRequireUserConsent)] {
            await fixture.prepareClosure()
            _ = await fixture.check(status: status)
            fixture.time += 1
        }
        await fixture.prepareClosure()
        XCTAssertTrue(fixture.authenticator.terminated.isEmpty)
        _ = await fixture.check()
        XCTAssertEqual(fixture.authenticator.terminated, [fixture.process])
    }

    func testPeerGrantOrUnknownAuthorityPreventsClosureAndRestartsTheWait() async {
        let fixture = Fixture()
        for (peer, rules) in [(true as Bool?, true as Bool?), (nil, true), (false, nil), (false, false)] {
            await fixture.prepareClosure()
            _ = await fixture.check(peer: peer, rules: rules)
            fixture.time += 1
        }
        await fixture.prepareClosure()
        XCTAssertTrue(fixture.authenticator.terminated.isEmpty)
        _ = await fixture.check()
        XCTAssertEqual(fixture.authenticator.terminated, [fixture.process])
    }

    func testProcessReplacementDuringPreflightAndExitRestartTheWait() async {
        let fixture = Fixture()
        await fixture.prepareClosure()
        _ = await fixture.guard.check(
            active: true, permission: { _ in OSStatus(errAEEventNotPermitted) },
            currentRules: { true },
            otherWorkerAccess: { _ in
                fixture.authenticator.running = [self.browser(pid: 101, token: 2)]
                return false
            })
        XCTAssertTrue(fixture.authenticator.terminated.isEmpty)
        fixture.time += 1
        _ = await fixture.check()
        XCTAssertTrue(fixture.authenticator.terminated.isEmpty)

        let exited = Fixture()
        await exited.prepareClosure()
        exited.authenticator.running = []
        _ = await exited.check()
        exited.authenticator.running = [exited.process]
        _ = await exited.check()
        XCTAssertTrue(exited.authenticator.terminated.isEmpty)
    }

    func testFreshPermissionGrantAndExpiredPreflightPreventClosure() async {
        let fixture = Fixture()
        await fixture.prepareClosure()
        var permissionCalls = 0
        _ = await fixture.guard.check(
            active: true,
            permission: { _ in
                permissionCalls += 1
                return permissionCalls == 1 ? OSStatus(errAEEventNotPermitted) : noErr
            }, currentRules: { true }, otherWorkerAccess: { _ in false })
        XCTAssertTrue(fixture.authenticator.terminated.isEmpty)
        fixture.time += 1
        await fixture.prepareClosure()
        _ = await fixture.guard.check(
            active: true, permission: { _ in OSStatus(errAEEventNotPermitted) },
            currentRules: {
                fixture.time += 6
                return true
            }, otherWorkerAccess: { _ in false })
        XCTAssertTrue(fixture.authenticator.terminated.isEmpty)
    }

    func testBackoffDefersPermissionChecksAndLongSchedulingGapRestartsWait() async {
        let fixture = Fixture()
        var checkedAt: [TimeInterval] = []
        let permission: (AuditedRunningProcess) async -> OSStatus = { _ in
            checkedAt.append(fixture.time)
            return OSStatus(errAEEventNotPermitted)
        }
        for time in [0.0, 0.5, 1, 2, 3, 6, 7, 14, 15, 22, 23, 30, 60] {
            fixture.time = time
            _ = await fixture.guard.check(
                active: true, permission: permission, currentRules: { true }, otherWorkerAccess: { _ in false })
        }
        XCTAssertEqual(checkedAt, [0, 1, 3, 7, 15, 23, 60])
        XCTAssertTrue(fixture.authenticator.terminated.isEmpty)
        await fixture.prepareClosure()
        XCTAssertTrue(fixture.authenticator.terminated.isEmpty)
        _ = await fixture.check()
        XCTAssertEqual(fixture.authenticator.terminated, [fixture.process])
    }

    func testInactiveClearsStatusAndInvalidatesAnInFlightCheck() async {
        let fixture = Fixture()
        await fixture.prepareClosure()
        _ = await fixture.check()
        XCTAssertFalse(fixture.guard.blockedBrowsers.isEmpty)
        _ = await fixture.check(active: false)
        XCTAssertTrue(fixture.guard.blockedBrowsers.isEmpty)
        fixture.authenticator.terminated.removeAll()
        await fixture.prepareClosure()
        _ = await fixture.guard.check(
            active: true, permission: { _ in OSStatus(errAEEventNotPermitted) },
            currentRules: { true },
            otherWorkerAccess: { _ in
                _ = await fixture.check(active: false)
                return false
            })
        XCTAssertTrue(fixture.authenticator.terminated.isEmpty)
        XCTAssertTrue(fixture.guard.blockedBrowsers.isEmpty)
    }

    private func browser(
        pid: pid_t, identifier: String = "com.google.Chrome", token: UInt8 = 1
    ) -> AuditedRunningProcess {
        AuditedRunningProcess(
            processIdentifier: pid, effectiveUserIdentifier: 501,
            auditTokenData: Data(repeating: token, count: 32),
            executablePath: "/Applications/TestBrowser.app/Contents/MacOS/TestBrowser",
            signingIdentifier: identifier)
    }

    @MainActor
    private final class Fixture {
        let authenticator = FakeAuthenticator()
        let process = AuditedRunningProcess(
            processIdentifier: 101, effectiveUserIdentifier: 501,
            auditTokenData: Data(repeating: 1, count: 32),
            executablePath: "/Applications/TestBrowser.app/Contents/MacOS/TestBrowser",
            signingIdentifier: "com.google.Chrome")
        var time: TimeInterval = 0
        lazy var `guard` = BrowserPermissionGuard(
            processes: authenticator, userIdentifier: 501, now: { [unowned self] in time })

        init() { authenticator.running = [process] }

        func prepareClosure() async {
            let start = time
            for offset in [0.0, 1, 3, 7, 15, 23] {
                time = start + offset
                _ = await check()
            }
            time = start + 31
        }

        func check(
            active: Bool = true, status: OSStatus = OSStatus(errAEEventNotPermitted),
            peer: Bool? = false, rules: Bool? = true
        ) async -> Set<String> {
            await self.guard.check(
                active: active, permission: { _ in status },
                currentRules: { rules }, otherWorkerAccess: { _ in peer })
        }
    }

    private final class FakeAuthenticator: RunningProcessAuthenticating {
        var running: [AuditedRunningProcess] = []
        var terminated: [AuditedRunningProcess] = []

        func runningProcesses(
            effectiveUserIdentifier: uid_t, matchingSigningIdentifiers: Set<String>
        ) -> [AuditedRunningProcess] {
            running.filter {
                $0.effectiveUserIdentifier == effectiveUserIdentifier
                    && matchingSigningIdentifiers.contains($0.signingIdentifier)
            }
        }

        func satisfies(_ process: AuditedRunningProcess, requirement: String) -> Bool { true }

        func refresh(_ process: AuditedRunningProcess) -> AuditedRunningProcess? {
            running.first { $0.processIdentifier == process.processIdentifier }
        }

        func terminate(_ process: AuditedRunningProcess) -> Bool {
            terminated.append(process)
            return true
        }
    }
}
