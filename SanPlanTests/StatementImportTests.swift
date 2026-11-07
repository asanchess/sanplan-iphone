import PDFKit
import UIKit
import XCTest
@testable import SanPlan

/// Anonymised statements in the layout of the real Kaspi Gold and Halyk PDFs. No real data lives in the repository.
final class StatementImportTests: XCTestCase {
    static let kaspiText = """
    АО «Kaspi Bank»
    Выписка по Kaspi Gold за период с 01.11.25 по 30.11.25
    Доступно на 30.11.25 98 450,50 ₸
    Дата Сумма Операция Детали
    03.11.25 - 2 500,00 ₸ Покупка MAGNUM CASH&CARRY
    04.11.25 + 50 000,00 ₸ Пополнение С Kaspi Депозита
    05.11.25 - 1 200,00 ₸ Покупка Yandex Go
    06.11.25 + 350 000,00 ₸ Перевод ТОО Ромашка зарплата
    07.11.25 - 15 000,00 ₸ Перевод Айгерим Т.
    08.11.25 - 20 000,00 ₸ Снятие Банкомат Kaspi
    09.11.25 - 3 750,50 ₸ Покупка MAGNUM CASH&CARRY
    """

    static let halykText = """
    АО «Народный Банк Казахстана» Halyk Bank
    Выписка по счёту за период с 01.11.2025 по 30.11.2025
    Дата операции Дата обработки Описание Сумма
    02.11.2025 03.11.2025 Покупка SMALL ALMATY -4 200,00 KZT
    04.11.2025 04.11.2025 Пополнение Перевод между своими счетами +100 000,00 KZT
    05.11.2025 06.11.2025 Покупка EUROPHARMA -6 300,00 KZT
    10.11.2025 10.11.2025 Возврат WILDBERRIES 2 000,00 KZT
    12.11.2025 13.11.2025 Оплата Beeline 3 990,00 KZT
    15.11.2025 15.11.2025 Перевод на карту Kaspi -10 000,00 KZT
    Остаток на конец периода: 210 450,00 KZT
    """

    func testKaspiTransactionsAndBalance() throws {
        let s = try BankStatementParser.parse(Self.kaspiText)
        XCTAssertEqual(s.bank, .kaspi)
        XCTAssertEqual(s.periodStart, "2025-11-01")
        XCTAssertEqual(s.periodEnd, "2025-11-30")
        XCTAssertEqual(s.closingBalance?.date, "2025-11-30")
        XCTAssertEqual(s.closingBalance?.amountMinor, 9_845_050)
        XCTAssertEqual(s.transactions, [
            .init(date: "2025-11-03", amountMinor: -250_000, operation: "Покупка", details: "MAGNUM CASH&CARRY"),
            .init(date: "2025-11-04", amountMinor: 5_000_000, operation: "Пополнение", details: "С Kaspi Депозита"),
            .init(date: "2025-11-05", amountMinor: -120_000, operation: "Покупка", details: "Yandex Go"),
            .init(date: "2025-11-06", amountMinor: 35_000_000, operation: "Перевод", details: "ТОО Ромашка зарплата"),
            .init(date: "2025-11-07", amountMinor: -1_500_000, operation: "Перевод", details: "Айгерим Т."),
            .init(date: "2025-11-08", amountMinor: -2_000_000, operation: "Снятие", details: "Банкомат Kaspi"),
            .init(date: "2025-11-09", amountMinor: -375_050, operation: "Покупка", details: "MAGNUM CASH&CARRY"),
        ])
    }

    func testHalykTransactionsAndBalanceEvenWithKaspiCounterparty() throws {
        let s = try BankStatementParser.parse(Self.halykText)
        XCTAssertEqual(s.bank, .halyk, "A transfer to a Kaspi card does not make it a Kaspi statement")
        XCTAssertEqual(s.periodStart, "2025-11-01")
        XCTAssertEqual(s.closingBalance?.date, "2025-11-30")
        XCTAssertEqual(s.closingBalance?.amountMinor, 21_045_000)
        XCTAssertEqual(s.transactions, Self.halykExpected)
    }

