import DeviceActivity
import Foundation

protocol TransitionScheduling {
    func ensureSchedules(for collection: LockCollection) throws
    func hasSchedule(for block: LockBlock) -> Bool
}

protocol DeviceActivityCenterScheduling {
    var activities: [DeviceActivityName] { get }

    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule?
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws
    func stopMonitoring(_ activities: [DeviceActivityName])
}

extension DeviceActivityCenter: DeviceActivityCenterScheduling {}

enum TransitionSchedulerError: LocalizedError, Equatable {
    case tooManyActiveSchedules
    case scheduleRestoreFailed

    var errorDescription: String? {
        switch self {
        case .tooManyActiveSchedules:
            "iOS has no free Screen Time schedule slots. This pause stayed blocked. End another scheduled pause and try again."
        case .scheduleRestoreFailed:
            "iOS could not restore an earlier Screen Time schedule. Existing restrictions remain active. Open Hard Pause to repair the schedule."
        }
    }
}

struct TransitionScheduler: TransitionScheduling {
    private let center: any DeviceActivityCenterScheduling
    private let calendar = Calendar(identifier: .gregorian)

    init(center: any DeviceActivityCenterScheduling = DeviceActivityCenter()) {
        self.center = center
    }

    func ensureSchedules(for collection: LockCollection) throws {
        let desired = Dictionary(
            uniqueKeysWithValues: collection.blocks.compactMap { block in
                TransitionScheduleProjection.deviceActivitySchedule(
                    for: block.state,
                    calendar: calendar
                ).map { (HardPauseConstants.transitionActivity(for: block.id), $0) }
            })
        let currentActivities = center.activities.filter(HardPauseConstants.isTransitionActivity)
        let currentSchedules = Dictionary(
            uniqueKeysWithValues: currentActivities.compactMap { activity in
                center.schedule(for: activity).map { (activity, $0) }
            }
        )
        guard desired.count <= LockCollection.maximumActiveBlocks else {
            throw TransitionSchedulerError.tooManyActiveSchedules
        }

        let currentActivitySet = Set(currentActivities)
        let newActivities = desired.keys.filter { !currentActivitySet.contains($0) }
        let obsolete = currentActivities.filter { desired[$0] == nil }
        let numberToFree = max(
            0,
            currentActivities.count + newActivities.count - LockCollection.maximumActiveBlocks
        )
        let freedObsolete = Array(
            obsolete.sorted(by: { $0.rawValue < $1.rawValue }).prefix(numberToFree)
        )
        guard freedObsolete.count == numberToFree else {
            throw TransitionSchedulerError.tooManyActiveSchedules
        }
        if !freedObsolete.isEmpty {
            center.stopMonitoring(freedObsolete)
        }

        var attempted: [DeviceActivityName] = []

        for activity in desired.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let schedule = desired[activity], currentSchedules[activity] != schedule else {
                continue
            }
            attempted.append(activity)
            do {
                // A successful call replaces an existing schedule with this name.
                try center.startMonitoring(activity, during: schedule, events: [:])
            } catch {
                var restorationFailed = false
                for changedActivity in attempted.reversed() {
                    if let oldSchedule = currentSchedules[changedActivity] {
                        do {
                            try center.startMonitoring(
                                changedActivity,
                                during: oldSchedule,
                                events: [:]
                            )
                        } catch {
                            restorationFailed = true
                        }
                    } else {
                        center.stopMonitoring([changedActivity])
                    }
                }
                for freedActivity in freedObsolete {
                    guard let oldSchedule = currentSchedules[freedActivity] else { continue }
                    do {
                        try center.startMonitoring(freedActivity, during: oldSchedule, events: [:])
                    } catch {
                        restorationFailed = true
                    }
                }
                if restorationFailed { throw TransitionSchedulerError.scheduleRestoreFailed }
                if let monitoringError = error as? DeviceActivityCenter.MonitoringError,
                    case .excessiveActivities = monitoringError
                {
                    throw TransitionSchedulerError.tooManyActiveSchedules
                }
                throw error
            }
        }

        let freedSet = Set(freedObsolete)
        let remainingObsolete = obsolete.filter { !freedSet.contains($0) }
        if !remainingObsolete.isEmpty {
            center.stopMonitoring(remainingObsolete)
        }
    }

    func hasSchedule(for block: LockBlock) -> Bool {
        guard
            let desired = TransitionScheduleProjection.deviceActivitySchedule(
                for: block.state,
                calendar: calendar
            )
        else { return false }
        return center.schedule(for: HardPauseConstants.transitionActivity(for: block.id)) == desired
    }
}

enum TransitionScheduleProjection {
    private struct ProjectedSchedule {
        let interval: DateInterval
        let endWarningDeadline: Date?
    }

    private static let components: Set<Calendar.Component> = [
        .era, .year, .month, .day, .hour, .minute, .second, .timeZone,
    ]

