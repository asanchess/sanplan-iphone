import XCTest
@testable import SanPlan

final class StreakEngineTests: XCTestCase {
    private func range(_ from: String, _ to: String, except: Set<String> = []) -> Set<String> {
        Set(HabitCalendar.days(from: from, to: to)).subtracting(except)
    }

    func testEmptyHistory() {
        XCTAssertEqual(StreakEngine.current(today: "2026-11-12", activeDays: []), StreakState(days: 0, restDaysLeft: 4))
    }

    func testConsecutiveDays() {
        let s = StreakEngine.current(today: "2026-11-12", activeDays: range("2026-11-01", "2026-11-12"))
        XCTAssertEqual(s, StreakState(days: 12, restDaysLeft: 4))
    }

    func testTodayWithoutActionDoesNotBreak() {
        let s = StreakEngine.current(today: "2026-11-12", activeDays: range("2026-11-09", "2026-11-11"))
        XCTAssertEqual(s.days, 3)
        XCTAssertEqual(s.restDaysLeft, 4)
    }

    func testRestDayKeepsStreakAndIsSpent() {
        let s = StreakEngine.current(today: "2026-11-12", activeDays: range("2026-11-01", "2026-11-12", except: ["2026-11-05"]))
        XCTAssertEqual(s, StreakState(days: 11, restDaysLeft: 3))
    }

    func testStreakBreaksWhenMonthlyRestRunsOut() {
        // 1 ноября — действие, 2–6 ноября — пять пропусков при четырёх днях отдыха, 7–12 — снова действия.
        var active = range("2026-11-07", "2026-11-12")
        active.insert("2026-11-01")
        let s = StreakEngine.current(today: "2026-11-12", activeDays: active)
        XCTAssertEqual(s, StreakState(days: 6, restDaysLeft: 0))
    }

    func testRestBudgetIsPerMonth() {
        // Четыре пропуска в октябре и ещё два в ноябре: оба месяца в пределах своих четырёх.
        let active = range("2026-10-20", "2026-11-12", except: ["2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25", "2026-11-03", "2026-11-04"])
        let s = StreakEngine.current(today: "2026-11-12", activeDays: active)
        XCTAssertEqual(s.days, 24 - 6)
        XCTAssertEqual(s.restDaysLeft, 2)
    }

    func testWeeklyOffDaysAreFree() {
        // Воскресенья 1 и 8 ноября пропущены, но они постоянные выходные.
        let active = range("2026-10-26", "2026-11-12", except: ["2026-11-01", "2026-11-08"])
        let s = StreakEngine.current(today: "2026-11-12", activeDays: active,
                                     settings: StreakSettings(restDaysPerMonth: 4, weeklyOffWeekdays: [7]))
        XCTAssertEqual(s, StreakState(days: 16, restDaysLeft: 4))
    }

    func testZeroRestDaysBreaksOnFirstGap() {
        let active = range("2026-11-01", "2026-11-12", except: ["2026-11-05"])
        let s = StreakEngine.current(today: "2026-11-12", activeDays: active, settings: StreakSettings(restDaysPerMonth: 0))
        XCTAssertEqual(s.days, 7)
    }

    func testSettingsAreClamped() {
        let s = StreakSettings(restDaysPerMonth: 99, weeklyOffWeekdays: [3, 1, 9, 5])
        XCTAssertEqual(s.restDaysPerMonth, 31)
        XCTAssertEqual(s.weeklyOffWeekdays, [1, 3])
        XCTAssertEqual(StreakSettings(restDaysPerMonth: -1).restDaysPerMonth, 0)
    }

    func testActiveDaysUnionsSections() {
        XCTAssertEqual(StreakEngine.activeDays([["2026-11-01"], ["2026-11-01", "2026-11-02"], []]), ["2026-11-01", "2026-11-02"])
    }
}
