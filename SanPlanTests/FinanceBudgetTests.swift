import XCTest
@testable import SanPlan

final class FinanceBudgetTests: XCTestCase {

    // MARK: Fixtures (synthetic, amounts in tenge)

    private func op(_ id: String, _ kind: String, _ tenge: Int64, _ date: String, category: String? = nil,
                    merchant: String? = nil, importId: String? = nil) -> FinanceRecord {
        var r = FinanceRecord(id: id, kind: kind, title: merchant ?? id, amountMinor: tenge * 100, date: date, category: category)
        r.merchant = merchant
        r.importId = importId
        return r
    }

    private var rent: FinanceRecord {
        FinanceRecord(id: "rent", kind: "obligation", title: "Аренда", amountMinor: 120_000_00, date: "2026-09-01", frequency: "monthly")
    }

    private var cushion: FinanceRecord {
        FinanceRecord(id: "cushion", kind: "goal", title: "Подушка", amountMinor: 500_000_00, savedMinor: 50_000_00)
    }

    /// 320 000 on the accounts on 1 Nov, 20 000 spent in a cafe, 50 000 set aside, rent 120 000 unpaid,
    /// a cafe limit of 80 000.
    private func november() -> FinanceState {
        FinanceState(
            records: [
                FinanceRecord(id: "b1", kind: "balance", title: "Остаток", amountMinor: 320_000_00, date: "2026-11-01"),
                op("cafe1", "expense", 20_000, "2026-11-05", category: "Кафе и рестораны", merchant: "Coffee Point"),
                cushion,
                rent,
            ],
            budget: FinanceBudget(limits: ["Кафе и рестораны": 80_000_00])
        )
    }

    // MARK: «Чистыми»

    func testCleanTakesOutEnvelopesUnpaidPaymentsAndWhatIsLeftOnLimits() throws {
        let snap = try FinanceBudgeting.snapshot(november(), today: "2026-11-10")
        XCTAssertEqual(snap.onAccountsMinor, 300_000_00)
        XCTAssertEqual(snap.reservedMinor, 50_000_00)
        XCTAssertEqual(snap.unpaidPaymentsMinor, 120_000_00)
        XCTAssertEqual(snap.limitsRemainingMinor, 60_000_00)
        XCTAssertEqual(snap.cleanMinor, 70_000_00)
        XCTAssertEqual(snap.daysLeft, 21)
        XCTAssertEqual(snap.flexiblePerDayMinor, 60_000_00 / 21)
        XCTAssertEqual(snap.asOf, "2026-11-01")
        XCTAssertTrue(snap.isStale, "a balance nine days old asks for a fresh statement")
    }

    func testOverspendingALimitLowersCleanThroughTheBalance() throws {
        var state = november()
        state.records.append(op("cafe2", "expense", 70_000, "2026-11-08", category: "Кафе и рестораны"))
        let snap = try FinanceBudgeting.snapshot(state, today: "2026-11-10")
        // 90 000 spent of 80 000: nothing left on the limit, and the extra 10 000 already left the accounts.
        XCTAssertEqual(snap.limitsRemainingMinor, 0)
        XCTAssertEqual(snap.cleanMinor, (230_000 - 50_000 - 120_000) * 100)
    }

    func testNegativeCleanWhenThePlanDoesNotFit() throws {
        var state = november()
        state.records[0].amountMinor = 100_000_00
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").cleanMinor, (80_000 - 50_000 - 120_000 - 60_000) * 100)
    }

    func testReconcileReplacesTheSameDayAndBecomesTheBalance() throws {
        var state = try FinanceBudgeting.reconcile(november(), totalMinor: 290_000_00, today: "2026-11-10", id: "r1")
        state = try FinanceBudgeting.reconcile(state, totalMinor: 295_000_00, today: "2026-11-10", id: "r2")
        XCTAssertEqual(state.records.filter { $0.title == FinanceBudgeting.reconcileTitle }.count, 1)
        let snap = try FinanceBudgeting.snapshot(state, today: "2026-11-10")
        XCTAssertEqual(snap.onAccountsMinor, 295_000_00)
        XCTAssertEqual(snap.asOf, "2026-11-10")
        XCTAssertFalse(snap.isStale)
    }

    // MARK: Payments of the plan

    func testPaidRentLeavesCleanUnchangedAndTheMerchantIsLearned() throws {
        var state = november()
        state.records.append(op("pay1", "expense", 120_000, "2026-11-06", category: "Переводы", merchant: "Иванов А."))
        // A transfer to a person shares no word with «Аренда»: nothing is guessed the first time.
        XCTAssertTrue(FinanceBudgeting.paymentMatches(state, today: "2026-11-10").isEmpty)

        state = try FinanceBudgeting.linkPayment(state, recordId: "pay1", obligationId: "rent")
        let snap = try FinanceBudgeting.snapshot(state, today: "2026-11-10")
        XCTAssertEqual(snap.unpaidPaymentsMinor, 0)
        XCTAssertEqual(snap.limitsRemainingMinor, 60_000_00, "a payment of the plan never eats a limit")
        XCTAssertEqual(snap.cleanMinor, 70_000_00, "paying a planned payment does not change «Чистыми»")

        // Next month the same person within 10 % is offered as the rent; a far amount is not.
        state.records.append(op("pay2", "expense", 125_000, "2026-12-02", category: "Переводы", merchant: "Иванов  А."))
        state.records.append(op("big", "expense", 200_000, "2026-12-02", category: "Покупки", merchant: "Аренда склада"))
        let matches = FinanceBudgeting.paymentMatches(state, today: "2026-12-03")
        XCTAssertEqual(matches.map(\.recordId), ["pay2"])
        XCTAssertEqual(matches.first?.obligationTitle, "Аренда")
    }

