import XCTest
import UserNotifications
@testable import SanPlan

/// 2026-11-12 is a Thursday; its week starts on Monday 2026-11-09.
final class ReviewDomainTests: XCTestCase {
    private let today = "2026-11-12"

    /// Epoch milliseconds of 12:00 in Asia/Qyzylorda (UTC+5) on the day.
    private func noon(_ day: String) -> Int64 {
        let date = ISO8601DateFormatter().date(from: day + "T07:00:00Z")!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func task(_ id: String, _ day: String, done: Bool = false) -> PlanItem {
        PlanItem(id: id, kind: "task", title: "Задача \(id)", date: day, completed: done ? true : nil)
    }

    private func expense(_ id: String, _ day: String, _ tenge: Int64, _ category: String) -> FinanceRecord {
        FinanceRecord(id: id, kind: "expense", title: id, amountMinor: tenge * 100, date: day, category: category)
    }

    private func workout(_ id: String, _ day: String, done: Bool = true) -> WorkoutRecord {
        WorkoutRecord(id: id, startedAt: noon(day), endedAt: noon(day) + 3_000_000, title: "Тренировка \(id)",
                      exercises: [WorkoutRecordExercise(name: "Жим", sets: [WorkoutRecordSet(done: done, weightKg: 50, reps: 8)])])
    }

    // MARK: Dates

    func testWeekStartIsMonday() {
        XCTAssertEqual(ReviewCalendar.weekStart("2026-11-12"), "2026-11-09")
        XCTAssertEqual(ReviewCalendar.weekStart("2026-11-09"), "2026-11-09")
        XCTAssertEqual(ReviewCalendar.weekStart("2026-11-15"), "2026-11-09") // Sunday
        XCTAssertEqual(ReviewCalendar.weekStart("2026-11-16"), "2026-11-16")
    }

    func testMonthBoundsAndRanges() {
        XCTAssertEqual(ReviewCalendar.monthStart("2026-11-12"), "2026-11-01")
        XCTAssertEqual(ReviewCalendar.monthEnd("2026-11-12"), "2026-11-30")
        XCTAssertEqual(ReviewCalendar.monthEnd("2028-02-10"), "2028-02-29")
        XCTAssertEqual(ReviewCalendar.days(from: "2026-11-29", to: "2026-12-02"), ["2026-11-29", "2026-11-30", "2026-12-01", "2026-12-02"])
        XCTAssertTrue(ReviewCalendar.days(from: "2026-12-02", to: "2026-11-29").isEmpty)
        XCTAssertFalse(ReviewCalendar.isDay("2026-02-30"))
    }

    // MARK: Summaries

    func testPlansDayCountsTasksOfThatDayOnly() {
        let plans = [task("a", today, done: true), task("b", today), task("c", "2026-11-13"), PlanItem(id: "e", kind: "event", title: "Встреча", date: today)]
        let summary = ReviewSummaries.plansDay(plans, day: today)
        XCTAssertEqual(summary.done, 1)
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.open, [OpenPlan(id: "b", title: "Задача b")])
    }

    func testFinanceDaySumsExpensesAndIgnoresExcludedAndIncome() {
        var excluded = expense("x", today, 999, "Покупки")
        excluded.excluded = true
        let records = [expense("a", today, 1500, "Продукты"), expense("b", today, 500, "Продукты"), expense("c", today, 700, "Транспорт"),
                       excluded, FinanceRecord(id: "i", kind: "income", title: "Зарплата", amountMinor: 9_000_000, date: today),
                       expense("old", "2026-11-11", 100, "Продукты")]
        let money = ReviewSummaries.financeDay(FinanceState(records: records), day: today)
        XCTAssertEqual(money.spentMinor, 270_000)
        XCTAssertEqual(money.count, 3)
        XCTAssertEqual(money.byCategory.map(\.name), ["Продукты", "Транспорт"])
        XCTAssertEqual(money.byCategory.first?.amountMinor, 200_000)
    }

    func testFinancePeriodFiltersByCategory() {
        let records = [expense("a", "2026-11-03", 1000, "Продукты"), expense("b", "2026-11-04", 2000, "Транспорт")]
        let food = ReviewSummaries.financePeriod(FinanceState(records: records), from: "2026-11-01", to: "2026-11-30", categories: ["Продукты"])
        XCTAssertEqual(food.spentMinor, 100_000)
        XCTAssertEqual(food.count, 1)
    }

