import Foundation
import Security

final class ClientAuthorizer {
    let enrolledUID: uid_t
    let enrolledRequirements: [String]
    let combinedCodeRequirement: String
    let updateCodeRequirement: String?

    init(enrollment: ProtectedServiceEnrollment) throws {
        try enrollment.validate()
        enrolledUID = uid_t(enrollment.enrolledUID)
        enrolledRequirements = enrollment.approvedClientRequirements
        combinedCodeRequirement = enrollment.approvedClientRequirements
            .map { "(\($0))" }
            .joined(separator: " or ")
        updateCodeRequirement =
            enrollment.approvedClientRequirements.count >= 3
            ? "(\(enrollment.approvedClientRequirements[0])) and identifier \"org.hardpause.app\""
            : nil

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
        if let updateCodeRequirement {
            var updateRequirement: SecRequirement?
            guard
                SecRequirementCreateWithString(
                    updateCodeRequirement as CFString,
                    [],
                    &updateRequirement
                ) == errSecSuccess,
                updateRequirement != nil
            else {
                throw ServiceRuntimeError.invalidInstall(
                    "the enrolled GUI code requirement is invalid"
                )
            }
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

    func configureUpdate(_ connection: NSXPCConnection) -> Bool {
        guard accepts(effectiveUserIdentifier: connection.effectiveUserIdentifier),
            let updateCodeRequirement
        else { return false }
        connection.setCodeSigningRequirement(updateCodeRequirement)
        return true
    }
}