    func testMatchByTitleWordAndDismissal() throws {
        var state = FinanceState(records: [
            FinanceRecord(id: "phone", kind: "obligation", title: "Связь", amountMinor: 5_000_00, date: "2026-09-01", frequency: "monthly"),
            op("beeline", "expense", 5_200, "2026-11-04", category: "Связь и интернет", merchant: "Beeline"),
        ])
        let matches = FinanceBudgeting.paymentMatches(state, today: "2026-11-10")
        XCTAssertEqual(matches.map(\.id), ["phone|beeline"])
        state = try FinanceBudgeting.dismissMatch(state, matches[0])
        XCTAssertTrue(FinanceBudgeting.paymentMatches(state, today: "2026-11-10").isEmpty)
    }

    // MARK: Limits

    func testSuggestedLimitsAverageWholeMonthsAndRoundUp() {
        var state = FinanceState(records: [
            op("s1", "expense", 30_500, "2026-09-10", category: "Кафе и рестораны"),
            op("o1", "expense", 41_000, "2026-10-10", category: "Кафе и рестораны"),
            op("aug", "expense", 900_000, "2026-08-10", category: "Кафе и рестораны"),
            op("now", "expense", 99_000, "2026-11-02", category: "Кафе и рестораны"),
            op("pay", "expense", 1_000, "2026-10-02", category: "Транспорт"),
            op("sal", "income", 300_000, "2026-10-01", category: "Зарплата"),
            rent,
        ])
        var paid = op("rentpay", "expense", 120_000, "2026-10-01", category: "Переводы")
        paid.obligationId = "rent"
        state.records.append(paid)
        let limits = FinanceBudgeting.suggestedLimits(state, today: "2026-11-10")
        // (30 500 + 41 000) / 2 = 35 750 → 36 000; August is before the start, November is not whole yet.
        XCTAssertEqual(limits, ["Кафе и рестораны": 36_000_00, "Транспорт": 1_000_00])
    }

    func testPaceRunsOutDayAndOverLimitHintsComeFirst() throws {
        var state = FinanceState(records: [
            op("t1", "expense", 15_000, "2026-11-04", category: "Транспорт"),
            op("c1", "expense", 45_000, "2026-11-05", category: "Кафе и рестораны"),
        ])
        state = try FinanceBudgeting.setLimits(state, ["Транспорт": 30_000_00, "Кафе и рестораны": 40_000_00])
        let statuses = FinanceBudgeting.limitStatuses(state, month: "2026-11", today: "2026-11-10")
        let transport = try XCTUnwrap(statuses.first { $0.category == "Транспорт" })
        XCTAssertEqual(transport.projectedMinor, 45_000_00)
        XCTAssertEqual(transport.runsOutDay, 20)

        let hints = FinanceBudgeting.hints(state, today: "2026-11-10")
        XCTAssertEqual(hints.first?.kind, .overLimit)
        XCTAssertTrue(hints[0].text.contains("5 000 ₸"))
        XCTAssertTrue(hints.contains { $0.kind == .pace && $0.text.contains("20-го") })
    }

    func testEarlyRunOutsAreOneHintAndLateOnesAreQuiet() throws {
        var state = FinanceState(records: [
            op("t1", "expense", 15_000, "2026-11-04", category: "Транспорт"),   // runs out on the 20th
            op("p1", "expense", 8_000, "2026-11-05", category: "Продукты"),     // on the 25th: five days early
            op("f1", "expense", 7_500, "2026-11-05", category: "Развлечения"),  // on the 27th: close enough
        ])
        state = try FinanceBudgeting.setLimits(state, ["Транспорт": 30_000_00, "Продукты": 20_000_00, "Развлечения": 20_000_00])
        let pace = FinanceBudgeting.hints(state, today: "2026-11-10").filter { $0.kind == .pace }
        XCTAssertEqual(pace.count, 1)
        XCTAssertEqual(pace.first?.text, "При таком темпе раньше срока закончатся: «Транспорт» 20-го, «Продукты» 25-го")
    }

    func testGrowthAgainstTheUsualMonth() {
        let state = FinanceState(records: [
            op("s", "expense", 30_000, "2026-09-10", category: "Доставка еды"),
            op("o", "expense", 30_000, "2026-10-10", category: "Доставка еды"),
            op("n", "expense", 30_000, "2026-11-12", category: "Доставка еды"),
        ])
        let growth = FinanceBudgeting.hints(state, today: "2026-11-15").filter { $0.kind == .growth }
        XCTAssertEqual(growth.map(\.subject), ["Доставка еды"])
        XCTAssertTrue(growth[0].text.contains("+100%"))
        XCTAssertTrue(FinanceBudgeting.hints(state, today: "2026-11-05").filter { $0.kind == .growth }.isEmpty, "too early in the month")
    }

    // MARK: Hints about merchants and the cushion

