import DeviceActivity
import XCTest

@testable import HardPause

final class TransitionSchedulerTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    func testFractionalDeadlineRegistersAtNonEarlyWholeSecond() throws {
        let requestDate = noon.addingTimeInterval(0.8)
        var state = try pendingBreak(at: requestDate)

        TransitionScheduleProjection.prepareRegistration(
            for: &state,
            wallClockNow: requestDate,
            elapsedTime: reading(100)
        )

        let logicalStart = requestDate.addingTimeInterval(3_600)
        let registeredStart = try XCTUnwrap(state.registeredScheduleStartsAt)
        XCTAssertGreaterThanOrEqual(registeredStart, logicalStart)
        XCTAssertEqual(registeredStart, noon.addingTimeInterval(3_601))

        let schedule = try XCTUnwrap(
            TransitionScheduleProjection.deviceActivitySchedule(
                for: state,
                calendar: calendar
            )
        )
        XCTAssertEqual(calendar.date(from: schedule.intervalStart), registeredStart)
        XCTAssertEqual(
            calendar.date(from: schedule.intervalEnd),
            noon.addingTimeInterval(4_501)
        )
    }

    func testCallbackAtRegisteredStartOpensBreak() throws {
        let requestDate = noon.addingTimeInterval(0.8)
        var state = try pendingBreak(at: requestDate)
        TransitionScheduleProjection.prepareRegistration(
            for: &state,
            wallClockNow: requestDate,
            elapsedTime: reading(100)
        )
        let registeredStart = try XCTUnwrap(state.registeredScheduleStartsAt)
        let registeredEnd = try XCTUnwrap(state.registeredScheduleEndsAt)

        LockStateMachine.reconcile(
            &state,
            at: registeredStart,
            elapsedTime: reading(3_700.2)
        )
        TransitionScheduleProjection.prepareRegistration(
            for: &state,
            wallClockNow: registeredStart,
            elapsedTime: reading(3_700.2)
        )

        XCTAssertEqual(state.phase, .breakActive)
        XCTAssertEqual(state.registeredScheduleStartsAt, registeredStart)
        XCTAssertEqual(state.registeredScheduleEndsAt, registeredEnd)
    }

    func testCallbackAtRegisteredEndRelocks() throws {
        let requestDate = noon.addingTimeInterval(0.8)
        var state = try pendingBreak(at: requestDate)
        TransitionScheduleProjection.prepareRegistration(
            for: &state,
            wallClockNow: requestDate,
            elapsedTime: reading(100)
        )
        let registeredStart = try XCTUnwrap(state.registeredScheduleStartsAt)
        let registeredEnd = try XCTUnwrap(state.registeredScheduleEndsAt)
        LockStateMachine.reconcile(
            &state,
            at: registeredStart,
            elapsedTime: reading(3_700.2)
        )

        LockStateMachine.reconcile(
            &state,
            at: registeredEnd,
            elapsedTime: reading(4_600.2)
        )

        XCTAssertEqual(state.phase, .locked)
    }

    func testAcceptedRegistrationSurvivesMicrosecondProjectionJitter() throws {
        let requestDate = noon.addingTimeInterval(0.8)
        var state = try pendingBreak(at: requestDate)
        TransitionScheduleProjection.prepareRegistration(
            for: &state,
            wallClockNow: requestDate,
            elapsedTime: reading(100)
        )
        let accepted = TransitionScheduleProjection.registeredInterval(for: state)

        TransitionScheduleProjection.prepareRegistration(
            for: &state,
            wallClockNow: requestDate.addingTimeInterval(0.000_002),
            elapsedTime: reading(100.000_001)
        )

        XCTAssertEqual(TransitionScheduleProjection.registeredInterval(for: state), accepted)
    }

    func testFixedDurationRegistersAnEndBoundaryWithoutRequest() throws {
        let requestDate = noon.addingTimeInterval(0.8)
        var policy = LockPolicy()
        policy.fixedDuration = 7_200
        var state = LockState()
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: requestDate,
            elapsedTime: reading(100)
        )

        TransitionScheduleProjection.prepareRegistration(
            for: &state,
            wallClockNow: requestDate,
            elapsedTime: reading(100)
        )

        let interval = try XCTUnwrap(TransitionScheduleProjection.registeredInterval(for: state))
        XCTAssertEqual(interval.duration, 900)
        XCTAssertEqual(interval.end, noon.addingTimeInterval(7_201))
    }

    func testFixedEndInsideBreakUsesNaturalIntervalAndEndWarning() throws {
        var policy = LockPolicy()
        policy.waitDuration = 3_600
        policy.breakDuration = 900
        policy.fixedDuration = 3_900
        var state = LockState()
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: noon,
            elapsedTime: reading(100)
        )
        try LockStateMachine.requestBreak(
            &state,
            at: noon,
            elapsedTime: reading(100)
        )

        TransitionScheduleProjection.prepareRegistration(
            for: &state,
            wallClockNow: noon,
            elapsedTime: reading(100)
        )

        let interval = try XCTUnwrap(TransitionScheduleProjection.registeredInterval(for: state))
        XCTAssertEqual(interval.start, noon.addingTimeInterval(3_600))
        XCTAssertEqual(interval.end, noon.addingTimeInterval(4_500))
        XCTAssertEqual(state.registeredScheduleWarningTime, 600)
        XCTAssertEqual(
            TransitionScheduleProjection.deviceActivitySchedule(for: state)?.warningTime?.second,
            600
        )
    }

    func testFixedEndBeforeBreakStartUsesTheExpiryBoundaryOnly() throws {
        var policy = LockPolicy()
        policy.waitDuration = 3_600
        policy.breakDuration = 1_800
        policy.fixedDuration = 3_600
        var state = LockState()
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: noon,
            elapsedTime: reading(100)
        )
        try LockStateMachine.requestBreak(
            &state,
            at: noon,
            elapsedTime: reading(100)
        )

        TransitionScheduleProjection.prepareRegistration(
            for: &state,
            wallClockNow: noon,
            elapsedTime: reading(100)
        )

        let interval = try XCTUnwrap(TransitionScheduleProjection.registeredInterval(for: state))
        XCTAssertEqual(interval.start, noon.addingTimeInterval(2_700))
        XCTAssertEqual(interval.end, noon.addingTimeInterval(3_600))
        XCTAssertNil(state.registeredScheduleWarningTime)
    }

    func testFixedEndSoonAfterNaturalBreakRelocksThenUsesEndWarning() throws {
        var policy = LockPolicy()
        policy.waitDuration = 3_600
        policy.breakDuration = 900
        policy.fixedDuration = 4_800
        var state = LockState()
        try LockStateMachine.activate(
            &state,
            policy: policy,
            at: noon,
            elapsedTime: reading(100)
        )
        try LockStateMachine.requestBreak(
            &state,
            at: noon,
            elapsedTime: reading(100)
        )
        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(3_600),
            elapsedTime: reading(3_700)
        )
        LockStateMachine.reconcile(
            &state,
            at: noon.addingTimeInterval(4_500),
            elapsedTime: reading(4_600)
        )

        TransitionScheduleProjection.prepareRegistration(
            for: &state,
            wallClockNow: noon.addingTimeInterval(4_500),
            elapsedTime: reading(4_600)
        )

        XCTAssertEqual(state.phase, .locked)
        let interval = try XCTUnwrap(TransitionScheduleProjection.registeredInterval(for: state))
        XCTAssertEqual(interval.start, noon.addingTimeInterval(4_500))
        XCTAssertEqual(interval.end, noon.addingTimeInterval(5_400))
        XCTAssertEqual(state.registeredScheduleWarningTime, 600)
        XCTAssertEqual(
            TransitionScheduleProjection.endWarningDeadline(for: state),
            noon.addingTimeInterval(4_800)
        )
    }

    func testReplacementFailureAfterSideEffectRestoresAcceptedSchedule() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let activity = HardPauseConstants.transitionActivity(for: id)
        let old = scheduledBlock(
            id: id,
            slot: 0,
            start: noon.addingTimeInterval(3_600),
            end: noon.addingTimeInterval(4_500)
        )
        let replacement = scheduledBlock(
            id: id,
            slot: 0,
            start: noon.addingTimeInterval(7_200),
            end: noon.addingTimeInterval(8_100)
        )
        let oldSchedule = try XCTUnwrap(
            TransitionScheduleProjection.deviceActivitySchedule(for: old.state, calendar: calendar)
        )
        let center = RecordingDeviceActivityCenter(schedules: [activity: oldSchedule])
        center.failNextStartFor = activity

        XCTAssertThrowsError(
            try TransitionScheduler(center: center).ensureSchedules(
                for: LockCollection(blocks: [replacement])
            )
        )

        XCTAssertEqual(center.schedules[activity], oldSchedule)
        XCTAssertEqual(center.startAttempts.map(\.activity), [activity, activity])
    }

    func testFailedReplacementRollsBackEarlierChangesAndKeepsObsoleteSchedule() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let obsoleteID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let firstActivity = HardPauseConstants.transitionActivity(for: firstID)
        let secondActivity = HardPauseConstants.transitionActivity(for: secondID)
        let obsoleteActivity = HardPauseConstants.transitionActivity(for: obsoleteID)
        let oldFirst = scheduledBlock(
            id: firstID,
            slot: 0,
            start: noon.addingTimeInterval(3_600),
            end: noon.addingTimeInterval(4_500)
        )
        let oldSecond = scheduledBlock(
            id: secondID,
            slot: 1,
            start: noon.addingTimeInterval(3_600),
            end: noon.addingTimeInterval(4_500)
        )
        let obsolete = scheduledBlock(
            id: obsoleteID,
            slot: 2,
            start: noon.addingTimeInterval(3_600),
            end: noon.addingTimeInterval(4_500)
        )
        let newFirst = scheduledBlock(
            id: firstID,
            slot: 0,
            start: noon.addingTimeInterval(7_200),
            end: noon.addingTimeInterval(8_100)
        )
        let newSecond = scheduledBlock(
            id: secondID,
            slot: 1,
            start: noon.addingTimeInterval(7_200),
            end: noon.addingTimeInterval(8_100)
        )
        let oldSchedules = Dictionary(
            uniqueKeysWithValues: [oldFirst, oldSecond, obsolete].map { block in
                (
                    HardPauseConstants.transitionActivity(for: block.id),
                    TransitionScheduleProjection.deviceActivitySchedule(
                        for: block.state,
                        calendar: calendar
                    )!
                )
            }
        )
        let center = RecordingDeviceActivityCenter(schedules: oldSchedules)
        center.failNextStartFor = secondActivity

        XCTAssertThrowsError(
            try TransitionScheduler(center: center).ensureSchedules(
                for: LockCollection(blocks: [newFirst, newSecond])
            )
        )

        XCTAssertEqual(center.schedules[firstActivity], oldSchedules[firstActivity])
        XCTAssertEqual(center.schedules[secondActivity], oldSchedules[secondActivity])
        XCTAssertEqual(center.schedules[obsoleteActivity], oldSchedules[obsoleteActivity])
    }

    func testFailedReplacementReportsWhenAcceptedScheduleCannotBeRestored() throws {
        let id = UUID()
        let activity = HardPauseConstants.transitionActivity(for: id)
        let old = scheduledBlock(
            id: id,
            slot: 0,
            start: noon.addingTimeInterval(3_600),
            end: noon.addingTimeInterval(4_500)
        )
        let replacement = scheduledBlock(
            id: id,
            slot: 0,
            start: noon.addingTimeInterval(7_200),
            end: noon.addingTimeInterval(8_100)
        )
        let oldSchedule = try XCTUnwrap(
            TransitionScheduleProjection.deviceActivitySchedule(for: old.state, calendar: calendar)
        )
        let center = RecordingDeviceActivityCenter(schedules: [activity: oldSchedule])
        center.startFailuresRemaining[activity] = 2
        center.removeScheduleOnFailure = true

        XCTAssertThrowsError(
            try TransitionScheduler(center: center).ensureSchedules(
                for: LockCollection(blocks: [replacement])
            )
        ) { error in
            XCTAssertEqual(error as? TransitionSchedulerError, .scheduleRestoreFailed)
        }

        XCTAssertNil(center.schedules[activity])
        XCTAssertEqual(center.startAttempts.count, 2)
    }

    func testSchedulerRepairsAReplacementLeftByAnInterruptedAttempt() throws {
        let id = UUID()
        let activity = HardPauseConstants.transitionActivity(for: id)
        let accepted = scheduledBlock(
            id: id,
            slot: 0,
            start: noon.addingTimeInterval(3_600),
            end: noon.addingTimeInterval(4_500)
        )
        let partial = scheduledBlock(
            id: id,
            slot: 0,
            start: noon.addingTimeInterval(7_200),
            end: noon.addingTimeInterval(8_100)
        )
        let partialSchedule = try XCTUnwrap(
            TransitionScheduleProjection.deviceActivitySchedule(
                for: partial.state,
                calendar: calendar
            )
        )
        let center = RecordingDeviceActivityCenter(schedules: [activity: partialSchedule])

        try TransitionScheduler(center: center).ensureSchedules(
            for: LockCollection(blocks: [accepted])
        )

        XCTAssertEqual(
            center.schedules[activity],
            TransitionScheduleProjection.deviceActivitySchedule(
                for: accepted.state,
                calendar: calendar
            )
        )
    }

    func testSchedulerSwapsAnObsoleteActivityAtFullCapacity() throws {
        let existing = (0..<LockCollection.maximumActiveBlocks).map { slot in
            scheduledBlock(
                id: UUID(),
                slot: slot,
                start: noon.addingTimeInterval(3_600),
                end: noon.addingTimeInterval(4_500)
            )
        }
        let replacement = scheduledBlock(
            id: UUID(),
            slot: 0,
            start: noon.addingTimeInterval(7_200),
            end: noon.addingTimeInterval(8_100)
        )
        let oldSchedules = Dictionary(
            uniqueKeysWithValues: existing.map { block in
                (
                    HardPauseConstants.transitionActivity(for: block.id),
                    TransitionScheduleProjection.deviceActivitySchedule(
                        for: block.state,
                        calendar: calendar
                    )!
                )
            }
        )
        let obsoleteActivity = HardPauseConstants.transitionActivity(for: existing[0].id)
        let replacementActivity = HardPauseConstants.transitionActivity(for: replacement.id)
        let center = RecordingDeviceActivityCenter(schedules: oldSchedules)

        try TransitionScheduler(center: center).ensureSchedules(
            for: LockCollection(blocks: Array(existing.dropFirst()) + [replacement])
        )

        XCTAssertEqual(center.schedules.count, LockCollection.maximumActiveBlocks)
        XCTAssertNil(center.schedules[obsoleteActivity])
        XCTAssertNotNil(center.schedules[replacementActivity])
        XCTAssertEqual(center.stopAttempts, [[obsoleteActivity]])
        XCTAssertEqual(center.startAttempts.map(\.activity), [replacementActivity])
    }

    func testFailedFullCapacitySwapRestoresTheFreedSchedule() throws {
        let existing = (0..<LockCollection.maximumActiveBlocks).map { slot in
            scheduledBlock(
                id: UUID(),
                slot: slot,
                start: noon.addingTimeInterval(3_600),
                end: noon.addingTimeInterval(4_500)
            )
        }
        let replacement = scheduledBlock(
            id: UUID(),
            slot: 0,
            start: noon.addingTimeInterval(7_200),
            end: noon.addingTimeInterval(8_100)
        )
        let oldSchedules = Dictionary(
            uniqueKeysWithValues: existing.map { block in
                (
                    HardPauseConstants.transitionActivity(for: block.id),
                    TransitionScheduleProjection.deviceActivitySchedule(
                        for: block.state,
                        calendar: calendar
                    )!
                )
            }
        )
        let obsoleteActivity = HardPauseConstants.transitionActivity(for: existing[0].id)
        let replacementActivity = HardPauseConstants.transitionActivity(for: replacement.id)
        let center = RecordingDeviceActivityCenter(schedules: oldSchedules)
        center.failNextStartFor = replacementActivity

        XCTAssertThrowsError(
            try TransitionScheduler(center: center).ensureSchedules(
                for: LockCollection(blocks: Array(existing.dropFirst()) + [replacement])
            )
        )

        XCTAssertEqual(center.schedules, oldSchedules)
        XCTAssertEqual(center.stopAttempts, [[obsoleteActivity], [replacementActivity]])
        XCTAssertEqual(
            center.startAttempts.map(\.activity),
            [replacementActivity, obsoleteActivity]
        )
    }

    func testBlockIDsProduceDistinctScheduleAndStoreNames() {
        let first = UUID()
        let second = UUID()

        XCTAssertNotEqual(
            HardPauseConstants.transitionActivity(for: first),
            HardPauseConstants.transitionActivity(for: second)
        )
        XCTAssertNotEqual(
            HardPauseConstants.settingsStoreName(for: 0),
            HardPauseConstants.settingsStoreName(for: 1)
        )
    }

    private func pendingBreak(at date: Date) throws -> LockState {
        var state = LockState()
        try LockStateMachine.activate(
            &state,
            policy: LockPolicy(),
            at: date,
            elapsedTime: reading(100)
        )
        try LockStateMachine.requestBreak(
            &state,
            at: date,
            elapsedTime: reading(100)
        )
        return state
    }

    private func scheduledBlock(
        id: UUID,
        slot: Int,
        start: Date,
        end: Date
    ) -> LockBlock {
        var state = LockState()
        state.phase = .waitingForEnd
        state.storeSlot = slot
        state.registeredScheduleStartsAt = start
        state.registeredScheduleEndsAt = end
        return LockBlock(id: id, name: "Scheduled", state: state)
    }

    private func reading(_ durationSinceBoot: TimeInterval) -> ElapsedTimeReading {
        ElapsedTimeReading(
            durationSinceBoot: durationSinceBoot,
            bootIdentifier: "boot-a"
        )
    }
}

