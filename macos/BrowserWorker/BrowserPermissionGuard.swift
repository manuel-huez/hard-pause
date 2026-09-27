import AppKit
import Darwin
import Foundation

@MainActor
final class BrowserPermissionGuard {
    private struct Denial {
        let process: AuditedRunningProcess
        let startedAt: TimeInterval
        let nextCheckAt: TimeInterval
        let interval: TimeInterval
    }

    private static let browserIdentifiers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
    ]
    private let processes: RunningProcessAuthenticating
    private let userIdentifier: uid_t
    private let now: () -> TimeInterval
    private var denials: [pid_t: Denial] = [:]
    private var isChecking = false
    private var revision = 0
    private(set) var blockedBrowsers: Set<String> = []

    init(
        processes: RunningProcessAuthenticating = SystemRunningProcessAuthenticator(),
        userIdentifier: uid_t = geteuid(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.processes = processes
        self.userIdentifier = userIdentifier
        self.now = now
    }

    func check(
        active: Bool,
        permission: (AuditedRunningProcess) async -> OSStatus,
        currentRules: () async -> Bool?,
        otherWorkerAccess: (String) async -> Bool?
    ) async -> Set<String> {
        guard active else {
            revision &+= 1
            denials.removeAll()
            blockedBrowsers.removeAll()
            return []
        }
        guard !isChecking else { return [] }
        isChecking = true
        defer { isChecking = false }
        let checkRevision = revision
        let running = processes.runningProcesses(
            effectiveUserIdentifier: userIdentifier,
            matchingSigningIdentifiers: Self.browserIdentifiers
        ).filter {
            $0.effectiveUserIdentifier == userIdentifier
                && Self.browserIdentifiers.contains($0.signingIdentifier)
        }
        let runningIDs = Set(running.map(\.processIdentifier))
        denials = denials.filter { runningIDs.contains($0.key) }
        var closed: Set<String> = []

        for process in running {
            let previous = denials[process.processIdentifier]
            let checkStartedAt = now()
            if let previous, previous.process == process,
                checkStartedAt >= previous.startedAt, checkStartedAt < previous.nextCheckAt
            {
                continue
            }
            let status = await permission(process)
            guard revision == checkRevision, !Task.isCancelled else { return closed }
            guard processes.refresh(process) == process else {
                denials.removeValue(forKey: process.processIdentifier)
                continue
            }
            guard Self.isDenied(status) else {
                denials.removeValue(forKey: process.processIdentifier)
                if status == noErr { blockedBrowsers.remove(process.signingIdentifier) }
                continue
            }
            let observedAt = now()
            guard let previous, previous.process == process,
                observedAt >= previous.nextCheckAt, observedAt - previous.nextCheckAt <= 5
            else {
                denials[process.processIdentifier] = Denial(
                    process: process, startedAt: observedAt, nextCheckAt: observedAt + 1, interval: 1)
                continue
            }
            guard observedAt - previous.startedAt >= 30 else {
                let interval = min(previous.interval * 2, 8)
                denials[process.processIdentifier] = Denial(
                    process: process, startedAt: previous.startedAt,
                    nextCheckAt: observedAt + interval, interval: interval)
                continue
            }
            // Consume the streak before waits; a failed preflight restarts the wait.
            denials.removeValue(forKey: process.processIdentifier)
            guard await otherWorkerAccess(process.signingIdentifier) == false,
                revision == checkRevision, !Task.isCancelled,
                await currentRules() == true,
                revision == checkRevision, !Task.isCancelled
            else { continue }
            let finalStatus = await permission(process)
            guard revision == checkRevision, !Task.isCancelled else { return closed }
            if finalStatus == noErr { blockedBrowsers.remove(process.signingIdentifier) }
            let finalObservedAt = now()
            guard Self.isDenied(finalStatus), finalObservedAt >= observedAt, finalObservedAt - observedAt <= 5,
                processes.refresh(process) == process,
                processes.terminate(process)
            else { continue }
            blockedBrowsers.insert(process.signingIdentifier)
            closed.insert(process.signingIdentifier)
        }
        return closed
    }

    private static func isDenied(_ status: OSStatus) -> Bool {
        status == OSStatus(errAEEventNotPermitted)
    }
}