    func testRecurringSmallFrequentAndRunway() {
        var records = [
            op("n1", "expense", 4_990, "2026-10-07", category: "Подписки", merchant: "Netflix"),
            op("n2", "expense", 4_990, "2026-11-07", category: "Подписки", merchant: "NETFLIX"),
            op("p1", "expense", 10_000, "2026-10-02", category: "Покупки", merchant: "Иван И."),
            op("p2", "expense", 10_000, "2026-11-02", category: "Покупки", merchant: "Иван И."),
            op("m1", "expense", 8_000, "2026-11-03", category: "Продукты", merchant: "Magnum"),
            op("m2", "expense", 9_000, "2026-11-06", category: "Продукты", merchant: "Magnum"),
            cushion,
            rent,
        ]
        for i in 1...9 { records.append(op("cof\(i)", "expense", 2_000, "2026-11-0\(i)", category: "Кафе и рестораны", merchant: "Coffee Point")) }
        let hints = FinanceBudgeting.hints(FinanceState(records: records), today: "2026-11-10")

        XCTAssertEqual(hints.filter { $0.kind == .recurring }.map(\.subject), ["Netflix"], "a person and a twice-a-month shop are not subscriptions")
        XCTAssertEqual(hints.filter { $0.kind == .smallFrequent }.map(\.subject), ["Coffee Point"])
        let runway = hints.first { $0.kind == .runway }
        XCTAssertEqual(runway?.text, "Отложенного хватит на 0,4 мес. обязательных трат")
        XCTAssertEqual(runway?.priority, 75)
    }

    // MARK: Envelopes

    func testSetAsideOffersAPercentOfEachIncomeOnce() throws {
        var state = FinanceState(records: [op("sal", "income", 250_000, "2026-11-05", category: "Зарплата", merchant: "ТОО Пример"), cushion])
        let offers = FinanceBudgeting.setAsideOffers(state, today: "2026-11-10")
        XCTAssertEqual(offers.map(\.suggestedMinor), [25_000_00])

        state = try FinanceBudgeting.setAside(state, amountMinor: 25_000_00, goalId: "cushion", incomeId: "sal")
        XCTAssertEqual(state.records.first { $0.id == "cushion" }?.savedMinor, 75_000_00)
        XCTAssertEqual(state.budget?.savingsGoalId, "cushion")
        XCTAssertTrue(FinanceBudgeting.setAsideOffers(state, today: "2026-11-10").isEmpty)

        XCTAssertThrowsError(try FinanceBudgeting.setAside(state, amountMinor: 500_000_00, goalId: "cushion"))
        state = try FinanceBudgeting.withdraw(state, amountMinor: 5_000_00, goalId: "cushion")
        XCTAssertEqual(state.records.first { $0.id == "cushion" }?.savedMinor, 70_000_00)
        XCTAssertThrowsError(try FinanceBudgeting.withdraw(state, amountMinor: 70_001_00, goalId: "cushion"))

        state = try FinanceBudgeting.updateBudget(state) { $0.savePercent = 0 }
        state.records.append(op("sal2", "income", 100_000, "2026-11-09"))
        XCTAssertTrue(FinanceBudgeting.setAsideOffers(state, today: "2026-11-10").isEmpty)
    }

    // MARK: Operations feed

    private func feed() -> FinanceState {
        var own = op("d", "expense", 50_000, "2026-11-05", category: "Переводы", merchant: "Halyk Bank", importId: "k")
        own.excluded = true
        own.pairedWith = "e"
        var other = op("e", "income", 50_000, "2026-11-05", category: "Переводы", merchant: "Kaspi Gold", importId: "h")
        other.excluded = true
        other.pairedWith = "d"
        var state = FinanceState(records: [
            op("a", "expense", 3_000, "2026-11-03", category: "Доставка еды", merchant: "Glovo", importId: "k"),
            op("b", "expense", 10_000, "2026-11-05", category: "Продукты", merchant: "Magnum", importId: "h"),
            op("c", "income", 250_000, "2026-11-01", category: "Зарплата"),
            own,
            other,
            op("f", "expense", 2_000, "2026-10-30", category: "Продукты"),
        ])
        state.imports = [
            FinanceImport(id: "k", bank: "Kaspi", fileName: "k.pdf", periodStart: nil, periodEnd: nil, importedAt: "2026-11-06", count: 2, account: "7781"),
            FinanceImport(id: "h", bank: "Halyk", fileName: "h.pdf", periodStart: nil, periodEnd: nil, importedAt: "2026-11-06", count: 2),
        ]
        return state
    }

    func testFeedIsChronologicalAcrossBanksAndGroupedByDay() {
        let days = FinanceBudgeting.ledger(feed())
        XCTAssertEqual(days.map(\.date), ["2026-11-05", "2026-11-03", "2026-11-01", "2026-10-30"])
        XCTAssertEqual(days[0].entries.map(\.id), ["e", "d", "b"])
        XCTAssertEqual(days[0].entries.map(\.source), ["Halyk", "Kaspi", "Halyk"])
        XCTAssertEqual(days[0].entries.map(\.isOwnTransfer), [true, true, false])
        XCTAssertEqual(days[0].netMinor, -10_000_00, "own transfers stay out of the day total")
        XCTAssertEqual(days[2].entries.first?.source, FinanceBudgeting.manualSource)
        XCTAssertEqual(FinanceBudgeting.ledgerSources(feed()), ["Halyk", "Kaspi", "Вручную"])
    }

    func testFeedFilters() {
        let state = feed()
        func ids(_ filter: LedgerFilter) -> [String] { FinanceBudgeting.ledger(state, filter: filter).flatMap(\.entries).map(\.id) }
        XCTAssertEqual(ids(LedgerFilter(source: "Kaspi")), ["d", "a"])
        XCTAssertEqual(ids(LedgerFilter(kind: .expense)), ["b", "a", "f"])
        XCTAssertEqual(ids(LedgerFilter(kind: .income)), ["c"])
        XCTAssertEqual(ids(LedgerFilter(kind: .transfer)), ["e", "d"])
        XCTAssertEqual(ids(LedgerFilter(month: "2026-10")), ["f"])
        XCTAssertEqual(ids(LedgerFilter(category: "Продукты")), ["b", "f"])
        XCTAssertEqual(ids(LedgerFilter(query: "  GLOVO ")), ["a"])
        let totals = FinanceBudgeting.ledgerTotals(FinanceBudgeting.ledger(state, filter: LedgerFilter(month: "2026-11")))
        XCTAssertEqual(totals.count, 5)
        XCTAssertEqual(totals.incomeMinor, 250_000_00)
        XCTAssertEqual(totals.expenseMinor, 13_000_00)
    }

