import XCTest
@testable import SanPlan

/// Money by account (docs/finance/ACCOUNTS-SPEC-2026-11-27.md §10). The fixtures are real statements with every
/// name and number replaced and every amount doubled, so Halyk's 200 ₸ fee reads as 400 ₸ in them.
final class FinanceAccountsTests: XCTestCase {
    private let fees = FinanceLedger.feeTable
    private let version = FinanceLedger.parserVersion

    override func setUp() {
        super.setUp()
        FinanceLedger.feeTable = [("2000-01-01", 40_000), ("2026-11-27", 50_000)]
    }

    override func tearDown() {
        FinanceLedger.feeTable = fees
        FinanceLedger.parserVersion = version
        super.tearDown()
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> ParsedStatement {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).txt")
        return try BankStatementParser.parse(String(contentsOf: url, encoding: .utf8))
    }

    private func apply(_ statement: ParsedStatement, _ id: String, to state: FinanceState) throws -> FinanceState {
        let preview = StatementImport.preview(statement, importId: id, rules: state.merchantCategories)
        return try StatementImport.apply(preview, to: state, importId: id, fileName: "\(id).pdf", today: "2026-11-27")
    }

    /// A made-up Halyk report: one card «0001» and one account «0003».
    private func halyk(_ lines: [ParsedStatement.Transaction], counterparties: [Int: String] = [:]) -> ParsedStatement {
        ParsedStatement(bank: .halyk, periodStart: "2026-03-01", periodEnd: "2026-03-31", transactions: lines,
                        account: ParsedStatement.allAccounts, ownerFirstName: "Арман", ownerSurname: "Тестов",
                        cards: ["0001"], counterparties: counterparties)
    }

    private func kaspi(_ lines: [ParsedStatement.Transaction]) -> ParsedStatement {
        ParsedStatement(bank: .kaspi, periodStart: "2026-01-01", periodEnd: "2026-11-27", transactions: lines,
                        account: "0006", identifiers: ["card:0006"])
    }

    private func line(_ date: String, _ amount: Int64, _ operation: String, _ details: String, account: String? = nil,
                      bankCategory: String? = nil) -> ParsedStatement.Transaction {
        .init(date: date, amountMinor: amount, operation: operation, details: details, account: account, bankCategory: bankCategory)
    }

    private var outgoing: ParsedStatement.Transaction {
        line("2026-03-10", -5_000_000, "Перевод", "Исходящий перевод", account: "0001")
    }

    private func arrival(_ date: String) -> ParsedStatement.Transaction {
        line(date, 5_000_000, "Пополнение", "С карты другого банка")
    }

    private func records(_ state: FinanceState, of importId: String) -> [FinanceRecord] {
        state.records.filter { $0.importId == importId }
    }

    // MARK: - Fixtures

    func testEveryFixtureReadsFully() throws {
        // Rows of the file; the year report also has three rows of bonus points, which are not money.
        let expected = ["halyk-report-week": 11, "halyk-report-partial": 11, "halyk-report-month": 34,
                        "halyk-report-year": 113, "kaspi-gold": 1617, "kaspi-dep": 31]
        for (name, count) in expected {
            // The parser itself refuses a file whose lines do not add up to the header's totals.
            XCTAssertEqual(try fixture(name).transactions.count, count, name)
        }
    }

    func testWeekMonthAndYearInAnyOrderGiveTheYearWithoutDuplicates() throws {
        func signature(_ state: FinanceState) -> [String] {
            state.records.map { "\($0.fp ?? $0.id)|\($0.amountMinor ?? 0)|\($0.excluded == true)|\($0.status ?? "")" }.sorted()
        }
        let year = try apply(fixture("halyk-report-year"), "year", to: FinanceState())
        for order in [["week", "partial", "month", "year", "week"], ["year", "month", "week", "year"], ["month", "year", "partial"]] {
            var state = FinanceState()
            for (n, name) in order.enumerated() {
                do {
                    state = try apply(fixture("halyk-report-\(name)"), "\(name)\(n)", to: state)
                } catch StatementError.alreadyImported {}
            }
            XCTAssertEqual(signature(state), signature(year), order.joined(separator: ", "))
        }
    }