    func testTrainingDayUsesLocalDayAndSkipsEmptyWorkouts() {
        let records = [workout("a", today), workout("b", today, done: false), workout("c", "2026-11-11")]
        let training = ReviewSummaries.trainingDay(records, day: today)
        XCTAssertEqual(training.completed, 1)
        XCTAssertEqual(training.titles, ["Тренировка a"])
    }

    func testDigestOverAWeekCombinesSections() {
        let sources = ReviewSources(
            plans: [task("a", "2026-11-10", done: true), task("b", "2026-11-12")],
            finance: FinanceState(records: [expense("a", "2026-11-11", 1000, "Продукты")]),
            workouts: [workout("a", "2026-11-10"), workout("b", "2026-11-17")],
            noteMoments: [noon("2026-11-09"), noon("2026-11-20")],
            habitsDay: nil)
        let digest = ReviewSummaries.digest(sources, from: "2026-11-09", to: "2026-11-15")
        XCTAssertEqual(digest.plans.total, 2)
        XCTAssertEqual(digest.plans.done, 1)
        XCTAssertEqual(digest.money.spentMinor, 100_000)
        XCTAssertEqual(digest.training.completed, 1)
        XCTAssertEqual(digest.notes, 1)
        XCTAssertNil(digest.habits)
        XCTAssertFalse(digest.isEmpty)
        XCTAssertTrue(ReviewSummaries.digest(ReviewSources(), day: today).isEmpty)
    }

    func testHabitsAppearOnlyWhenPlansProvidesThem() {
        let sources = ReviewSources(habitsDay: { $0 == "2026-11-10" ? HabitsSummary(done: 2, total: 3) : nil })
        let digest = ReviewSummaries.digest(sources, from: "2026-11-09", to: "2026-11-15")
        XCTAssertEqual(digest.habits, HabitsSummary(done: 2, total: 3))
    }

    // MARK: Entries

    func testEntryNeedsMoodOrTextAndValidMood() {
        XCTAssertNil(ReviewEntry.make(day: today, mood: nil, text: "  ", now: 1))
        XCTAssertNil(ReviewEntry.make(day: today, mood: 6, text: "ok", now: 1))
        XCTAssertNil(ReviewEntry.make(day: today, mood: 0, text: "", now: 1))
        XCTAssertNil(ReviewEntry.make(day: "2026-13-01", mood: 3, text: "", now: 1))
        XCTAssertEqual(ReviewEntry.make(day: today, mood: 4, text: "  Хороший день  ", now: 7),
                       ReviewEntry(day: today, mood: 4, text: "Хороший день", updatedAt: 7))
        XCTAssertNil(ReviewEntry.make(day: today, mood: nil, text: "Только текст", now: 1)?.mood)
    }

    func testEntryTextIsCapped() {
        let long = String(repeating: "а", count: 900)
        XCTAssertEqual(ReviewEntry.make(day: today, mood: nil, text: long, now: 1)?.text.count, ReviewLimits.maxTextLength)
    }

    // MARK: Week

    func testWeekReviewKeepsOnlyValidRatingsAndUsesMonday() {
        let week = WeekReview.make(containing: today, ratings: ["health": 7, "money": 11, "rest": 0, "work": 10], now: 5)
        XCTAssertEqual(week?.weekStart, "2026-11-09")
        XCTAssertEqual(week?.ratings, ["health": 7, "work": 10])
        XCTAssertEqual(week?.average, 8.5)
        XCTAssertNil(WeekReview.make(containing: today, ratings: ["health": 12], now: 5))
    }

    func testComparisonUsesSpheresRatedInBothWeeks() {
        let now = WeekReview(weekStart: "2026-11-09", ratings: ["health": 8, "money": 5, "rest": 9], updatedAt: 1)
        let before = WeekReview(weekStart: "2026-11-02", ratings: ["health": 6, "money": 7], updatedAt: 1)
        let comparison = WeekComparison.make(current: now, previous: before)
        XCTAssertEqual(comparison.deltas, ["health": 2, "money": -2])
        XCTAssertEqual(comparison.averageDelta, 0)
        XCTAssertNil(WeekComparison.make(current: now, previous: nil).averageDelta)
    }