    // MARK: Month review

    func testReviewOfLastMonthAndItsCard() throws {
        var paid = op("rentpay", "expense", 120_000, "2026-10-01", category: "Переводы")
        paid.obligationId = "rent"
        var state = FinanceState(
            records: [
                op("cafe", "expense", 50_000, "2026-10-12", category: "Кафе и рестораны"),
                op("sal", "income", 300_000, "2026-10-05", category: "Зарплата"),
                rent,
                FinanceRecord(id: "phone", kind: "obligation", title: "Связь", amountMinor: 5_000_00, date: "2026-09-01", frequency: "monthly"),
                paid,
            ],
            budget: FinanceBudget(limits: ["Кафе и рестораны": 80_000_00])
        )
        let review = FinanceBudgeting.review(state, month: "2026-10", today: "2026-11-02")
        XCTAssertEqual(review.incomeMinor, 300_000_00)
        XCTAssertEqual(review.expenseMinor, 170_000_00)
        XCTAssertEqual(review.savedOnLimitsMinor, 30_000_00)
        XCTAssertEqual(review.paidPayments, ["Аренда"])
        XCTAssertEqual(review.unpaidPayments, ["Связь"])

        XCTAssertEqual(FinanceBudgeting.pendingReviewMonth(state, today: "2026-11-02"), "2026-10")
        state = try FinanceBudgeting.markReviewed(state, month: "2026-10")
        XCTAssertNil(FinanceBudgeting.pendingReviewMonth(state, today: "2026-11-02"))
    }

    // MARK: Export

    func testExportHasThePromptAndNoNamesOrAccountNumbers() {
        var state = feed()
        state.records.append(op("p", "expense", 15_000, "2026-11-04", category: "Переводы", merchant: "Айгерим К.", importId: "k"))
        state.records.append(op("q", "expense", 6_000, "2026-11-04", category: "Покупки", merchant: "Ержан Б.", importId: "k"))
        state.records.append(rent)
        let text = FinanceBudgeting.exportText(state, today: "2026-11-10")
        XCTAssertTrue(text.hasPrefix(FinanceBudgeting.exportPrompt))
        XCTAssertTrue(text.contains("Переводы людям за период: 15 000 ₸"))
        XCTAssertTrue(text.contains("Magnum"))
        XCTAssertTrue(text.contains("Аренда: 120 000 ₸ в месяц"))
        XCTAssertFalse(text.contains("Айгерим"))
        XCTAssertFalse(text.contains("Ержан"))
        XCTAssertFalse(text.contains("7781"))
        XCTAssertFalse(text.contains("Halyk Bank"), "own transfers are not spending")
    }

    // MARK: Storage

    func testBudgetSurvivesEncodingAndDropsAnswersAboutDeletedRecords() throws {
        var state = november()
        state.budget?.savePercent = 15
        state.budget?.savingsGoalId = "cushion"
        state.budget?.obligationMerchants = ["иванов а.": "rent", "старый": "gone"]
        state.budget?.handledIncomes = ["missing"]
        let decoded = try JSONDecoder().decode(FinanceState.self, from: JSONEncoder().encode(state))
        let clean = try validateFinance(decoded)
        XCTAssertEqual(clean.budget?.savePercent, 15)
        XCTAssertEqual(clean.budget?.limits, ["Кафе и рестораны": 80_000_00])
        XCTAssertEqual(clean.budget?.obligationMerchants, ["иванов а.": "rent"])
        XCTAssertNil(clean.budget?.handledIncomes)

        let withoutGoal = try removeFinanceRecord(state: clean, id: "cushion")
        XCTAssertNil(withoutGoal.budget?.savingsGoalId)
        XCTAssertEqual(withoutGoal.budget?.savePercent, 15, "deleting a record keeps the plan")

        state.budget?.savePercent = 150
        XCTAssertThrowsError(try validateFinance(state))
    }

    func testOlderStateWithoutABudgetStillLoads() throws {
        let json = #"{"version":1,"records":[],"committedBatches":[]}"#
        let state = try JSONDecoder().decode(FinanceState.self, from: Data(json.utf8))
        XCTAssertNil(try validateFinance(state).budget)
    }

    func testMoneyFormatting() {
        XCTAssertEqual(FinanceBudgeting.money(1_240_000), "12 400 ₸")
        XCTAssertEqual(FinanceBudgeting.money(-300_000), "-3 000 ₸")
        XCTAssertEqual(FinanceBudgeting.money(0), "0 ₸")
        XCTAssertEqual(FinanceBudgeting.money(123_456_789_00), "123 456 789 ₸")
    }

    // MARK: Review fixes

