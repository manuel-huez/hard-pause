import Foundation
import XCTest

let serviceTestStart = Date(timeIntervalSince1970: 1_700_000_000)

func serviceTestReading(_ elapsed: TimeInterval, boot: String? = "boot-a") -> ClockReading {
    ClockReading(
        wallTime: serviceTestStart.addingTimeInterval(elapsed),
        continuousTime: elapsed,
        bootIdentifier: boot
    )
}

func serviceTestApplication(
    bundleIdentifier: String = "org.example.Focus",
    name: String = "Focus",
    requirement: String = "identifier \"org.example.Focus\""
) -> ProtectedApplication {
    ProtectedApplication(
        bundleIdentifier: bundleIdentifier,
        displayName: name,
        designatedRequirement: requirement
    )
}

func serviceTestDraft(
    name: String = "Focus",
    domains: [String] = ["example.com"],
    applications: [ProtectedApplication] = [],
    protectionMode: ProtectionMode = .softLock,
    breakDelay: TimeInterval = 60,
    fullUnlockDelay: TimeInterval = 180,
    breakDuration: TimeInterval = 60,
    elapsedDuration: TimeInterval? = nil
) -> ProtectedBlockDraft {
    ProtectedBlockDraft(
        name: name,
        rules: ProtectedRules(
            blockedDomains: domains,
            blockedApplications: applications,
            blocksStarterAdultSites: false
        ),
        protectionMode: protectionMode,
        breakDelay: breakDelay,
        fullUnlockDelay: fullUnlockDelay,
        breakDuration: breakDuration,
        elapsedDuration: elapsedDuration
    )
}

final class FakeServiceClock: ServiceClock, @unchecked Sendable {
    var reading: ClockReading

    init(_ reading: ClockReading) { self.reading = reading }

    func read() -> ClockReading { reading }
}

final class TestEventLog {
    var values: [String] = []
}

final class FakeProtectedStateStore: ProtectedStateStoring {
    var persisted: ProtectedState
    var pending: ProtectedState?
    var mainSaveFailures = 0
    var pendingSaveFailures = 0
    var clearFailures = 0
    var mainSaveCount = 0
    var pendingSaveCount = 0
    var clearCount = 0
    let events: TestEventLog?

    init(_ state: ProtectedState = ProtectedState(), events: TestEventLog? = nil) {
        persisted = state
        self.events = events
    }

    func load() throws -> ProtectedState { pending ?? persisted }

    func save(_ state: ProtectedState) throws {
        mainSaveCount += 1
        events?.values.append("save-main")
        if mainSaveFailures > 0 {
            mainSaveFailures -= 1
            throw ServiceRuntimeError.stateWriteFailed("injected main save failure")
        }
        persisted = state
    }

    func savePendingCandidate(_ state: ProtectedState) throws {
        pendingSaveCount += 1
        events?.values.append("save-pending")
        if pendingSaveFailures > 0 {
            pendingSaveFailures -= 1
            throw ServiceRuntimeError.stateWriteFailed("injected pending save failure")
        }
        pending = state
    }

    func clearPendingCandidate() throws {
        clearCount += 1
        events?.values.append("clear-pending")
        if clearFailures > 0 {
            clearFailures -= 1
            throw ServiceRuntimeError.stateWriteFailed("injected pending clear failure")
        }
        pending = nil
    }
}

final class FakeAppleLockdownStateStore: AppleLockdownStateStoring {
    var persisted: AppleLockdownState
    var saveFailures = 0
    var saved: [AppleLockdownState] = []
    let events: TestEventLog?

    init(_ state: AppleLockdownState = AppleLockdownState(), events: TestEventLog? = nil) {
        persisted = state
        self.events = events
    }

    func load() throws -> AppleLockdownState { persisted }

    func save(_ state: AppleLockdownState) throws {
        events?.values.append("save-apple-state:\(state.phase.rawValue)")
        if saveFailures > 0 {
            saveFailures -= 1
            throw ServiceRuntimeError.stateWriteFailed("injected Apple state save failure")
        }
        persisted = state
        saved.append(state)
    }
}

final class FakeAppleLockdownVault: AppleLockdownCredentialVault {
    var values: [UUID: String] = [:]
    var saveFailures = 0
    var readFailures = 0
    var deleteFailures = 0
    var readOverride: String?
    let events: TestEventLog?

    init(events: TestEventLog? = nil) { self.events = events }

    func save(passcode: String, credentialID: UUID) throws {
        events?.values.append("save-credential")
        if saveFailures > 0 {
            saveFailures -= 1
            throw AppleLockdownError.credentialStoreFailed
        }
        guard values[credentialID] == nil else {
            throw AppleLockdownError.credentialStoreFailed
        }
        values[credentialID] = passcode
    }

    func read(credentialID: UUID) throws -> String {
        events?.values.append("read-credential")
        if readFailures > 0 {
            readFailures -= 1
            throw AppleLockdownError.credentialUnavailable
        }
        if let readOverride { return readOverride }
        guard let value = values[credentialID] else {
            throw AppleLockdownError.credentialUnavailable
        }
        return value
    }