    func testWeekFiguresCompareWithPreviousWeek() {
        let current = PeriodDigest(plans: PlansSummary(done: 5, total: 6), money: MoneySummary(spentMinor: 300_000, count: 4), training: TrainingSummary(completed: 3), notes: 2)
        let previous = PeriodDigest(plans: PlansSummary(done: 2, total: 4), money: MoneySummary(spentMinor: 500_000, count: 5), training: TrainingSummary(completed: 3), notes: 0)
        let figures = ReviewWeekFigures.make(current: current, previous: previous)
        XCTAssertEqual(figures.map(\.title), ["Задач выполнено", "Тренировок", "Потрачено", "Заметок"])
        XCTAssertEqual(figures.map(\.delta), [3, 0, -200_000, 2])
    }

    // MARK: Reminder

    func testReminderDefaultsToNineInTheEveningAndClamps() {
        XCTAssertEqual(ReviewReminderSettings.standard.timeText, "21:00")
        XCTAssertEqual(ReviewReminderSettings(enabled: true, hour: 31, minute: -4).timeText, "23:00")
    }

    func testReminderRequestRepeatsDailyAtTheChosenTime() {
        let request = ReviewReminder.request(for: ReviewReminderSettings(enabled: true, hour: 22, minute: 15))
        let trigger = request.trigger as? UNCalendarNotificationTrigger
        XCTAssertEqual(trigger?.dateComponents.hour, 22)
        XCTAssertEqual(trigger?.dateComponents.minute, 15)
        XCTAssertEqual(trigger?.repeats, true)
        XCTAssertEqual(request.identifier, ReviewReminder.identifier)
        XCTAssertFalse(request.content.body.contains("₸"))
    }

    // MARK: Format

    func testRussianPlurals() {
        XCTAssertEqual(ReviewFormat.plural(1, "трата", "траты", "трат"), "1 трата")
        XCTAssertEqual(ReviewFormat.plural(3, "трата", "траты", "трат"), "3 траты")
        XCTAssertEqual(ReviewFormat.plural(5, "трата", "траты", "трат"), "5 трат")
        XCTAssertEqual(ReviewFormat.plural(11, "трата", "траты", "трат"), "11 трат")
        XCTAssertEqual(ReviewFormat.plural(21, "трата", "траты", "трат"), "21 трата")
    }

    func testCanSpendLinePicksAmountGapOrNothing() {
        XCTAssertEqual(CanSpendLine.make(spend: CanSpendToday(amount: 5000, basis: "b"), gap: nil, hasData: true), .amount(5000, basis: "b"))
        XCTAssertEqual(CanSpendLine.make(spend: nil, gap: "Задайте лимиты", hasData: true), .gap("Задайте лимиты"))
        XCTAssertNil(CanSpendLine.make(spend: nil, gap: "Задайте лимиты", hasData: false))
        XCTAssertNil(CanSpendLine.make(spend: nil, gap: nil, hasData: true))
    }

    func testWeekGoalLineCarriesProgressAndHidesWithoutTitle() {
        let line = WeekGoalLine.make(title: " Пробежать 20 км ", progressText: "8 из 20 км", fraction: 0.4)
        XCTAssertEqual(line, WeekGoalLine(title: "Пробежать 20 км", text: "8 из 20 км", fraction: 0.4, achieved: false))
        XCTAssertEqual(WeekGoalLine.make(title: "Цель", progressText: "x", fraction: 3)?.fraction, 1)
        XCTAssertNil(WeekGoalLine.make(title: "Цель", progressText: "Нет данных", fraction: nil)?.fraction)
        XCTAssertNil(WeekGoalLine.make(title: "  ", progressText: "", fraction: 0.5))
        XCTAssertNil(WeekGoalLine.make(title: nil, progressText: nil, fraction: nil))
    }

    func testStreakLineStatesDaysAndRestDays() {
        XCTAssertEqual(StreakLine.text(StreakState(days: 5, restDaysLeft: 2)), "Серия: 5 дней · отдыха осталось 2")
        XCTAssertEqual(StreakLine.text(StreakState(days: 1, restDaysLeft: 0)), "Серия: 1 день · дней отдыха не осталось")
        XCTAssertNil(StreakLine.text(StreakState(days: 0, restDaysLeft: 2)))
        XCTAssertNil(StreakLine.text(nil))
    }
}
