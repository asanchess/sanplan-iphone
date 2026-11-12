import XCTest
@testable import SanPlan

/// Сводки тренировок для Итогов, «+», привычек и целей (docs/contracts/DOMAINS.md §2).
final class WorkoutSummaryTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 5 * 3600)!

    private func ms(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func record(_ id: String, start: Int64, title: String? = nil, _ exercises: [(String, [(Bool, Double?, Int?)])]) -> WorkoutRecord {
        WorkoutRecord(
            id: id, startedAt: start, endedAt: start + 3_600_000, title: title,
            exercises: exercises.map { name, sets in
                WorkoutRecordExercise(name: name, sets: sets.map { WorkoutRecordSet(done: $0.0, weightKg: $0.1, reps: $0.2) })
            }
        )
    }

    private func fixture() -> [WorkoutRecord] {
        [
            record("a", start: ms(2026, 11, 10, 18), title: "Вторник", [("Жим лёжа", [(true, 60, 8), (true, 70, 5), (false, 80, 3)]), ("Пресс", [(true, nil, 20)])]),
            record("b", start: ms(2026, 11, 12, 7), [("жим лежа", [(true, 65, 8)])]),
            record("c", start: ms(2026, 11, 12, 19), [("Тяга", [(true, 40, 10)])]),
            record("empty", start: ms(2026, 11, 11, 10), [("Жим лёжа", [(false, 100, 5)])]),
        ]
    }

    func testDayKeyUsesQyzylordaNotUTC() {
        XCTAssertEqual(WorkoutSummary.dayKey(ms(2026, 11, 12, 23, 30), timeZone: zone), "2026-11-12")
        XCTAssertEqual(WorkoutSummary.dayKey(ms(2026, 11, 13, 1), timeZone: zone), "2026-11-13")
    }

    func testDaySummaryListsOnlyCompletedSessionsOfThatDay() {
        let day = WorkoutSummary.day(fixture(), "2026-11-12", timeZone: zone)
        XCTAssertTrue(day.completed)
        XCTAssertEqual(day.sessions.map(\.id), ["b", "c"])
        XCTAssertEqual(WorkoutSummary.day(fixture(), "2026-11-10", timeZone: zone).sessions.first?.title, "Вторник")
        let empty = WorkoutSummary.day(fixture(), "2026-11-11", timeZone: zone)
        XCTAssertFalse(empty.completed)
        XCTAssertTrue(empty.sessions.isEmpty)
    }

    func testPeriodSummaryIsInclusiveAndGroupsByNormalizedName() {
        let all = WorkoutSummary.period(fixture(), from: "2026-11-10", to: "2026-11-12", timeZone: zone)
        XCTAssertEqual(all.completed, 3)
        let bench = all.byExercise["жим лежа"]
        XCTAssertEqual(bench?.sets, 3)
        XCTAssertEqual(bench?.reps, 21)
        XCTAssertEqual(bench?.tonnageKg ?? 0, Double(60 * 8 + 70 * 5 + 65 * 8), accuracy: 0.001)
        XCTAssertEqual(bench?.bestWeightKg, 70)
        XCTAssertNil(all.byExercise["пресс"]?.bestWeightKg)
        XCTAssertEqual(all.byExercise["пресс"]?.reps, 20)

        let one = WorkoutSummary.period(fixture(), from: "2026-11-12", to: "2026-11-12", timeZone: zone)
        XCTAssertEqual(one.completed, 2)
        XCTAssertNil(one.byExercise["пресс"])
        XCTAssertEqual(WorkoutSummary.period(fixture(), from: "2026-12-01", to: "2026-12-31", timeZone: zone).completed, 0)
    }

    func testBestWeightIgnoresUndoneSetsAndNameCase() {
        XCTAssertEqual(WorkoutSummary.bestWeight(fixture(), exercise: "Жим лёжа"), 70)
        XCTAssertEqual(WorkoutSummary.bestWeight(fixture(), exercise: " ЖИМ ЛЕЖА "), 70)
        XCTAssertNil(WorkoutSummary.bestWeight(fixture(), exercise: "Пресс"))
        XCTAssertNil(WorkoutSummary.bestWeight(fixture(), exercise: "Присед"))
    }

    func testActivityDaysAreSortedUniqueAndInRange() {
        XCTAssertEqual(WorkoutSummary.activityDays(fixture(), from: "2026-11-01", to: "2026-11-30", timeZone: zone), ["2026-11-10", "2026-11-12"])
        XCTAssertEqual(WorkoutSummary.activityDays(fixture(), from: "2026-11-11", to: "2026-11-11", timeZone: zone), [])
    }
}
