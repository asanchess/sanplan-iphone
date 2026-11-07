import PDFKit
import UIKit
import XCTest
@testable import SanPlan

/// Anonymised statements in the cell-per-line layout of the real Kaspi Gold and Halyk PDFs (as their text extracts).
/// No real data lives in the repository.
final class StatementImportTests: XCTestCase {
    static let kaspiText = """
    АО «Kaspi Bank», БИК CASPKZKA, www.kaspi.kz
    СПРАВКА
    об остатке на счете
    АО  «Kaspi Bank» подтверждает, что Тестов Арман Ержанович, ИИН 000000000000, действительно
    является клиентом со счетом KZ00722C000000000001.
    Выписка по Kaspi Gold за период с 01.11.25 по 30.11.25 прилагается.

    АО «Kaspi Bank», БИК CASPKZKA, www.kaspi.kz
    Приложение к Справке №1000000001 от 30 ноября 2025
    ВЫПИСКА
    по Kaspi Gold за период с 01.11.25 по 30.11.25
    Номер счета:
    KZ00722C000000000001
    Доступно на 30.11.25:
    + 357 549,50 ₸
    Краткое содержание операций по карте:
    Доступно на 01.11.25
    + 10 000,00 ₸
      Пополнения
    + 420 000,00 ₸
    Дата
    Сумма
    Операция       Детали
    03.11.25
    - 2 500,00 ₸
    Покупка      MAGNUM CASH&CARRY
    04.11.25
    + 50 000,00 ₸
    Поступление со      С Kaspi Депозита
    своего счета
    05.11.25
    - 1 200,00 ₸
    Покупка      Yandex Go
    (- 2,40 USD)
    06.11.25
    + 350 000,00 ₸
    Пополнение      ТОО Ромашка зарплата

    АО «Kaspi Bank», БИК CASPKZKA, www.kaspi.kz
    Приложение к Справке №1000000001 от 30 ноября 2025
    07.11.25
    - 15 000,00 ₸
    Перевод      Т. Марина
    08.11.25
    - 20 000,00 ₸
    Снятие      Банкомат Kaspi
    09.11.25
    - 3 750,50 ₸
    Покупка      MAGNUM CASH&CARRY
    10.11.25
    - 30 000,00 ₸
    Перевод на свой      На Kaspi Депозит
    счет
    11.11.25
    + 20 000,00 ₸
    Пополнение      АРМАН Т., Halyk Bank
        - Сумма заблокирована. Банк ожидает подтверждения от платежной системы.

    АО «Kaspi Bank», БИК CASPKZKA, www.kaspi.kz
    Раздел «Краткое содержание операций по карте», в строках «Поступления со своих счетов» содержит информацию об операциях клиента между счетами в Kaspi.
    """

    static let kaspiExpected: [ParsedStatement.Transaction] = [
        .init(date: "2025-11-03", amountMinor: -250_000, operation: "Покупка", details: "MAGNUM CASH&CARRY"),
        .init(date: "2025-11-04", amountMinor: 5_000_000, operation: "Поступление со своего счета", details: "С Kaspi Депозита"),
        .init(date: "2025-11-05", amountMinor: -120_000, operation: "Покупка", details: "Yandex Go"),
        .init(date: "2025-11-06", amountMinor: 35_000_000, operation: "Пополнение", details: "ТОО Ромашка зарплата"),
        .init(date: "2025-11-07", amountMinor: -1_500_000, operation: "Перевод", details: "Т. Марина"),
        .init(date: "2025-11-08", amountMinor: -2_000_000, operation: "Снятие", details: "Банкомат Kaspi"),
        .init(date: "2025-11-09", amountMinor: -375_050, operation: "Покупка", details: "MAGNUM CASH&CARRY"),
        .init(date: "2025-11-10", amountMinor: -3_000_000, operation: "Перевод на свой счет", details: "На Kaspi Депозит"),
        .init(date: "2025-11-11", amountMinor: 2_000_000, operation: "Пополнение", details: "АРМАН Т., Halyk Bank"),
    ]

