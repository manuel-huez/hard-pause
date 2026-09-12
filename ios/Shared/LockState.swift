import Foundation

enum LockPhase: String, Codable, Equatable {
    case inactive
    case locked
    case waitingForBreak
    case breakActive
    case waitingForEnd
}

struct LockState: Codable, Equatable {
    // Kept for decoding the original single-lock file. Collection revisions are authoritative.
    var revision = 0
    var phase: LockPhase = .inactive
    var policy = LockPolicy()
    var storeSlot: Int?
    var activatedAt: Date?
    var automaticEndAt: Date?
    var nextTransitionAt: Date?
    var monitoringStartsAt: Date?
    var monitoringEndsAt: Date?
    var breakEndsAt: Date?
    var lastEvaluationDate: Date?
    var lastSystemUptime: TimeInterval?
    var lastBootIdentifier: String?
    var registeredScheduleStartsAt: Date?
    var registeredScheduleEndsAt: Date?
    var registeredScheduleWarningTime: TimeInterval?
    var enforcementNeedsRefresh: Bool?
    var recoveryNotice: String?

    var isActive: Bool { phase != .inactive }

    var blocksTargets: Bool {
        switch phase {
        case .inactive, .breakActive:
            false
        case .locked, .waitingForBreak, .waitingForEnd:
            true
        }
    }

    func remaining(
        wallClockDate: Date = Date(),
        elapsedTime: ElapsedTimeReading = ElapsedTimeClock.current
    ) -> TimeInterval? {
        guard let nextTransitionAt else { return nil }
        return remaining(until: nextTransitionAt, wallClockDate: wallClockDate, elapsedTime: elapsedTime)
    }

    func automaticEndRemaining(
        wallClockDate: Date = Date(),
        elapsedTime: ElapsedTimeReading = ElapsedTimeClock.current
    ) -> TimeInterval? {
        guard let automaticEndAt else { return nil }
        return remaining(until: automaticEndAt, wallClockDate: wallClockDate, elapsedTime: elapsedTime)
    }

    func countdownLabel(
        wallClockDate: Date = Date(),
        elapsedTime: ElapsedTimeReading = ElapsedTimeClock.current
    ) -> String {
        Self.durationLabel(remaining(wallClockDate: wallClockDate, elapsedTime: elapsedTime))
    }

    func automaticEndCountdownLabel(
        wallClockDate: Date = Date(),
        elapsedTime: ElapsedTimeReading = ElapsedTimeClock.current
    ) -> String {
        Self.durationLabel(
            automaticEndRemaining(wallClockDate: wallClockDate, elapsedTime: elapsedTime)
        )
    }

    func effectiveDate(
        wallClockDate: Date,
        elapsedTime: ElapsedTimeReading
    ) -> Date {
        guard
            let lastEvaluationDate,
            let lastSystemUptime,
            let lastBootIdentifier,
            lastBootIdentifier == elapsedTime.bootIdentifier,
            elapsedTime.durationSinceBoot >= lastSystemUptime
        else {
            // A changed or unavailable boot identity cannot safely prove elapsed time.
            return lastEvaluationDate ?? wallClockDate
        }

        return lastEvaluationDate.addingTimeInterval(
            elapsedTime.durationSinceBoot - lastSystemUptime
        )
    }

    private func remaining(
        until deadline: Date,
        wallClockDate: Date,
        elapsedTime: ElapsedTimeReading
    ) -> TimeInterval {
        max(
            0,
            deadline.timeIntervalSince(
                effectiveDate(wallClockDate: wallClockDate, elapsedTime: elapsedTime)
            ))
    }

    private static func durationLabel(_ interval: TimeInterval?) -> String {
        let remaining = Int((interval ?? 0).rounded(.up))
        let hours = remaining / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60
        if hours >= 24 {
            let days = hours / 24
            return String(format: "%dd %02dh %02dm", days, hours % 24, minutes)
        }
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

struct LockBlock: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var draftPolicy: LockPolicy
    var state: LockState

    init(
        id: UUID = UUID(),
        name: String = "My pause",
        draftPolicy: LockPolicy = LockPolicy(),
        state: LockState = LockState()
    ) {
        self.id = id
        self.name = Self.normalizedName(name)
        self.draftPolicy = draftPolicy
        self.state = state
    }

    static func normalizedName(_ input: String) -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(name.prefix(48))
    }
}

struct LockCollection: Codable, Equatable {
    static let maximumActiveBlocks = 16