    /// Kaspi closes on 1 Nov, Halyk on 10 Nov. Halyk's later operations are taken back to 1 Nov, so a hand-entered
    /// operation and a reconciliation in between still count.
    func testBalanceStartsFromTheOldestStatementSoLaterRecordsCount() throws {
        var state = FinanceState(records: [
            op("h0", "expense", 5_000, "2026-11-01", category: "Продукты", importId: "h"),
            op("h1", "expense", 30_000, "2026-11-05", category: "Продукты", importId: "h"),
            op("h2", "income", 10_000, "2026-11-08", category: "Зарплата", importId: "h"),
            op("m1", "expense", 4_000, "2026-11-06", category: "Кафе и рестораны"),
        ])
        state.imports = [
            FinanceImport(id: "k", bank: "Kaspi", fileName: "k.pdf", periodStart: nil, periodEnd: nil, importedAt: "2026-11-02",
                          count: 0, closingMinor: 100_000_00, closingDate: "2026-11-01"),
            FinanceImport(id: "h", bank: "Halyk", fileName: "h.pdf", periodStart: nil, periodEnd: nil, importedAt: "2026-11-10",
                          count: 3, closingMinor: 200_000_00, closingDate: "2026-11-10"),
        ]
        StatementImport.rebuildBalance(&state)
        let checkpoint = try XCTUnwrap(state.records.first { $0.id == StatementImport.balanceRecordId })
        XCTAssertEqual(checkpoint.date, "2026-11-01")
        XCTAssertEqual(checkpoint.amountMinor, 320_000_00)

        var snap = try FinanceBudgeting.snapshot(state, today: "2026-11-10")
        XCTAssertEqual(snap.onAccountsMinor, (300_000 - 4_000) * 100, "both closing balances, less the hand-entered spending")
        XCTAssertEqual(snap.asOf, "2026-11-01", "freshness is the oldest account's")

        // Editing or deleting an imported operation moves the checkpoint with it.
        var edited = try StatementImport.edit("h1", StatementImport.RecordEdit(
            title: "Магнум", amountMinor: 30_000_00, date: "2026-11-05", category: "Продукты", note: "", excluded: true,
            applyCategoryToMerchant: false
        ), in: state)
        XCTAssertEqual(try FinanceBudgeting.snapshot(edited, today: "2026-11-10").onAccountsMinor, (300_000 - 4_000) * 100)
        edited = try removeFinanceRecord(state: state, id: "h2")
        XCTAssertEqual(try FinanceBudgeting.snapshot(edited, today: "2026-11-10").onAccountsMinor, (300_000 - 4_000) * 100)

        // A hand-entered operation on the checkpoint day still counts after another import.
        state.records.append(op("m0", "expense", 1_000, "2026-11-01", category: "Наличные"))
        StatementImport.rebuildBalance(&state)
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").onAccountsMinor, (300_000 - 4_000 - 1_000) * 100)

        state = try FinanceBudgeting.reconcile(state, totalMinor: 250_000_00, today: "2026-11-07", id: "r1")
        snap = try FinanceBudgeting.snapshot(state, today: "2026-11-10")
        XCTAssertEqual(snap.onAccountsMinor, 260_000_00, "the reconciliation stands, plus Halyk's income after it")
    }

    /// Kaspi → Halyk on 5 Nov: Kaspi's statement ends on 1 Nov, so only Halyk's incoming side is known.
    func testLoneTransferFromAnOwnAccountIsNotCountedTwice() throws {
        var incoming = op("in", "income", 50_000, "2026-11-05", category: "Переводы", importId: "h")
        incoming.excluded = true
        incoming.note = StatementImport.ownTransferNote
        var state = FinanceState(records: [incoming])
        state.imports = [
            FinanceImport(id: "k", bank: "Kaspi", fileName: "k.pdf", periodStart: nil, periodEnd: nil, importedAt: "2026-11-02",
                          count: 0, closingMinor: 100_000_00, closingDate: "2026-11-01"),
            FinanceImport(id: "h", bank: "Halyk", fileName: "h.pdf", periodStart: nil, periodEnd: nil, importedAt: "2026-11-10",
                          count: 1, closingMinor: 200_000_00, closingDate: "2026-11-10"),
        ]
        StatementImport.rebuildBalance(&state)
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").onAccountsMinor, 250_000_00)
    }

    func testRealPaymentReplacesAMarkByHand() throws {
        var state = try FinanceBudgeting.togglePaidByHand(november(), obligationId: "rent", today: "2026-11-03")
        state.records.append(op("pay1", "expense", 120_000, "2026-11-06", merchant: "Иванов А."))
        state = try FinanceBudgeting.linkPayment(state, recordId: "pay1", obligationId: "rent")
        XCTAssertNil(state.budget?.manualPaid)
        XCTAssertNotNil(state.budget?.obligationMerchants)
        XCTAssertTrue(FinanceBudgeting.paymentStatus(state, obligation: rent, today: "2026-11-10").isPaid)
    }

    /// Marked by hand before the statement came: the imported rent is still offered, so it leaves flexible spending.
    func testAMarkByHandStillOffersTheImportedPayment() throws {
        var state = try FinanceBudgeting.togglePaidByHand(november(), obligationId: "rent", today: "2026-11-03")
        state.records.append(op("pay1", "expense", 118_000, "2026-11-06", merchant: "Аренда квартиры", importId: "k"))
        let match = try XCTUnwrap(FinanceBudgeting.paymentMatches(state, today: "2026-11-10").first { $0.obligationId == "rent" })
        XCTAssertEqual(match.recordId, "pay1")

        state = try FinanceBudgeting.linkPayment(state, recordId: match.recordId, obligationId: "rent")
        XCTAssertNil(state.budget?.manualPaid)
        XCTAssertTrue(FinanceBudgeting.paymentMatches(state, today: "2026-11-10").allSatisfy { $0.obligationId != "rent" },
                      "paid by the operation, nothing more to offer")
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").unpaidPaymentsMinor, 0)
    }