    static let halykText = """
    Statement of account: KZ000000000000000002
    1
    JSC "Halyk Savings Bank of Kazakhstan"
    across Kazakhstan, www.halykbank.kz
    Account statement
    Customer
    Name: ARMAN TESTOV
    Date of statement: 30.11.2025
    Period of statement: between 01.11.2025 and 30.11.2025
    Account number: KZ000000000000000002
    Account currency: KZT
    Account opening date: 01.10.2025
    Opening balance: 0,00
    Closing balance: 195 400,00
    Date of
    transaction
    Transaction description
    Fee
    Card number/account
    number
    Total:
    230 000,00
    -34 500,00
    -100,00
    02.11.2025
    03.11.2025
    Merchant payment
    transaction SMALL
    ALMATY
    -4 200,00
    KZT
    0,00
    -4 200,00
    0,00
    400000******0001
    04.11.2025
    04.11.2025
    Receipt of transfer
    100 000,00
    KZT
    100 000,00
    0,00
    0,00
    KZ000000000000000002
    05.11.2025
    06.11.2025
    Merchant payment
    transaction OPENAI *CHATGPT
    SUBSCR
    -10,00
    USD
    0,00
    -5 300,00
    0,00
    400000******0001
    10.11.2025
    10.11.2025
    Transfer to another card
    -20 000,00
    KZT
    0,00
    -20 000,00
    0,00
    400000******0001
    12.11.2025
    13.11.2025
    Recharge card account
    through payment terminal
    13080047
    130 000,00
    KZT
    130 000,00
    0,00
    0,00
    KZ000000000000000002
    (KZT)
    Statement of account: KZ000000000000000002
    2
    JSC "Halyk Savings Bank of Kazakhstan"
    15.11.2025
    15.11.2025
    Merchant payment
    transaction BEELINE
    -5 000,00
    KZT
    0,00
    -5 000,00
    -100,00
    400000******0001
    """

    static let halykExpected: [ParsedStatement.Transaction] = [
        .init(date: "2025-11-02", amountMinor: -420_000, operation: "Покупка", details: "SMALL ALMATY"),
        .init(date: "2025-11-04", amountMinor: 10_000_000, operation: "Перевод", details: "Входящий перевод"),
        .init(date: "2025-11-05", amountMinor: -530_000, operation: "Покупка", details: "OPENAI *CHATGPT SUBSCR"),
        .init(date: "2025-11-10", amountMinor: -2_000_000, operation: "Перевод", details: "Перевод на другую карту"),
        .init(date: "2025-11-12", amountMinor: 13_000_000, operation: "Пополнение", details: "Пополнение через терминал"),
        .init(date: "2025-11-15", amountMinor: -510_000, operation: "Покупка", details: "BEELINE"),
    ]

    func testKaspiCellLayout() throws {
        let s = try BankStatementParser.parse(Self.kaspiText)
        XCTAssertEqual(s.bank, .kaspi)
        XCTAssertEqual(s.periodStart, "2025-11-01")
        XCTAssertEqual(s.periodEnd, "2025-11-30")
        XCTAssertEqual(s.closingBalance?.date, "2025-11-30")
        XCTAssertEqual(s.closingBalance?.amountMinor, 35_754_950)
        XCTAssertEqual(s.account, "0001")
        XCTAssertEqual(s.ownerFirstName, "Арман")
        XCTAssertEqual(s.transactions, Self.kaspiExpected)
        // Opening 10 000 plus every operation is the closing balance, as in the real statements.
        XCTAssertEqual(1_000_000 + s.transactions.reduce(0) { $0 + $1.amountMinor }, 35_754_950)
    }

    func testKaspiRowPerLineLayout() throws {
        let text = """
        Kaspi Gold за период с 01.11.25 по 30.11.25
        Доступно на 30.11.25 98 450,50 ₸
        03.11.25 - 2 500,00 ₸ Покупка MAGNUM CASH&CARRY
        04.11.25 + 50 000,00 ₸ Пополнение С Kaspi Депозита
        """
        let s = try BankStatementParser.parse(text)
        XCTAssertEqual(s.closingBalance?.amountMinor, 9_845_050)
        XCTAssertEqual(s.transactions, [
            .init(date: "2025-11-03", amountMinor: -250_000, operation: "Покупка", details: "MAGNUM CASH&CARRY"),
            .init(date: "2025-11-04", amountMinor: 5_000_000, operation: "Пополнение", details: "С Kaspi Депозита"),
        ])
    }

