import Foundation
import Testing

@testable import PauseCore

@Suite("Portable domain list")
struct PortableDomainListTests {
    @Test("Block List Project format preserves count and malformed-entry safeguards")
    func parsesBlockListProjectFormat() throws {
        let valid = (0..<1_000).map { "site\($0).example" }
        let list = try PortableDomainList(
            data: upstream(valid + ["*.invalid.example"]),
            format: .blockListProject(minimumCount: 1_000)
        )

        #expect(list.domains.count == 1_000)
        #expect(list.skippedEntries == 1)
        #expect(list.metadata["license"] == "MIT")
    }

    @Test("Block List Project format rejects partial and unsafe files")
    func rejectsInvalidUpstreamData() {
        for text in [
            "# Entries: 2\nadult.example\n",
            "<html>network error</html>",
            "# Entries: 1\nhttps://adult.example/path\n",
            "# Entries: 1\n*.adult.example\n",
            "# Entries: 1\n127.0.0.1\n",
            "# Entries: 1\ncom\n",
            "# Entries: 1\na..example\n",
        ] {
            #expect(throws: PortableDomainListError.invalidData) {
                try PortableDomainList(
                    data: Data(text.utf8),
                    format: .blockListProject(minimumCount: 1)
                )
            }
        }
    }

    @Test("Supplement requires provenance and rejects duplicate or malformed domains")
    func validatesSupplementContract() throws {
        let valid = try PortableDomainList(
            data: supplement(["reviewed.example", "another.example"]),
            format: .hardPauseSupplement(category: "adult")
        )
        #expect(valid.domains == Set(["reviewed.example", "another.example"]))

        for data in [
            supplement(["reviewed.example", "reviewed.example"]),
            supplement(["https://reviewed.example"]),
            supplement(["*.reviewed.example"]),
            supplement(["127.0.0.1"]),
            Data("# Format: hard-pause-domain-list-v1\n# Entries: 0\n".utf8),
        ] {
            #expect(throws: PortableDomainListError.invalidData) {
                try PortableDomainList(data: data, format: .hardPauseSupplement(category: "adult"))
            }
        }
    }

    @Test("Matching uses whole domain labels")
    func matchesWholeLabels() throws {
        let list = try PortableDomainList(
            data: supplement(["adult.example"]),
            format: .hardPauseSupplement(category: "adult")
        )
        #expect(list.contains(canonicalASCIIHost: "adult.example"))
        #expect(list.contains(canonicalASCIIHost: "video.deep.adult.example"))
        #expect(list.contains(canonicalASCIIHost: "ADULT.EXAMPLE."))
        #expect(!list.contains(canonicalASCIIHost: "notadult.example"))
        #expect(!list.contains(canonicalASCIIHost: "adult.example.safe.test"))
    }

    @Test("Repository supplement follows the portable contract")
    func repositorySupplementParses() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("data/adult-domains/supplement.txt")
        )
        let list = try PortableDomainList(
            data: data,
            format: .hardPauseSupplement(category: "adult")
        )
        #expect(list.domains.isEmpty)
    }

    private func upstream(_ domains: [String]) -> Data {
        let text =
            "# Title: Porn Block List\n"
            + "# License: MIT\n"
            + "# Entries: \(domains.count)\n"
            + domains.joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }

    private func supplement(_ domains: [String]) -> Data {
        let text =
            "# Format: hard-pause-domain-list-v1\n"
            + "# Category: adult\n"
            + "# Revision: 2026-09-17\n"
            + "# License: CC0-1.0\n"
            + "# Provenance: manual-review\n"
            + "# Entries: \(domains.count)\n"
            + domains.joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }
}