    static func prepareRegistration(
        for state: inout LockState,
        wallClockNow: Date,
        elapsedTime: ElapsedTimeReading
    ) {
        guard
            let projected = projectedSchedule(
                for: state,
                wallClockNow: wallClockNow,
                elapsedTime: elapsedTime
            )
        else {
            state.registeredScheduleStartsAt = nil
            state.registeredScheduleEndsAt = nil
            state.registeredScheduleWarningTime = nil
            return
        }

        let desired = DateInterval(
            start: roundedUpToWholeSecond(projected.interval.start),
            end: roundedUpToWholeSecond(projected.interval.end)
        )
        if let registered = registeredInterval(for: state),
            !registeredBoundaryFiredEarly(
                state: state,
                registered: registered,
                wallClockNow: wallClockNow,
                elapsedTime: elapsedTime
            )
        {
            return
        }

        state.registeredScheduleStartsAt = desired.start
        state.registeredScheduleEndsAt = desired.end
        state.registeredScheduleWarningTime = endWarningTime(
            deadline: projected.endWarningDeadline,
            registered: desired,
            roundedUpToWholeSecond: roundedUpToWholeSecond
        )
    }

    static func registeredInterval(for state: LockState) -> DateInterval? {
        guard
            state.isActive,
            let start = state.registeredScheduleStartsAt,
            let end = state.registeredScheduleEndsAt,
            end.timeIntervalSince(start) >= 900
        else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }

    static func deviceActivitySchedule(
        for state: LockState,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> DeviceActivitySchedule? {
        guard let interval = registeredInterval(for: state) else { return nil }
        return DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(components, from: interval.start),
            intervalEnd: calendar.dateComponents(components, from: interval.end),
            repeats: false,
            warningTime: state.registeredScheduleWarningTime.map {
                DateComponents(second: Int($0))
            }
        )
    }

    static func endWarningDeadline(for state: LockState) -> Date? {
        guard state.registeredScheduleWarningTime != nil,
            let monitoringStart = state.monitoringStartsAt,
            let monitoringEnd = state.monitoringEndsAt
        else { return nil }
        if let automaticEndAt = state.automaticEndAt,
            automaticEndAt > monitoringStart,
            automaticEndAt < monitoringEnd
        {
            return automaticEndAt
        }
        return monitoringEnd
    }

    private static func projectedSchedule(
        for state: LockState,
        wallClockNow: Date,
        elapsedTime: ElapsedTimeReading
    ) -> ProjectedSchedule? {
        guard
            state.isActive,
            let effectiveStart = state.monitoringStartsAt,
            let effectiveEnd = state.monitoringEndsAt,
            effectiveEnd.timeIntervalSince(effectiveStart) >= 900
        else {
            return nil
        }

        let effectiveNow = state.effectiveDate(
            wallClockDate: wallClockNow,
            elapsedTime: elapsedTime
        )
        let rawStart = wallClockNow.addingTimeInterval(
            effectiveStart.timeIntervalSince(effectiveNow)
        )
        let rawEnd = wallClockNow.addingTimeInterval(
            effectiveEnd.timeIntervalSince(effectiveNow)
        )
        guard rawEnd > wallClockNow else { return nil }
        let start = max(rawStart, wallClockNow)
        let end = max(rawEnd, start.addingTimeInterval(900))
        var warningDeadline = rawEnd < end ? rawEnd : nil
        if let automaticEndAt = state.automaticEndAt,
            automaticEndAt > effectiveStart,
            automaticEndAt < effectiveEnd
        {
            let projectedAutomaticEnd = wallClockNow.addingTimeInterval(
                automaticEndAt.timeIntervalSince(effectiveNow)
            )
            if projectedAutomaticEnd > start, projectedAutomaticEnd < end {
                warningDeadline = min(warningDeadline ?? projectedAutomaticEnd, projectedAutomaticEnd)
            }
        }
        return ProjectedSchedule(
            interval: DateInterval(start: start, end: end),
            endWarningDeadline: warningDeadline
        )
    }

    private static func registeredBoundaryFiredEarly(
        state: LockState,
        registered: DateInterval,
        wallClockNow: Date,
        elapsedTime: ElapsedTimeReading
    ) -> Bool {
        let effectiveNow = state.effectiveDate(
            wallClockDate: wallClockNow,
            elapsedTime: elapsedTime
        )
        if let warningDeadline = endWarningDeadline(for: state),
            effectiveNow < warningDeadline,
            let warningTime = state.registeredScheduleWarningTime,
            wallClockNow >= registered.end.addingTimeInterval(-warningTime)
        {
            return true
        }
        guard let transition = state.nextTransitionAt, effectiveNow < transition else {
            return false
        }

        switch state.phase {
        case .waitingForBreak:
            return wallClockNow >= registered.start
        case .breakActive, .waitingForEnd:
            return wallClockNow >= registered.end
        case .inactive, .locked:
            return false
        }
    }

    private static func roundedUpToWholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.up))
    }

    private static func endWarningTime(
        deadline: Date?,
        registered: DateInterval,
        roundedUpToWholeSecond: (Date) -> Date
    ) -> TimeInterval? {
        guard let deadline else { return nil }
        let nonEarlyDeadline = roundedUpToWholeSecond(deadline)
        let warning = registered.end.timeIntervalSince(nonEarlyDeadline).rounded(.down)
        guard warning > 0, warning < registered.duration else { return nil }
        return warning
    }
}
