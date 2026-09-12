import Darwin
import Foundation
import Security

struct AuditedRunningProcess: Equatable {
    let processIdentifier: pid_t
    let effectiveUserIdentifier: uid_t
    let auditTokenData: Data
    let executablePath: String
    let signingIdentifier: String
}

protocol RunningProcessAuthenticating: AnyObject {
    func runningProcesses(
        effectiveUserIdentifier: uid_t,
        matchingSigningIdentifiers: Set<String>
    ) -> [AuditedRunningProcess]
    func satisfies(_ process: AuditedRunningProcess, requirement: String) -> Bool
    func refresh(_ process: AuditedRunningProcess) -> AuditedRunningProcess?
    func terminate(_ process: AuditedRunningProcess) -> Bool
}

final class SystemRunningProcessAuthenticator: RunningProcessAuthenticating {
    func runningProcesses(
        effectiveUserIdentifier: uid_t,
        matchingSigningIdentifiers: Set<String>
    ) -> [AuditedRunningProcess] {
        guard !matchingSigningIdentifiers.isEmpty else { return [] }
        var capacity = max(proc_listallpids(nil, 0), 256) + 128
        for _ in 0..<2 {
            var identifiers = [pid_t](repeating: 0, count: Int(capacity))
            let count = identifiers.withUnsafeMutableBytes { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count))
            }
            guard count >= 0 else { return [] }
            if count < capacity {
                return identifiers.prefix(Int(count)).compactMap { identifier in
                    guard identifier > 1, identifier != getpid() else { return nil }
                    guard processEffectiveUserIdentifier(identifier) == effectiveUserIdentifier,
                        let executablePath = executablePath(identifier),
                        let bundleIdentifier = bundleIdentifier(forExecutablePath: executablePath),
                        matchingSigningIdentifiers.contains(bundleIdentifier)
                    else { return nil }
                    return authenticatedProcess(identifier)
                }
            }
            capacity *= 2
        }
        return []
    }

    private func processEffectiveUserIdentifier(_ processIdentifier: pid_t) -> uid_t? {
        var information = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &information,
            Int32(expectedSize)
        )
        return result == expectedSize ? information.pbi_uid : nil
    }

    private func executablePath(_ processIdentifier: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
            return nil
        }
        return String(cString: pathBuffer)
    }

    private func bundleIdentifier(forExecutablePath path: String) -> String? {
        var candidate = URL(fileURLWithPath: path).deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                return Bundle(url: candidate)?.bundleIdentifier
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    func satisfies(_ process: AuditedRunningProcess, requirement: String) -> Bool {
        guard let code = code(for: process.auditTokenData) else { return false }
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess,
            let parsed
        else { return false }
        return SecCodeCheckValidity(code, [], parsed) == errSecSuccess
    }

    func refresh(_ process: AuditedRunningProcess) -> AuditedRunningProcess? {
        guard let current = authenticatedProcess(process.processIdentifier), current == process else {
            return nil
        }
        return current
    }

    func terminate(_ process: AuditedRunningProcess) -> Bool {
        guard let current = refresh(process), signal(current, SIGTERM) else { return false }
        if waitUntilExited(current, timeout: 0.25) { return true }
        guard signal(current, SIGKILL) else { return false }
        return waitUntilExited(current, timeout: 1)
    }

    private func authenticatedProcess(_ processIdentifier: pid_t) -> AuditedRunningProcess? {
        guard let auditToken = auditToken(for: processIdentifier) else { return nil }
        var mutableToken = auditToken
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath_audittoken(
            &mutableToken,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard pathLength > 0 else { return nil }
        let executablePath = String(cString: pathBuffer)
        let tokenData = withUnsafeBytes(of: auditToken) { Data($0) }
        guard code(for: tokenData) != nil else { return nil }

        let executableURL = URL(fileURLWithPath: executablePath)
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode,
            SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
            let values = information as? [CFString: Any],
            let signingIdentifier = values[kSecCodeInfoIdentifier] as? String,
            let mainExecutable = values[kSecCodeInfoMainExecutable] as? URL
        else { return nil }
        guard canonicalPath(mainExecutable.path) == canonicalPath(executablePath) else { return nil }

        return AuditedRunningProcess(
            processIdentifier: processIdentifier,
            effectiveUserIdentifier: audit_token_to_euid(auditToken),
            auditTokenData: tokenData,
            executablePath: executablePath,
            signingIdentifier: signingIdentifier
        )
    }

    private func auditToken(for processIdentifier: pid_t) -> audit_token_t? {
        var task = mach_port_name_t()
        guard task_name_for_pid(mach_task_self_, processIdentifier, &task) == KERN_SUCCESS else {
            return nil
        }
        defer { _ = mach_port_deallocate(mach_task_self_, task) }

        var token = audit_token_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { info in
                task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), info, &count)
            }
        }
        guard result == KERN_SUCCESS, audit_token_to_pid(token) == processIdentifier else {
            return nil
        }
        return token
    }

    private func code(for tokenData: Data) -> SecCode? {
        guard tokenData.count == MemoryLayout<audit_token_t>.size else { return nil }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    private func signal(_ process: AuditedRunningProcess, _ signal: Int32) -> Bool {
        guard var token = auditToken(from: process.auditTokenData) else { return false }
        return proc_signal_with_audittoken(&token, signal) == 0
    }

    private func waitUntilExited(_ process: AuditedRunningProcess, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if refresh(process) == nil { return true }
            Thread.sleep(forTimeInterval: 0.025)
        } while Date() < deadline
        return refresh(process) == nil
    }

    private func auditToken(from data: Data) -> audit_token_t? {
        guard data.count == MemoryLayout<audit_token_t>.size else { return nil }
        var token = audit_token_t()
        let copied = withUnsafeMutableBytes(of: &token) { destination in
            data.copyBytes(to: destination)
        }
        return copied == data.count ? token : nil
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

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
