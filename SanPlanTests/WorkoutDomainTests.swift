import XCTest
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
