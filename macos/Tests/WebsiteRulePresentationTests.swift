import XCTest

final class WebsiteRulePresentationTests: XCTestCase {
    func testRootWildcardAndGeneratedWWWShareOneRow() {
        XCTAssertEqual(
            WebsiteRulePresentation.rows(
                domains: ["example.com", "www.example.com"], patterns: ["*.example.com"]
            ),
            [WebsiteRulePresentation(title: "example.com", includesSubdomains: true)]
        )
    }

    func testIndependentDomainsRemainSeparate() {
        XCTAssertEqual(
            WebsiteRulePresentation.rows(domains: ["one.example", "two.example"], patterns: []),
            [
                WebsiteRulePresentation(title: "one.example", includesSubdomains: false),
                WebsiteRulePresentation(title: "two.example", includesSubdomains: false),
            ]
        )
    }

    func testPageAndPathWildcardsRemainSeparate() {
        let patterns = ["example.com/path*", "https://example.com:8443/private*"]
        XCTAssertEqual(
            WebsiteRulePresentation.rows(domains: ["example.com"], patterns: patterns),
            [
                WebsiteRulePresentation(title: "example.com", includesSubdomains: false),
                WebsiteRulePresentation(title: "example.com/path*", includesSubdomains: false),
                WebsiteRulePresentation(
                    title: "https://example.com:8443/private*", includesSubdomains: false
                ),
            ]
        )
    }

    func testLoneWildcardRemainsLiteralWithoutRootRepresentation() {
        XCTAssertEqual(
            WebsiteRulePresentation.rows(domains: [], patterns: ["*.example.com"]),
            [WebsiteRulePresentation(title: "*.example.com", includesSubdomains: false)]
        )
    }

    func testRootAndWWWWithoutWildcardDoNotClaimSubdomains() {
        XCTAssertEqual(
            WebsiteRulePresentation.rows(
                domains: ["example.com", "www.example.com"], patterns: []
            ),
            [
                WebsiteRulePresentation(title: "example.com", includesSubdomains: false),
                WebsiteRulePresentation(title: "www.example.com", includesSubdomains: false),
            ]
        )
    }

    func testDuplicatesAreRemovedAndOrderIsStable() {
        XCTAssertEqual(
            WebsiteRulePresentation.rows(
                domains: ["second.example", "first.example", "second.example"],
                patterns: ["first.example/page", "*.second.example", "first.example/page"]
            ),
            [
                WebsiteRulePresentation(title: "second.example", includesSubdomains: true),
                WebsiteRulePresentation(title: "first.example", includesSubdomains: false),
                WebsiteRulePresentation(title: "first.example/page", includesSubdomains: false),
            ]
        )
    }

    func testInputsAreNotMutated() {
        let domains = ["example.com", "www.example.com"]
        let patterns = ["*.example.com", "example.com/page*"]
        _ = WebsiteRulePresentation.rows(domains: domains, patterns: patterns)
        XCTAssertEqual(domains, ["example.com", "www.example.com"])
        XCTAssertEqual(patterns, ["*.example.com", "example.com/page*"])
    }
}