    func testHalykCellLayoutUsesAccountCurrencyColumnsAndFees() throws {
        let s = try BankStatementParser.parse(Self.halykText)
        XCTAssertEqual(s.bank, .halyk)
        XCTAssertEqual(s.periodStart, "2025-11-01")
        XCTAssertEqual(s.periodEnd, "2025-11-30")
        XCTAssertEqual(s.closingBalance?.date, "2025-11-30")
        XCTAssertEqual(s.closingBalance?.amountMinor, 19_540_000)
        XCTAssertEqual(s.account, "0002")
        XCTAssertEqual(s.transactions, Self.halykExpected)
        XCTAssertEqual(s.transactions.reduce(0) { $0 + $1.amountMinor }, 19_540_000, "Opening 0 plus operations is the closing balance")
    }

    func testHalykRowPerLineRussianLayout() throws {
        let text = """
        АО «Народный Банк Казахстана»
        Выписка за период с 01.11.2025 по 30.11.2025
        02.11.2025 03.11.2025 Покупка SMALL ALMATY -4 200,00 KZT
        10.11.2025 10.11.2025 Возврат WILDBERRIES 2 000,00 KZT
        12.11.2025 13.11.2025 Оплата Beeline 3 990,00 KZT
        Остаток на конец периода: 210 450,00 KZT
        """
        let s = try BankStatementParser.parse(text)
        XCTAssertEqual(s.bank, .halyk)
        XCTAssertEqual(s.closingBalance?.amountMinor, 21_045_000)
        XCTAssertEqual(s.transactions, [
            .init(date: "2025-11-02", amountMinor: -420_000, operation: "Покупка", details: "SMALL ALMATY"),
            .init(date: "2025-11-10", amountMinor: 200_000, operation: "Возврат", details: "WILDBERRIES"),
            .init(date: "2025-11-12", amountMinor: -399_000, operation: "Оплата", details: "Beeline"),
        ])
    }

    func testParsesTextExtractedFromRenderedPDFs() throws {
        for (text, expected) in [(Self.halykText, Self.halykExpected), (Self.kaspiText, Self.kaspiExpected)] {
            let document = try XCTUnwrap(PDFDocument(data: Self.renderPDF(text)))
            let s = try BankStatementParser.parse(BankStatementParser.text(of: document))
            XCTAssertEqual(s.transactions, expected)
            XCTAssertNotNil(s.closingBalance)
        }
    }

    func testLookalikeGlyphsFromPDFExtractionAreNormalised() throws {
        // Seen in PDFKit output: Latin kra instead of Cyrillic «к», no-break spaces in amounts, «№» as «No».
        let text = Self.kaspiText
            .replacingOccurrences(of: "к", with: "ĸ")
            .replacingOccurrences(of: "350 000,00", with: "350\u{00A0}000,00")
        let s = try BankStatementParser.parse(text)
        XCTAssertEqual(s.transactions, Self.kaspiExpected)
        XCTAssertEqual(s.closingBalance?.amountMinor, 35_754_950)
    }

    func testUnknownOrEmptyStatementIsRejected() {
        XCTAssertThrowsError(try BankStatementParser.parse("Какой-то документ 01.11.2025 100,00")) {
            XCTAssertEqual($0 as? StatementError, .unknownBank)
        }
        XCTAssertThrowsError(try BankStatementParser.parse("Kaspi Gold\nОпераций нет")) {
            XCTAssertEqual($0 as? StatementError, .noTransactions)
        }
    }

    func testPreviewExcludesOwnTransfersAndCategorises() throws {
        let preview = StatementImport.preview(try BankStatementParser.parse(Self.kaspiText), importId: "k", rules: nil)
        XCTAssertEqual(preview.excludedCount, 3, "Deposit in, deposit out, and the owner's Halyk card")
        let byId = Dictionary(uniqueKeysWithValues: preview.records.map { ($0.id, $0) })
        XCTAssertEqual(byId["k-1"]?.excluded, true)
        XCTAssertEqual(byId["k-7"]?.excluded, true)
        XCTAssertEqual(byId["k-8"]?.excluded, true)
        XCTAssertEqual(byId["k-8"]?.note, "Перевод между своими счетами")
        XCTAssertNil(byId["k-0"]?.excluded)
        XCTAssertNil(byId["k-4"]?.excluded, "A stranger whose name ends like a word is still a stranger")
        XCTAssertEqual(byId["k-0"]?.category, "Продукты")
        XCTAssertEqual(byId["k-2"]?.category, "Транспорт")
        XCTAssertEqual(byId["k-3"]?.category, "Зарплата")
        XCTAssertEqual(byId["k-4"]?.category, "Переводы")
        XCTAssertEqual(byId["k-5"]?.category, "Наличные")
        XCTAssertTrue(preview.records.allSatisfy { $0.kind != "balance" })

        let halyk = StatementImport.preview(try BankStatementParser.parse(Self.halykText), importId: "h", rules: nil)
        XCTAssertEqual(halyk.excludedCount, 0)
        let h = Dictionary(uniqueKeysWithValues: halyk.records.map { ($0.id, $0) })
        XCTAssertEqual(h["h-0"]?.category, "Продукты")
        XCTAssertEqual(h["h-2"]?.category, "Подписки")
        XCTAssertEqual(h["h-3"]?.category, "Переводы")
        XCTAssertEqual(h["h-4"]?.category, "Пополнения")
        XCTAssertEqual(h["h-5"]?.category, "Связь и интернет")
    }