    var schemaVersion = 2
    var revision = 0
    var blocks: [LockBlock]
    var enforcementNeedsRefresh: Bool?

    init(
        revision: Int = 0,
        blocks: [LockBlock] = [LockBlock()],
        enforcementNeedsRefresh: Bool? = nil
    ) {
        self.revision = revision
        self.blocks = blocks
        self.enforcementNeedsRefresh = enforcementNeedsRefresh
    }

    var activeBlocks: [LockBlock] { blocks.filter(\.state.isActive) }
    var hasActiveBlocks: Bool { blocks.contains(where: \.state.isActive) }

    func block(id: UUID) -> LockBlock? {
        blocks.first { $0.id == id }
    }

    func index(of id: UUID) throws -> Int {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            throw LockCollectionError.blockNotFound
        }
        return index
    }
}

enum LockCollectionError: LocalizedError, Equatable {
    case blockNotFound
    case invalidName
    case duplicateBlockIdentifier
    case invalidStoreSlot
    case activeBlockCannotBeEdited
    case maximumActiveBlocks

    var errorDescription: String? {
        switch self {
        case .blockNotFound:
            "The selected pause no longer exists."
        case .invalidName:
            "Enter a name for this pause."
        case .duplicateBlockIdentifier:
            "The saved pause collection contains a duplicate identifier."
        case .invalidStoreSlot:
            "The active pause store assignment is invalid."
        case .activeBlockCannotBeEdited:
            "An active pause cannot be edited or deleted."
        case .maximumActiveBlocks:
            "No more than 16 pauses can be active at the same time."
        }
    }
}

enum LockStateError: LocalizedError, Equatable {
    case alreadyActive
    case inactive
    case requestAlreadyPending
    case breakAlreadyActive
    case noBlockingTarget
    case tooManyManualDomains
    case tooManySelectedWebDomains

    var errorDescription: String? {
        switch self {
        case .alreadyActive:
            "This pause is already active."
        case .inactive:
            "This pause is not active."
        case .requestAlreadyPending:
            "A timeout or full-unlock request is already pending."
        case .breakAlreadyActive:
            "A timeout is already active."
        case .noBlockingTarget:
            "Choose at least one app or website, or enable adult website filtering."
        case .tooManyManualDomains:
            "Choose no more than 50 manually entered website domains."
        case .tooManySelectedWebDomains:
            "Choose no more than 50 Screen Time website domains."
        }
    }
}

enum LockCollectionStateMachine {
    static func activate(
        _ collection: inout LockCollection,
        blockID: UUID,
        at date: Date,
        elapsedTime: ElapsedTimeReading
    ) throws {
        let index = try collection.index(of: blockID)
        guard !collection.blocks[index].state.isActive else {
            throw LockStateError.alreadyActive
        }
        guard collection.activeBlocks.count < LockCollection.maximumActiveBlocks else {
            throw LockCollectionError.maximumActiveBlocks
        }
        let usedSlots = Set(collection.activeBlocks.compactMap(\.state.storeSlot))
        guard
            let storeSlot = (0..<LockCollection.maximumActiveBlocks).first(where: {
                !usedSlots.contains($0)
            })
        else {
            throw LockCollectionError.maximumActiveBlocks
        }
        try LockStateMachine.activate(
            &collection.blocks[index].state,
            policy: collection.blocks[index].draftPolicy,
            at: date,
            elapsedTime: elapsedTime
        )
        collection.blocks[index].state.storeSlot = storeSlot
    }

    static func requestBreak(
        _ collection: inout LockCollection,
        blockID: UUID,
        at date: Date,
        elapsedTime: ElapsedTimeReading
    ) throws {
        let index = try collection.index(of: blockID)
        try LockStateMachine.requestBreak(
            &collection.blocks[index].state,
            at: date,
            elapsedTime: elapsedTime
        )
    }

    static func requestEnd(
        _ collection: inout LockCollection,
        blockID: UUID,
        at date: Date,
        elapsedTime: ElapsedTimeReading
    ) throws {
        let index = try collection.index(of: blockID)
        try LockStateMachine.requestEnd(
            &collection.blocks[index].state,
            at: date,
            elapsedTime: elapsedTime
        )
    }

    @discardableResult
    static func reconcile(
        _ collection: inout LockCollection,
        at date: Date,
        elapsedTime: ElapsedTimeReading
    ) -> Bool {
        let original = collection
        for index in collection.blocks.indices {
            _ = LockStateMachine.reconcile(
                &collection.blocks[index].state,
                at: date,
                elapsedTime: elapsedTime
            )
        }
        return collection != original
    }
}

