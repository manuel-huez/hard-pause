import Darwin
import Foundation

final class ApplicationEnforcer: ApplicationRuleEnforcing {
    private let processes: RunningProcessAuthenticating
    private let enrolledUID: uid_t

    init(
        enrolledUID: uid_t,
        processes: RunningProcessAuthenticating = SystemRunningProcessAuthenticator()
    ) {
        self.enrolledUID = enrolledUID
        self.processes = processes
    }

    func close(
        applications: [ProtectedApplication],
        contributingBlockIDs activeBlockIDs: [UUID],
        state: ProtectedState,
        at date: Date
    ) -> EnforcementOutcome {
        guard !applications.isEmpty else { return .success }
        let configured = Dictionary(grouping: applications, by: \.bundleIdentifier)
        var issues: [ProtectionIssue] = []
        var notices: [ClosedApplicationNotice] = []

        for process in processes.runningProcesses(
            effectiveUserIdentifier: enrolledUID,
            matchingSigningIdentifiers: Set(configured.keys)
        ) {
            guard process.effectiveUserIdentifier == enrolledUID,
                let candidates = configured[process.signingIdentifier]
            else { continue }
            guard
                let application = candidates.first(where: { application in
                    guard let requirement = application.designatedRequirement else { return false }
                    return processes.satisfies(process, requirement: requirement)
                }),
                let requirement = application.designatedRequirement
            else {
                issues.append(
                    ProtectionIssue(
                        code: "application_identity_mismatch",
                        message:
                            "\(candidates[0].displayName) is running with a different signed identity and was not closed.",
                        blockIDs: contributingBlockIDs(
                            for: candidates,
                            allowedBlockIDs: Set(activeBlockIDs),
                            in: state
                        )
                    )
                )
                continue
            }
            let blockIDs = contributingBlockIDs(
                for: application,
                allowedBlockIDs: Set(activeBlockIDs),
                in: state
            )
            guard let current = processes.refresh(process),
                current == process,
                current.effectiveUserIdentifier == enrolledUID,
                processes.satisfies(current, requirement: requirement),
                processes.terminate(current)
            else {
                issues.append(
                    ProtectionIssue(
                        code: "application_close_failed",
                        message: "\(application.displayName) could not be closed safely.",
                        blockIDs: blockIDs
                    )
                )
                continue
            }
            notices.append(
                ClosedApplicationNotice(
                    id: UUID(),
                    applicationName: application.displayName,
                    blockNames: contributingBlockNames(
                        for: application,
                        allowedBlockIDs: Set(activeBlockIDs),
                        in: state
                    ),
                    closedAt: date
                )
            )
        }
        return EnforcementOutcome(issues: issues, closedApplications: notices)
    }

    private func contributingBlockIDs(
        for application: ProtectedApplication,
        allowedBlockIDs: Set<UUID>,
        in state: ProtectedState
    ) -> [UUID] {
        state.blocks.compactMap { block in
            guard allowedBlockIDs.contains(block.id),
                block.draft.rules.blockedApplications.contains(where: { $0.id == application.id })
            else { return nil }
            return block.id
        }
    }

    private func contributingBlockIDs(
        for applications: [ProtectedApplication],
        allowedBlockIDs: Set<UUID>,
        in state: ProtectedState
    ) -> [UUID] {
        let applicationIDs = Set(applications.map(\.id))
        return state.blocks.compactMap { block in
            guard allowedBlockIDs.contains(block.id),
                block.draft.rules.blockedApplications.contains(where: {
                    applicationIDs.contains($0.id)
                })
            else { return nil }
            return block.id
        }
    }

    private func contributingBlockNames(
        for application: ProtectedApplication,
        allowedBlockIDs: Set<UUID>,
        in state: ProtectedState
    ) -> [String] {
        state.blocks.compactMap { block in
            guard allowedBlockIDs.contains(block.id),
                block.draft.rules.blockedApplications.contains(where: { $0.id == application.id })
            else { return nil }
            return block.draft.name
        }
    }
}
