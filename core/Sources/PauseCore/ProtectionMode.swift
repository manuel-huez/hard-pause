import Foundation

/// User-visible commitment strength; native permission protection is tracked separately.
enum ProtectionMode: String, Codable, Equatable, Sendable, CaseIterable {
    case softLock
    case lockdown

    var allowsBreaks: Bool { self == .softLock }
}