enum LockStateMachine {
    static func activate(
        _ state: inout LockState,
        policy: LockPolicy,
        at date: Date,
        elapsedTime: ElapsedTimeReading
    ) throws {
        guard !state.isActive else { throw LockStateError.alreadyActive }
        var fixedPolicy = policy
        fixedPolicy.normalize()
        try fixedPolicy.validateManagedSettingsLimits()
        guard fixedPolicy.hasBlockingTarget else { throw LockStateError.noBlockingTarget }

        state.phase = .locked
        state.policy = fixedPolicy
        state.storeSlot = nil
        state.activatedAt = date
        state.automaticEndAt = fixedPolicy.fixedDuration.map(date.addingTimeInterval)
        state.nextTransitionAt = nil
        state.breakEndsAt = nil
        state.registeredScheduleStartsAt = nil
        state.registeredScheduleEndsAt = nil
        state.registeredScheduleWarningTime = nil
        state.recoveryNotice = nil
        checkpoint(&state, at: date, elapsedTime: elapsedTime)
        refreshMonitoringWindow(&state)
    }

    static func requestBreak(
        _ state: inout LockState,
        at date: Date,
        elapsedTime: ElapsedTimeReading
    ) throws {
        _ = reconcile(&state, at: date, elapsedTime: elapsedTime)
        switch state.phase {
        case .locked:
            let requestDate = state.effectiveDate(wallClockDate: date, elapsedTime: elapsedTime)
            let breakStartsAt = requestDate.addingTimeInterval(state.policy.waitDuration)
            checkpoint(&state, at: requestDate, elapsedTime: elapsedTime)
            state.phase = .waitingForBreak
            state.nextTransitionAt = breakStartsAt
            state.breakEndsAt = breakStartsAt.addingTimeInterval(state.policy.breakDuration)
            state.registeredScheduleStartsAt = nil
            state.registeredScheduleEndsAt = nil
            state.registeredScheduleWarningTime = nil
            state.recoveryNotice =
                elapsedTime.bootIdentifier == nil
                ? "Hard Pause could not verify elapsed time, so the delay is paused."
                : nil
            refreshMonitoringWindow(&state)
        case .waitingForBreak, .waitingForEnd:
            throw LockStateError.requestAlreadyPending
        case .breakActive:
            throw LockStateError.breakAlreadyActive
        case .inactive:
            throw LockStateError.inactive
        }
    }

    static func requestEnd(
        _ state: inout LockState,
        at date: Date,
        elapsedTime: ElapsedTimeReading
    ) throws {
        _ = reconcile(&state, at: date, elapsedTime: elapsedTime)
        guard state.isActive else { throw LockStateError.inactive }
        if state.phase == .waitingForBreak || state.phase == .waitingForEnd {
            throw LockStateError.requestAlreadyPending
        }

        state.phase = .waitingForEnd
        let requestDate = state.effectiveDate(wallClockDate: date, elapsedTime: elapsedTime)
        checkpoint(&state, at: requestDate, elapsedTime: elapsedTime)
        state.nextTransitionAt = requestDate.addingTimeInterval(
            state.policy.fullUnlockDelay ?? state.policy.waitDuration
        )
        state.breakEndsAt = nil
        state.registeredScheduleStartsAt = nil
        state.registeredScheduleEndsAt = nil
        state.registeredScheduleWarningTime = nil
        state.recoveryNotice =
            elapsedTime.bootIdentifier == nil
            ? "Hard Pause could not verify elapsed time, so the delay is paused."
            : nil
        refreshMonitoringWindow(&state)
    }