private enum RecordingDeviceActivityCenterError: Error {
    case failedAfterSideEffect
}

private final class RecordingDeviceActivityCenter: DeviceActivityCenterScheduling {
    struct StartAttempt {
        let activity: DeviceActivityName
        let schedule: DeviceActivitySchedule
    }

    var schedules: [DeviceActivityName: DeviceActivitySchedule]
    var failNextStartFor: DeviceActivityName?
    var startFailuresRemaining: [DeviceActivityName: Int] = [:]
    var removeScheduleOnFailure = false
    private(set) var startAttempts: [StartAttempt] = []
    private(set) var stopAttempts: [[DeviceActivityName]] = []

    init(schedules: [DeviceActivityName: DeviceActivitySchedule] = [:]) {
        self.schedules = schedules
    }

    var activities: [DeviceActivityName] {
        Array(schedules.keys)
    }

    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? {
        schedules[activity]
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events _: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        startAttempts.append(StartAttempt(activity: activity, schedule: schedule))
        schedules[activity] = schedule
        let configuredFailures = startFailuresRemaining[activity] ?? 0
        if failNextStartFor == activity || configuredFailures > 0 {
            failNextStartFor = nil
            startFailuresRemaining[activity] = max(0, configuredFailures - 1)
            if removeScheduleOnFailure {
                schedules[activity] = nil
            }
            throw RecordingDeviceActivityCenterError.failedAfterSideEffect
        }
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopAttempts.append(activities)
        for activity in activities {
            schedules[activity] = nil
        }
    }
}
