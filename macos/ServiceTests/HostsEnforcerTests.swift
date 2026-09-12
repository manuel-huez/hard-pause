import Foundation
import XCTest

final class HostsEnforcerTests: XCTestCase {
    func testApplyAndCleanupPreserveEveryUnmanagedByteIncludingBlankLines() throws {
        let original = "127.0.0.1 localhost\r\n# local note\r\n\r\n\r\n"
        let file = FakeManagedTextFile(original)
        let enforcer = HostsEnforcer(file: file)

        try enforcer.apply(domains: ["b.example", "a.example"])

        XCTAssertTrue(file.contents.hasPrefix(original))
        XCTAssertTrue(file.contents.contains("0.0.0.0\ta.example\r\n::\ta.example\r\n"))
        XCTAssertTrue(file.contents.contains("0.0.0.0\tb.example\r\n::\tb.example\r\n"))
        try enforcer.apply(domains: [])
        XCTAssertEqual(file.contents, original)
    }

    func testConflictingMultiAliasEntryFailsWithoutWriting() throws {
        let original = "203.0.113.8 unrelated.example selected.example other.example # keep\n"
        let file = FakeManagedTextFile(original)
        let enforcer = HostsEnforcer(file: file)

        XCTAssertThrowsError(try enforcer.apply(domains: ["selected.example"])) { error in
            guard case ServiceRuntimeError.enforcementFailed(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("selected.example"))
        }
        XCTAssertEqual(file.contents, original)
        XCTAssertTrue(file.writes.isEmpty)
    }

    func testCommentedAliasDoesNotConflictAndExistingSinkEntryIsPreserved() throws {
        let original = "0.0.0.0 selected.example # real.example\n203.0.113.8 other.example # selected.example\n"
        let file = FakeManagedTextFile(original)
        let enforcer = HostsEnforcer(file: file)

        try enforcer.apply(domains: ["selected.example"])

        XCTAssertTrue(file.contents.hasPrefix(original))
    }

    func testMalformedOwnedSectionFailsWithoutChangingFile() throws {
        let original = "127.0.0.1 localhost\n\(HostsEnforcer.endMarker)\n"
        let file = FakeManagedTextFile(original)
        let enforcer = HostsEnforcer(file: file)

        XCTAssertThrowsError(try enforcer.apply(domains: ["selected.example"]))
        XCTAssertEqual(file.contents, original)
        XCTAssertTrue(file.writes.isEmpty)
    }

    func testLiteralAddressIsRejectedByHostsLayer() {
        let file = FakeManagedTextFile("127.0.0.1 localhost\n")
        let enforcer = HostsEnforcer(file: file)

        XCTAssertThrowsError(try enforcer.apply(domains: ["203.0.113.8"]))
        XCTAssertTrue(file.writes.isEmpty)
    }
}