    @discardableResult
    static func reconcile(
        _ state: inout LockState,
        at wallClockDate: Date,
        elapsedTime: ElapsedTimeReading
    ) -> Bool {
        let oldState = state
        let isSameBoot =
            state.lastBootIdentifier != nil
            && state.lastBootIdentifier == elapsedTime.bootIdentifier
            && (state.lastSystemUptime.map { elapsedTime.durationSinceBoot >= $0 } ?? false)
        let effectiveNow = state.effectiveDate(
            wallClockDate: wallClockDate,
            elapsedTime: elapsedTime
        )

        if state.isActive, !isSameBoot {
            checkpoint(&state, at: effectiveNow, elapsedTime: elapsedTime)
            state.registeredScheduleStartsAt = nil
            state.registeredScheduleEndsAt = nil
            state.registeredScheduleWarningTime = nil
            if state.nextTransitionAt != nil || state.automaticEndAt != nil {
                state.recoveryNotice =
                    elapsedTime.bootIdentifier == nil
                    ? "Hard Pause could not verify elapsed time, so the delay is paused."
                    : "The device restarted, so time while it was off did not reduce the delay."
            }
        }

        let phaseBeforeReconcile = state.phase
        if let automaticEndAt = state.automaticEndAt, effectiveNow >= automaticEndAt {
            deactivate(&state)
        } else {
            switch state.phase {
            case .waitingForBreak:
                guard let startsAt = state.nextTransitionAt, effectiveNow >= startsAt else { break }
                if let endsAt = state.breakEndsAt, effectiveNow < endsAt {
                    state.phase = .breakActive
                    state.nextTransitionAt = endsAt
                } else {
                    returnToLocked(&state)
                }
            case .breakActive:
                if let endsAt = state.nextTransitionAt, effectiveNow >= endsAt {
                    returnToLocked(&state)
                }
            case .waitingForEnd:
                if let endsAt = state.nextTransitionAt, effectiveNow >= endsAt {
                    deactivate(&state)
                }
            case .inactive, .locked:
                break
            }
        }

        if state.isActive, state.phase != phaseBeforeReconcile {
            checkpoint(&state, at: effectiveNow, elapsedTime: elapsedTime)
        }
        if state.phase != phaseBeforeReconcile {
            refreshMonitoringWindow(&state)
        }

        return state != oldState
    }

    static func recoverMissingRelockSchedule(_ state: inout LockState) {
        returnToLocked(&state)
        state.recoveryNotice =
            "The timeout ended because iOS could not confirm its return-to-block schedule. You can request another timeout."
    }

    private static func deactivate(_ state: inout LockState) {
        state.phase = .inactive
        state.storeSlot = nil
        state.activatedAt = nil
        state.automaticEndAt = nil
        state.nextTransitionAt = nil
        state.monitoringStartsAt = nil
        state.monitoringEndsAt = nil
        state.breakEndsAt = nil
        state.lastEvaluationDate = nil
        state.lastSystemUptime = nil
        state.lastBootIdentifier = nil
        state.registeredScheduleStartsAt = nil
        state.registeredScheduleEndsAt = nil
        state.registeredScheduleWarningTime = nil
        state.recoveryNotice = nil
    }

    private static func returnToLocked(_ state: inout LockState) {
        state.phase = .locked
        state.nextTransitionAt = nil
        state.breakEndsAt = nil
        state.registeredScheduleStartsAt = nil
        state.registeredScheduleEndsAt = nil
        state.registeredScheduleWarningTime = nil
        refreshMonitoringWindow(&state)
    }

    private static func refreshMonitoringWindow(_ state: inout LockState) {
        let minimumInterval: TimeInterval = 900
        switch state.phase {
        case .inactive:
            state.monitoringStartsAt = nil
            state.monitoringEndsAt = nil
        case .locked:
            state.monitoringEndsAt = state.automaticEndAt
            state.monitoringStartsAt = state.automaticEndAt?.addingTimeInterval(-minimumInterval)
        case .waitingForBreak:
            guard let breakStart = state.nextTransitionAt else { return }
            if let automaticEndAt = state.automaticEndAt, automaticEndAt <= breakStart {
                state.monitoringStartsAt = automaticEndAt.addingTimeInterval(-minimumInterval)
                state.monitoringEndsAt = automaticEndAt
            } else {
                state.monitoringStartsAt = breakStart
                state.monitoringEndsAt = state.breakEndsAt
            }
        case .breakActive:
            guard let breakEnd = state.breakEndsAt else { return }
            state.monitoringStartsAt = breakEnd.addingTimeInterval(-state.policy.breakDuration)
            state.monitoringEndsAt = breakEnd
        case .waitingForEnd:
            guard let phaseEnd = state.nextTransitionAt else { return }
            let end = min(phaseEnd, state.automaticEndAt ?? .distantFuture)
            state.monitoringEndsAt = end
            state.monitoringStartsAt = end.addingTimeInterval(-minimumInterval)
        }
    }

    private static func checkpoint(
        _ state: inout LockState,
        at date: Date,
        elapsedTime: ElapsedTimeReading
    ) {
        state.lastEvaluationDate = date
        state.lastSystemUptime =
            elapsedTime.bootIdentifier == nil
            ? nil
            : elapsedTime.durationSinceBoot
        state.lastBootIdentifier = elapsedTime.bootIdentifier
    }
}
