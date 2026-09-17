import Foundation
import XCTest

final class AdultWebsiteRulesTests: XCTestCase {
    private func fixture(_ domains: [String]) -> Data {
        Data(("# Entries: \(domains.count)\n" + domains.joined(separator: "\n") + "\n").utf8)
    }

    func testValidCacheLoadsWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("domains.txt")
        let data = fixture((0..<1_000).map { "site\($0).example" })
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: cache)

        let database = await AdultWebsiteDatabase(cacheURL: cache).current()

        XCTAssertEqual(database?.domains.count, 1_000)
        XCTAssertTrue(database?.contains("site999.example") == true)
    }

    func testFreshInvalidCacheIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("domains.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html>network error</html>".utf8).write(to: cache)
        let store = AdultWebsiteDatabase(cacheURL: cache)

        let database = await store.current()

        XCTAssertNil(database)
    }

    func testDatabaseMatchesWholeLabelsOnly() throws {
        let database = try AdultDomainDatabase(
            data: fixture(["adult.example", "xn--bcher-kva.example"]), minimumCount: 2)
        XCTAssertTrue(database.contains("adult.example"))
        XCTAssertTrue(database.contains("video.deep.adult.example"))
        XCTAssertTrue(database.contains("ADULT.EXAMPLE."))
        XCTAssertTrue(database.contains("bücher.example"))
        XCTAssertFalse(database.contains("notadult.example"))
        XCTAssertFalse(database.contains("adult.example.safe.test"))
        XCTAssertFalse(database.contains("example"))
    }

    func testPortableSupplementMergesWithoutChangingUpstreamValidation() throws {
        let supplement = Data(
            """
            # Format: hard-pause-domain-list-v1
            # Category: adult
            # Revision: 2026-09-17
            # License: CC0-1.0
            # Provenance: manual-review
            # Entries: 2
            supplement.example
            xn--bcher-kva.example

            """.utf8
        )
        let database = try AdultDomainDatabase(
            data: fixture(["upstream.example"]),
            supplementData: supplement,
            minimumCount: 1
        )

        XCTAssertEqual(database.domains.count, 3)
        XCTAssertTrue(database.contains("deep.supplement.example"))
        XCTAssertTrue(database.contains("bücher.example"))
        XCTAssertTrue(database.contains("upstream.example"))
    }

    func testRejectsPartialMalformedAndUnsafeLists() {
        for text in [
            "# Entries: 2\nadult.example\n",
            "<html>upstream failed</html>",
            "# Entries: 1\nhttps://adult.example/path\n",
            "# Entries: 1\n*.adult.example\n",
            "# Entries: 1\n127.0.0.1\n",
            "# Entries: 1\ncom\n",
            "# Entries: 1\na..example\n",
        ] {
            XCTAssertThrowsError(try AdultDomainDatabase(data: Data(text.utf8), minimumCount: 1))
        }
    }

    func testCategoryIsPersistedAndLegacyRulesDoNotChange() throws {
        let rules = ProtectedRules(
            blockedDomains: [], blockedApplications: [], blocksStarterAdultSites: false, blocksAdultWebsites: true)
        try rules.validateForPersistence()
        let encoded = try JSONEncoder().encode(rules)
        XCTAssertEqual(try JSONDecoder().decode(ProtectedRules.self, from: encoded), rules)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "blocksAdultWebsites")
        object["blockedAdultDomains"] = ["legacy.example"]
        object["adultRulesVersion"] = 1
        let legacy = try JSONDecoder().decode(ProtectedRules.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(legacy.blocksAdultWebsites)
        XCTAssertEqual(legacy.blockedAdultDomains, ["legacy.example"])
        object["blocksAdultWebsites"] = NSNull()
        XCTAssertThrowsError(
            try JSONDecoder().decode(ProtectedRules.self, from: JSONSerialization.data(withJSONObject: object)))
        object["blocksAdultWebsites"] = "invalid"
        XCTAssertThrowsError(
            try JSONDecoder().decode(ProtectedRules.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testAdultDatabaseOnlyAppliesToSelectedCategory() throws {
        let database = try AdultDomainDatabase(data: fixture(["adult.example"]), minimumCount: 1)
        let enabled = ProtectedRules(
            blockedDomains: [], blockedApplications: [], blocksStarterAdultSites: false, blocksAdultWebsites: true)
        let disabled = ProtectedRules(
            blockedDomains: ["manual.example"], blockedApplications: [], blocksStarterAdultSites: false)
        let url = try XCTUnwrap(URL(string: "https://video.adult.example/"))
        XCTAssertTrue(BrowserURLMatcher.matches(url, rules: [enabled], adultDomains: database))
        XCTAssertFalse(BrowserURLMatcher.matches(url, rules: [disabled], adultDomains: database))
        XCTAssertFalse(BrowserURLMatcher.matches(url, rules: [], adultDomains: database))
        XCTAssertFalse(
            BrowserURLMatcher.matches(
                URL(string: "file://adult.example/path")!, rules: [enabled], adultDomains: database))
    }

    func testAdultRatingDoesNotApplyDuringBreakOrAfterEnd() throws {
        let rules = ProtectedRules(
            blockedDomains: [], blockedApplications: [], blocksStarterAdultSites: false, blocksAdultWebsites: true)
        let draft = ProtectedBlockDraft(
            name: "Adult sites", rules: rules, breakDelay: 300, fullUnlockDelay: 300, breakDuration: 300,
            elapsedDuration: nil)
        let url = URL(string: "https://unlisted.example/page")!
        for (phase, expected) in [
            (ProtectedBlockPhase.active(naturalEndRemaining: nil), true),
            (.waitingForBreak(remaining: 30, naturalEndRemaining: nil), true),
            (.waitingForFullUnlock(remaining: 30, naturalEndRemaining: nil), true),
            (.breakActive(remaining: 300, fullUnlockRemaining: nil, naturalEndRemaining: nil), false),
            (.inactive, false),
        ] {
            let latest = ProtectedServiceSnapshot(
                generatedAt: Date(),
                blocks: [ProtectedBlockSnapshot(id: UUID(), revision: 1, draft: draft, phase: phase)],
                effectiveRestrictions: EffectiveRestrictions(
                    blockedDomains: [], blockedApplications: [], contributingBlockIDs: []),
                protection: .unavailable)
            XCTAssertEqual(
                BrowserURLMatcher.matches(url, rules: BrowserURLMatcher.rules(from: latest), hasAdultRating: true),
                expected)
        }
    }

    func testRatingCacheExpiresWithoutExtendingOnHitsAndStaysPageScoped() {
        var cache = AdultRatingCache(lifetime: 10, capacity: 2)
        let adult = URL(string: "https://mixed.example/adult?id=1")!
        cache.record(adult, now: 0)
        XCTAssertTrue(cache.contains(adult, now: 5))
        cache.record(adult, now: 5)
        XCTAssertFalse(cache.contains(URL(string: "https://mixed.example/news")!, now: 5))
        XCTAssertFalse(cache.contains(URL(string: "https://mixed.example/adult?id=2")!, now: 5))
        XCTAssertFalse(cache.contains(adult, now: 10))
        cache.record(adult, now: 11)
        XCTAssertTrue(cache.contains(adult, now: 12))
        cache.record(URL(string: "https://second.example/")!, now: 12)
        cache.record(URL(string: "https://third.example/")!, now: 13)
        XCTAssertFalse(cache.contains(adult, now: 13))
    }

    func testRatingCacheSurvivesRestartWithoutStoringPlainURLs() throws {
        let url = URL(string: "https://mixed.example/private-page?token=secret")!
        var original = AdultRatingCache(lifetime: 10)
        original.record(url, now: 0)
        let data = try original.encoded(now: 5)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("mixed.example"))
        XCTAssertFalse(text.contains("private-page"))
        XCTAssertFalse(text.contains("secret"))
        var restored = AdultRatingCache(data: data, lifetime: 10, now: 5)
        XCTAssertTrue(restored.contains(url, now: 6))
        XCTAssertFalse(restored.contains(url, now: 10))
        let expired = AdultRatingCache(data: data, lifetime: 10, now: 11)
        XCTAssertEqual(String(decoding: try expired.encoded(now: 11), as: UTF8.self), "{}")
    }

    @MainActor
    func testRatingStorePersistsPositiveCacheWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ratings.json")
        let url = URL(string: "https://mixed.example/labelled-page")!
        let store = AdultRatingStore(file: file)
        store.record(url)
        XCTAssertFalse(store.saveFailed)
        XCTAssertTrue(AdultRatingStore(file: file).contains(url))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testUnexpectedLargeListShrinkKeepsPreviousDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("domains.txt")
        let store = AdultWebsiteDatabase(cacheURL: file)
        let original = fixture((0..<2_000).map { "site\($0).example" })
        try await store.install(data: original)
        do {
            try await store.install(data: fixture((0..<1_000).map { "site\($0).example" }))
            XCTFail("Unexpected loss of half the list was accepted")
        } catch {}
        let current = await store.current()
        XCTAssertTrue(current?.contains("site1999.example") == true)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testFailedUpdateKeepsLastValidListOnDiskAndInMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("domains.txt")
        let store = AdultWebsiteDatabase(cacheURL: cache)
        let data = fixture((0..<1_000).map { "site\($0).example" })
        try await store.install(data: data)
        do {
            try await store.install(data: Data("<html>network error</html>".utf8))
            XCTFail("Invalid update accepted")
        } catch {}
        let current = await store.current()
        XCTAssertTrue(current?.contains("site999.example") == true)
        XCTAssertEqual(try Data(contentsOf: cache), data)
        let reopened = AdultWebsiteDatabase(cacheURL: cache)
        let restored = await reopened.current()
        XCTAssertEqual(restored?.domains.count, 1_000)
    }
}
