import PDFKit
import UIKit
import XCTest
@testable import SanPlan

/// Halyk «Аналитический отчет по операциям клиента»: one file over every card and account. Made-up owner, cards,
/// amounts and merchants in the layout of the real report (cells one after another, the date split as «2025-11-» «02»).
final class HalykReportTests: XCTestCase {
    static let reportText = """
    Аналитический отчет по операциям клиента
    ТЕСТОВ АРМАН ЕРЛАНОВИЧ за период с 01.11.2025 по 30.11.2025
    В отчет включены данные по счетам пользователя
    Карточные счета:
    400000******0001
    KZ*0003
    KZ*0004
    Сумма расходов
    Сумма доходов
    60 615 ₸
    380 000 ₸
    Дата
    Тип
    операции
    Продукт
    Счет
    Категория
    Код
    MCC
    Название операции
    Сумма
    Описание
    Настоящий аналитический отчет подготовлен исключительно в информационных целях на основании данных о движении
    средств по продуктам клиента. Отчет не является официальным документом.
    2025-11-
    26
    Доход
    Карточный
    счет
    KZ*0003
    Входящие
    переводы
    -
    Поступление на счет : Арман Тестов
    +30 000
    ₸
    Поступление на счет : Арман Тестов
    2025-11-
    26
    Расход
    Карточный
    счет
    KZ*0004
    Исходящие
    переводы
    -
    Исходящий перевод
    -30 000
    ₸
    Исходящий перевод
    2025-11-
    25
    Доход
    Карточный
    счет
    KZ*0004
    Зарплата
    -
    ТОО "ТЕСТ КОМПАНИ"
    +250 000
    ₸
    ТОО "ТЕСТ КОМПАНИ"
    2025-11-
    20
    Расход
    Карточный
    счет
    400000******0001
    Здоровье и уход
    5912
    APTEKA 7 ROSTA
    -1 115
    ₸
    APTEKA 7 ROSTA
    2025-11-
    10
    Расход
    Карточный
    счет
    KZ*0003
    Исходящие
    переводы
    -
    Исходящий перевод
    -20 000
    ₸
    Исходящий перевод
    2025-11-
    05
    Расход
    Карточный
    счет
    400000******0001
    Цифровые товары
    5734
    OPENAI *CHATGPT SUBSCR
    -5 300
    ₸
    OPENAI *CHATGPT SUBSCR
    2025-11-
    04
    Доход
    Карточный
    счет
    KZ*0003
    Входящие
    переводы
    -
    Поступление на счет : Дана Серикова
    +100 000
    ₸
    Поступление на счет : Дана Серикова
    2025-11-
    02
    Расход
    Карточный
    счет
    400000******0001
    Супермаркеты
    5411
    SMALL ALMATY
    -4 200
    ₸
    SMALL ALMATY
    """

    static let expected: [ParsedStatement.Transaction] = [
        .init(date: "2025-11-26", amountMinor: 3_000_000, operation: "Перевод", details: "Арман Тестов", account: "0003", bankCategory: "Входящие переводы"),
        .init(date: "2025-11-26", amountMinor: -3_000_000, operation: "Перевод", details: "Исходящий перевод", account: "0004", bankCategory: "Исходящие переводы"),
        .init(date: "2025-11-25", amountMinor: 25_000_000, operation: "Зарплата", details: "ТОО \"ТЕСТ КОМПАНИ\"", account: "0004", bankCategory: "Зарплата"),
        .init(date: "2025-11-20", amountMinor: -111_500, operation: "Покупка", details: "APTEKA 7 ROSTA", account: "0001", bankCategory: "Здоровье и уход"),
        .init(date: "2025-11-10", amountMinor: -2_000_000, operation: "Перевод", details: "Исходящий перевод", account: "0003", bankCategory: "Исходящие переводы"),
        .init(date: "2025-11-05", amountMinor: -530_000, operation: "Покупка", details: "OPENAI *CHATGPT SUBSCR", account: "0001", bankCategory: "Цифровые товары"),
        .init(date: "2025-11-04", amountMinor: 10_000_000, operation: "Перевод", details: "Дана Серикова", account: "0003", bankCategory: "Входящие переводы"),
        .init(date: "2025-11-02", amountMinor: -420_000, operation: "Покупка", details: "SMALL ALMATY", account: "0001", bankCategory: "Супермаркеты"),
    ]