    func testTransfersBetweenOwnCardsArePairedAndNotSpending() throws {
        let state = try apply(fixture("halyk-report-year"), "h", to: FinanceState())
        let own = state.records.filter { $0.hint == "own-card" }
        XCTAssertEqual(own.count, 22)
        XCTAssertTrue(own.allSatisfy { $0.excluded == true && $0.pairedWith != nil })
    }

    func testHalykAndKaspiYearsPairOwnTransfersAndKeepFeesApart() throws {
        let halykYear = try fixture("halyk-report-year"), gold = try fixture("kaspi-gold")
        for halykFirst in [true, false] {
            var state = FinanceState()
            for statement in halykFirst ? [halykYear, gold] : [gold, halykYear] {
                state = try apply(statement, statement.bank.rawValue, to: state)
            }
            let byId = Dictionary(state.records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            func partner(_ r: FinanceRecord) -> FinanceRecord? { r.pairedWith.flatMap { byId[$0] } }

            let named = state.records.filter { $0.hint?.hasPrefix("name:АРМАН Т.|Halyk") == true }
            XCTAssertEqual(named.count, 5)
            for r in named {
                XCTAssertEqual(partner(r)?.importId, "Halyk", r.date ?? "")
                XCTAssertEqual(partner(r)?.amountMinor, r.amountMinor, r.date ?? "")
                XCTAssertEqual(r.excluded, true)
            }

            // «Transfer to card *0006» −20 400: 20 000 arrived, 400 is the fee.
            let card = try XCTUnwrap(state.records.first { $0.hint == "card:0006" })
            XCTAssertEqual(card.amountMinor, 2_000_000)
            XCTAssertEqual(partner(card)?.accountId, "acc-kaspi-card-0006")

            let charged = records(state, of: "Halyk").filter { $0.hint == "fee" }
            XCTAssertEqual(charged.count, 7)
            XCTAssertTrue(charged.allSatisfy { $0.amountMinor == 40_000 && $0.excluded != true && $0.category == "Комиссии" })
            XCTAssertEqual(records(state, of: "Halyk").count, 113 + 1, "Bonus points are not money; one fee was split off")
        }
    }

    func testKaspiGoldYearGoesFromOneBalanceToTheOther() throws {
        let statement = try fixture("kaspi-gold")
        XCTAssertEqual(statement.transactions.reduce(Int64(0)) { $0 + $1.amountMinor }, 56_728 - 401_068)
        let state = try apply(statement, "k", to: FinanceState())
        let gold = try XCTUnwrap(state.ledger?.accounts.first { $0.id == "acc-kaspi-card-0006" })
        XCTAssertEqual(FinanceLedger.balance(gold, on: "2026-11-27", in: state), 56_728)
        XCTAssertEqual(FinanceLedger.balance(gold, on: "2025-11-26", in: state), 401_068)
    }

    func testKaspiDepositMatchesItsColumnAndPairsWithGold() throws {
        var state = try apply(fixture("kaspi-gold"), "k", to: FinanceState())
        state = try apply(fixture("kaspi-dep"), "d", to: state)
        let deposits = state.ledger?.accounts.filter { $0.kind == "deposit" } ?? []
        XCTAssertEqual(deposits.count, 1, "The statement joins the deposit Gold's transfers had named")
        let deposit = try XCTUnwrap(deposits.first)
        let column: [(String, Int64)] = [("2026-09-25", 0), ("2026-09-26", 1_000_000), ("2026-10-03", 6_005_876),
                                         ("2026-11-08", 654_980), ("2026-11-17", 4_054_980), ("2026-11-27", 1_934_980)]
        for (date, minor) in column {
            XCTAssertEqual(FinanceLedger.balance(deposit, on: date, in: state), minor, date)
        }
        let lines = records(state, of: "d")
        let moved = lines.filter { $0.hint == "deposit" }
        XCTAssertEqual(moved.count, 29)
        XCTAssertTrue(moved.allSatisfy { $0.pairedWith != nil && $0.excluded == true })
        let interest = lines.filter { $0.hint == nil }
        XCTAssertEqual(interest.compactMap(\.amountMinor).sorted(), [5_876, 49_104])
        XCTAssertTrue(interest.allSatisfy { $0.kind == "income" && $0.excluded != true })
    }

    // MARK: - Between banks

    func testOutgoingTransferWaitsForKaspiThenPairsADayApart() throws {
        var state = try apply(halyk([outgoing]), "h", to: FinanceState())
        XCTAssertEqual(state.records.map(\.status), ["pendingPair"])
        XCTAssertEqual(state.records.map(\.excluded), [true])
        let waiting = ImportReport(importIds: ["h"], in: state)
        XCTAssertEqual(waiting.waiting, ["Kaspi": 1])
        XCTAssertEqual(waiting.periodStart, "2026-03-01")
        XCTAssertEqual(waiting.transfers, 0)

        state = try apply(kaspi([arrival("2026-03-11")]), "k", to: state)
        XCTAssertTrue(state.records.allSatisfy { $0.pairedWith != nil && $0.excluded == true && $0.status == nil })
        XCTAssertEqual(ImportReport(importIds: ["h", "k"], in: state).transfers, 1, "A pair counts once")
    }

    func testTwoCandidatesAreAskedAboutAndTheAnswerPairs() throws {
        var state = try apply(halyk([outgoing]), "h", to: FinanceState())
        state = try apply(kaspi([arrival("2026-03-10"), arrival("2026-03-11")]), "k", to: state)
        let sent = try XCTUnwrap(records(state, of: "h").first)
        XCTAssertEqual(sent.status, "review")
        XCTAssertNil(sent.pairedWith)
        let offered = FinanceLedger.candidates(for: sent, in: state)
        XCTAssertEqual(offered.count, 2)

        let chosen = try XCTUnwrap(offered.last)
        state = try FinanceLedger.decide(sent.id, .pair(chosen.id), in: state)
        XCTAssertEqual(state.records.first { $0.id == sent.id }?.pairedWith, chosen.id)
        XCTAssertNil(state.records.first { $0.id == sent.id }?.status)
    }

    func testTransferBetweenTwoHalykAccountsNamingTheOwnerIsPaired() throws {
        let incoming = line("2026-03-10", 5_000_000, "Перевод", "Арман Тестов", account: "0003")
        let state = try apply(halyk([outgoing, incoming], counterparties: [1: "Арман Тестов"]), "h", to: FinanceState())
        XCTAssertTrue(state.records.allSatisfy { $0.pairedWith != nil && $0.excluded == true })
    }

    // MARK: - Balances and totals

    func testBalanceOfEveryMonthIsCountedFromTodaysAnchor() throws {
        var state = try apply(kaspi([line("2026-01-10", 1_000_000, "Пополнение", "Зарплата"),
                                     line("2026-02-15", -200_000, "Покупка", "MAGNUM"),
                                     line("2026-03-01", -50_000, "Покупка", "MAGNUM")]), "k", to: FinanceState())
        let id = try XCTUnwrap(state.ledger?.accounts.first?.id)
        state = try FinanceLedger.setAnchor(id, minor: 5_000_000, date: "2026-11-27", in: state)
        let account = try XCTUnwrap(state.ledger?.accounts.first)
        let ends: [(String, Int64)] = [("2025-12-31", 4_250_000), ("2026-01-01", 4_250_000), ("2026-01-31", 5_250_000),
                                       ("2026-02-01", 5_250_000), ("2026-02-28", 5_050_000), ("2026-03-01", 5_000_000),
                                       ("2026-11-30", 5_000_000)]
        for (date, minor) in ends {
            XCTAssertEqual(FinanceLedger.balance(account, on: date, in: state), minor, date)
        }
    }

    func testRefundReducesTheCategorysSpending() throws {
        let state = try apply(halyk([
            line("2026-03-02", -100_000, "Покупка", "MAGNUM", account: "0001", bankCategory: "Supermarkets"),
            line("2026-03-05", 30_000, "Зачисление", "MAGNUM", account: "0001", bankCategory: "Supermarkets"),
        ]), "h", to: FinanceState())
        let insights = FinanceInsights.compute(state, month: "2026-03", today: "2026-03-31")
        XCTAssertEqual(insights.expenseMinor, 70_000)
        XCTAssertEqual(insights.incomeMinor, 0)
        XCTAssertEqual(insights.categories.map(\.amountMinor), [70_000])
    }

    func testCashWithdrawalIsATransferToCash() throws {
        let state = try apply(kaspi([line("2026-03-02", -2_000_000, "Снятие", "Банкомат Kaspi")]), "k", to: FinanceState())
        XCTAssertEqual(state.records.first?.excluded, true)
        XCTAssertEqual(state.records.first?.transfer?.to, FinanceLedger.cashId)
        XCTAssertTrue(state.ledger?.accounts.contains { $0.id == FinanceLedger.cashId } == true)
    }

    // MARK: - Re-reading and starting over

    func testOwnersEditsSurviveANewParserVersion() throws {
        var state = try apply(fixture("halyk-report-week"), "w", to: FinanceState())
        let spent = state.records.filter { $0.kind == "expense" && $0.hint == nil }
        XCTAssertGreaterThan(spent.count, 1)
        let edited = spent[0], deleted = spent[1]
        let edit = StatementImport.RecordEdit(title: "Подарок маме", amountMinor: try XCTUnwrap(edited.amountMinor),
                                              date: try XCTUnwrap(edited.date), category: "Подарки", note: "моё", excluded: false)
        state = try StatementImport.edit(edited.id, edit, in: state)
        state = try removeFinanceRecord(state: state, id: deleted.id)
        XCTAssertNil(FinanceLedger.upkeep(state), "Nothing to re-read yet")

        FinanceLedger.parserVersion += 1
        let next = try XCTUnwrap(FinanceLedger.upkeep(state))
        let kept = try XCTUnwrap(next.records.first { $0.fp == edited.fp })
        XCTAssertEqual(kept.title, "Подарок маме")
        XCTAssertEqual(kept.category, "Подарки")
        XCTAssertEqual(kept.note, "моё")
        XCTAssertFalse(next.records.contains { $0.fp == deleted.fp }, "A deleted operation stays deleted")
        XCTAssertEqual(next.records.count, state.records.count)
        XCTAssertNil(FinanceLedger.upkeep(next))
    }

    func testClearingFinancesKeepsOnlyEnvelopesAndCategoryRules() throws {
        var goal = FinanceRecord(id: "g", kind: "goal", title: "Отпуск", amountMinor: 100_000, date: "2026-01-01")
        goal.savedMinor = 40_000
        var state = FinanceState(records: [goal], merchantCategories: ["magnum": "Продукты"])
        state = try apply(fixture("halyk-report-week"), "w", to: state)
        let cleared = try FinanceLedger.cleared(state)
        XCTAssertEqual(cleared.records.map(\.id), ["g"])
        XCTAssertEqual(cleared.records.first?.savedMinor, 40_000)
        XCTAssertNil(cleared.imports)
        XCTAssertNil(cleared.ledger)
        XCTAssertEqual(cleared.merchantCategories, ["magnum": "Продукты"])
    }

    @MainActor
    func testTypedBalanceAndGapText() {
        XCTAssertEqual(AnchorSheet.minor("152 300,50"), 15_230_050)
        XCTAssertEqual(AnchorSheet.minor("−5000"), -500_000)
        XCTAssertEqual(AnchorSheet.minor("0"), 0)
        XCTAssertNil(AnchorSheet.minor("много"))
        XCTAssertEqual(ImportReport.gapText("Kaspi Gold", from: "2026-03-01", to: "2026-03-15"), "Kaspi Gold: нет данных с 01.03 по 15.03")
    }
}
