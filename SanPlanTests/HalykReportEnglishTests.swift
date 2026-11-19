import XCTest
@testable import SanPlan

/// The same Halyk report in English (the bank app gives it in its own language). Made-up owner, cards, amounts and
/// merchants, cells in the order of the real file. Transfers between own cards there carry neither sign nor «₸».
final class HalykReportEnglishTests: XCTestCase {
    static let reportText = """
    The report includes data for the following products:
    Card accounts:
    400000******0001
    400000******0002
    KZ*0003
    Date
    Operation
    type
    Product Account Category
    MCC
    Code
    Operation name Amount Description
    This analytical report has been prepared solely for informational purposes based on data on the movement of funds on client products.
    2025-11-
    10
    Expense
    Card
    account
    400000******0001
    Transfers between own
    accounts
    - Transfer between own cards 22 000  Transfer between own cards
    2025-11-
    10
    Income
    Card
    account
    400000******0002
    Transfers between own
    accounts
    - Transfer between own cards 22 000  Transfer between own cards
    2025-11-
    09
    Expense
    Card
    account
    400000******0002 Cafes and restaurants 5814 TEST DONER FAST FOOD -1 895  TEST DONER FAST FOOD
    2025-11-
    06
    Expense
    Card
    account
    400000******0002 Health and care 5912 APTEKA 98 TEST -1 115  APTEKA 98 TEST
    2025-11-
    05
    Income
    Card
    account
    KZ*0003 Incoming transfers -
    Credit to account : Dana Serikova
    +50 000  Credit to account : Dana Serikova
    Analytical report on the transactions of customer
    TESTOV ARMAN for the period from 01.11.2025 to 19.11.2025
    Expenses amount 3 010
    Income amount 50 000
    """

    func testReadsTheEnglishReport() throws {
        let s = try BankStatementParser.parse(Self.reportText)
        XCTAssertEqual(s.bank, .halyk)
        XCTAssertEqual(s.account, ParsedStatement.allAccounts)
        XCTAssertEqual(s.periodStart, "2025-11-01")
        XCTAssertEqual(s.periodEnd, "2025-11-19")
        XCTAssertEqual(s.ownerSurname, "TESTOV")
        XCTAssertEqual(s.ownerFirstName, "ARMAN")
        XCTAssertEqual(s.transactions.map(\.date), ["2025-11-10", "2025-11-10", "2025-11-09", "2025-11-06", "2025-11-05"])
        XCTAssertEqual(s.transactions.map(\.amountMinor), [-2_200_000, 2_200_000, -189_500, -111_500, 5_000_000])
        XCTAssertEqual(s.transactions.map(\.account), ["0001", "0002", "0002", "0002", "0003"])
        XCTAssertEqual(s.transactions.map(\.operation), ["Перевод", "Перевод", "Покупка", "Покупка", "Перевод"])
        XCTAssertEqual(s.transactions.last?.details, "Dana Serikova", "«Credit to account :» is dropped")
        XCTAssertEqual(s.transactions[3].details, "APTEKA 98 TEST", "A number inside the name is not the amount")
    }

    func testEnglishCategoriesAndOwnTransfers() throws {
        let preview = StatementImport.preview(try BankStatementParser.parse(Self.reportText), importId: "e", rules: nil)
        let byId = Dictionary(uniqueKeysWithValues: preview.records.map { ($0.id, $0) })
        XCTAssertEqual(byId["e-2-0002"]?.category, "Кафе и рестораны")
        XCTAssertEqual(byId["e-3-0002"]?.category, "Здоровье")

        let state = try StatementImport.apply(preview, to: FinanceState(), importId: "e", fileName: "e.pdf", today: "2025-12-01")
        let own = state.records.filter { $0.amountMinor == 2_200_000 }
        XCTAssertEqual(own.count, 2)
        XCTAssertTrue(own.allSatisfy { $0.excluded == true }, "A transfer between own cards leaves the totals")
    }
}