    func testReadsEveryAccountOfTheReport() throws {
        let s = try BankStatementParser.parse(Self.reportText)
        XCTAssertEqual(s.bank, .halyk, "The report names no bank; its title is Halyk's")
        XCTAssertEqual(s.account, ParsedStatement.allAccounts)
        XCTAssertEqual(s.periodStart, "2025-11-01")
        XCTAssertEqual(s.periodEnd, "2025-11-30")
        XCTAssertNil(s.closingBalance, "The report has totals, not a balance")
        XCTAssertEqual(s.ownerFirstName, "АРМАН")
        XCTAssertEqual(s.ownerSurname, "ТЕСТОВ")
        XCTAssertEqual(s.transactions, Self.expected)
    }

    func testRowWhoseDayComesOnItsOwnLine() throws {
        // If the PDF text comes out line by line, the first line of a row holds «2025-11-» and the top halves of the
        // two-line cells, the middle line the one-line cells, the last line the day.
        let text = """
        Аналитический отчет по операциям клиента
        ТЕСТОВ АРМАН ЕРЛАНОВИЧ за период с 01.11.2025 по 30.11.2025
        2025-11- Карточный Входящие
        Доход KZ*0003 - Поступление на счет : Дана Серикова +100 000 ₸ Поступление на счет : Дана Серикова
        04 счет переводы
        2025-11- Карточный
        Расход 400000******0001 Супермаркеты 5411 SMALL 12 ALMATY -4 200 ₸ SMALL 12 ALMATY
        02 счет
        """
        let s = try BankStatementParser.parse(text)
        XCTAssertEqual(s.transactions.map(\.date), ["2025-11-04", "2025-11-02"])
        XCTAssertEqual(s.transactions.map(\.amountMinor), [10_000_000, -420_000])
        XCTAssertEqual(s.transactions.map(\.account), ["0003", "0001"])
        XCTAssertEqual(s.transactions.first?.operation, "Перевод", "The name tells a transfer when the category is elsewhere")
        XCTAssertEqual(s.transactions.first?.details, "Дана Серикова")

        let unspaced = text.replacingOccurrences(of: "-4 200 ₸", with: "-4200 ₸")
        XCTAssertEqual(try BankStatementParser.parse(unspaced).transactions.last?.amountMinor, -420_000)
    }

    func testReadsTheReportFromAPDFWithTwoLineCells() throws {
        let document = try XCTUnwrap(PDFDocument(data: Self.renderReport()))
        let s = try BankStatementParser.parse(BankStatementParser.text(of: document))
        XCTAssertEqual(s.transactions.map(\.date), ["2025-11-26", "2025-11-20", "2025-11-02"])
        XCTAssertEqual(s.transactions.map(\.amountMinor), [3_000_000, -111_500, -420_000])
        XCTAssertEqual(s.transactions.map(\.account), ["0003", "0001", "0001"])
    }

    func testCategoriesAccountsAndTheOwnersOwnMoney() throws {
        let preview = StatementImport.preview(try BankStatementParser.parse(Self.reportText), importId: "r", rules: nil)
        let byId = Dictionary(uniqueKeysWithValues: preview.records.map { ($0.id, $0) })
        XCTAssertEqual(byId["r-7-0001"]?.category, "Продукты", "The bank's «Супермаркеты», not «shop»-like guessing")
        XCTAssertEqual(byId["r-3-0001"]?.category, "Здоровье")
        XCTAssertEqual(byId["r-5-0001"]?.category, "Подписки")
        XCTAssertEqual(byId["r-2-0004"]?.category, "Зарплата")
        XCTAssertEqual(byId["r-4-0003"]?.category, "Переводы")
        XCTAssertEqual(byId["r-6-0003"]?.category, "Переводы")
        XCTAssertEqual(byId["r-6-0003"]?.title, "Дана Серикова")
        XCTAssertNil(byId["r-6-0003"]?.excluded, "Money from someone else is income")
        XCTAssertEqual(byId["r-0-0003"]?.excluded, true, "Money from the owner's own name")
        XCTAssertEqual(byId["r-0-0003"]?.note, StatementImport.ownTransferNote)
        XCTAssertEqual(preview.excludedCount, 1)

        let rules = ["small almaty": "Покупки"]
        let ruled = StatementImport.preview(try BankStatementParser.parse(Self.reportText), importId: "r", rules: rules)
        XCTAssertEqual(ruled.records.first { $0.id == "r-7-0001" }?.category, "Покупки", "The owner's rule wins")
    }

