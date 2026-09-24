import Foundation

enum ProtectionMode: String, Codable, Equatable, Sendable, CaseIterable {
    case softLock
    case lockdown

    private struct Arguments: Encodable { let mode: ProtectionMode }
    private struct Result: Decodable { let allowsBreaks: Bool }

    var allowsBreaks: Bool {
        let result: Result? = try? RustCoreBridge.call(
            "protection.allows_breaks", Arguments(mode: self)
        )
        return result?.allowsBreaks == true
    }
}
