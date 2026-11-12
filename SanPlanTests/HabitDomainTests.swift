import XCTest
@testable import SanPlan

final class HabitDomainTests: XCTestCase {
    // 2026-11-12 — четверг; неделя с понедельника 2026-11-09.
    private let today = "2026-11-12"

    private func habit(_ schedule: HabitSchedule = .everyDay, target: HabitTarget = .once, rule: HabitRule? = nil) -> Habit {
        Habit(id: "h", title: "Привычка", schedule: schedule, target: target, rule: rule, createdDay: "2026-10-01")
    }

    private func marks(_ days: [String]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: days.map { ($0, 1) })
    }

    func testCalendarHelpers() {
        XCTAssertEqual(HabitCalendar.isoWeekday("2026-11-12"), 4)
        XCTAssertEqual(HabitCalendar.isoWeekday("2026-11-15"), 7)
        XCTAssertEqual(HabitCalendar.weekStart("2026-11-12"), "2026-11-09")
        XCTAssertEqual(HabitCalendar.weekStart("2026-11-15"), "2026-11-09")
        XCTAssertEqual(HabitCalendar.weekStart("2026-11-16"), "2026-11-16")
        XCTAssertEqual(HabitCalendar.days(from: "2026-11-29", to: "2026-12-02"), ["2026-11-29", "2026-11-30", "2026-12-01", "2026-12-02"])
        XCTAssertEqual(HabitCalendar.days(from: "2026-12-02", to: "2026-11-29"), [])
    }

    func testWeekdaysStreakSkipsDaysOutsideSchedule() {
        let h = habit(.onWeekdays([1, 3, 5]))
        let m = marks(["2026-11-11", "2026-11-09", "2026-11-06", "2026-11-04", "2026-11-02"])
        let s = HabitEngine.streak(h, today: today, marks: m, context: .empty)
        XCTAssertEqual(s, HabitStreak(count: 5, unit: .days))
    }

    func testPendingTodayDoesNotBreakButMissedDayDoes() {
        let h = habit()
        let ok = marks(["2026-11-09", "2026-11-10", "2026-11-11"])
        XCTAssertEqual(HabitEngine.streak(h, today: today, marks: ok, context: .empty).count, 3)
        XCTAssertEqual(HabitEngine.streak(h, today: today, marks: ok.merging(["2026-11-12": 1]) { a, _ in a }, context: .empty).count, 4)
        let gap = marks(["2026-11-09", "2026-11-11"])
        XCTAssertEqual(HabitEngine.streak(h, today: today, marks: gap, context: .empty).count, 1)
    }

    func testStreakDoesNotCountBeforeCreation() {
        var h = habit()
        h.createdDay = "2026-11-11"
        let m = marks(["2026-11-09", "2026-11-10", "2026-11-11"])
        XCTAssertEqual(HabitEngine.streak(h, today: today, marks: m, context: .empty).count, 1)
    }

    func testTimesPerWeekStreakCountsWeeks() {
        let h = habit(.timesPerWeek(3))
        let m = marks(["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-02", "2026-11-04", "2026-11-06", "2026-10-27"])
        let s = HabitEngine.streak(h, today: today, marks: m, context: .empty)
        XCTAssertEqual(s, HabitStreak(count: 2, unit: .weeks))
    }

    func testTimesPerWeekDueUntilQuotaMet() {
        let h = habit(.timesPerWeek(3))
        let two = marks(["2026-11-09", "2026-11-10"])
        XCTAssertTrue(HabitEngine.isDue(h, day: today, marks: two, context: .empty))
        let three = marks(["2026-11-09", "2026-11-10", "2026-11-11"])
        XCTAssertFalse(HabitEngine.isDue(h, day: today, marks: three, context: .empty))
        XCTAssertTrue(HabitEngine.isDue(h, day: "2026-11-11", marks: three, context: .empty), "отмеченный день остаётся в списке")
        XCTAssertTrue(HabitEngine.isDue(h, day: "2026-11-16", marks: three, context: .empty), "новая неделя — норма с нуля")
    }

    func testCountableTargetNeedsFullAmount() {
        let h = habit(target: HabitTarget(amount: 8, unit: "стаканов"))
        XCTAssertFalse(HabitEngine.isDone(h, day: today, marks: [today: 7], context: .empty))
        XCTAssertTrue(HabitEngine.isDone(h, day: today, marks: [today: 8], context: .empty))
    }

    func testTrainingRuleUsesTrainingSummary() {
        let h = habit(rule: .training)
        let ctx = HabitContext(trainingDay: { $0 == "2026-11-12" ? HabitTrainingDay(completed: true) : HabitTrainingDay(completed: false) })
        XCTAssertTrue(HabitEngine.isDone(h, day: today, marks: [:], context: ctx))
        XCTAssertFalse(HabitEngine.isDone(h, day: "2026-11-11", marks: [:], context: ctx))
        XCTAssertFalse(HabitEngine.isDone(h, day: today, marks: [:], context: .empty), "без данных тренировки — не выполнено")
        XCTAssertTrue(HabitEngine.isDone(h, day: "2026-11-11", marks: ["2026-11-11": 1], context: ctx), "ручная отметка тоже считается")
    }

    func testMoneyRules() {
        let ctx = HabitContext(financeDay: { _ in HabitFinanceDay(spent: 2500, byCategory: ["Такси": 2500]) })
        XCTAssertTrue(HabitEngine.ruleSatisfied(.noSpend(category: "Кафе"), day: today, context: ctx))
        XCTAssertFalse(HabitEngine.ruleSatisfied(.noSpend(category: "Такси"), day: today, context: ctx))
        XCTAssertFalse(HabitEngine.ruleSatisfied(.noSpend(), day: today, context: ctx))
        XCTAssertTrue(HabitEngine.ruleSatisfied(.spendAtMost(3000), day: today, context: ctx))
        XCTAssertFalse(HabitEngine.ruleSatisfied(.spendAtMost(2000), day: today, context: ctx))
        XCTAssertTrue(HabitEngine.ruleSatisfied(.spendAtMost(2500, category: "Такси"), day: today, context: ctx))
        XCTAssertFalse(HabitEngine.ruleSatisfied(.noSpend(category: "Кафе"), day: today, context: .empty), "без данных денег — не выполнено")
        XCTAssertFalse(HabitEngine.ruleSatisfied(HabitRule(kind: .spendAtMost), day: today, context: ctx), "без лимита правило не работает")
    }

    func testDaySummaryCountsDueHabitsOnly() {
        let daily = Habit(id: "a", title: "Вода", createdDay: "2026-10-01")
        let mon = Habit(id: "b", title: "Пн", schedule: .onWeekdays([1]), createdDay: "2026-10-01")
        let future = Habit(id: "c", title: "Новая", createdDay: "2026-12-01")
        var archived = Habit(id: "d", title: "Старая", createdDay: "2026-10-01")
        archived.archived = true
        let s = HabitEngine.daySummary(
            habits: [daily, mon, future, archived], day: today,
            marks: ["a": [today: 1]], context: .empty)
        XCTAssertEqual(s, HabitDaySummary(done: 1, total: 1))
    }

    func testCodableRoundTrip() throws {
        let h = Habit(id: "x", title: "Без такси", schedule: .timesPerWeek(4), target: HabitTarget(amount: 2, unit: "раза"),
                      rule: .noSpend(category: "Такси"), sphere: "Деньги", createdDay: "2026-11-01")
        let data = try JSONEncoder().encode(h)
        XCTAssertEqual(try JSONDecoder().decode(Habit.self, from: data), h)
    }
}

