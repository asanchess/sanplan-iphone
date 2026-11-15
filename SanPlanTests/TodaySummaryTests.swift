import XCTest
@testable import SanPlan

/// Зеркало `test/today-summary.test.mjs`: те же случаи, те же числа.
final class TodaySummaryTests: XCTestCase {
    private let day = "2026-11-16" // понедельник

    private func habit(_ id: String, schedule: HabitSchedule = .everyDay, target: HabitTarget = .once,
                       rule: HabitRule? = nil, createdDay: String = "2026-11-01", archived: Bool = false) -> Habit {
        Habit(id: id, title: id, schedule: schedule, target: target, rule: rule, createdDay: createdDay, archived: archived)
    }

    func testBlockOrderIsFixed() {
        XCTAssertEqual(TodaySummary.order, ["review", "plans", "habits", "goals", "notes", "money", "workout"])
    }

    func testHabitsOnlyWhatIsDueUnfinishedFirstArchivedAndLaterSkipped() throws {
        let habits = [
            habit("a"), habit("b"), habit("c", schedule: .onWeekdays([3])),
            habit("d", archived: true), habit("e", createdDay: "2026-12-01")
        ]
        let block = try XCTUnwrap(TodayHabitsSummary.make(habits: habits, marks: ["a": [day: 1]], day: day, context: .empty))
        XCTAssertEqual(block.rows.map(\.id), ["b", "a"])
        XCTAssertEqual([block.done, block.total, block.more], [1, 2, 0])
        XCTAssertTrue(block.rows[1].done)
    }

    func testCountedHabitShowsProgressAndRuleHabitIsAuto() throws {
        let habits = [
            habit("w", target: HabitTarget(amount: 8, unit: "стак.")),
            habit("t", rule: HabitRule(kind: .training))
        ]
        let context = HabitContext(trainingDay: { _ in HabitTrainingDay(completed: true) })
        let rows = try XCTUnwrap(TodayHabitsSummary.make(habits: habits, marks: ["w": [day: 3]], day: day, context: context)).rows
        let w = try XCTUnwrap(rows.first { $0.id == "w" })
        let t = try XCTUnwrap(rows.first { $0.id == "t" })
        XCTAssertEqual(w.detail, "3 из 8 стак.")
        XCTAssertFalse(w.done)
        XCTAssertTrue(t.auto)
        XCTAssertTrue(t.done)
    }

    func testHabitsLimitFourAndNilWhenNothingDue() throws {
        let many = ["a", "b", "c", "d", "e", "f"].map { habit($0) }
        let block = try XCTUnwrap(TodayHabitsSummary.make(habits: many, marks: [:], day: day, context: .empty))
        XCTAssertEqual(block.rows.count, TodaySummary.habitsLimit)
        XCTAssertEqual(block.more, 2)
        XCTAssertEqual(TodaySummary.moreText(block.more), "ещё 2")
        XCTAssertEqual(TodaySummary.moreText(0), "")
        XCTAssertNil(TodayHabitsSummary.make(habits: [habit("x", schedule: .onWeekdays([3]))], marks: [:], day: day, context: .empty))
        XCTAssertNil(TodayHabitsSummary.make(habits: [], marks: [:], day: day, context: .empty))
    }

    func testTimesPerWeekHabitIsDueUntilTheNormIsMet() throws {
        let block = try XCTUnwrap(TodayHabitsSummary.make(habits: [habit("w", schedule: .timesPerWeek(1))], marks: [:], day: day, context: .empty))
        XCTAssertEqual(block.rows.count, 1)
    }

    private func goal(_ id: String, archived: Bool = false) -> Goal {
        Goal(id: id, title: id, createdDay: "2026-11-01", kind: .trainingCount(target: 5), archived: archived)
    }

    func testGoalsUpToThreeWeekGoalFirstAchievedAndArchivedLeftOut() throws {
        let goals = [goal("g1"), goal("g2"), goal("g3"), goal("g4"), goal("gx"), goal("ga", archived: true)]
        let progress: (Goal) -> GoalProgress = { g in
            if g.id == "gx" { return GoalProgress(fraction: 1, text: "Готово", achieved: true) }
            return GoalProgress(fraction: g.id == "g3" ? 0.5 : nil, text: "текст \(g.id)", achieved: false)
        }
        let block = try XCTUnwrap(GoalsSummary.make(goals: goals, weekGoalId: "g3", progressOf: progress))
        XCTAssertEqual(block.rows.map(\.id), ["g3", "g1", "g2"])
        XCTAssertTrue(block.rows[0].isWeek)
        XCTAssertEqual(block.rows[0].fraction, 0.5)
        XCTAssertNil(block.rows[1].fraction)
        XCTAssertEqual(block.more, 1)
        XCTAssertNil(GoalsSummary.make(goals: [], weekGoalId: nil, progressOf: progress))
        XCTAssertNil(GoalsSummary.make(goals: [goal("gx")], weekGoalId: nil, progressOf: progress))
    }

