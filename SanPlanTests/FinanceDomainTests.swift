import XCTest
@testable import SanPlan

final class FinanceDomainTests: XCTestCase {

    // MARK: - Validation & State Invariants

    func testEmptyFinance() {
        let empty = emptyFinance()
        XCTAssertEqual(empty.version, 1)
        XCTAssertTrue(empty.records.isEmpty)
        XCTAssertTrue(empty.committedBatches.isEmpty)
        XCTAssertNoThrow(try validateFinance(empty))
    }

    func testValidateRejectsBadVersion() {
        var state = emptyFinance()
        state.version = 2
        XCTAssertThrowsError(try validateFinance(state))
    }

    func testValidateRecordsAndLimits() {
        var state = emptyFinance()
        state.records.append(FinanceRecord(id: "rec1", kind: "balance", title: "Остаток", amountMinor: 50000, date: "2026-05-01"))
        state.records.append(FinanceRecord(id: "rec2", kind: "income", title: "Зарплата", amountMinor: 25000000, date: "2026-05-02", category: "Работа"))
        state.records.append(FinanceRecord(id: "rec3", kind: "expense", title: "Кафе", amountMinor: 350000, date: "2026-05-03", category: "Еда"))
        state.records.append(FinanceRecord(id: "rec4", kind: "obligation", title: "Интернет", amountMinor: 600000, frequency: "monthly"))
        state.records.append(FinanceRecord(id: "rec5", kind: "goal", title: "Ноутбук", amountMinor: 80000000, savedMinor: 20000000, dueDate: "2026-12-31"))

        XCTAssertNoThrow(try validateFinance(state))
    }

    func testValidateRejectsDuplicateId() {
        var state = emptyFinance()
        state.records.append(FinanceRecord(id: "dup", kind: "income", title: "Аванс", amountMinor: 10000, date: "2026-05-01"))
        state.records.append(FinanceRecord(id: "dup", kind: "expense", title: "Обед", amountMinor: 2000, date: "2026-05-01"))
        XCTAssertThrowsError(try validateFinance(state))
    }

    func testValidateRejectsExcessiveGoalSaved() {
        var state = emptyFinance()
        state.records.append(FinanceRecord(id: "g1", kind: "goal", title: "Машина", amountMinor: 500000, savedMinor: 600000))
        XCTAssertThrowsError(try validateFinance(state))
    }

    // MARK: - Questions

    func testQuestionsForIncompleteDraft() {
        let draft = FinanceDraft(kind: "expense", title: "", amountMinor: nil, date: nil)
        let questions = financeQuestions(draft)
        let fields = questions.map { $0.field }
        XCTAssertTrue(fields.contains("title"))
        XCTAssertTrue(fields.contains("amountMinor"))
        XCTAssertTrue(fields.contains("date"))
    }

    func testQuestionsForCompleteDraft() {
        let draft = FinanceDraft(kind: "expense", title: "Обед", amountMinor: 250000, date: "2026-05-01")
        let questions = financeQuestions(draft)
        XCTAssertTrue(questions.isEmpty)
    }

    // MARK: - Commit & Mutations

    func testCommitDraftsAndIdempotency() throws {
        let initial = emptyFinance()
        // A spend named together with a balance must say whether the balance already includes it.
        var expense = FinanceDraft(kind: "expense", title: "Проезд", amountMinor: 15000, date: "2026-05-01", category: "Транспорт")
        expense.balanceRelation = "after"
        let drafts = [
            FinanceDraft(kind: "balance", title: "Остаток", amountMinor: 10000000, date: "2026-05-01"),
            expense
        ]

        let updated = try commitFinance(state: initial, drafts: drafts, batchId: "batch1", nowDate: "2026-05-01")
        XCTAssertEqual(updated.records.count, 2)
        XCTAssertEqual(updated.committedBatches, ["batch1"])

        // Idempotent commit
        let repeated = try commitFinance(state: updated, drafts: drafts, batchId: "batch1", nowDate: "2026-05-01")
        XCTAssertEqual(repeated, updated)
    }

    func testRemoveRecordUnlinksObligation() throws {
        var state = emptyFinance()
        state.records.append(FinanceRecord(id: "ob1", kind: "obligation", title: "Связь", amountMinor: 500000, frequency: "monthly"))
        state.records.append(FinanceRecord(id: "exp1", kind: "expense", title: "Оплата связи", amountMinor: 500000, date: "2026-05-05", obligationId: "ob1"))

        let afterRemove = try removeFinanceRecord(state: state, id: "ob1")
        XCTAssertEqual(afterRemove.records.count, 1)
        XCTAssertEqual(afterRemove.records[0].id, "exp1")
        XCTAssertNil(afterRemove.records[0].obligationId)
    }

    // MARK: - Summary & Math