@MainActor
final class HabitStoreTests: XCTestCase {
    private func makeStore() -> (HabitStore, UserDefaults, String) {
        let name = "habit-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (HabitStore(defaults: defaults, owner: .device), defaults, name)
    }

    func testTapTogglesOnceHabitAndCyclesCountable() {
        let (store, _, _) = makeStore()
        let once = Habit(id: "o", title: "Зарядка", createdDay: "2026-11-01")
        let water = Habit(id: "w", title: "Вода", target: HabitTarget(amount: 3, unit: "стакана"), createdDay: "2026-11-01")
        store.add(once)
        store.add(water)
        XCTAssertEqual(store.tap(once, on: "2026-11-12"), 1)
        XCTAssertTrue(store.isDone(once, on: "2026-11-12"))
        XCTAssertEqual(store.tap(once, on: "2026-11-12"), 0)
        XCTAssertEqual([store.tap(water, on: "2026-11-12"), store.tap(water, on: "2026-11-12"), store.tap(water, on: "2026-11-12"), store.tap(water, on: "2026-11-12")], [1, 2, 3, 0])
        store.complete(water, on: "2026-11-12")
        XCTAssertTrue(store.isDone(water, on: "2026-11-12"))
    }

    func testPersistsBetweenLaunches() {
        let (store, defaults, _) = makeStore()
        store.add(Habit(id: "o", title: "Зарядка", createdDay: "2026-11-01"))
        store.complete(store.habits[0], on: "2026-11-12")
        store.streakSettings = StreakSettings(restDaysPerMonth: 2, weeklyOffWeekdays: [7])

        let reloaded = HabitStore(defaults: defaults, owner: .device)
        XCTAssertEqual(reloaded.habits.map(\.id), ["o"])
        XCTAssertEqual(reloaded.daySummary(for: "2026-11-12"), HabitDaySummary(done: 1, total: 1))
        XCTAssertEqual(reloaded.streakSettings.restDaysPerMonth, 2)
        XCTAssertEqual(reloaded.activityDays(from: "2026-11-01", to: "2026-11-30"), ["2026-11-12"])
    }

