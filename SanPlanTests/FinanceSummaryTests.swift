import XCTest
@testable import SanPlan

final class FinanceSummaryTests: XCTestCase {

    // Выдуманные данные, суммы в тенге.
    private func op(_ id: String, _ kind: String, _ tenge: Int64, _ date: String, category: String? = nil) -> FinanceRecord {
        FinanceRecord(id: id, kind: kind, title: id, amountMinor: tenge * 100, date: date, category: category)
    }

    private func state(_ records: [FinanceRecord], limits: [String: Int64]? = nil) -> FinanceState {
        FinanceState(records: records, budget: limits.map { FinanceBudget(limits: $0.mapValues { $0 * 100 }) })
    }

    // MARK: Day, period, activity, goals

    func testDayAndPeriodCountOnlyRealSpending() {
        var transfer = op("t", "expense", 9_000, "2026-11-10", category: "Переводы")
        transfer.excluded = true
        var own = op("o", "expense", 7_000, "2026-11-10", category: "Переводы")
        own.pairedWith = "x"
        let s = state([
            op("a", "expense", 1_500, "2026-11-10", category: "Кафе"),
            op("b", "expense", 2_500, "2026-11-10", category: "Такси"),
            op("c", "expense", 1_000, "2026-11-11", category: "Кафе"),
            op("i", "income", 50_000, "2026-11-10"),
            transfer, own,
        ])
        let d = FinanceSummaries.day(s, "2026-11-10")
        XCTAssertEqual(d.spent, 4_000)
        XCTAssertEqual(d.byCategory, ["Кафе": 1_500, "Такси": 2_500])
        XCTAssertEqual(d.currency, "KZT")
        let p = FinanceSummaries.period(s, from: "2026-11-01", to: "2026-11-30")
        XCTAssertEqual(p.spent, 5_000)
        XCTAssertEqual(p.count, 3)
        XCTAssertEqual(FinanceSummaries.period(s, from: "2026-11-01", to: "2026-11-30", category: "Кафе").spent, 2_500)
        XCTAssertEqual(FinanceSummaries.period(s, from: "2026-11-11", to: "2026-11-11").count, 1)
        XCTAssertEqual(FinanceSummaries.day(s, "2026-11-12").spent, 0)
    }

    func testActivityDaysAreSortedUniqueAndInRange() {
        let s = state([
            op("a", "expense", 100, "2026-11-10"), op("b", "income", 100, "2026-11-10"),
            op("c", "expense", 100, "2026-11-03"), op("d", "expense", 100, "2026-10-30"),
        ])
        XCTAssertEqual(FinanceSummaries.activityDays(s, from: "2026-11-01", to: "2026-11-30"), ["2026-11-03", "2026-11-10"])
    }

    func testSavingsGoalsInTenge() {
        let s = state([FinanceRecord(id: "g", kind: "goal", title: "Подушка", amountMinor: 500_000_00, savedMinor: 50_000_00)])
        XCTAssertEqual(FinanceSummaries.savingsGoals(s), [SavingsGoalSummary(id: "g", title: "Подушка", saved: 50_000, target: 500_000)])
    }

    // MARK: Можно потратить сегодня

    func testNoLimitsGivesNil() {
        XCTAssertNil(FinanceSummaries.canSpendToday(state([]), on: "2026-11-12"))
    }

    func testSplitsRemainingLimitOverDaysLeftIncludingToday() throws {
        // Лимит 30 000, до сегодняшнего дня потрачено 3 000, 19 дней (12–30 ноября).
        let s = state([op("a", "expense", 3_000, "2026-11-05", category: "Кафе")], limits: ["Кафе": 30_000])
        let r = try XCTUnwrap(FinanceSummaries.canSpendToday(s, on: "2026-11-12"))
        XCTAssertEqual(r.amount, 27_000 / 19)
        XCTAssertTrue(r.basis.contains("19 дней"))
    }

    func testTodaySpendingReducesTodayButNotTomorrowsShare() throws {
        let s = state([op("a", "expense", 600, "2026-11-12", category: "Кафе")], limits: ["Кафе": 30_000])
        let r = try XCTUnwrap(FinanceSummaries.canSpendToday(s, on: "2026-11-12"))
        XCTAssertEqual(r.amount, 30_000 / 19 - 600)
        XCTAssertTrue(r.basis.contains("сегодня уже потрачено"))
    }