    /// Mondays of November 2026: 2, 9, 16, 23, 30. Charges already past are in the balance; only the ones ahead stay.
    func testWeeklyPaymentKeepsOnlyTheChargesAhead() throws {
        let gym = FinanceRecord(id: "gym", kind: "obligation", title: "Зал", amountMinor: 10_000_00, date: "2026-11-02", frequency: "weekly")
        var state = FinanceState(records: [FinanceRecord(id: "b", kind: "balance", title: "Остаток", amountMinor: 300_000_00, date: "2026-11-01"), gym])

        var status = FinanceBudgeting.paymentStatus(state, obligation: gym, today: "2026-11-10")
        XCTAssertEqual(status.chargesLeft, 3)
        XCTAssertEqual(status.unpaidMinor, 30_000_00)
        XCTAssertFalse(status.isDue)
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").unpaidPaymentsMinor, 30_000_00)

        state.records.append(op("g16", "expense", 10_000, "2026-11-16", category: "Развлечения"))
        state = try FinanceBudgeting.linkPayment(state, recordId: "g16", obligationId: "gym")
        status = FinanceBudgeting.paymentStatus(state, obligation: gym, today: "2026-11-16")
        XCTAssertTrue(status.isDue && status.isPaid)
        XCTAssertEqual(status.unpaidMinor, 20_000_00)

        state = try FinanceBudgeting.togglePaidByHand(state, obligationId: "gym", today: "2026-11-23")
        status = FinanceBudgeting.paymentStatus(state, obligation: gym, today: "2026-11-23")
        XCTAssertTrue(status.markedByHand)
        XCTAssertEqual(status.unpaidMinor, 10_000_00)
    }

    func testPaymentMarkedPaidByHandAndUnmarked() throws {
        var state = try FinanceBudgeting.togglePaidByHand(november(), obligationId: "rent", today: "2026-11-10")
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").unpaidPaymentsMinor, 0)
        XCTAssertTrue(FinanceBudgeting.paymentStatus(state, obligation: rent, today: "2026-11-10").markedByHand)
        XCTAssertEqual(FinanceBudgeting.review(state, month: "2026-11", today: "2026-11-30").paidPayments, ["Аренда"])
        XCTAssertFalse(FinanceBudgeting.paymentStatus(state, obligation: rent, today: "2026-12-03").isPaid, "the mark is for one month")

        state = try FinanceBudgeting.togglePaidByHand(state, obligationId: "rent", today: "2026-11-10")
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").unpaidPaymentsMinor, 120_000_00)
    }

    func testAPaymentIsNeverClosedTwiceAndAnOperationPaysOnlyOne() throws {
        var state = november()
        state.records.append(FinanceRecord(id: "phone", kind: "obligation", title: "Связь", amountMinor: 5_000_00, date: "2026-09-01", frequency: "monthly"))
        state.records.append(op("pay1", "expense", 120_000, "2026-11-06", merchant: "Иванов А."))
        state.records.append(op("pay2", "expense", 118_000, "2026-11-07", merchant: "Иванов А."))
        state = try FinanceBudgeting.linkPayment(state, recordId: "pay1", obligationId: "rent")
        XCTAssertThrowsError(try FinanceBudgeting.linkPayment(state, recordId: "pay2", obligationId: "rent"))
        XCTAssertThrowsError(try FinanceBudgeting.linkPayment(state, recordId: "pay1", obligationId: "phone"))
        XCTAssertTrue(FinanceBudgeting.paymentMatches(state, today: "2026-11-10").allSatisfy { $0.obligationId != "rent" })

        let candidates = FinanceBudgeting.paymentCandidates(state, obligation: state.records.first { $0.id == "phone" }!, today: "2026-11-10")
        XCTAssertEqual(candidates.first?.id, "cafe1", "the closest amount first, linked operations left out")
        XCTAssertFalse(candidates.contains { $0.id == "pay1" })
    }

    func testSetAsideGrowsTheTargetOnlyWhenAskedAndOncePerIncome() throws {
        var state = FinanceState(records: [op("sal", "income", 250_000, "2026-11-05", category: "Зарплата"), cushion])
        XCTAssertThrowsError(try FinanceBudgeting.setAside(state, amountMinor: 460_000_00, goalId: "cushion"))
        let grown = try FinanceBudgeting.setAside(state, amountMinor: 460_000_00, goalId: "cushion", raiseTarget: true)
        XCTAssertEqual(grown.records.first { $0.id == "cushion" }?.savedMinor, 510_000_00)
        XCTAssertEqual(grown.records.first { $0.id == "cushion" }?.amountMinor, 510_000_00)

        state = try FinanceBudgeting.setAside(state, amountMinor: 25_000_00, goalId: "cushion", incomeId: "sal")
        XCTAssertThrowsError(try FinanceBudgeting.setAside(state, amountMinor: 25_000_00, goalId: "cushion", incomeId: "sal"))
        XCTAssertThrowsError(try FinanceBudgeting.setAside(state, amountMinor: 0, goalId: "cushion")) {
            XCTAssertFalse(($0 as? FinanceError)?.errorDescription?.contains("Nothing") ?? true)
        }
    }

    func testNoSetAsideOfferForOwnTransfersOrTopUps() {
        var own = op("own", "income", 50_000, "2026-11-05", category: "Переводы", merchant: "Kaspi Gold")
        own.note = StatementImport.ownTransferNote
        let state = FinanceState(records: [own, op("top", "income", 40_000, "2026-11-06", category: "Пополнения"), cushion])
        XCTAssertTrue(FinanceBudgeting.setAsideOffers(state, today: "2026-11-10").isEmpty)
    }

