import Foundation
import XCTest

final class BrowserURLMatcherTests: XCTestCase {
    private var rules: ProtectedRules {
        ProtectedRules(
            blockedDomains: ["example.com"], blockedApplications: [],
            blocksStarterAdultSites: true, blockedURLPatterns: ["reddit.com/r/example", "*.xxx"]
        )
    }

    func testExactRulesAndPatternsShareRedirectButNeverLocalPage() throws {
        for value in [
            "https://example.com/path", "https://reddit.com/r/example/new",
            "https://reddit.com/r/%65xample/new", "https://site.xxx/",
            "https://www.pornhub.com/",
        ] {
            XCTAssertTrue(BrowserURLMatcher.matches(try XCTUnwrap(URL(string: value)), rules: [rules]), value)
        }
        for value in [
            "https://example.com.evil.test/", "https://sub.example.com/", "https://reddit.com/r/examples",
            "file:///tmp/BlockedPage/index.html", "chrome://settings", "https://allowed.test/",
        ] {
            XCTAssertFalse(BrowserURLMatcher.matches(try XCTUnwrap(URL(string: value)), rules: [rules]), value)
        }
    }

    func testInternationalDomainMatchesBrowserASCIIHost() throws {
        let rule = ProtectedRules(
            blockedDomains: ["bücher.example"], blockedApplications: [], blocksStarterAdultSites: false)
        XCTAssertTrue(
            BrowserURLMatcher.matches(try XCTUnwrap(URL(string: "https://xn--bcher-kva.example/path")), rules: [rule]))
        XCTAssertTrue(
            URLPatternRule.matches(
                try XCTUnwrap(URL(string: "https://xn--bcher-kva.example/read")), pattern: "bücher.example/read"))
    }

    func testAllowedDomainAppliesOnlyWithinItsPlan() throws {
        let allowedPlan = ProtectedRules(
            blockedDomains: ["example.com"], allowedDomains: ["example.com"],
            blockedApplications: [], blocksStarterAdultSites: false)
        let url = try XCTUnwrap(URL(string: "https://example.com/"))
        XCTAssertFalse(BrowserURLMatcher.matches(url, rules: [allowedPlan]))
        let otherPlan = ProtectedRules(
            blockedDomains: ["example.com"], blockedApplications: [], blocksStarterAdultSites: false)
        XCTAssertTrue(BrowserURLMatcher.matches(url, rules: [allowedPlan, otherPlan]))
        let snapshot = { (rules: ProtectedRules) in
            ProtectedBlockSnapshot(
                id: UUID(), revision: 1,
                draft: ProtectedBlockDraft(
                    name: "Test", rules: rules, breakDelay: 60,
                    fullUnlockDelay: 60, breakDuration: 60, elapsedDuration: nil),
                phase: .active(naturalEndRemaining: nil))
        }
        XCTAssertEqual(
            AppleWebsiteSyncTargets(blocks: [snapshot(allowedPlan)]).allowed,
            ["example.com"])
        let targets = AppleWebsiteSyncTargets(blocks: [snapshot(allowedPlan), snapshot(otherPlan)])
        XCTAssertEqual(targets.restricted, ["example.com"])
        XCTAssertTrue(targets.allowed.isEmpty)

        let unrelatedException = ProtectedRules(
            blockedDomains: ["example.com"], allowedDomains: ["other.example"],
            blockedApplications: [], blocksStarterAdultSites: false)
        XCTAssertTrue(AppleWebsiteSyncTargets(blocks: [snapshot(unrelatedException)]).allowed.isEmpty)

        let subdomainBlock = ProtectedRules(
            blockedDomains: ["www.example.com"], blockedApplications: [], blocksStarterAdultSites: false)
        XCTAssertTrue(
            AppleWebsiteSyncTargets(blocks: [snapshot(allowedPlan), snapshot(subdomainBlock)]).allowed.isEmpty)
    }

    func testUnsupportedSchemesCannotCreateUnenforcedPatterns() {
        XCTAssertNil(URLPatternRule.normalize("ftp://example.com/private"))
        XCTAssertNil(URLPatternRule.exactDomain(from: "file://example.com"))
    }

    func testOnlyCurrentlyEnforcedPhasesRedirect() {
        let draft = ProtectedBlockDraft(
            name: "Test", rules: rules, breakDelay: 60,
            fullUnlockDelay: 60, breakDuration: 60, elapsedDuration: nil)
        let phases: [(ProtectedBlockPhase, Bool)] = [
            (.inactive, false), (.active(naturalEndRemaining: nil), true),
            (.waitingForBreak(remaining: 60, naturalEndRemaining: nil), true),
            (.waitingForFullUnlock(remaining: 60, naturalEndRemaining: nil), true),
            (.breakActive(remaining: 60, fullUnlockRemaining: nil, naturalEndRemaining: nil), false),
        ]
        for (phase, applies) in phases {
            let snapshot = ProtectedServiceSnapshot(
                generatedAt: Date(),
                blocks: [ProtectedBlockSnapshot(id: UUID(), revision: 1, draft: draft, phase: phase)],
                effectiveRestrictions: EffectiveRestrictions(
                    blockedDomains: [], blockedApplications: [], contributingBlockIDs: []),
                protection: .unavailable)
            XCTAssertEqual(!BrowserURLMatcher.rules(from: snapshot).isEmpty, applies)
        }
    }
}