    func testSummaryCalculation() throws {
        var state = emptyFinance()
        // Checkpoint on 2026-05-01: 100 000 KZT
        state.records.append(FinanceRecord(id: "b1", kind: "balance", title: "Остаток", amountMinor: 10000000, date: "2026-05-01"))
        // Income on 2026-05-02: 50 000 KZT
        state.records.append(FinanceRecord(id: "inc1", kind: "income", title: "Подработка", amountMinor: 5000000, date: "2026-05-02"))
        // Expense on 2026-05-03: 20 000 KZT
        state.records.append(FinanceRecord(id: "exp1", kind: "expense", title: "Покупки", amountMinor: 2000000, date: "2026-05-03", category: "Продукты"))
        // Goal: target 200 000 KZT, saved 30 000 KZT
        state.records.append(FinanceRecord(id: "g1", kind: "goal", title: "Резерв", amountMinor: 20000000, savedMinor: 3000000))
        // Obligation: 15 000 KZT monthly
        state.records.append(FinanceRecord(id: "ob1", kind: "obligation", title: "Коммуналка", amountMinor: 1500000, frequency: "monthly"))

        let summary = try financeSummary(state, today: "2026-05-05", month: "2026-05", horizonDays: 25)

        // Balance: 100k + 50k - 20k = 130 000 KZT (13_000_000 minor)
        XCTAssertEqual(summary.balanceMinor, 13000000)
        XCTAssertEqual(summary.incomeMinor, 5000000)
        XCTAssertEqual(summary.expenseMinor, 2000000)
        XCTAssertEqual(summary.netMinor, 3000000)
        XCTAssertEqual(summary.reservedGoalMinor, 3000000)
        XCTAssertEqual(summary.obligationsMinor, 1500000)

        // Spendable: 130k - 30k (goal) - 15k (obligation) = 85 000 KZT (8_500_000 minor)
        XCTAssertEqual(summary.spendableMinor, 8500000)
        XCTAssertEqual(summary.deficitMinor, 0)
        // Daily: 8_500_000 / 25 = 340 000 minor (3400 KZT)
        XCTAssertEqual(summary.dailyMinor, 340000)
    }

    // MARK: - Goal Progress

    func testGoalProgressActive() throws {
        let prog = try goalProgress(
            amountMinor: 10000000, // 100k target
            savedMinor: 4000000,   // 40k saved
            dueDate: "2026-05-11",
            today: "2026-05-01"    // 11 days left: May 1 to May 11 inclusive
        )

        XCTAssertEqual(prog.progressPercent, 40)
        XCTAssertEqual(prog.remainingMinor, 6000000)
        XCTAssertEqual(prog.daysLeft, 11)
        XCTAssertEqual(prog.status, "active")
        // Required daily: 6_000_000 / 11 rounded up = 545455
        XCTAssertEqual(prog.requiredDailyMinor, 545455)
    }

    func testGoalProgressComplete() throws {
        let prog = try goalProgress(
            amountMinor: 5000000,
            savedMinor: 5000000,
            dueDate: "2026-05-20",
            today: "2026-05-01"
        )
        XCTAssertEqual(prog.status, "complete")
        XCTAssertEqual(prog.progressPercent, 100)
        XCTAssertEqual(prog.requiredDailyMinor, 0)
    }

    // MARK: - Text Parsing

    func testParseKzt() throws {
        XCTAssertEqual(try parseKzt("2500"), 250000)
        XCTAssertEqual(try parseKzt("8,5 тыс."), 850000)
        XCTAssertEqual(try parseKzt("1 млн"), 100000000)
        XCTAssertEqual(try parseKzt("15 000 ₸"), 1500000)
    }

    func testParseFinanceTextSingleExpense() throws {
        let drafts = try parseFinanceText("Потратил 2500 на обед", today: "2026-05-01")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].kind, "expense")
        XCTAssertEqual(drafts[0].amountMinor, 250000)
        XCTAssertEqual(drafts[0].category, "Кафе и рестораны")
        XCTAssertEqual(drafts[0].date, "2026-05-01")
    }

    func testParseFinanceTextCompound() throws {
        let text = "Вчера потратил 3500 на такси; получил 40000 за проект"
        let drafts = try parseFinanceText(text, today: "2026-05-05")
        XCTAssertEqual(drafts.count, 2)

        XCTAssertEqual(drafts[0].kind, "expense")
        XCTAssertEqual(drafts[0].amountMinor, 350000)
        XCTAssertEqual(drafts[0].date, "2026-05-04") // yesterday

        XCTAssertEqual(drafts[1].kind, "income")
        XCTAssertEqual(drafts[1].amountMinor, 4000000)
        XCTAssertEqual(drafts[1].date, "2026-05-05")
    }
}