    func testTransferBetweenOwnStatementsLeavesTotalsAndBalancesAddUp() throws {
        var state = try importing(Self.kaspiText, id: "k", into: FinanceState())
        state = try importing(Self.halykText, id: "h", into: state)

        // Halyk «Transfer to another card» 20 000 on the 10th arrives in Kaspi from the owner's name on the 11th.
        XCTAssertEqual(state.records.first { $0.id == "h-3" }?.excluded, true)
        XCTAssertEqual(state.records.first { $0.id == "h-3" }?.note, "Перевод между своими счетами")
        XCTAssertNil(state.records.first { $0.id == "h-1" }?.excluded, "An incoming transfer with no matching side stays")

        let balances = state.records.filter { $0.kind == "balance" }
        XCTAssertEqual(balances.count, 1)
        XCTAssertEqual(balances.first?.amountMinor, 35_754_950 + 19_540_000)
        XCTAssertEqual(balances.first?.date, "2025-11-30")
        XCTAssertEqual(state.records.last?.id, StatementImport.balanceRecordId, "Placed after the operations of its day")

        let summary = try financeSummary(state, today: "2025-11-30")
        XCTAssertEqual(summary.balanceMinor, 35_754_950 + 19_540_000)
    }

    func testExcludedRecordsNeverCount() throws {
        let state = try importing(Self.kaspiText, id: "k", into: FinanceState())
        let insights = FinanceInsights.compute(state, month: "2025-11", today: "2025-11-15")
        let expenses: Int64 = 250_000 + 120_000 + 1_500_000 + 2_000_000 + 375_050
        XCTAssertEqual(insights.incomeMinor, 35_000_000, "Deposit and own-card top-ups are left out")
        XCTAssertEqual(insights.expenseMinor, expenses, "The deposit transfer is left out")
        XCTAssertEqual(insights.forecastExpenseMinor, expenses * 30 / 15)
        XCTAssertEqual(insights.categories.first?.name, "Наличные")
        XCTAssertEqual(insights.topMerchants.first?.name, "Банкомат Kaspi")
        XCTAssertEqual(insights.categories.first { $0.name == "Продукты" }?.amountMinor, 625_050)
        XCTAssertEqual(insights.previousExpenseMinor, 0)
    }

    func testMergeSuggestionForSameDateAndAmount() throws {
        let manual = FinanceRecord(id: "m1", kind: "expense", title: "магазин у дома", amountMinor: 250_000, date: "2025-11-03", category: "Продукты")
        let other = FinanceRecord(id: "m2", kind: "expense", title: "обед", amountMinor: 250_000, date: "2025-11-20", category: "Кафе и рестораны")
        var state = FinanceState(records: [manual, other])
        state = try importing(Self.kaspiText, id: "k", into: state)

        let suggestions = StatementImport.mergeSuggestions(in: state, importId: "k")
        XCTAssertEqual(suggestions, [StatementImport.MergeSuggestion(manualId: "m1", importedId: "k-0")])

        let merged = try StatementImport.merge(suggestions[0], in: state)
        XCTAssertNil(merged.records.first { $0.id == "m1" })
        XCTAssertNotNil(merged.records.first { $0.id == "m2" }, "Different date stays")
        XCTAssertEqual(merged.records.first { $0.id == "k-0" }?.note, "магазин у дома")
    }