    static let halykExpected: [ParsedStatement.Transaction] = [
        .init(date: "2025-11-02", amountMinor: -420_000, operation: "Покупка", details: "SMALL ALMATY"),
        .init(date: "2025-11-04", amountMinor: 10_000_000, operation: "Пополнение", details: "Перевод между своими счетами"),
        .init(date: "2025-11-05", amountMinor: -630_000, operation: "Покупка", details: "EUROPHARMA"),
        .init(date: "2025-11-10", amountMinor: 200_000, operation: "Возврат", details: "WILDBERRIES"),
        .init(date: "2025-11-12", amountMinor: -399_000, operation: "Оплата", details: "Beeline"),
        .init(date: "2025-11-15", amountMinor: -1_000_000, operation: "Перевод", details: "на карту Kaspi"),
    ]

    func testParsesTextExtractedFromARenderedPDF() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let data = renderer.pdfData { context in
            context.beginPage()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9)]
            for (index, line) in Self.halykText.components(separatedBy: "\n").enumerated() {
                (line as NSString).draw(at: CGPoint(x: 24, y: 24 + CGFloat(index) * 16), withAttributes: attributes)
            }
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let s = try BankStatementParser.parse(BankStatementParser.text(of: document))
        XCTAssertEqual(s.bank, .halyk)
        XCTAssertEqual(s.transactions, Self.halykExpected)
        XCTAssertEqual(s.closingBalance?.amountMinor, 21_045_000)
    }

    func testLookalikeGlyphsFromPDFExtractionAreNormalised() throws {
        // Seen in PDFKit output: Latin kra instead of Cyrillic «к», no-break spaces in amounts.
        let text = Self.halykText.replacingOccurrences(of: "к", with: "ĸ").replacingOccurrences(of: "100 000,00", with: "100\u{00A0}000,00")
        let s = try BankStatementParser.parse(text)
        XCTAssertEqual(s.transactions, Self.halykExpected)
        XCTAssertEqual(s.closingBalance?.amountMinor, 21_045_000)
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
        XCTAssertEqual(preview.excludedCount, 1)
        let byId = Dictionary(uniqueKeysWithValues: preview.records.map { ($0.id, $0) })
        XCTAssertEqual(byId["k-1"]?.excluded, true, "Deposit top-up is the owner's own money")
        XCTAssertNil(byId["k-0"]?.excluded)
        XCTAssertEqual(byId["k-0"]?.category, "Продукты")
        XCTAssertEqual(byId["k-2"]?.category, "Транспорт")
        XCTAssertEqual(byId["k-3"]?.category, "Зарплата")
        XCTAssertEqual(byId["k-4"]?.category, "Переводы")
        XCTAssertEqual(byId["k-5"]?.category, "Наличные")
        XCTAssertEqual(preview.records.last?.kind, "balance")
        XCTAssertEqual(preview.records.last?.amountMinor, 9_845_050)

        let halyk = StatementImport.preview(try BankStatementParser.parse(Self.halykText), importId: "h", rules: nil)
        XCTAssertEqual(halyk.excludedCount, 1)
        XCTAssertEqual(halyk.records.first { $0.id == "h-4" }?.category, "Связь и интернет")
    }

    func testExcludedRecordsNeverCount() throws {
        let state = try importing(Self.kaspiText, id: "k", into: FinanceState())
        let insights = FinanceInsights.compute(state, month: "2025-11", today: "2025-11-15")
        XCTAssertEqual(insights.incomeMinor, 35_000_000, "The deposit top-up is left out")
        XCTAssertEqual(insights.expenseMinor, 250_000 + 120_000 + 1_500_000 + 2_000_000 + 375_050)
        XCTAssertEqual(insights.forecastExpenseMinor, (250_000 + 120_000 + 1_500_000 + 2_000_000 + 375_050) * 30 / 15)
        XCTAssertEqual(insights.categories.first?.name, "Наличные")
        XCTAssertEqual(insights.topMerchants.first?.name, "Банкомат Kaspi")
        XCTAssertEqual(insights.categories.first { $0.name == "Продукты" }?.amountMinor, 625_050)
        XCTAssertEqual(insights.previousExpenseMinor, 0)
    }

    func testMergeSuggestionForSameDateAndAmount() throws {
        var manual = FinanceRecord(id: "m1", kind: "expense", title: "магазин у дома", amountMinor: 250_000, date: "2025-11-03", category: "Продукты")
        manual.note = nil
        let other = FinanceRecord(id: "m2", kind: "expense", title: "обед", amountMinor: 250_000, date: "2025-11-20", category: "Кафе и рестораны")
        var state = FinanceState(records: [manual, other])
        state = try importing(Self.kaspiText, id: "k", into: state)

        let suggestions = StatementImport.mergeSuggestions(in: state, importId: "k")
        XCTAssertEqual(suggestions, [StatementImport.MergeSuggestion(manualId: "m1", importedId: "k-0")])

        let merged = try StatementImport.merge(suggestions[0], in: state)
        XCTAssertNil(merged.records.first { $0.id == "m1" })
        XCTAssertNotNil(merged.records.first { $0.id == "m2" }, "Different date stays")
        XCTAssertEqual(merged.records.first { $0.id == "k-0" }?.note, "магазин у дома")
        XCTAssertEqual(merged.records.filter { $0.importId == nil }.count, 1)
    }

    func testCategoryForAllOperationsOfAMerchant() throws {
        var state = try importing(Self.kaspiText, id: "k", into: FinanceState())
        let edit = StatementImport.RecordEdit(title: "MAGNUM", amountMinor: 250_000, date: "2025-11-03", category: "Покупки", note: "", excluded: false, applyCategoryToMerchant: true)
        state = try StatementImport.edit("k-0", edit, in: state)
        XCTAssertEqual(state.records.first { $0.id == "k-0" }?.category, "Покупки")
        XCTAssertEqual(state.records.first { $0.id == "k-6" }?.category, "Покупки", "The other MAGNUM purchase follows")
        XCTAssertEqual(state.records.first { $0.id == "k-2" }?.category, "Транспорт")
        XCTAssertEqual(state.merchantCategories?["magnum cash&carry"], "Покупки")

        // The next statement remembers the choice.
        let next = StatementImport.preview(try BankStatementParser.parse(Self.kaspiText), importId: "k2", rules: state.merchantCategories)
        XCTAssertEqual(next.records.first { $0.id == "k2-0" }?.category, "Покупки")
    }

    func testEditCanExcludeAndValidates() throws {
        var state = try importing(Self.kaspiText, id: "k", into: FinanceState())
        let exclude = StatementImport.RecordEdit(title: "Айгерим", amountMinor: 1_500_000, date: "2025-11-07", category: "Переводы", note: "вернёт", excluded: true)
        state = try StatementImport.edit("k-4", exclude, in: state)
        XCTAssertEqual(state.records.first { $0.id == "k-4" }?.excluded, true)
        XCTAssertEqual(state.records.first { $0.id == "k-4" }?.note, "вернёт")
        XCTAssertEqual(FinanceInsights.compute(state, month: "2025-11", today: "2025-11-30").expenseMinor, 250_000 + 120_000 + 2_000_000 + 375_050)

        let bad = StatementImport.RecordEdit(title: " ", amountMinor: 100, date: "2025-11-07", category: "", note: "", excluded: false)
        XCTAssertThrowsError(try StatementImport.edit("k-4", bad, in: state))
    }

    func testDeleteImportRemovesOnlyItsRecords() throws {
        let manual = FinanceRecord(id: "m1", kind: "expense", title: "обед", amountMinor: 300_000, date: "2025-11-05", category: "Кафе и рестораны")
        var state = FinanceState(records: [manual])
        state = try importing(Self.kaspiText, id: "k", into: state)
        state = try importing(Self.halykText, id: "h", into: state)
        XCTAssertEqual(state.imports?.map(\.id), ["k", "h"])

        state = try StatementImport.deleteImport("k", from: state)
        XCTAssertEqual(state.imports?.map(\.id), ["h"])
        XCTAssertTrue(state.records.allSatisfy { $0.importId != "k" })
        XCTAssertNotNil(state.records.first { $0.id == "m1" })
        XCTAssertEqual(state.records.filter { $0.importId == "h" }.count, 7, "6 operations and the balance")
    }

    func testImportingTwiceWithSameIdIsIgnoredAndSurvivesCoding() throws {
        var state = try importing(Self.halykText, id: "h", into: FinanceState())
        let count = state.records.count
        state = try importing(Self.halykText, id: "h", into: state)
        XCTAssertEqual(state.records.count, count)

        let decoded = try JSONDecoder().decode(FinanceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try validateFinance(decoded), try validateFinance(state))
        XCTAssertEqual(decoded.records.first { $0.id == "h-1" }?.excluded, true)
    }

    private func importing(_ text: String, id: String, into state: FinanceState) throws -> FinanceState {
        let preview = StatementImport.preview(try BankStatementParser.parse(text), importId: id, rules: state.merchantCategories)
        return try StatementImport.apply(preview, to: state, importId: id, fileName: "\(id).pdf", today: "2025-12-01")
    }
}
