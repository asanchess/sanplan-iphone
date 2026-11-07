import XCTest
import Combine
import AlarmKit
@testable import SanPlan

final class FakeRestAlarmService: RestAlarmProtocol, @unchecked Sendable {
    var authorizationState: AlarmManager.AuthorizationState = .authorized
    var scheduledDates: [Date] = []
    var scheduledNames: [String] = []
    var cancelCallCount: Int = 0

    func requestAuthorization() async throws {
        authorizationState = .authorized
    }

    func schedule(at date: Date, exerciseName: String) async throws {
        scheduledDates.append(date)
        scheduledNames.append(exerciseName)
    }

    func cancel() async throws {
        cancelCallCount += 1
    }
}

final class WorkoutDomainTests: XCTestCase {

    private func twoExerciseWorkout(now: Int64) throws -> WorkoutSessionState {
        try WorkoutDomain.createWorkout(exercises: [
            SessionExercise(name: "Жим", rests: [60, 60]),
            SessionExercise(name: "Тяга", rests: [90])
        ], now: now)
    }

    func testStartRestDuringWarmUpRestsAfterTheFirstSet() throws {
        let state = try twoExerciseWorkout(now: 1_000_000)
        let resting = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_010_000)
        XCTAssertEqual(resting.phase, .resting)
        XCTAssertEqual(resting.setIndex, 0)
        XCTAssertEqual(resting.deadline, 1_070_000)
        XCTAssertNil(resting.workStartedAt)
    }

    func testStartRestAfterRestRanOutMovesToNextSetAndRests() throws {
        var state = try twoExerciseWorkout(now: 1_000_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .startNow(), now: 1_001_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_040_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: 1_100_000)
        XCTAssertEqual(state.phase, .alerting)
        XCTAssertEqual(state.workStartedAt, 1_100_000)

        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_130_000)
        XCTAssertEqual(state.phase, .resting)
        XCTAssertEqual(state.setIndex, 1)
        XCTAssertEqual(state.deadline, 1_190_000)

        // Last set of the last exercise: ending it from the alert finishes the workout.
        state = try WorkoutDomain.workoutCommand(state: state, command: .skipRest(), now: 1_140_000)
        XCTAssertEqual(state.exerciseIndex, 1)
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_160_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: 1_250_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_260_000)
        XCTAssertEqual(state.phase, .complete)
    }

    func testStartRestIsRejectedDuringARest() throws {
        var state = try twoExerciseWorkout(now: 1_000_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_001_000)
        XCTAssertThrowsError(try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_002_000))
        state = try WorkoutDomain.workoutCommand(state: state, command: .pause(), now: 1_003_000)
        XCTAssertThrowsError(try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_004_000))
    }

    func testSetStopwatchCountsFromSetStartAndSurvivesSaving() throws {
        var state = try twoExerciseWorkout(now: 1_000_000)
        XCTAssertNil(WorkoutDomain.elapsedWorkSeconds(state: state, now: 1_005_000))
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: 1_031_000)
        XCTAssertEqual(state.workStartedAt, 1_030_000)
        XCTAssertEqual(WorkoutDomain.elapsedWorkSeconds(state: state, now: 1_075_500), 45)

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(WorkoutSessionState.self, from: data)
        try WorkoutDomain.validateState(restored)
        XCTAssertEqual(WorkoutDomain.elapsedWorkSeconds(state: restored, now: 1_090_000), 60)

        let skipped = try WorkoutDomain.workoutCommand(state: try twoExerciseWorkout(now: 2_000_000), command: .startNow(), now: 2_004_000)
        XCTAssertEqual(skipped.phase, .working)
        XCTAssertEqual(skipped.workStartedAt, 2_004_000)
    }

    private func withoutSetStart(_ state: WorkoutSessionState) throws -> WorkoutSessionState {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json.removeValue(forKey: "workStartedAt")
        return try JSONDecoder().decode(WorkoutSessionState.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Working and alerting sessions saved by 2.0 have no set start; they must load and keep working.
    func testSessionSavedBefore21StillLoads() throws {
        var working = try twoExerciseWorkout(now: 1_000_000)
        working = try WorkoutDomain.workoutCommand(state: working, command: .startNow(), now: 1_001_000)
        let legacyWorking = try withoutSetStart(working)
        XCTAssertNil(legacyWorking.workStartedAt)
        try WorkoutDomain.validateState(legacyWorking)
        XCTAssertNil(WorkoutDomain.elapsedWorkSeconds(state: legacyWorking, now: 1_010_000))
        let rested = try WorkoutDomain.workoutCommand(state: legacyWorking, command: .startRest(), now: 1_020_000)
        XCTAssertEqual(rested.phase, .resting)

        let alerting = try WorkoutDomain.workoutCommand(state: rested, command: .tick(), now: 1_090_000)
        let legacyAlerting = try withoutSetStart(alerting)
        try WorkoutDomain.validateState(legacyAlerting)
        let next = try WorkoutDomain.workoutCommand(state: legacyAlerting, command: .acknowledge(), now: 1_095_000)
        XCTAssertEqual(next.phase, .working)
        XCTAssertEqual(next.workStartedAt, 1_095_000)
    }

    func testTapFromAnEarlierFrameStillCounts() throws {
        var state = try twoExerciseWorkout(now: 1_000_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_001_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: 1_200_000)
        XCTAssertEqual(state.phase, .alerting)

        let frameTime: Int64 = 1_199_600
        XCTAssertThrowsError(try WorkoutDomain.workoutCommand(state: state, command: .acknowledge(), now: frameTime))
        let at = WorkoutDomain.userCommandTime(frameTime, state: state)
        XCTAssertEqual(at, 1_200_000)
        XCTAssertNoThrow(try WorkoutDomain.workoutCommand(state: state, command: .acknowledge(), now: at))
        XCTAssertNoThrow(try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: at))
        XCTAssertNoThrow(try WorkoutDomain.workoutCommand(state: state, command: .setSets(3), now: at))
        // A real clock jump back is left for recoverClock, not hidden.
        XCTAssertEqual(WorkoutDomain.userCommandTime(1_100_000, state: state), 1_100_000)
    }

    func testClockRecoveryShiftsSetStartAndNeverGoesNegative() throws {
        var state = try twoExerciseWorkout(now: 1_000_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .startNow(), now: 1_001_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .setSets(3), now: 1_031_000)

        let shifted = try WorkoutDomain.workoutCommand(state: state, command: .recoverClock(), now: 600_000)
        XCTAssertEqual(shifted.workStartedAt, 570_000)
        XCTAssertEqual(WorkoutDomain.elapsedWorkSeconds(state: shifted, now: 600_000), 30)

        let nearEpoch = try WorkoutDomain.workoutCommand(state: state, command: .recoverClock(), now: 1_000)
        XCTAssertEqual(nearEpoch.workStartedAt, 0)
        XCTAssertNoThrow(try WorkoutDomain.validateState(nearEpoch))
    }

    func testAcknowledgeKeepsTheAlertStartTime() throws {
        var state = try twoExerciseWorkout(now: 1_000_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_001_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: 1_070_000)
        XCTAssertEqual(state.workStartedAt, 1_061_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .acknowledge(), now: 1_080_000)
        XCTAssertEqual(state.phase, .working)
        XCTAssertEqual(state.setIndex, 1)
        XCTAssertEqual(state.workStartedAt, 1_061_000)
    }

    func testAdjustingARestToZeroStartsTheSetStopwatch() throws {
        var state = try twoExerciseWorkout(now: 1_000_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_001_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .adjust(seconds: -120), now: 1_005_000)
        XCTAssertEqual(state.phase, .alerting)
        XCTAssertEqual(state.workStartedAt, 1_005_000)
    }

    func testSavedSetStartOutsideASetIsRejected() throws {
        var resting = try twoExerciseWorkout(now: 1_000_000)
        resting = try WorkoutDomain.workoutCommand(state: resting, command: .startRest(), now: 1_001_000)
        var paused = try WorkoutDomain.workoutCommand(state: resting, command: .pause(), now: 1_002_000)
        resting.workStartedAt = 1_000_500
        paused.workStartedAt = 1_000_500
        XCTAssertThrowsError(try WorkoutDomain.validateState(resting))
        XCTAssertThrowsError(try WorkoutDomain.validateState(paused))

        var complete = try WorkoutDomain.createWorkout(exercises: [SessionExercise(name: "Жим", rests: [60])], now: 1_000_000)
        complete = try WorkoutDomain.workoutCommand(state: complete, command: .startRest(), now: 1_001_000)
        complete = try WorkoutDomain.workoutCommand(state: complete, command: .tick(), now: 1_100_000)
        complete = try WorkoutDomain.workoutCommand(state: complete, command: .startRest(), now: 1_101_000)
        XCTAssertEqual(complete.phase, .complete)
        XCTAssertNil(complete.workStartedAt)
        XCTAssertThrowsError(try WorkoutDomain.workoutCommand(state: complete, command: .setSets(2), now: 1_102_000))
        complete.workStartedAt = 1_000_500
        XCTAssertThrowsError(try WorkoutDomain.validateState(complete))
    }

    func testLastSetIsKnownSoTheScreenOffersToFinish() throws {
        var state = try twoExerciseWorkout(now: 1_000_000)
        XCTAssertFalse(WorkoutDomain.isLastSet(state))
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_001_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .skipRest(), now: 1_002_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_003_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .skipRest(), now: 1_004_000)
        XCTAssertEqual(state.exerciseIndex, 1)
        XCTAssertTrue(WorkoutDomain.isLastSet(state))
        state = try WorkoutDomain.workoutCommand(state: state, command: .finish(), now: 1_005_000)
        XCTAssertEqual(state.phase, .complete)
        XCTAssertNil(state.workStartedAt)
    }

    func testSetsStepperWorksDuringARestAndRejectsAReusedId() throws {
        var state = try twoExerciseWorkout(now: 1_000_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_001_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .setSets(3, id: "s1"), now: 1_002_000)
        XCTAssertEqual(state.phase, .resting)
        XCTAssertEqual(state.exercises[0].rests, [60, 60, 60])
        let repeated = try WorkoutDomain.workoutCommand(state: state, command: .setSets(3, id: "s1"), now: 1_003_000)
        XCTAssertEqual(repeated.exercises[0].rests.count, 3)
        XCTAssertThrowsError(try WorkoutDomain.workoutCommand(state: state, command: .setSets(4, id: "s1"), now: 1_003_000))
    }

    @MainActor
    func testAlarmWarningRedrawsTheWorkoutScreen() async throws {
        let fake = FakeRestAlarmService()
        fake.authorizationState = .denied
        let coordinator = RestAlarmCoordinator(service: fake)
        let store = WorkoutStore(restAlarm: coordinator)
        var redraws = 0
        let observation = store.objectWillChange.sink { _ in redraws += 1 }
        defer { observation.cancel() }

        await coordinator.schedule(at: Date().addingTimeInterval(60), exerciseName: "Жим")
        XCTAssertNotNil(coordinator.warningMessage)
        for _ in 0..<20 where redraws == 0 { await Task.yield() }
        XCTAssertGreaterThan(redraws, 0)
    }

    func testSetsStepperNeverDropsTheSetInProgress() throws {
        var state = try twoExerciseWorkout(now: 1_000_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .setSets(4), now: 1_001_000)
        XCTAssertEqual(state.exercises[0].rests, [60, 60, 60, 60])

        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_002_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .skipRest(), now: 1_003_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: 1_004_000)
        state = try WorkoutDomain.workoutCommand(state: state, command: .skipRest(), now: 1_005_000)
        XCTAssertEqual(state.setIndex, 2)

        XCTAssertThrowsError(try WorkoutDomain.workoutCommand(state: state, command: .setSets(2), now: 1_006_000))
        state = try WorkoutDomain.workoutCommand(state: state, command: .setSets(3), now: 1_006_000)
        XCTAssertEqual(state.exercises[0].rests.count, 3)
        XCTAssertEqual(state.exercises[1].rests, [90])
        XCTAssertThrowsError(try WorkoutDomain.workoutCommand(state: state, command: .setSets(101), now: 1_007_000))
    }

    func testCreateWorkoutAndFullProgressionFlow() throws {
        let exercises = [
            SessionExercise(name: "Приседания", rests: [60, 60]),
            SessionExercise(name: "Отжимания", rests: [90])
        ]

        var now: Int64 = 1_000_000
        var state = try WorkoutDomain.createWorkout(exercises: exercises, now: now)

        XCTAssertEqual(state.phase, .preparing)
        XCTAssertEqual(state.exerciseIndex, 0)
        XCTAssertEqual(state.setIndex, 0)
        XCTAssertEqual(state.deadline, 1_030_000)

        // Tick before deadline keeps preparing
        now = 1_015_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: now)
        XCTAssertEqual(state.phase, .preparing)

        // Tick at deadline transitions to working
        now = 1_030_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: now)
        XCTAssertEqual(state.phase, .working)
        XCTAssertNil(state.deadline)

        // Start rest for set 0 (60s)
        now = 1_040_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: now)
        XCTAssertEqual(state.phase, .resting)
        XCTAssertEqual(state.deadline, 1_100_000)

        // Resting ticks to alerting
        now = 1_100_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: now)
        XCTAssertEqual(state.phase, .alerting)

        // Acknowledge moves to next set in same exercise
        now = 1_105_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .acknowledge(), now: now)
        XCTAssertEqual(state.phase, .working)
        XCTAssertEqual(state.exerciseIndex, 0)
        XCTAssertEqual(state.setIndex, 1)

        // Set 1 finishes, start rest
        now = 1_120_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: now)
        XCTAssertEqual(state.phase, .resting)

        // Rest completes to alerting
        now = 1_180_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: now)
        XCTAssertEqual(state.phase, .alerting)

        // Acknowledge moves to next exercise (Отжимания)
        now = 1_185_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .acknowledge(), now: now)
        XCTAssertEqual(state.phase, .working)
        XCTAssertEqual(state.exerciseIndex, 1)
        XCTAssertEqual(state.setIndex, 0)

        // Last set rest and ack leads to complete
        now = 1_200_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: now)
        now = 1_290_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: now)
        XCTAssertEqual(state.phase, .alerting)

        now = 1_295_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .acknowledge(), now: now)
        XCTAssertEqual(state.phase, .complete)
    }

    func testPauseAndResumePreservesRemainingTime() throws {
        let exercises = [SessionExercise(name: "Тяга", rests: [120])]
        var now: Int64 = 2_000_000
        var state = try WorkoutDomain.createWorkout(exercises: exercises, now: now)

        now = 2_030_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: now)
        XCTAssertEqual(state.phase, .working)

        now = 2_050_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: now)
        XCTAssertEqual(state.phase, .resting)
        XCTAssertEqual(state.deadline, 2_170_000) // 120s = 120_000ms

        // 40 seconds elapse, 80 seconds remain
        now = 2_090_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .pause(), now: now)
        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(state.pausedRemainingMs, 80_000)
        XCTAssertNil(state.deadline)

        let remaining = try WorkoutDomain.remainingSeconds(state: state, now: now)
        XCTAssertEqual(remaining, 80)

        // Resume 10 seconds later, new deadline is now + 80_000
        now = 2_100_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .resume(), now: now)
        XCTAssertEqual(state.phase, .resting)
        XCTAssertEqual(state.deadline, 2_180_000)
        XCTAssertNil(state.pausedRemainingMs)
    }

    func testAdjustSecondsPlus30And60() throws {
        let exercises = [SessionExercise(name: "Планка", rests: [60])]
        var now: Int64 = 3_000_000
        var state = try WorkoutDomain.createWorkout(exercises: exercises, now: now)

        now = 3_030_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: now)

        now = 3_040_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: now)
        XCTAssertEqual(state.deadline, 3_100_000)

        now = 3_050_000
        // +30 seconds
        state = try WorkoutDomain.workoutCommand(state: state, command: .adjust(seconds: 30), now: now)
        XCTAssertEqual(state.deadline, 3_130_000)

        // +60 seconds
        state = try WorkoutDomain.workoutCommand(state: state, command: .adjust(seconds: 60), now: now)
        XCTAssertEqual(state.deadline, 3_190_000)

        let sec = try WorkoutDomain.remainingSeconds(state: state, now: now)
        XCTAssertEqual(sec, 140)
    }

    func testSkipRestMovesForward() throws {
        let exercises = [
            SessionExercise(name: "Упр 1", rests: [60, 60]),
            SessionExercise(name: "Упр 2", rests: [60])
        ]
        var now: Int64 = 4_000_000
        var state = try WorkoutDomain.createWorkout(exercises: exercises, now: now)
        now = 4_030_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: now)

        // In working -> start rest
        now = 4_040_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: now)
        XCTAssertEqual(state.phase, .resting)

        // Skip rest skips set 0 rest to set 1 working
        now = 4_050_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .skipRest(), now: now)
        XCTAssertEqual(state.phase, .working)
        XCTAssertEqual(state.exerciseIndex, 0)
        XCTAssertEqual(state.setIndex, 1)

        // Start set 1 rest, then skip rest -> moves to Упр 2 set 0
        now = 4_060_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: now)
        state = try WorkoutDomain.workoutCommand(state: state, command: .skipRest(), now: now)
        XCTAssertEqual(state.phase, .working)
        XCTAssertEqual(state.exerciseIndex, 1)
        XCTAssertEqual(state.setIndex, 0)

        // Start Упр 2 rest, skip -> complete
        now = 4_070_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: now)
        state = try WorkoutDomain.workoutCommand(state: state, command: .skipRest(), now: now)
        XCTAssertEqual(state.phase, .complete)
    }

    func testRepeatRestKeepsSameExerciseAndSet() throws {
        let exercises = [SessionExercise(name: "Брусья", rests: [45])]
        var now: Int64 = 5_000_000
        var state = try WorkoutDomain.createWorkout(exercises: exercises, now: now)
        now = 5_030_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: now)

        now = 5_040_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: now)
        now = 5_085_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .tick(), now: now)
        XCTAssertEqual(state.phase, .alerting)

        // Repeat rest restarts rest of 45s for the same set
        now = 5_090_000
        state = try WorkoutDomain.workoutCommand(state: state, command: .repeatRest(), now: now)
        XCTAssertEqual(state.phase, .resting)
        XCTAssertEqual(state.exerciseIndex, 0)
        XCTAssertEqual(state.setIndex, 0)
        XCTAssertEqual(state.deadline, 5_135_000)
    }

    func testRelaunchMidRestFromEncodedState() throws {
        let exercises = [SessionExercise(name: "Жим", rests: [100])]
        let initial = try WorkoutDomain.createWorkout(exercises: exercises, now: 10_000_000)
        let working = try WorkoutDomain.workoutCommand(state: initial, command: .tick(), now: 10_030_000)
        let resting = try WorkoutDomain.workoutCommand(state: working, command: .startRest(), now: 10_050_000)

        let data = try JSONEncoder().encode(resting)
        let restored = try JSONDecoder().decode(WorkoutSessionState.self, from: data)

        XCTAssertEqual(restored.phase, .resting)
        XCTAssertEqual(restored.deadline, 10_150_000)

        // Derive remaining time 30s into rest
        let rem = try WorkoutDomain.remainingSeconds(state: restored, now: 10_080_000)
        XCTAssertEqual(rem, 70)
    }

    func testDeadlinePassingWhileAppIsClosed() throws {
        let exercises = [SessionExercise(name: "Махи", rests: [60])]
        let initial = try WorkoutDomain.createWorkout(exercises: exercises, now: 20_000_000)
        let working = try WorkoutDomain.workoutCommand(state: initial, command: .tick(), now: 20_030_000)
        let resting = try WorkoutDomain.workoutCommand(state: working, command: .startRest(), now: 20_040_000)
        XCTAssertEqual(resting.deadline, 20_100_000)

        // App wakes up after deadline
        let wakeupTime: Int64 = 20_120_000
        let updated = try WorkoutDomain.workoutCommand(state: resting, command: .tick(), now: wakeupTime)
        XCTAssertEqual(updated.phase, .alerting)
    }

    func testIdempotentCommandHistoryMatchingPayload() throws {
        let exercises = [SessionExercise(name: "Приседания", rests: [60])]
        let initial = try WorkoutDomain.createWorkout(exercises: exercises, now: 30_000_000)

        let cmd = WorkoutCommand(type: "tick", id: "cmd_1")
        let first = try WorkoutDomain.workoutCommand(state: initial, command: cmd, now: 30_030_000)
        XCTAssertEqual(first.phase, .working)
        XCTAssertEqual(first.commandHistory.count, 1)

        // Same command id and same payload is ignored
        let second = try WorkoutDomain.workoutCommand(state: first, command: cmd, now: 30_035_000)
        XCTAssertEqual(second.revision, first.revision)

        // Same command id with conflicting payload throws error
        let conflicting = WorkoutCommand(type: "adjust", id: "cmd_1", seconds: 30)
        XCTAssertThrowsError(try WorkoutDomain.workoutCommand(state: first, command: conflicting, now: 30_035_000))
    }

    func testParseWorkoutTextScenarios() throws {
        let sample = """
        везде по 3 подхода
        вт
        Приседания, 15 раз
        Выпады, 10 раз на каждую ногу.
        чт
        Отжимания, 20 раз
        """

        let plan = try WorkoutDomain.parseWorkoutText(sample)
        XCTAssertEqual(plan.days.count, 2)
        XCTAssertEqual(plan.days[0].weekday, 2)
        XCTAssertEqual(plan.days[0].exercises.count, 2)
        XCTAssertEqual(plan.days[0].exercises[0].name, "Приседания")
        XCTAssertEqual(plan.days[0].exercises[0].reps, 15)
        XCTAssertEqual(plan.days[0].exercises[0].sets, 3)
        XCTAssertFalse(plan.days[0].exercises[0].perSide)

        XCTAssertEqual(plan.days[0].exercises[1].name, "Выпады")
        XCTAssertEqual(plan.days[0].exercises[1].reps, 10)
        XCTAssertTrue(plan.days[0].exercises[1].perSide)

        XCTAssertEqual(plan.days[1].weekday, 4)
        XCTAssertEqual(plan.days[1].exercises[0].name, "Отжимания")
        XCTAssertEqual(plan.days[1].exercises[0].reps, 20)

        // Duplicate day throws
        let duplicateDay = "пн\nБег, 10 раз\nпн\nПрыжки, 10 раз"
        XCTAssertThrowsError(try WorkoutDomain.parseWorkoutText(duplicateDay))

        // Time based exercise throws informative error
        let timed = "пн\nПланка, 60 секунд"
        XCTAssertThrowsError(try WorkoutDomain.parseWorkoutText(timed))
    }

    func testRestAlarmCoordinatorTransitions() async {
        let fake = FakeRestAlarmService()
        let coordinator = await RestAlarmCoordinator(service: fake)

        let targetDate = Date().addingTimeInterval(120)
        await coordinator.schedule(at: targetDate, exerciseName: "Приседания · 12")

        let scheduledCount = fake.scheduledDates.count
        XCTAssertEqual(scheduledCount, 1)
        XCTAssertEqual(fake.scheduledNames.first, "Приседания · 12")

        // Scheduling clears the previous alarm first, because the id is fixed.
        let cancelsBefore = fake.cancelCallCount
        await coordinator.cancel()
        XCTAssertEqual(fake.cancelCallCount, cancelsBefore + 1)
    }
}
