import Foundation
import Security

final class ClientAuthorizer {
    let enrolledUID: uid_t
    let combinedCodeRequirement: String

    init(enrollment: ProtectedServiceEnrollment) throws {
        try enrollment.validate()
        enrolledUID = uid_t(enrollment.enrolledUID)
        combinedCodeRequirement = enrollment.approvedClientRequirements
            .map { "(\($0))" }
            .joined(separator: " or ")

        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(
                combinedCodeRequirement as CFString,
                [],
                &requirement
            ) == errSecSuccess,
            requirement != nil
        else {
            throw ServiceRuntimeError.invalidInstall(
                "the combined client code requirement is invalid"
            )
        }
    }

    func accepts(effectiveUserIdentifier: uid_t) -> Bool {
        effectiveUserIdentifier == enrolledUID
    }

    func configure(_ connection: NSXPCConnection) -> Bool {
        guard accepts(effectiveUserIdentifier: connection.effectiveUserIdentifier) else {
            return false
        }
        connection.setCodeSigningRequirement(combinedCodeRequirement)
        return true
    }
}