    func testSwitchOwnerKeepsEachAccountsHabits() {
        let defaults = UserDefaults(suiteName: "habit-tests-\(UUID().uuidString)")!
        let store = HabitStore(defaults: defaults)
        store.add(Habit(title: "Нельзя", createdDay: "2026-11-01"))
        XCTAssertTrue(store.habits.isEmpty, "без владельца ничего не сохраняется")

        store.switchOwner(to: .account("a@example.com"))
        let h = Habit(id: "o", title: "Зарядка", createdDay: "2026-11-01")
        store.add(h)
        store.complete(h, on: "2026-11-12")
        store.streakSettings = StreakSettings(restDaysPerMonth: 2, weeklyOffWeekdays: [7])

        store.switchOwner(to: .none)
        XCTAssertTrue(store.habits.isEmpty)
        XCTAssertTrue(store.marks.isEmpty)

        store.switchOwner(to: .account("B@example.com"))
        XCTAssertTrue(store.habits.isEmpty)
        store.add(Habit(id: "b", title: "Вода", createdDay: "2026-11-01"))

        store.switchOwner(to: .account(" a@example.com "))
        XCTAssertEqual(store.habits.map(\.id), ["o"])
        XCTAssertTrue(store.isDone(h, on: "2026-11-12"))
        XCTAssertEqual(store.streakSettings, StreakSettings(restDaysPerMonth: 2, weeklyOffWeekdays: [7]))
        store.switchOwner(to: .none)
        store.switchOwner(to: .account("a@example.com"))
        XCTAssertEqual(store.habits.map(\.id), ["o"], "повторный возврат тоже не стирает")
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.contains("example") }, "почта на диск не пишется")
    }

    func testRejectsEmptyTitleAndDeleteRemovesMarks() {
        let (store, _, _) = makeStore()
        store.add(Habit(title: "   ", createdDay: "2026-11-01"))
        XCTAssertTrue(store.habits.isEmpty)
        let h = Habit(id: "o", title: "Зарядка", createdDay: "2026-11-01")
        store.add(h)
        store.complete(h, on: "2026-11-12")
        store.delete(id: "o")
        XCTAssertTrue(store.marks.isEmpty)
    }
}

final class HabitTextTests: XCTestCase {
    func testScheduleAndRuleLabels() {
        XCTAssertEqual(HabitText.schedule(.everyDay), "Каждый день")
        XCTAssertEqual(HabitText.schedule(.onWeekdays([5, 1, 3])), "Пн, Ср, Пт")
        XCTAssertEqual(HabitText.schedule(.timesPerWeek(3)), "3 раза в неделю")
        XCTAssertEqual(HabitText.times(1), "1 раз")
        XCTAssertEqual(HabitText.times(12), "12 раз")
        XCTAssertEqual(HabitText.times(22), "22 раза")
        XCTAssertEqual(HabitText.rule(.training), "тренировка")
        XCTAssertEqual(HabitText.rule(.noSpend(category: "Такси")), "нет трат: Такси")
        XCTAssertEqual(HabitText.rule(.noSpend()), "нет трат")
    }

    func testStreakLabelHiddenAtZero() {
        XCTAssertNil(HabitText.streak(HabitStreak(count: 0, unit: .days)))
        XCTAssertEqual(HabitText.streak(HabitStreak(count: 5, unit: .weeks)), "серия 5 нед.")
    }
}
