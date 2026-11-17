import XCTest
@testable import SanPlan

/// «Прогресс», round 6: explicit periods, arcs that never reset, numbers that open their exact place.
final class ProgressModelTests: XCTestCase {
    private let today = "2026-11-17" // вторник

    func testWeekAndMonthPeriodsAreCalendarStretches() {
        let week = ProgressPeriod.make(.week, today: today)
        XCTAssertEqual(week.from, "2026-11-16")
        XCTAssertEqual(week.to, today)
        XCTAssertEqual(week.previousFrom, "2026-11-09")
        XCTAssertEqual(week.previousTo, "2026-11-10")
        XCTAssertEqual(week.label, "за неделю")
        XCTAssertEqual(week.caption, "за неделю · 16–22 ноября")

        let month = ProgressPeriod.make(.month, today: today)
        XCTAssertEqual(month.from, "2026-11-01")
        XCTAssertEqual(month.previousFrom, "2026-10-01")
        XCTAssertEqual(month.previousTo, "2026-10-17")
        XCTAssertEqual(month.label, "за ноябрь")
        XCTAssertEqual(month.previousIn, "в октябре")
        XCTAssertEqual(month.caption, "за ноябрь · 1–30 ноября")
    }

    func testCountedWeeksNeedThreeWorkoutsOrFiveClosedDays() {
        let workouts = ["2026-11-02", "2026-11-04", "2026-11-06", "2026-11-10", "2026-11-11"]
        let closed = ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-30"]
        // Week of 2 Nov: 3 workouts. Week of 26 Oct: 5 different days. Week of 9 Nov: 2 workouts only.
        XCTAssertEqual(ProgressArcs.countedWeeks(closedTaskDays: closed, workoutDays: workouts), 2)
    }

    func testArcPositionCarriesOverAndNeverResets() {
        let start = ProgressArcs.position(counted: 0)
        XCTAssertEqual(start.arc.id, "nobody")
        XCTAssertEqual(start.next?.id, "shinobi")
        XCTAssertEqual(start.arc.sceneAsset, "arc-nobody")

        let third = ProgressArcs.position(counted: 9)
        XCTAssertEqual(third.arc.id, "shinobi")
        XCTAssertEqual(third.done, 3)
        XCTAssertEqual(third.line, "Неделя 3 из 6. Дальше — Пират.")

        let all = ProgressArcs.position(counted: 40)
        XCTAssertTrue(all.finishedAll)
        XCTAssertEqual(all.arc.id, "hunter")
    }

    func testTrendsLinkToTheirExactPlace() {
        let input = ProgressInputs(
            today: today, plans: [], finance: emptyFinance(), workouts: [], weeklyGoal: 3,
            goals: nil, overdueGoals: [], notes: []
        )
        let snap = ProgressBuilder.make(input, kind: .month)
        XCTAssertEqual(snap.trends.map(\.link), [.moneyOverview(.month), .workoutHistory(.month), .plansAll, .workoutHistory(.month)])
        XCTAssertEqual(snap.notes.headline, "Заметок нет.")
        XCTAssertNil(snap.goals)
    }
}