    func testTransferBetweenTwoAccountsOfTheReportLeavesTheTotals() throws {
        let state = try importing(Self.reportText, id: "r", into: FinanceState())
        let out = try XCTUnwrap(state.records.first { $0.id == "r-1-0004" })
        let inn = try XCTUnwrap(state.records.first { $0.id == "r-0-0003" })
        XCTAssertEqual(out.excluded, true)
        XCTAssertEqual(out.pairedWith, inn.id)
        XCTAssertEqual(inn.excluded, true)
        let lone = state.records.first { $0.id == "r-4-0003" }
        XCTAssertEqual(lone?.status, "pendingPair", "An outgoing transfer with no own side waits for the other bank")
        XCTAssertEqual(lone?.excluded, true)
        XCTAssertEqual(StatementImport.account(of: out, in: state), "0004")
        XCTAssertEqual(StatementImport.account(of: inn, in: state), "0003")
        XCTAssertNil(state.records.first { $0.kind == "balance" }, "No balance in the report")
    }

    func testReportAfterAStatementOfOneAccountAddsOnlyWhatIsNew() throws {
        var state = try importing(StatementImportTests.halykText, id: "h", into: FinanceState())
        state = try importing(Self.reportText, id: "r", into: state)
        // 02, 04, 05 and 10 November are in the card's statement already, though the report shows the card number,
        // other names and no fee.
        let fromReport = state.records.filter { $0.importId == "r" }
        XCTAssertEqual(Set(fromReport.map(\.date)), ["2025-11-20", "2025-11-25", "2025-11-26"])
        XCTAssertEqual(fromReport.count, 4)
        XCTAssertEqual(state.records.filter { $0.date == "2025-11-02" && $0.kind == "expense" }.count, 1)
        XCTAssertEqual(state.imports?.first { $0.id == "r" }?.count, 4)
        XCTAssertEqual(StatementImport.account(of: try XCTUnwrap(state.records.first { $0.id == "h-0" }), in: state), "0002")

        XCTAssertThrowsError(try importing(Self.reportText, id: "r2", into: state)) {
            XCTAssertEqual($0 as? StatementError, .alreadyImported)
        }
    }

    func testStatementOfOneAccountAfterTheReportTakesItsLinesOver() throws {
        var state = try importing(Self.reportText, id: "r", into: FinanceState())
        let small = try XCTUnwrap(state.records.firstIndex { $0.id == "r-7-0001" })
        state.records[small].category = "Покупки"
        state.records[small].note = "к ужину"
        state = try importing(StatementImportTests.halykText, id: "h", into: state)

        XCTAssertNil(state.records.first { $0.id == "r-7-0001" }, "The card's statement holds the line now")
        let h0 = try XCTUnwrap(state.records.first { $0.id == "h-0" })
        XCTAssertEqual(h0.category, "Покупки", "What the owner set moves over")
        XCTAssertEqual(h0.note, "к ужину")
        let reportLeft = state.records.filter { $0.importId == "r" }.map(\.date)
        XCTAssertEqual(Set(reportLeft), ["2025-11-20", "2025-11-25", "2025-11-26"])
        XCTAssertEqual(state.records.filter { $0.importId == "h" }.count, 6)
        XCTAssertEqual(state.records.filter { $0.kind == "expense" && $0.date == "2025-11-05" }.count, 1)
        let card = state.ledger?.accounts.first { $0.identifiers.contains("kz:0002") }
        XCTAssertEqual(card?.anchorMinor, 19_540_000, "The card's closing balance")
    }

