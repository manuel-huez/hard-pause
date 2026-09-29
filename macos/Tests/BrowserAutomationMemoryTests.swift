import Darwin
import Foundation
import XCTest

final class BrowserAutomationMemoryTests: XCTestCase {
    func testRepeatedClosedProcessChecksKeepMemoryBounded() async throws {
        let worker = BrowserAutomationWorker()
        let page = URL(string: "http://127.0.0.1:1234/BlockedPage/index.html")!

        func check() async -> Bool {
            let outcome = await worker.check(
                "com.apple.Safari", processIdentifier: pid_t.max, rules: [], page: page,
                adultDomains: nil, cachedRating: { _ in false }, authorize: { _, _ in false })
            return outcome.success
        }

        for _ in 0..<10 {
            let success = await check()
            XCTAssertFalse(success)
        }
        let before = try footprint()
        for _ in 0..<500 {
            let success = await check()
            XCTAssertFalse(success)
        }
        let after = try footprint()
        XCTAssertLessThan(after, before + 128 * 1024 * 1024)
    }

    private func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(status)) }
        return info.phys_footprint
    }
}