    func testPeopleAndCardNumbersStayOutOfHintsAndTheExport() {
        for name in ["Айгерим К.", "Иванов А.А.", "А. Иванов", "ИП Сейткали", "ИВАНОВ АЛЕКСЕЙ", "Айгерим Кайратовна", "AIGERIM K."] {
            XCTAssertTrue(FinanceBudgeting.looksLikePerson(name), name)
        }
        for name in ["Magnum", "ТОО ПРИМЕР", "MAGNUM CASH&CARRY", "Coffee Point", "Kaspi Gold", "Apple TV", "Beeline KZ",
                     "АПТЕКА ПЛЮС", "ЯНДЕКС ТАКСИ", "КАФЕ ДАСТАРХАН"] {
            XCTAssertFalse(FinanceBudgeting.looksLikePerson(name), name)
        }
        XCTAssertEqual(FinanceBudgeting.safeName("Halyk 4400 43** **** 1234"), "Halyk …")
        XCTAssertNil(FinanceBudgeting.safeName("ИП Сейткали"))

        var state = feed()
        state.records.append(op("ip", "expense", 9_000, "2026-11-04", category: "Покупки", merchant: "ИП Сейткали", importId: "k"))
        state.records.append(op("card", "expense", 7_000, "2026-11-04", category: "Покупки", merchant: "Halyk 4400 43** **** 1234", importId: "h"))
        let text = FinanceBudgeting.exportText(state, today: "2026-11-10")
        XCTAssertFalse(text.contains("Сейткали"))
        XCTAssertFalse(text.contains("1234"))
        XCTAssertTrue(text.contains("Halyk …"))
    }

    func testTypedCategoriesMatchStatementsAndOldOnesAreRead() throws {
        XCTAssertEqual(try parseFinanceText("Купил продукты на 8000", today: "2026-11-10").first?.category, "Продукты")
        XCTAssertEqual(try parseFinanceText("Оплатил интернет 5000", today: "2026-11-10").first?.category, "Связь и интернет")

        let state = FinanceState(records: [
            FinanceRecord(id: "a", kind: "expense", title: "Обед", amountMinor: 2_500_00, date: "2026-05-01", category: "Еда"),
            FinanceRecord(id: "b", kind: "expense", title: "Магнум", amountMinor: 8_000_00, date: "2026-05-01", category: "Еда"),
            FinanceRecord(id: "c", kind: "expense", title: "Тариф", amountMinor: 5_000_00, date: "2026-05-01", category: "Связь"),
        ])
        let clean = try validateFinance(state)
        XCTAssertEqual(clean.records.map(\.category), ["Кафе и рестораны", "Продукты", "Связь и интернет"])
        XCTAssertEqual(try validateFinance(clean), clean, "reading again changes nothing")
    }

    func testNoRunOutForecastInTheFirstDays() throws {
        var state = FinanceState(records: [op("t1", "expense", 15_000, "2026-11-02", category: "Транспорт")])
        state = try FinanceBudgeting.setLimits(state, ["Транспорт": 30_000_00])
        let early = FinanceBudgeting.limitStatuses(state, month: "2026-11", today: "2026-11-03")
        XCTAssertNil(early.first?.runsOutDay, "one purchase on the 2nd sets no pace")
    }

    func testTypedAmountsAreBounded() {
        XCTAssertEqual(FinanceText.tenge("25 000"), 25_000)
        XCTAssertNil(FinanceText.tenge(""))
        XCTAssertNil(FinanceText.tenge("999999999999"), "twelve digits would overflow minor units in a sum")
        XCTAssertNil(FinanceText.tenge("99999999999999999999"))
    }

    /// Cash or a deposit no statement shows: it fills the envelope but never comes out of «Чистыми».
    func testMoneyOutsideTheAccountsFillsTheEnvelopeButNotTheBalance() throws {
        var state = november()
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").cleanMinor, 70_000_00)

        state = try FinanceBudgeting.setAside(state, amountMinor: 30_000_00, goalId: "cushion", outsideAccounts: true)
        var snap = try FinanceBudgeting.snapshot(state, today: "2026-11-10")
        XCTAssertEqual(snap.cleanMinor, 70_000_00, "outside money leaves «Чистыми» alone")
        XCTAssertEqual(snap.reservedMinor, 50_000_00)
        XCTAssertEqual(snap.outsideMinor, 30_000_00)
        XCTAssertEqual(state.records.first { $0.id == "cushion" }?.savedMinor, 80_000_00)

        state = try FinanceBudgeting.setAside(state, amountMinor: 10_000_00, goalId: "cushion")
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").cleanMinor, 60_000_00)

        XCTAssertThrowsError(try FinanceBudgeting.withdraw(state, amountMinor: 40_000_00, goalId: "cushion", outsideAccounts: true))
        state = try FinanceBudgeting.withdraw(state, amountMinor: 20_000_00, goalId: "cushion", outsideAccounts: true)
        snap = try FinanceBudgeting.snapshot(state, today: "2026-11-10")
        XCTAssertEqual(snap.cleanMinor, 60_000_00, "taking outside money back changes nothing on the accounts")
        XCTAssertEqual(snap.outsideMinor, 10_000_00)

        XCTAssertThrowsError(try FinanceBudgeting.withdraw(state, amountMinor: 61_000_00, goalId: "cushion"),
                             "only 60 000 of the envelope is on the accounts")
        state = try FinanceBudgeting.withdraw(state, amountMinor: 10_000_00, goalId: "cushion")
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").cleanMinor, 70_000_00)
        XCTAssertTrue(FinanceBudgeting.exportText(state, today: "2026-11-10").contains("вне счетов"))

        // Lowering what is saved by hand lowers the outside part with it.
        let i = try XCTUnwrap(state.records.firstIndex { $0.id == "cushion" })
        state.records[i].savedMinor = 4_000_00
        XCTAssertEqual(try validateFinance(state).records[i].outsideMinor, 4_000_00)
    }

    // MARK: Hand-entered history

