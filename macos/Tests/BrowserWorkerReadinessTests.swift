import Foundation
import XCTest

final class BrowserWorkerReadinessTests: XCTestCase {
    func testOnlyStableOrVersionedMachServiceNamesAreAccepted() {
        XCTAssertTrue(BrowserWorkerIdentity.acceptsMachService("org.hardpause.browser-worker"))
        XCTAssertTrue(BrowserWorkerIdentity.acceptsMachService("org.hardpause.browser-worker.v4"))
        XCTAssertFalse(BrowserWorkerIdentity.acceptsMachService("org.hardpause.browser-worker.v"))
        XCTAssertFalse(BrowserWorkerIdentity.acceptsMachService("org.hardpause.browser-worker.v4.extra"))
        XCTAssertFalse(BrowserWorkerIdentity.acceptsMachService("org.hardpause.service"))
    }

    func testMigrationAcceptsOnlyTheLocalPausePageAddress() {
        XCTAssertTrue(
            BrowserWorkerIdentity.isLocalPausePage(
                URL(string: "http://127.0.0.1:1234/BlockedPage/index.html")!))
        for text in [
            "https://127.0.0.1:1234/BlockedPage/index.html",
            "http://localhost:1234/BlockedPage/index.html",
            "http://127.0.0.1:1234/other",
            "http://127.0.0.1:1234/BlockedPage/index.html?next=https://example.com",
        ] {
            XCTAssertFalse(BrowserWorkerIdentity.isLocalPausePage(URL(string: text)!))
        }
    }

    func testHandoffRequiresWorkerServicePageAndSeparatePermissions() {
        let granted = BrowserWorkerAccess(
            identifier: "com.apple.Safari", installed: true, running: true, permission: "granted")
        let absent = BrowserWorkerAccess(
            identifier: "com.google.Chrome", installed: false, running: false, permission: "unavailable")
        let firefox = BrowserWorkerAccess(
            identifier: "org.mozilla.firefox", installed: true, running: false, permission: "granted")
        let ready = BrowserWorkerReadiness(
            observedAt: Date(), serviceReady: true, serviceReachable: true, standbyReady: false,
            cachedActiveRestrictions: true, pausePageReady: true, adultDatabaseReady: true,
            pausePageURL: URL(string: "http://127.0.0.1:1234/BlockedPage/index.html"),
            browserAccess: [granted, absent, firefox], browserStatuses: [:])
        XCTAssertTrue(ready.readyForHandoff)
        XCTAssertTrue(ready.readyForRetirement)

        let closedPreviouslyGranted = BrowserWorkerAccess(
            identifier: "com.apple.Safari", installed: true, running: false,
            permission: "previouslyGranted")
        let closedBrowser = replacing(ready, browserAccess: [closedPreviouslyGranted, absent, firefox])
        XCTAssertTrue(closedBrowser.readyForHandoff)
        XCTAssertFalse(closedBrowser.readyForRetirement)
        let reopenedWithoutGrant = BrowserWorkerAccess(
            identifier: "com.apple.Safari", installed: true, running: true,
            permission: "previouslyGranted")
        XCTAssertFalse(replacing(ready, browserAccess: [reopenedWithoutGrant, absent, firefox]).readyForHandoff)
        let firefoxWithoutGrant = BrowserWorkerAccess(
            identifier: "org.mozilla.firefox", installed: true, running: false,
            permission: "denied")
        XCTAssertFalse(replacing(ready, browserAccess: [granted, absent, firefoxWithoutGrant]).readyForHandoff)
        XCTAssertFalse(replacing(ready, serviceReady: false).readyForHandoff)
        XCTAssertFalse(replacing(ready, pausePageReady: false).readyForHandoff)
        XCTAssertFalse(replacing(ready, adultDatabaseReady: false).readyForHandoff)
        XCTAssertFalse(replacing(ready, browserAccess: [granted, absent]).readyForHandoff)
    }

    func testReadinessMustBeFreshEvenWhenChecksWereReady() {
        let now = Date()
        let report = BrowserWorkerReadiness(
            observedAt: now, serviceReady: true, serviceReachable: true, standbyReady: false,
            cachedActiveRestrictions: false, pausePageReady: true, adultDatabaseReady: true,
            pausePageURL: URL(string: "http://127.0.0.1:1234/BlockedPage/index.html"),
            browserAccess: [
                BrowserWorkerAccess(identifier: "a", installed: false, running: false, permission: "unavailable"),
                BrowserWorkerAccess(identifier: "b", installed: false, running: false, permission: "unavailable"),
                BrowserWorkerAccess(identifier: "c", installed: false, running: false, permission: "unavailable"),
            ], browserStatuses: [:])
        XCTAssertTrue(report.isFresh(at: now.addingTimeInterval(4)))
        XCTAssertFalse(report.isFresh(at: now.addingTimeInterval(6)))
    }

    private func replacing(
        _ original: BrowserWorkerReadiness, serviceReady: Bool? = nil,
        pausePageReady: Bool? = nil, adultDatabaseReady: Bool? = nil,
        browserAccess: [BrowserWorkerAccess]? = nil
    ) -> BrowserWorkerReadiness {
        BrowserWorkerReadiness(
            observedAt: original.observedAt,
            serviceReady: serviceReady ?? original.serviceReady,
            serviceReachable: original.serviceReachable,
            standbyReady: original.standbyReady,
            cachedActiveRestrictions: original.cachedActiveRestrictions,
            pausePageReady: pausePageReady ?? original.pausePageReady,
            adultDatabaseReady: adultDatabaseReady ?? original.adultDatabaseReady,
            pausePageURL: original.pausePageURL,
            browserAccess: browserAccess ?? original.browserAccess,
            browserStatuses: original.browserStatuses)
    }
}
