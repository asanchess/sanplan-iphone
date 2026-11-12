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
}