    func testCategoryForAllOperationsOfAMerchant() throws {
        var state = try importing(Self.kaspiText, id: "k", into: FinanceState())
        let edit = StatementImport.RecordEdit(title: "MAGNUM", amountMinor: 250_000, date: "2025-11-03", category: "Покупки", note: "", excluded: false, applyCategoryToMerchant: true)
        state = try StatementImport.edit("k-0", edit, in: state)
        XCTAssertEqual(state.records.first { $0.id == "k-0" }?.category, "Покупки")
        XCTAssertEqual(state.records.first { $0.id == "k-6" }?.category, "Покупки", "The other MAGNUM purchase follows")
        XCTAssertEqual(state.records.first { $0.id == "k-2" }?.category, "Транспорт")
        XCTAssertEqual(state.merchantCategories?["magnum cash&carry"], "Покупки")

        let next = StatementImport.preview(try BankStatementParser.parse(Self.kaspiText), importId: "k2", rules: state.merchantCategories)
        XCTAssertEqual(next.records.first { $0.id == "k2-0" }?.category, "Покупки", "The next statement remembers the choice")
    }

    func testEditCanExcludeAndValidates() throws {
        var state = try importing(Self.kaspiText, id: "k", into: FinanceState())
        let exclude = StatementImport.RecordEdit(title: "Марина", amountMinor: 1_500_000, date: "2025-11-07", category: "Переводы", note: "вернёт", excluded: true)
        state = try StatementImport.edit("k-4", exclude, in: state)
        XCTAssertEqual(state.records.first { $0.id == "k-4" }?.excluded, true)
        XCTAssertEqual(state.records.first { $0.id == "k-4" }?.note, "вернёт")
        XCTAssertEqual(FinanceInsights.compute(state, month: "2025-11", today: "2025-11-30").expenseMinor, 250_000 + 120_000 + 2_000_000 + 375_050)

        let bad = StatementImport.RecordEdit(title: " ", amountMinor: 100, date: "2025-11-07", category: "", note: "", excluded: false)
        XCTAssertThrowsError(try StatementImport.edit("k-4", bad, in: state))
    }

    func testDeleteImportRemovesOnlyItsRecordsAndRebuildsBalance() throws {
        let manual = FinanceRecord(id: "m1", kind: "expense", title: "обед", amountMinor: 300_000, date: "2025-11-05", category: "Кафе и рестораны")
        var state = FinanceState(records: [manual])
        state = try importing(Self.kaspiText, id: "k", into: state)
        state = try importing(Self.halykText, id: "h", into: state)
        XCTAssertEqual(state.imports?.map(\.id), ["k", "h"])

        state = try StatementImport.deleteImport("k", from: state)
        XCTAssertEqual(state.imports?.map(\.id), ["h"])
        XCTAssertTrue(state.records.allSatisfy { $0.importId != "k" })
        XCTAssertNotNil(state.records.first { $0.id == "m1" })
        XCTAssertEqual(state.records.filter { $0.importId == "h" }.count, 6)
        XCTAssertEqual(state.records.filter { $0.kind == "balance" }.map(\.amountMinor), [19_540_000])
    }

    func testNewerStatementOfTheSameAccountReplacesItsBalance() throws {
        var state = try importing(Self.halykText, id: "h1", into: FinanceState())
        let december = Self.halykText
            .replacingOccurrences(of: "between 01.11.2025 and 30.11.2025", with: "between 01.12.2025 and 31.12.2025")
            .replacingOccurrences(of: "Closing balance: 195 400,00", with: "Closing balance: 100 000,00")
            .replacingOccurrences(of: ".11.2025", with: ".12.2025")
        state = try importing(december, id: "h2", into: state)
        let balances = state.records.filter { $0.kind == "balance" }
        XCTAssertEqual(balances.map(\.amountMinor), [10_000_000])
        XCTAssertEqual(balances.first?.date, "2025-12-31")
    }

    func testTheSameStatementAgainIsRejectedAndAnOverlapAddsOnlyNewOperations() throws {
        var state = try importing(Self.kaspiText, id: "k1", into: FinanceState())
        XCTAssertThrowsError(try importing(Self.kaspiText, id: "k2", into: state)) {
            XCTAssertEqual($0 as? StatementError, .alreadyImported)
        }

        let longer = Self.kaspiText.replacingOccurrences(of: "    - Сумма заблокирована", with: """
        12.11.25
        - 2 500,00 ₸
        Покупка      MAGNUM CASH&CARRY
            - Сумма заблокирована
        """)
        state = try importing(longer, id: "k2", into: state)
        XCTAssertEqual(state.records.filter { $0.importId == "k2" }.map(\.date), ["2025-11-12"], "Only the day the first statement did not have")
        XCTAssertEqual(state.imports?.first { $0.id == "k2" }?.count, 1)
        XCTAssertEqual(state.records.filter { $0.kind == "balance" }.map(\.amountMinor), [35_754_950], "One account counts once")
    }

