import Foundation
import XCTest

final class ProcessCommandRunnerTests: XCTestCase {
    func testDrainsLargeStandardOutputAndStandardErrorWithoutDeadlock() throws {
        let runner = ProcessCommandRunner(
            timeout: 5,
            terminationGrace: 1,
            maximumCapturedBytes: 1_024 * 1_024
        )
        let standardOutputPayload = String(repeating: "o", count: 64)
        let standardErrorPayload = String(repeating: "e", count: 64)
        let script = """
            i=0
            while [ "$i" -lt 4096 ]; do
                printf 'stdout-%s-\(standardOutputPayload)\\n' "$i"
                printf 'stderr-%s-\(standardErrorPayload)\\n' "$i" >&2
                i=$((i + 1))
            done
            """

        let result = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", script],
            standardInput: nil
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertGreaterThan(result.standardOutput.utf8.count, 256 * 1_024)
        XCTAssertGreaterThan(result.standardError.utf8.count, 256 * 1_024)
        XCTAssertTrue(result.standardOutput.contains("stdout-4095-\(standardOutputPayload)"))
        XCTAssertTrue(result.standardError.contains("stderr-4095-\(standardErrorPayload)"))
    }

    func testWritesBoundedStandardInputWhileDrainingOutput() throws {
        let runner = ProcessCommandRunner(
            timeout: 5,
            terminationGrace: 1,
            maximumCapturedBytes: 512 * 1_024,
            maximumInputBytes: 512 * 1_024
        )
        let input = Data(repeating: 0x5A, count: 256 * 1_024)

        let result = try runner.run(
            executable: "/bin/cat",
            arguments: [],
            standardInput: input
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput.data(using: .utf8), input)
        XCTAssertEqual(result.standardError, "")
    }

    func testTerminatesStalledCommandAtTimeout() {
        let runner = ProcessCommandRunner(
            timeout: 0.05,
            terminationGrace: 0.5,
            maximumCapturedBytes: 1_024
        )

        XCTAssertThrowsError(
            try runner.run(
                executable: "/bin/sleep",
                arguments: ["5"],
                standardInput: nil
            )
        ) { error in
            XCTAssertEqual(error as? ServiceRuntimeError, .commandTimedOut("/bin/sleep"))
        }
    }

    func testRejectsCapturedOutputOverLimit() {
        let runner = ProcessCommandRunner(
            timeout: 5,
            terminationGrace: 1,
            maximumCapturedBytes: 128
        )

        XCTAssertThrowsError(
            try runner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%1024s' x >&2"],
                standardInput: nil
            )
        ) { error in
            XCTAssertEqual(error as? ServiceRuntimeError, .commandOutputTooLarge("/bin/sh"))
        }
    }
}
