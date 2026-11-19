import XCTest
@testable import SanPlan

/// The numbers behind the new «Обзор»: the pace mark of an envelope, the cushion and its history, the top categories.
final class MoneyVisualsTests: XCTestCase {
    private func goal(_ id: String, saved: Int64, target: Int64 = 100_000, made: String? = nil, due: String? = nil) -> FinanceRecord {
        FinanceRecord(id: id, kind: "goal", title: id, amountMinor: target * 100, date: made, savedMinor: saved * 100, dueDate: due)
    }

    private func state(_ records: [FinanceRecord], log: [EnvelopeLogEntry] = []) -> FinanceState {
        FinanceState(records: records, imports: [], budget: FinanceBudget(envelopeLog: log))
    }

    // MARK: Pace

    func testPaceIsTheShareOfTimeGoneBetweenTheDayMadeAndTheDate() {
        let g = goal("trip", saved: 30_000, made: "2026-01-01", due: "2026-01-11")
        XCTAssertEqual(MoneyVisuals.paceFraction(goal: g, today: "2026-01-06") ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(MoneyVisuals.paceFraction(goal: g, today: "2026-02-01"), 1, "past the date the whole target is due")
        XCTAssertEqual(MoneyVisuals.paceFraction(goal: g, today: "2025-12-25"), 0)
        // Half the time gone, 30 000 of 100 000 saved: 20 000 behind.
        XCTAssertEqual(MoneyVisuals.paceGap(goal: g, today: "2026-01-06"), -20_000 * 100)
    }

    func testNoDateMeansNoMark() {
        XCTAssertNil(MoneyVisuals.paceFraction(goal: goal("a", saved: 1, made: "2026-01-01"), today: "2026-01-06"))
        XCTAssertNil(MoneyVisuals.paceFraction(goal: goal("b", saved: 1, due: "2026-02-01"), today: "2026-01-06"))
        XCTAssertNil(MoneyVisuals.paceFraction(goal: goal("c", saved: 1, made: "2026-02-01", due: "2026-01-01"), today: "2026-01-06"))
        XCTAssertNil(MoneyVisuals.paceGap(goal: goal("d", saved: 1), today: "2026-01-06"))
    }

    // MARK: Cushion

    func testHistoryTakesBackEveryMoveAfterEachMonthEnd() {
        let log = [
            EnvelopeLogEntry(id: "1", goalId: "old", amountMinor: 40_000 * 100, date: "2026-10-15"),
            EnvelopeLogEntry(id: "2", goalId: "old", amountMinor: 60_000 * 100, date: "2026-11-05"),
            EnvelopeLogEntry(id: "3", goalId: "gone", amountMinor: 99_000 * 100, date: "2026-11-06"),
        ]
        // «new» was made on 10 November with 50 000 already in it; «gone» was deleted.
        let s = state([goal("old", saved: 100_000), goal("new", saved: 50_000, made: "2026-11-10")], log: log)
        let history = MoneyVisuals.savedHistory(s, today: "2026-11-19", months: 3)
        XCTAssertEqual(history.map(\.month), ["2026-09", "2026-10", "2026-11"])
        XCTAssertEqual(history.map(\.minor), [0, 40_000 * 100, 150_000 * 100])
    }

    func testCushionInMonthsOfThePlanPayments() {
        let rent = FinanceRecord(id: "rent", kind: "obligation", title: "Аренда", amountMinor: 100_000 * 100, frequency: "monthly")
        let c = MoneyVisuals.cushion(state([goal("a", saved: 245_000, target: 300_000), rent]), today: "2026-11-19")
        XCTAssertEqual(c.savedMinor, 245_000 * 100)
        XCTAssertEqual(c.monthlyMinor, 100_000 * 100)
        XCTAssertEqual(c.monthsText, "2,4")
        XCTAssertEqual(c.history.count, 6)
        XCTAssertEqual(c.history.last?.month, "2026-11")
    }

    func testCushionWithoutAMonthOfLivingHasNoMonths() {
        let c = MoneyVisuals.cushion(state([goal("a", saved: 10_000)]), today: "2026-11-19")
        XCTAssertNil(c.months)
        XCTAssertNil(c.monthsText)
    }

    // MARK: Tiles

    func testTopThreeCategoriesOfThisCalendarMonth() {
        func spend(_ id: String, _ category: String, _ tenge: Int64, _ date: String) -> FinanceRecord {
            FinanceRecord(id: id, kind: "expense", title: id, amountMinor: tenge * 100, date: date, category: category)
        }
        let s = state([
            spend("1", "Продукты", 30_000, "2026-11-03"),
            spend("2", "Кафе", 12_000, "2026-11-04"),
            spend("3", "Транспорт", 8_000, "2026-11-05"),
            spend("4", "Кино", 2_000, "2026-11-06"),
            spend("5", "Покупки", 90_000, "2026-10-30"),
        ])
        let top = MoneyVisuals.topCategories(s, today: "2026-11-19")
        XCTAssertEqual(top.map(\.name), ["Продукты", "Кафе", "Транспорт"], "October and the fourth category stay out")
        XCTAssertEqual(top.first?.tenge, 30_000)
    }

    func testShortSumsForTheNarrowTile() {
        XCTAssertEqual(MoneyOverviewTiles.short(48_400), "48 тыс.")
        XCTAssertEqual(MoneyOverviewTiles.short(1_250_000), "1,2 млн")
        XCTAssertEqual(MoneyOverviewTiles.short(2_000_000), "2 млн")
    }
}