    func testOverdrawnAccountLowersTheCombinedBalance() throws {
        var state = try importing(Self.kaspiText, id: "k", into: FinanceState())
        let overdrawn = Self.halykText.replacingOccurrences(of: "Closing balance: 195 400,00", with: "Closing balance: -5 000,00")
        state = try importing(overdrawn, id: "h", into: state)
        XCTAssertEqual(state.imports?.first { $0.id == "h" }?.closingMinor, -500_000)
        XCTAssertEqual(state.records.filter { $0.kind == "balance" }.map(\.amountMinor), [35_754_950 - 500_000])
    }

    func testDeletingOneSideOfAnOwnTransferCountsTheOtherAgain() throws {
        var state = try importing(Self.kaspiText, id: "k", into: FinanceState())
        state = try importing(Self.halykText, id: "h", into: state)
        XCTAssertEqual(state.records.first { $0.id == "h-3" }?.pairedWith, "k-8")
        XCTAssertNil(state.records.first { $0.id == "k-8" }?.pairedWith, "Already the owner's by name, so nothing to undo")

        state = try StatementImport.deleteImport("k", from: state)
        let transfer = try XCTUnwrap(state.records.first { $0.id == "h-3" })
        XCTAssertNil(transfer.excluded)
        XCTAssertNil(transfer.note)
        XCTAssertNil(transfer.pairedWith)

        var both = try importing(Self.kaspiText, id: "k", into: FinanceState())
        both = try importing(Self.halykText, id: "h", into: both)
        both = try StatementImport.deleteImport("h", from: both)
        XCTAssertEqual(both.records.first { $0.id == "k-8" }?.excluded, true, "The Kaspi side stays the owner's own transfer")
    }

    func testDeletingAStatementGivesBackTheMergedManualRecord() throws {
        let manual = FinanceRecord(id: "m1", kind: "expense", title: "магазин у дома", amountMinor: 250_000, date: "2025-11-03", category: "Продукты")
        var state = try importing(Self.kaspiText, id: "k", into: FinanceState(records: [manual]))
        state = try StatementImport.merge(.init(manualId: "m1", importedId: "k-0"), in: state)
        XCTAssertNil(state.records.first { $0.id == "m1" })

        let decoded = try JSONDecoder().decode(FinanceState.self, from: JSONEncoder().encode(state))
        let restored = try StatementImport.deleteImport("k", from: decoded)
        XCTAssertEqual(restored.records, [manual])
        XCTAssertNil(restored.imports)
    }

    func testOperationCountWording() {
        XCTAssertEqual(MoneyFormat.operations(1), "1 операция")
        XCTAssertEqual(MoneyFormat.operations(3), "3 операции")
        XCTAssertEqual(MoneyFormat.operations(5), "5 операций")
        XCTAssertEqual(MoneyFormat.operations(11), "11 операций")
        XCTAssertEqual(MoneyFormat.operations(22), "22 операции")
    }

    func testImportingTwiceWithSameIdIsIgnoredAndSurvivesCoding() throws {
        var state = try importing(Self.halykText, id: "h", into: FinanceState())
        let count = state.records.count
        state = try importing(Self.halykText, id: "h", into: state)
        XCTAssertEqual(state.records.count, count)

        let decoded = try JSONDecoder().decode(FinanceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try validateFinance(decoded), try validateFinance(state))
        XCTAssertEqual(decoded.imports?.first?.closingMinor, 19_540_000)
        XCTAssertEqual(decoded.imports?.first?.account, "0002")
    }

    private func importing(_ text: String, id: String, into state: FinanceState) throws -> FinanceState {
        let preview = StatementImport.preview(try BankStatementParser.parse(text), importId: id, rules: state.merchantCategories)
        return try StatementImport.apply(preview, to: state, importId: id, fileName: "\(id).pdf", today: "2025-12-01")
    }

    /// Each line drawn on its own, the way the banks lay out table cells.
    private static func renderPDF(_ text: String) -> Data {
        let lines = text.components(separatedBy: "\n")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8)]
        return renderer.pdfData { context in
            for (index, line) in lines.enumerated() {
                let row = index % 60
                if row == 0 { context.beginPage() }
                (line as NSString).draw(at: CGPoint(x: 24, y: 24 + CGFloat(row) * 12), withAttributes: attributes)
            }
        }
    }
}
