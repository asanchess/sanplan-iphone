import XCTest
@testable import SanPlan

final class MascotLifeTests: XCTestCase {
    // MARK: Throttle

    func testMinorEventsWaitTwoMinutesImportantOnesNever() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(MascotThrottle.allows(.expense, now: t0, lastMinor: nil))
        XCTAssertFalse(MascotThrottle.allows(.expense, now: t0.addingTimeInterval(119), lastMinor: t0))
        XCTAssertTrue(MascotThrottle.allows(.noteSaved, now: t0.addingTimeInterval(120), lastMinor: t0))
        XCTAssertTrue(MascotThrottle.allows(.workoutDone, now: t0.addingTimeInterval(1), lastMinor: t0))
        XCTAssertTrue(MascotThrottle.allows(.planDone, now: t0, lastMinor: t0))
        XCTAssertTrue(MascotThrottle.allows(.limitKept, now: t0, lastMinor: t0))
    }

    // MARK: Big expense

    func testBigExpense() {
        XCTAssertTrue(MascotReactions.isBigExpense(2_000_100, history: []))
        XCTAssertFalse(MascotReactions.isBigExpense(1_500_000, history: []))
        XCTAssertTrue(MascotReactions.isBigExpense(400_000, history: [100_000, 100_000]))
        XCTAssertFalse(MascotReactions.isBigExpense(300_000, history: [100_000, 100_000]))
    }

    // MARK: Self-talk

    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testSelfTalkPlanSoon() {
        var input = MascotSelfTalkInput(now: now)
        input.nextStart = (title: "Тренировка", at: now.addingTimeInterval(14 * 60 + 10))
        XCTAssertEqual(MascotSelfTalk.line(input), "Через 15 мин: Тренировка")
        input.nextStart = (title: "Тренировка", at: now.addingTimeInterval(20 * 60))
        XCTAssertNil(MascotSelfTalk.line(input))
    }

    func testSelfTalkLimitAlmostOver() {
        var input = MascotSelfTalkInput(now: now)
        input.dayLimit = 10_000
        input.spentToday = 9_000
        XCTAssertEqual(MascotSelfTalk.line(input), "Лимит на сегодня почти кончился")
        input.spentToday = 8_000
        XCTAssertNil(MascotSelfTalk.line(input))
    }

    func testSelfTalkHabitStreakOnlyInTheEvening() {
        var input = MascotSelfTalkInput(now: now)
        input.habitsAtRisk = ["Зарядка"]
        input.hour = 19
        XCTAssertNil(MascotSelfTalk.line(input))
        input.hour = 21
        XCTAssertEqual(MascotSelfTalk.line(input), "Серия «Зарядка» под угрозой")
    }

    // MARK: Hidden edge

    func testHiddenEdgeFromFling() {
        let bounds = CGRect(x: 10, y: 50, width: 300, height: 600)
        XCTAssertNil(MascotEdge.pick(predicted: CGPoint(x: 150, y: 300), bounds: bounds))
        XCTAssertEqual(MascotEdge.pick(predicted: CGPoint(x: -100, y: 300), bounds: bounds), .left)
        XCTAssertEqual(MascotEdge.pick(predicted: CGPoint(x: 500, y: 300), bounds: bounds), .right)
        XCTAssertEqual(MascotEdge.pick(predicted: CGPoint(x: 150, y: 900), bounds: bounds), nil)
    }

    func testNightHours() {
        XCTAssertTrue(MascotClock.isNight(hour: 23))
        XCTAssertTrue(MascotClock.isNight(hour: 3))
        XCTAssertFalse(MascotClock.isNight(hour: 7))
        XCTAssertFalse(MascotClock.isNight(hour: 22))
    }

    // MARK: Summary

    func testSummaryPerTab() {
        var input = MascotReminderInput()
        input.nextPlanTitle = "Стоматолог"
        input.nextPlanTime = "14:30"
        input.canSpend = "4 500 ₸"
        input.dayLimit = "6 000 ₸"
        input.pinnedCount = 2
        XCTAssertEqual(MascotReminders.summary(input, tab: .today), "Дальше «Стоматолог» в 14:30, можно потратить 4 500 ₸.")
        XCTAssertEqual(MascotReminders.summary(input, tab: .plans), "Дальше «Стоматолог» в 14:30.")
        XCTAssertEqual(MascotReminders.summary(input, tab: .money), "Сегодня можно 4 500 ₸ из 6 000 ₸.")
        XCTAssertEqual(MascotReminders.summary(input, tab: .notes), "Закреплено: 2 заметки.")
        input.nextWorkout = "завтра: Ноги"
        XCTAssertEqual(MascotReminders.summary(input, tab: .workout), "Следующая тренировка завтра: Ноги.")
    }
}