    func testTakingOverKeepsTheTransferPartner() throws {
        var state = FinanceState()
        state.imports = [
            FinanceImport(id: "r", bank: "Halyk", fileName: "r.pdf", periodStart: nil, periodEnd: nil, importedAt: "2025-12-01", count: 2, account: ParsedStatement.allAccounts),
            FinanceImport(id: "h", bank: "Halyk", fileName: "h.pdf", periodStart: nil, periodEnd: nil, importedAt: "2025-12-02", count: 1, account: "0009"),
        ]
        var out = FinanceRecord(id: "r-1-0004", kind: "expense", title: "Исходящий перевод", amountMinor: 3_000_000, date: "2025-11-26")
        out.importId = "r"
        out.excluded = true
        out.pairedWith = "r-0-0003"
        var inn = FinanceRecord(id: "r-0-0003", kind: "income", title: "Арман Тестов", amountMinor: 3_000_000, date: "2025-11-26")
        inn.importId = "r"
        inn.excluded = true
        inn.pairedWith = "r-1-0004"
        var line = FinanceRecord(id: "h-0", kind: "expense", title: "Перевод на другую карту", amountMinor: 3_000_000, date: "2025-11-27")
        line.importId = "h"
        state.records = [out, inn, line]

        StatementImport.takeOverReportLines(&state, importId: "h")
        XCTAssertEqual(state.records.map(\.id), ["r-0-0003", "h-0"])
        XCTAssertEqual(state.records[1].excluded, true)
        XCTAssertEqual(state.records[1].pairedWith, "r-0-0003")
        XCTAssertEqual(state.records[0].pairedWith, "h-0")
    }

    private func importing(_ text: String, id: String, into state: FinanceState) throws -> FinanceState {
        let preview = StatementImport.preview(try BankStatementParser.parse(text), importId: id, rules: state.merchantCategories)
        return try StatementImport.apply(preview, to: state, importId: id, fileName: "\(id).pdf", today: "2025-12-01")
    }

    /// Three rows placed like the real report: two-line cells («2025-11-» over «26», «Карточный» over «счет») around
    /// one-line cells set half a line lower.
    private static func renderReport() -> Data {
        // Day, type, account, category (top, bottom), MCC, name (top, bottom), amount. An empty bottom: a one-line cell.
        let rows: [(String, String, String, String, String, String, String, String, String)] = [
            ("26", "Доход", "KZ*0003", "Входящие", "переводы", "-", "Поступление на счет :", "Арман Тестов", "+30 000"),
            ("20", "Расход", "400000******0001", "Здоровье и уход", "", "5912", "APTEKA 7 ROSTA", "", "-1 115"),
            ("02", "Расход", "400000******0001", "Супермаркеты", "", "5411", "SMALL ALMATY", "", "-4 200"),
        ]
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 5)]
        func draw(_ text: String, _ x: CGFloat, _ y: CGFloat) {
            guard !text.isEmpty else { return }
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        }
        func cell(_ top: String, _ bottom: String, _ x: CGFloat, _ y: CGFloat) {
            if bottom.isEmpty {
                draw(top, x, y + 3)
            } else {
                draw(top, x, y)
                draw(bottom, x, y + 6)
            }
        }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        return renderer.pdfData { context in
            context.beginPage()
            draw("Аналитический отчет по операциям клиента", 42, 40)
            draw("ТЕСТОВ АРМАН ЕРЛАНОВИЧ за период с 01.11.2025 по 30.11.2025", 42, 52)
            for (n, row) in rows.enumerated() {
                let top = 240 + CGFloat(n) * 20
                cell("2025-11-", row.0, 47, top)
                cell(row.1, "", 80, top)
                cell("Карточный", "счет", 119, top)
                cell(row.2, "", 163, top)
                cell(row.3, row.4, 212, top)
                cell(row.5, "", 267, top)
                cell(row.6, row.7, 295, top)
                cell(row.8, "", 395, top)
                cell("₸", "", 420, top)
                cell(row.6, row.7, 458, top)
            }
        }
    }
}