    func testLastDayOfMonthGivesWholeRemainder() throws {
        let s = state([op("a", "expense", 10_000, "2026-11-05", category: "Кафе")], limits: ["Кафе": 30_000])
        let r = try XCTUnwrap(FinanceSummaries.canSpendToday(s, on: "2026-11-30"))
        XCTAssertEqual(r.amount, 20_000)
        XCTAssertTrue(r.basis.contains("1 день"))
    }

    func testOverspentLimitGivesZeroAndSaysSo() throws {
        let s = state([op("a", "expense", 35_000, "2026-11-05", category: "Кафе")], limits: ["Кафе": 30_000])
        let r = try XCTUnwrap(FinanceSummaries.canSpendToday(s, on: "2026-11-12"))
        XCTAssertEqual(r.amount, 0)
        XCTAssertEqual(r.basis, "Лимиты месяца исчерпаны")
    }

    func testOverspentCategoryDoesNotEatOtherCategories() throws {
        let s = state([op("a", "expense", 35_000, "2026-11-05", category: "Кафе")], limits: ["Кафе": 30_000, "Такси": 19_000])
        let r = try XCTUnwrap(FinanceSummaries.canSpendToday(s, on: "2026-11-12"))
        XCTAssertEqual(r.amount, 1_000)
    }

    func testCappedByMoneyLeftAfterPaymentsAndEnvelopes() throws {
        // На счетах 100 000, накопления 50 000 и аренда 40 000 не оплачена: свободно 10 000, доля лимитов 20 000 больше.
        let s = state([
            FinanceRecord(id: "b", kind: "balance", title: "Остаток", amountMinor: 100_000_00, date: "2026-11-01"),
            FinanceRecord(id: "g", kind: "goal", title: "Подушка", amountMinor: 500_000_00, savedMinor: 50_000_00),
            FinanceRecord(id: "rent", kind: "obligation", title: "Аренда", amountMinor: 40_000_00, date: "2026-09-01", frequency: "monthly"),
        ], limits: ["Кафе": 380_000])
        let r = try XCTUnwrap(FinanceSummaries.canSpendToday(s, on: "2026-11-12"))
        XCTAssertEqual(r.amount, 10_000)
        XCTAssertTrue(r.basis.hasPrefix("Ограничено свободными деньгами"))
    }

    func testNegativeFreeMoneyGivesZero() throws {
        let s = state([
            FinanceRecord(id: "b", kind: "balance", title: "Остаток", amountMinor: 10_000_00, date: "2026-11-01"),
            FinanceRecord(id: "rent", kind: "obligation", title: "Аренда", amountMinor: 40_000_00, date: "2026-09-01", frequency: "monthly"),
        ], limits: ["Кафе": 30_000])
        XCTAssertEqual(FinanceSummaries.canSpendToday(s, on: "2026-11-12")?.amount, 0)
    }

    @MainActor
    func testStoreForwardsToSummaries() {
        let store = FinanceStore(owner: .none)
        XCTAssertEqual(store.daySummary(for: "2026-11-12").spent, 0)
        XCTAssertNil(store.canSpendToday(on: "2026-11-12"))
        XCTAssertTrue(store.savingsGoals.isEmpty)
    }
}

final class FinanceSwipeTests: XCTestCase {
    func testRecategorizeChangesOnlyTheCategory() throws {
        var r = FinanceRecord(id: "a", kind: "expense", title: "Кофе", amountMinor: 150_000, date: "2026-11-10", category: "Без категории")
        r.note = "утром"
        let state = FinanceState(records: [r])
        let next = try StatementImport.recategorize("a", to: "Кафе и рестораны", in: state)
        let changed = try XCTUnwrap(next.records.first)
        XCTAssertEqual(changed.category, "Кафе и рестораны")
        XCTAssertEqual(changed.amountMinor, 150_000)
        XCTAssertEqual(changed.title, "Кофе")
        XCTAssertEqual(changed.note, "утром")
        XCTAssertEqual(changed.date, "2026-11-10")
    }

    func testCanSpendGapNamesMissingLimits() {
        XCTAssertNotNil(FinanceSummaries.canSpendGap(FinanceState(records: []), on: "2026-11-12"))
        let withLimit = FinanceState(records: [], budget: FinanceBudget(limits: ["Кафе": 30_000_00]))
        XCTAssertNil(FinanceSummaries.canSpendGap(withLimit, on: "2026-11-12"))
    }

    func testRecategorizeUnknownRecordThrows() {
        XCTAssertThrowsError(try StatementImport.recategorize("zzz", to: "Кафе", in: FinanceState(records: [])))
    }
}