    func delete(credentialID: UUID) throws {
        events?.values.append("delete-credential")
        if deleteFailures > 0 {
            deleteFailures -= 1
            throw AppleLockdownError.credentialStoreFailed
        }
        values.removeValue(forKey: credentialID)
    }

    func deleteAll() throws {
        if deleteFailures > 0 {
            deleteFailures -= 1
            throw AppleLockdownError.credentialStoreFailed
        }
        values.removeAll()
    }

    func containsAnyCredential() throws -> Bool { !values.isEmpty }
}

final class FakeAppleLockdownPasscodeGenerator: AppleLockdownPasscodeGenerating {
    var passcodes: [String]

    init(_ passcodes: [String] = ["1234"]) { self.passcodes = passcodes }

    func generate() throws -> String {
        guard !passcodes.isEmpty else {
            throw AppleLockdownError.credentialStoreFailed
        }
        return passcodes.removeFirst()
    }
}

final class FakeProtectionEnforcer: ProtectionEnforcing {
    var applications: [EffectiveRestrictions] = []
    var applicationScans: [EffectiveRestrictions] = []
    var applyFailures = 0
    var outcome = EnforcementOutcome.success
    let events: TestEventLog?

    init(events: TestEventLog? = nil) { self.events = events }

    func apply(
        _ restrictions: EffectiveRestrictions,
        state: ProtectedState,
        at date: Date
    ) throws -> EnforcementOutcome {
        applications.append(restrictions)
        events?.values.append("apply:\(restrictions.blockedDomains.joined(separator: ","))")
        if applyFailures > 0 {
            applyFailures -= 1
            throw ServiceRuntimeError.enforcementFailed("injected apply failure")
        }
        return outcome
    }

    func closeApplications(
        _ restrictions: EffectiveRestrictions,
        state: ProtectedState,
        at date: Date
    ) -> EnforcementOutcome {
        applicationScans.append(restrictions)
        return .success
    }
}

final class FakeManagedTextFile: ManagedTextFile {
    var contents: String
    var writes: [String] = []

    init(_ contents: String) { self.contents = contents }

    func read() throws -> String { contents }

    func write(_ contents: String) throws {
        self.contents = contents
        writes.append(contents)
    }
}

final class FakePFTokenStore: PFTokenStoring {
    var token: PFEnableToken?
    var saves: [PFEnableToken?] = []
    var failNonNilSave = false

    init(_ token: PFEnableToken? = nil) { self.token = token }

    func load() throws -> PFEnableToken? { token }

    func save(_ token: PFEnableToken?) throws {
        saves.append(token)
        if token != nil, failNonNilSave {
            throw ServiceRuntimeError.enforcementFailed("injected token save failure")
        }
        self.token = token
    }
}

final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let standardInput: Data?
    }

    var invocations: [Invocation] = []
    var handler: ([String], Data?) throws -> CommandResult

    init(handler: @escaping ([String], Data?) throws -> CommandResult) {
        self.handler = handler
    }

    func run(executable: String, arguments: [String], standardInput: Data?) throws -> CommandResult {
        invocations.append(
            Invocation(executable: executable, arguments: arguments, standardInput: standardInput)
        )
        return try handler(arguments, standardInput)
    }
}

final class FakeProcessAuthenticator: RunningProcessAuthenticating {
    var processes: [AuditedRunningProcess] = []
    var requestedUserIdentifiers: [uid_t] = []
    var requestedSigningIdentifierSets: [Set<String>] = []
    var matchingRequirements: [pid_t: Set<String>] = [:]
    var refreshResults: [pid_t: AuditedRunningProcess?] = [:]
    var terminateResult = true
    var terminated: [AuditedRunningProcess] = []

    func runningProcesses(
        effectiveUserIdentifier: uid_t,
        matchingSigningIdentifiers: Set<String>
    ) -> [AuditedRunningProcess] {
        requestedUserIdentifiers.append(effectiveUserIdentifier)
        requestedSigningIdentifierSets.append(matchingSigningIdentifiers)
        return processes.filter {
            $0.effectiveUserIdentifier == effectiveUserIdentifier
                && matchingSigningIdentifiers.contains($0.signingIdentifier)
        }
    }

    func satisfies(_ process: AuditedRunningProcess, requirement: String) -> Bool {
        matchingRequirements[process.processIdentifier, default: []].contains(requirement)
    }

    func refresh(_ process: AuditedRunningProcess) -> AuditedRunningProcess? {
        if let configured = refreshResults[process.processIdentifier] { return configured }
        return process
    }

    func terminate(_ process: AuditedRunningProcess) -> Bool {
        terminated.append(process)
        return terminateResult
    }
}

func makeAuditedProcess(
    pid: pid_t,
    uid: uid_t = 501,
    signingIdentifier: String = "org.example.Focus"
) -> AuditedRunningProcess {
    AuditedRunningProcess(
        processIdentifier: pid,
        effectiveUserIdentifier: uid,
        auditTokenData: Data(repeating: UInt8(pid % 255), count: 32),
        executablePath: "/Applications/Focus.app/Contents/MacOS/Focus",
        signingIdentifier: signingIdentifier
    )
}
