import Foundation

struct EnforcementOutcome: Equatable {
    let issues: [ProtectionIssue]
    let closedApplications: [ClosedApplicationNotice]

    static let success = EnforcementOutcome(issues: [], closedApplications: [])

    func merging(_ other: EnforcementOutcome) -> EnforcementOutcome {
        EnforcementOutcome(
            issues: issues + other.issues,
            closedApplications: closedApplications + other.closedApplications
        )
    }
}

protocol ProtectionEnforcing: AnyObject {
    func apply(
        _ restrictions: EffectiveRestrictions,
        state: ProtectedState,
        at date: Date
    ) throws -> EnforcementOutcome

    func closeApplications(
        _ restrictions: EffectiveRestrictions,
        state: ProtectedState,
        at date: Date
    ) -> EnforcementOutcome
}

protocol HostsRuleEnforcing: AnyObject {
    func apply(domains: [String]) throws
}

protocol PFRuleEnforcing: AnyObject {
    func apply(addresses: [String], blockIDs: [UUID]) throws -> [ProtectionIssue]
}

protocol ApplicationRuleEnforcing: AnyObject {
    func close(
        applications: [ProtectedApplication],
        contributingBlockIDs: [UUID],
        state: ProtectedState,
        at date: Date
    ) -> EnforcementOutcome
}

enum OwnedRuleCleanup {
    static func run(hosts: HostsRuleEnforcing, packetFilter: PFRuleEnforcing) throws {
        try hosts.apply(domains: [])
        let issues = try packetFilter.apply(addresses: [], blockIDs: [])
        guard issues.isEmpty else {
            throw ServiceRuntimeError.enforcementFailed(
                issues.map(\.message).joined(separator: " ")
            )
        }
    }
}

final class CompositeProtectionEnforcer: ProtectionEnforcing {
    private let hosts: HostsRuleEnforcing
    private let packetFilter: PFRuleEnforcing
    private let applications: ApplicationRuleEnforcing

    init(
        hosts: HostsRuleEnforcing,
        packetFilter: PFRuleEnforcing,
        applications: ApplicationRuleEnforcing
    ) {
        self.hosts = hosts
        self.packetFilter = packetFilter
        self.applications = applications
    }

    func apply(
        _ restrictions: EffectiveRestrictions,
        state: ProtectedState,
        at date: Date
    ) throws -> EnforcementOutcome {
        let domains = restrictions.blockedDomains.filter { !DomainRule.isLiteralIPAddress($0) }
        let addresses = restrictions.blockedDomains.filter(DomainRule.isLiteralIPAddress)
        try hosts.apply(domains: domains)
        let pfIssues = try packetFilter.apply(
            addresses: addresses,
            blockIDs: restrictions.contributingBlockIDs
        )
        let applicationOutcome = applications.close(
            applications: restrictions.blockedApplications,
            contributingBlockIDs: restrictions.contributingBlockIDs,
            state: state,
            at: date
        )
        return EnforcementOutcome(
            issues: pfIssues + applicationOutcome.issues,
            closedApplications: applicationOutcome.closedApplications
        )
    }

    func closeApplications(
        _ restrictions: EffectiveRestrictions,
        state: ProtectedState,
        at date: Date
    ) -> EnforcementOutcome {
        applications.close(
            applications: restrictions.blockedApplications,
            contributingBlockIDs: restrictions.contributingBlockIDs,
            state: state,
            at: date
        )
    }
}