    func testManualHistoryListsWhatWasTypedLastFirstWithoutStatementsOrReconciliations() {
        var state = november()
        state.records.append(op("imported", "expense", 5_000, "2026-11-06", importId: "kaspi-1"))
        state.records.append(FinanceRecord(id: StatementImport.balanceRecordId, kind: "balance", title: "Остаток по выпискам", amountMinor: 1_00, date: "2026-11-06"))
        state.records.append(FinanceRecord(id: "rec", kind: "balance", title: FinanceBudgeting.reconcileTitle, amountMinor: 1_00, date: "2026-11-07"))
        XCTAssertEqual(FinanceBudgeting.manualEntries(state).map(\.id), ["rent", "cushion", "cafe1", "b1"])
    }

    func testEditingAHandEnteredRecordRecountsTheBalanceAndClean() throws {
        var state = november()
        state = try FinanceBudgeting.editManual(state, id: "cafe1", .init(kind: "expense", title: "Кофе", amountMinor: 30_000_00, date: "2026-11-05", category: "Кафе и рестораны"))
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").onAccountsMinor, 290_000_00)
        XCTAssertEqual(state.records.first { $0.id == "cafe1" }?.title, "Кофе")

        state.records[1].obligationId = "rent"
        state = try FinanceBudgeting.editManual(state, id: "cafe1", .init(kind: "income", title: "Возврат", amountMinor: 30_000_00, date: "2026-11-05", category: "Пополнения", note: " вернули "))
        let fixed = try XCTUnwrap(state.records.first { $0.id == "cafe1" })
        XCTAssertEqual(fixed.kind, "income")
        XCTAssertNil(fixed.obligationId, "income never pays a planned payment")
        XCTAssertEqual(fixed.note, "вернули")
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").onAccountsMinor, 350_000_00)

        state = try removeFinanceRecord(state: state, id: "cafe1")
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").onAccountsMinor, 320_000_00)
    }

    func testEditingKeepsKindsAndRefusesWhatCannotBeRight() throws {
        var state = november()
        state.records.append(op("imported", "expense", 5_000, "2026-11-06", importId: "kaspi-1"))
        XCTAssertThrowsError(try FinanceBudgeting.editManual(state, id: "imported", .init(kind: "expense", title: "x", amountMinor: 1_00, date: "2026-11-06")))
        XCTAssertThrowsError(try FinanceBudgeting.editManual(state, id: "cushion", .init(kind: "goal", title: "Подушка", amountMinor: 40_000_00)),
                             "a target below what is already saved")
        XCTAssertThrowsError(try FinanceBudgeting.editManual(state, id: "cafe1", .init(kind: "expense", title: "  ", amountMinor: 1_00, date: "2026-11-05")))
        XCTAssertThrowsError(try FinanceBudgeting.editManual(state, id: "cafe1", .init(kind: "expense", title: "Кофе", amountMinor: 0, date: "2026-11-05")))

        state = try FinanceBudgeting.editManual(state, id: "rent", .init(kind: "income", title: "Аренда", amountMinor: 130_000_00, frequency: "weekly"))
        let rent = try XCTUnwrap(state.records.first { $0.id == "rent" })
        XCTAssertEqual(rent.kind, "obligation", "only spending and income swap")
        XCTAssertEqual(rent.frequency, "weekly")
        XCTAssertEqual(rent.amountMinor, 130_000_00)

        state = try FinanceBudgeting.editManual(state, id: "b1", .init(kind: "balance", title: "Остаток", amountMinor: 0, date: "2026-11-02"))
        XCTAssertEqual(state.records.first { $0.id == "b1" }?.date, "2026-11-02")
    }

    func testAHandEnteredRecordCanLeaveTheTotalsAndComeBack() throws {
        var state = november()
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").onAccountsMinor, 300_000_00)
        state = try FinanceBudgeting.editManual(state, id: "cafe1", .init(kind: "expense", title: "Кофе", amountMinor: 20_000_00, date: "2026-11-05", excluded: true))
        XCTAssertEqual(state.records.first { $0.id == "cafe1" }?.excluded, true)
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").onAccountsMinor, 320_000_00)
        state = try FinanceBudgeting.editManual(state, id: "cafe1", .init(kind: "expense", title: "Кофе", amountMinor: 20_000_00, date: "2026-11-05", excluded: false))
        XCTAssertNil(state.records.first { $0.id == "cafe1" }?.excluded)
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").onAccountsMinor, 300_000_00)
    }

    /// «Коплю на подушку 600к» about an envelope that already exists keeps its outside part and note.
    func testAPhraseAboutAnExistingEnvelopeKeepsWhatItDidNotSay() throws {
        var state = try FinanceBudgeting.setAside(november(), amountMinor: 30_000_00, goalId: "cushion", outsideAccounts: true)
        let i = try XCTUnwrap(state.records.firstIndex { $0.id == "cushion" })
        state.records[i].note = "наличные дома"
        let draft = FinanceDraft(kind: "goal", title: "подушка", amountMinor: 600_000_00, savedMinor: 80_000_00)
        state = try commitFinance(state: state, drafts: [draft], batchId: "phrase", nowDate: "2026-11-10")
        let cushion = try XCTUnwrap(state.records.first { $0.id == "cushion" })
        XCTAssertEqual(state.records.filter { $0.kind == "goal" }.count, 1)
        XCTAssertEqual(cushion.amountMinor, 600_000_00)
        XCTAssertEqual(cushion.outsideMinor, 30_000_00)
        XCTAssertEqual(cushion.note, "наличные дома")
        XCTAssertEqual(try FinanceBudgeting.snapshot(state, today: "2026-11-10").cleanMinor, 70_000_00)
    }
}
