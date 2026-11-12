import XCTest
@testable import SanPlan

final class GoalDomainTests: XCTestCase {
    private let today = "2026-11-12"

    private func goal(_ kind: GoalProgressKind, due: String? = nil) -> Goal {
        Goal(id: "goal-0001", title: "Цель", sphereId: "money", dueDay: due, createdDay: "2026-11-01", kind: kind)
    }

    func testMoneyProgressUsesSavingsGoal() {
        let ctx = GoalContext(savedAmount: { $0 == "sv1" ? 120_000 : nil })
        let p = GoalEngine.progress(goal(.money(target: 300_000, savingsGoalId: "sv1")), today: today, context: ctx)
        XCTAssertEqual(p.fraction ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(p.text, "120\u{00A0}000 из 300\u{00A0}000 ₸")
        XCTAssertFalse(p.achieved)
        let none = GoalEngine.progress(goal(.money(target: 300_000, savingsGoalId: nil)), today: today, context: ctx)
        XCTAssertNil(none.fraction)
    }

    func testTrainingCountWindowEndsAtDueDay() {
        var seen: (String, String)?
        let ctx = GoalContext(trainingCompleted: { from, to in seen = (from, to); return 5 })
        let p = GoalEngine.progress(goal(.trainingCount(target: 5), due: "2026-11-10"), today: today, context: ctx)
        XCTAssertEqual(seen?.0, "2026-11-01")
        XCTAssertEqual(seen?.1, "2026-11-10")
        XCTAssertTrue(p.achieved)
        XCTAssertEqual(p.fraction, 1)
    }

    func testWeightAndMilestones() {
        let ctx = GoalContext(bestWeight: { $0 == "Жим" ? 80 : nil })
        let w = GoalEngine.progress(goal(.trainingWeight(exercise: "Жим", target: 100)), today: today, context: ctx)
        XCTAssertEqual(w.text, "80 из 100 кг")
        XCTAssertNil(GoalEngine.progress(goal(.trainingWeight(exercise: "Присед", target: 100)), today: today, context: ctx).fraction)
        let items = [GoalMilestone(id: "a", title: "Один", done: true), GoalMilestone(id: "b", title: "Два")]
        let m = GoalEngine.progress(goal(.milestones(items)), today: today, context: .empty)
        XCTAssertEqual(m.fraction, 0.5)
        XCTAssertEqual(m.text, "1 из 2 этапов")
    }

    func testHabitGoalCountsPercentAndClampsToCreatedDay() {
        var asked: (String, String)?
        let ctx = GoalContext(habitCompletion: { _, from, to in asked = (from, to); return (done: 6, total: 8) })
        let p = GoalEngine.progress(goal(.habit(habitId: "h1", targetPercent: 80, days: 30)), today: today, context: ctx)
        XCTAssertEqual(asked?.0, "2026-11-01")
        XCTAssertEqual(p.text, "75% из 80%")
        XCTAssertEqual(p.fraction ?? 0, 0.9375, accuracy: 0.0001)
        let empty = GoalContext(habitCompletion: { _, _, _ in (done: 0, total: 0) })
        XCTAssertNil(GoalEngine.progress(goal(.habit(habitId: "h1", targetPercent: 80, days: 30)), today: today, context: empty).fraction)
    }

    func testHabitCompletionOverPeriod() {
        let habit = Habit(id: "h1", title: "Зарядка", createdDay: "2026-11-05")
        let marks = ["2026-11-06": 1, "2026-11-07": 1, "2026-11-01": 1]
        let c = HabitEngine.completion(habit, from: "2026-11-01", to: "2026-11-08", marks: marks, context: .empty)
        XCTAssertEqual(c.total, 4)
        XCTAssertEqual(c.done, 2)
    }

    func testOverdueAndSphereFilter() {
        let late = goal(.milestones([GoalMilestone(title: "Один")]), due: "2026-11-10")
        let progress = GoalEngine.progress(late, today: today, context: .empty)
        XCTAssertTrue(GoalEngine.isOverdue(late, today: today, progress: progress))
        var archived = late; archived.archived = true
        XCTAssertFalse(GoalEngine.isOverdue(archived, today: today, progress: progress))
        XCTAssertEqual(GoalEngine.goals([late, archived], sphereId: "money").count, 1)
        XCTAssertEqual(GoalEngine.goals([late], sphereId: nil).count, 0)
    }

    func testFlatJSONRoundTrip() throws {
        let kinds: [GoalProgressKind] = [
            .money(target: 300_000, savingsGoalId: "sv1"), .trainingCount(target: 12),
            .trainingWeight(exercise: "Жим", target: 90.5), .habit(habitId: "h1", targetPercent: 80, days: 14),
            .milestones([GoalMilestone(id: "a", title: "Один", dueDay: "2026-12-01", done: true)])
        ]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(GoalProgressKind.self, from: data), kind)
        }
        let json = #"{"type":"money","target":300000}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(GoalProgressKind.self, from: json), .money(target: 300_000, savingsGoalId: nil))
    }
}

final class GoalFactsTests: XCTestCase {
    func testSphereFacts() {
        var window: (String, String)?
        let ctx = GoalContext(
            trainingCompleted: { from, to in window = (from, to); return 7 },
            spending: { _, _ in (total: 125_000, topCategory: "Еда", topAmount: 54_000) }
        )
        XCTAssertEqual(GoalEngine.sphereFacts(sphereId: "health", today: "2026-11-12", context: ctx), ["Тренировок за 30 дней: 7"])
        XCTAssertEqual(window?.0, "2026-10-14")
        XCTAssertEqual(GoalEngine.sphereFacts(sphereId: "money", today: "2026-11-12", context: ctx),
                       ["Потрачено за 30 дней: 125\u{00A0}000 ₸", "Больше всего — Еда: 54\u{00A0}000 ₸"])
        XCTAssertTrue(GoalEngine.sphereFacts(sphereId: "money", today: "2026-11-12", context: .empty).isEmpty)
        XCTAssertTrue(GoalEngine.sphereFacts(sphereId: "rest", today: "2026-11-12", context: ctx).isEmpty)
    }
}
