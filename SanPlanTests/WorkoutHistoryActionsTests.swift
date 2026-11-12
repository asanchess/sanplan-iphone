import XCTest
@testable import SanPlan

/// «Повторить тренировку» из истории: план дня собирается из записи.
final class WorkoutHistoryActionsTests: XCTestCase {
    private func record(weekday: Int? = 2, title: String? = "Вторник") -> WorkoutRecord {
        WorkoutRecord(
            id: "r1", startedAt: 1_700_000_000_000, endedAt: 1_700_003_600_000, weekday: weekday, title: title,
            exercises: [
                WorkoutRecordExercise(exerciseId: "bench", name: "Жим", targetReps: 8, sets: [
                    WorkoutRecordSet(done: true, weightKg: 60, reps: 8),
                    WorkoutRecordSet(done: false, weightKg: nil, reps: nil),
                    WorkoutRecordSet(done: true, weightKg: 62.5, reps: 6),
                ]),
                WorkoutRecordExercise(name: "Подтягивания", bodyweight: true, sets: [
                    WorkoutRecordSet(done: true, weightKg: nil, reps: 9),
                ]),
                WorkoutRecordExercise(name: "Пустое", sets: []),
            ]
        )
    }

    func testDayPlanKeepsExercisesSetsAndRepsAndSkipsEmptyOnes() throws {
        let day = try XCTUnwrap(WorkoutStore.dayPlan(repeating: record(), defaults: .standard, today: 5))
        XCTAssertEqual(day.weekday, 2)
        XCTAssertEqual(day.title, "Вторник")
        XCTAssertEqual(day.exercises.map(\.name), ["Жим", "Подтягивания"])
        XCTAssertEqual(day.exercises[0].sets, 3)
        XCTAssertEqual(day.exercises[0].reps, 8)
        XCTAssertEqual(day.exercises[0].id, "bench")
        XCTAssertNil(day.exercises[0].weightKg)
        XCTAssertEqual(day.exercises[1].reps, 9)
        XCTAssertEqual(day.exercises[1].bodyweight, true)
        XCTAssertNotNil(day.exercises[1].id)
        XCTAssertEqual(day.exercises[0].restSeconds, WorkoutDefaults.standard.restBetweenSets)
    }

    func testManualRecordWithoutWeekdayUsesToday() throws {
        let day = try XCTUnwrap(WorkoutStore.dayPlan(repeating: record(weekday: nil, title: nil), defaults: .standard, today: 5))
        XCTAssertEqual(day.weekday, 5)
        XCTAssertNil(day.title)
    }

    func testRecordWithoutExercisesGivesNoPlan() {
        let empty = WorkoutRecord(id: "e", startedAt: 0, endedAt: 1000, exercises: [])
        XCTAssertNil(WorkoutStore.dayPlan(repeating: empty, defaults: .standard, today: 1))
    }

    @MainActor
    func testRepeatedWorkoutAsksBeforeReplacingTheDayOfThePlan() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("workout-repeat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = WorkoutStore(restAlarm: RestAlarmCoordinator(service: FakeRestAlarmService()), baseDirectory: base, owner: .device)
        let planned = WorkoutDayPlan(weekday: 2, exercises: [WorkoutExercisePlan(name: "Присед", sets: 3, reps: 5, id: "squat")], title: "Ноги")
        store.setTrainingPlan(WorkoutTrainingPlan(days: [planned]))

        // Тренировка прямо из плана: заменять нечего.
        store.startWorkout(day: planned)
        XCTAssertNil(store.planDayToReplace)
        store.discardWorkout()

        // Повтор другой тренировки того же дня недели: сохранение в план заменило бы «Ноги», поэтому нужно подтверждение.
        store.repeatWorkout(from: record())
        XCTAssertEqual(store.planDayToReplace, planned)
    }
}
