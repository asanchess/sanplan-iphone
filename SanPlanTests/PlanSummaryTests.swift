import XCTest
@testable import SanPlan

final class PlanSummaryTests: XCTestCase {
    private func task(_ id: String, _ title: String, date: String, time: String? = nil, done: Bool = false) -> PlanItem {
        PlanItem(id: id, kind: "task", title: title, date: date, time: time, completed: done)
    }

    func testDayCountsOnlyTasksOfThatDay() {
        let plans = [
            task("a", "Купить хлеб", date: "2026-11-12", time: "18:00"),
            task("b", "Позвонить", date: "2026-11-12", time: "09:00", done: true),
            task("c", "Другой день", date: "2026-11-13"),
            PlanItem(id: "e", kind: "event", title: "Встреча", date: "2026-11-12", time: "10:00"),
            PlanItem(id: "al", kind: "task", title: "Будильник", date: "2026-11-12", alarmOnly: true)
        ]
        let s = PlanSummary.day(plans: plans, day: "2026-11-12")
        XCTAssertEqual(s.total, 2)
        XCTAssertEqual(s.done, 1)
        XCTAssertEqual(s.open, [PlanOpenItem(id: "a", title: "Купить хлеб")])
    }

    func testOpenSortedByTimeThenTitle() {
        let plans = [
            task("a", "Б", date: "2026-11-12"),
            task("b", "Я", date: "2026-11-12", time: "08:00"),
            task("c", "А", date: "2026-11-12")
        ]
        let s = PlanSummary.day(plans: plans, day: "2026-11-12")
        XCTAssertEqual(s.open.map(\.id), ["b", "c", "a"])
    }

    func testMovedToNextDaySkipsDoneEventsAndUnknown() {
        let plans = [
            task("a", "Открытая", date: "2026-11-30"),
            task("b", "Закрытая", date: "2026-11-30", done: true),
            PlanItem(id: "e", kind: "event", title: "Событие", date: "2026-11-30", time: "10:00")
        ]
        let moved = PlanSummary.movedToNextDay(plans: plans, ids: ["a", "b", "e", "zzz"])
        XCTAssertEqual(moved.map(\.id), ["a"])
        XCTAssertEqual(moved.first?.date, "2026-12-01")
        XCTAssertEqual(plans[0].date, "2026-11-30")
    }

    func testActivityDaysUsesDoneTasksAndSavedDay() {
        var created = task("n", "Новая", date: "2026-11-20")
        created.savedAt = "2026-11-10T19:30:00.000Z" // 00:30 следующего дня в Asia/Qyzylorda (UTC+5)
        let plans = [
            task("a", "Сделана", date: "2026-11-09", done: true),
            task("b", "Открыта", date: "2026-11-08"),
            created
        ]
        let days = PlanSummary.activityDays(plans: plans, from: "2026-11-01", to: "2026-11-30", timeZone: "Asia/Qyzylorda")
        XCTAssertEqual(days, ["2026-11-09", "2026-11-11"])
        XCTAssertEqual(PlanSummary.activityDays(plans: plans, from: "2026-11-10", to: "2026-11-10"), [])
    }
}