    func testGoalFractionsAreClamped() throws {
        let block = try XCTUnwrap(GoalsSummary.make(goals: [goal("a"), goal("b")], weekGoalId: nil) { g in
            GoalProgress(fraction: g.id == "a" ? 7 : -1, text: "", achieved: false)
        })
        XCTAssertEqual(block.rows.map(\.fraction), [1, 0])
    }

    func testPinnedNotesPinnedOnlyNewestFirstThreeAtMost() throws {
        func note(_ id: String, _ text: String, pinned: Bool = true, at: Int64, deleted: Bool = false) -> Note {
            Note(id: id, text: text, pinned: pinned, createdAt: at, deleted: deleted)
        }
        let notes = [
            note("1", "Старая\nстрока", at: 10),
            note("2", "Обычная", pinned: false, at: 99),
            note("3", "- [ ] Список дел\nещё", at: 30),
            note("4", "Удалённая", at: 40, deleted: true),
            note("5", "Свежая", at: 50),
            note("6", "Четвёртая", at: 20),
            note("7", "   ", at: 60)
        ]
        let block = try XCTUnwrap(PinnedNotesSummary.make(notes: notes))
        XCTAssertEqual(block.rows.map(\.id), ["5", "3", "6"])
        XCTAssertEqual(block.rows[1].title, "Список дел")
        XCTAssertEqual(block.more, 1)
        XCTAssertNil(PinnedNotesSummary.make(notes: [note("a", "x", pinned: false, at: 1)]))
        XCTAssertNil(PinnedNotesSummary.make(notes: []))
    }

    func testWorkoutActiveThenTodayThenNextOverTheWeek() {
        let days = [WorkoutDayPlan(weekday: 3, exercises: [], title: "Ноги"), WorkoutDayPlan(weekday: 6, exercises: [])]
        XCTAssertEqual(TodayWorkoutSummary.make(active: true, currentName: "Присед", days: days, weekday: 1),
                       WorkoutSummaryLine(kind: .active, title: "Присед", when: "Идёт сейчас"))
        XCTAssertEqual(TodayWorkoutSummary.make(active: false, currentName: "", days: days, weekday: 3),
                       WorkoutSummaryLine(kind: .today, title: "Ноги", when: "Сегодня"))
        XCTAssertEqual(TodayWorkoutSummary.make(active: false, currentName: "", days: days, weekday: 2),
                       WorkoutSummaryLine(kind: .next, title: "Ноги", when: "Завтра"))
        XCTAssertEqual(TodayWorkoutSummary.make(active: false, currentName: "", days: days, weekday: 4),
                       WorkoutSummaryLine(kind: .next, title: "Тренировка", when: "Сб"))
        XCTAssertEqual(TodayWorkoutSummary.make(active: false, currentName: "", days: days, weekday: 7),
                       WorkoutSummaryLine(kind: .next, title: "Ноги", when: "Ср"))
        XCTAssertNil(TodayWorkoutSummary.make(active: false, currentName: "", days: [], weekday: 1))
    }
}

@MainActor
final class TodaySummaryTapTests: XCTestCase {
    /// Отметка из сводки идёт через `HabitStore.tap` — тот же путь, что в разделе «Привычки».
    func testTapThroughTheStoreMarksAndUnmarksTheSummaryRow() throws {
        let name = "today-summary-\(UUID().uuidString)"
        let store = HabitStore(defaults: UserDefaults(suiteName: name)!, owner: .device)
        let day = "2026-11-16"
        let h = Habit(id: "hw", title: "Вода", createdDay: "2026-11-01")
        store.add(h)
        XCTAssertFalse(try XCTUnwrap(TodayHabitsSummary.make(habits: store.habits, marks: store.marks, day: day, context: .empty)).rows[0].done)
        XCTAssertEqual(store.tap(h, on: day), 1)
        XCTAssertTrue(try XCTUnwrap(TodayHabitsSummary.make(habits: store.habits, marks: store.marks, day: day, context: .empty)).rows[0].done)
        XCTAssertEqual(store.tap(h, on: day), 0)
        XCTAssertFalse(try XCTUnwrap(TodayHabitsSummary.make(habits: store.habits, marks: store.marks, day: day, context: .empty)).rows[0].done)
    }
}
