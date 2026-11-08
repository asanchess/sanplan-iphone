import XCTest
@testable import SanPlan

final class MerchantCategoriesTests: XCTestCase {

    func testKeyLowercasesAndCollapsesWhitespace() {
        XCTAssertEqual(MerchantCategories.key("  ТОО   Ромашка\tPLUS  "), "тоо ромашка plus")
        XCTAssertEqual(MerchantCategories.key("Shop"), MerchantCategories.key("  SHOP "))
        XCTAssertEqual(MerchantCategories.key("   "), "")
    }

    func testOwnerRuleWinsOverKeywordsAndDirection() {
        let rules = ["test coffee point": "Учёба"]
        // «coffee» would otherwise mean a cafe; the owner's per-merchant choice wins.
        XCTAssertEqual(
            MerchantCategories.category(operation: "Покупка", merchant: "  TEST  Coffee Point ", incoming: false, rules: rules),
            "Учёба"
        )
        // The rule applies to incoming operations of the same merchant too.
        XCTAssertEqual(
            MerchantCategories.category(operation: "Пополнение", merchant: "Test Coffee Point", incoming: true, rules: rules),
            "Учёба"
        )
        // A rule for another merchant changes nothing.
        XCTAssertEqual(
            MerchantCategories.category(operation: "Покупка", merchant: "Other Coffee", incoming: false, rules: rules),
            "Кафе и рестораны"
        )
    }

    func testIncomingOperations() {
        XCTAssertEqual(MerchantCategories.category(operation: "Пополнение", merchant: "Иван И.", incoming: true, rules: nil), "Пополнения")
        XCTAssertEqual(MerchantCategories.category(operation: "Перевод", merchant: "Иван И.", incoming: true, rules: nil), "Переводы")
        XCTAssertEqual(MerchantCategories.category(operation: "Пополнение", merchant: "ТОО Пример, зарплата", incoming: true, rules: nil), "Зарплата")
        XCTAssertEqual(MerchantCategories.category(operation: "Salary payment", merchant: "Example LLP", incoming: true, rules: [:]), "Зарплата")
        // Keywords never apply to money coming in: a refund from a shop is a top-up, not a purchase.
        XCTAssertEqual(MerchantCategories.category(operation: "Покупка", merchant: "Wolt", incoming: true, rules: nil), "Пополнения")
    }

    func testWithdrawalAndTransferPrecedeKeywords() {
        XCTAssertEqual(MerchantCategories.category(operation: "Снятие наличных", merchant: "Банкомат Magnum", incoming: false, rules: nil), "Наличные")
        XCTAssertEqual(MerchantCategories.category(operation: "СНЯТИЕ", merchant: "ATM", incoming: false, rules: nil), "Наличные")
        XCTAssertEqual(MerchantCategories.category(operation: "Перевод", merchant: "Yandex Go", incoming: false, rules: nil), "Переводы")
        XCTAssertEqual(MerchantCategories.category(operation: "Перевод на карту", merchant: "Иван И.", incoming: false, rules: nil), "Переводы")
    }

    func testKeywordCategoriesForPurchases() {
        func cat(_ merchant: String, _ operation: String = "Покупка") -> String {
            MerchantCategories.category(operation: operation, merchant: merchant, incoming: false, rules: nil)
        }
        XCTAssertEqual(cat("WOLT ALMATY"), "Доставка еды")
        XCTAssertEqual(cat("Yandex Go Ride"), "Транспорт")
        XCTAssertEqual(cat("NETFLIX.COM"), "Подписки")
        XCTAssertEqual(cat("Аптека №1"), "Здоровье")
        XCTAssertEqual(cat("Beeline KZ", "Оплата"), "Связь и интернет")
        XCTAssertEqual(cat("Kinopark 7"), "Развлечения")
        XCTAssertEqual(cat("Starbucks"), "Кафе и рестораны")
        // The operation text is searched too, not only the merchant.
        XCTAssertEqual(cat("ТОО Пример", "Оплата такси"), "Транспорт")
    }

    func testUnknownMerchantFallsBackByOperation() {
        XCTAssertEqual(MerchantCategories.category(operation: "Покупка", merchant: "ТОО Ромашка", incoming: false, rules: nil), "Покупки")
        XCTAssertEqual(MerchantCategories.category(operation: "ОПЛАТА услуг", merchant: "ИП Пример", incoming: false, rules: nil), "Покупки")
        XCTAssertEqual(MerchantCategories.category(operation: "Разное", merchant: "ИП Пример", incoming: false, rules: nil), "Без категории")
        XCTAssertEqual(MerchantCategories.category(operation: "", merchant: "", incoming: false, rules: nil), "Без категории")
    }

    func testEveryAutomaticCategoryIsOfferedInTheList() {
        let samples: [(String, String, Bool)] = [
            ("Покупка", "Wolt", false), ("Покупка", "Magnum", false), ("Покупка", "KFC", false),
            ("Покупка", "Uber", false), ("Покупка", "Ozon", false), ("Покупка", "Europharma", false),
            ("Оплата", "Kcell", false), ("Оплата", "Spotify", false), ("Оплата", "Alseco", false),
            ("Оплата", "Steam", false), ("Оплата", "Университет", false), ("Снятие", "ATM", false),
            ("Перевод", "X", false), ("Пополнение", "X", true), ("Пополнение", "salary", true),
            ("Покупка", "ТОО Ромашка", false), ("Прочее", "ТОО Ромашка", false),
        ]
        for (operation, merchant, incoming) in samples {
            let category = MerchantCategories.category(operation: operation, merchant: merchant, incoming: incoming, rules: nil)
            XCTAssertTrue(MerchantCategories.all.contains(category), "\(category) for \(merchant) is missing from the picker")
        }
    }
}

final class FinanceInsightsTests: XCTestCase {

    private func record(
        _ id: String,
        _ kind: String,
        _ amount: Int64,
        _ date: String,
        category: String? = nil,
        merchant: String? = nil,
        title: String = "Запись",
        excluded: Bool? = nil
    ) -> FinanceRecord {
        var r = FinanceRecord(id: id, kind: kind, title: title, amountMinor: amount, date: date, category: category)
        r.merchant = merchant
        r.excluded = excluded
        return r
    }

    func testMonthTotalsCountOnlyUpToTodayAndComparePreviousMonth() {
        let state = FinanceState(records: [
            record("b", "balance", 999_999, "2026-03-01"),
            record("e1", "expense", 10_000, "2026-03-02", category: "Продукты"),
            record("e2", "expense", 20_000, "2026-03-20", category: "Транспорт"),
            record("e3", "expense", 99_000, "2026-03-25", category: "Транспорт"),
            record("i1", "income", 50_000, "2026-03-05"),
            record("e4", "expense", 7_000, "2026-02-10"),
            record("i2", "income", 30_000, "2026-02-01"),
            record("g", "goal", 123_000, "2026-03-03"),
        ])
        let insights = FinanceInsights.compute(state, month: "2026-03", today: "2026-03-20")
        XCTAssertEqual(insights.month, "2026-03")
        XCTAssertEqual(insights.expenseMinor, 30_000, "The future operation on the 25th does not count yet")
        XCTAssertEqual(insights.incomeMinor, 50_000)
        XCTAssertEqual(insights.previousExpenseMinor, 7_000)
        XCTAssertEqual(insights.previousIncomeMinor, 30_000)
        XCTAssertEqual(insights.categories.map(\.name), ["Транспорт", "Продукты"])
        XCTAssertEqual(insights.categories.map(\.amountMinor), [20_000, 10_000])
    }

    func testExcludedRecordsAreLeftOutEverywhere() {
        let state = FinanceState(records: [
            record("e1", "expense", 5_000, "2026-03-02", category: "Продукты", merchant: "Shop A"),
            record("t1", "expense", 80_000, "2026-03-03", category: "Переводы", merchant: "Own card", excluded: true),
            record("t2", "income", 80_000, "2026-03-03", merchant: "Own card", excluded: true),
            record("t3", "expense", 4_000, "2026-02-03", excluded: true),
        ])
        let insights = FinanceInsights.compute(state, month: "2026-03", today: "2026-03-31")
        XCTAssertEqual(insights.expenseMinor, 5_000)
        XCTAssertEqual(insights.incomeMinor, 0)
        XCTAssertEqual(insights.previousExpenseMinor, 0)
        XCTAssertEqual(insights.categories.map(\.name), ["Продукты"])
        XCTAssertEqual(insights.topMerchants.map(\.name), ["Shop A"])
    }

    func testPreviousMonthWrapsAcrossYears() {
        XCTAssertEqual(FinanceInsights.previousMonth("2026-01"), "2025-12")
        XCTAssertEqual(FinanceInsights.previousMonth("2026-10"), "2026-09")
        XCTAssertEqual(FinanceInsights.previousMonth("2026-12"), "2026-11")
        XCTAssertEqual(FinanceInsights.previousMonth("bad"), "bad")

        let state = FinanceState(records: [
            record("dec", "expense", 1_500, "2025-12-31"),
            record("jan", "expense", 2_500, "2026-01-02"),
        ])
        let insights = FinanceInsights.compute(state, month: "2026-01", today: "2026-01-15")
        XCTAssertEqual(insights.expenseMinor, 2_500)
        XCTAssertEqual(insights.previousExpenseMinor, 1_500)
    }

    func testMoreThanSixCategoriesFoldIntoRest() {
        let names = ["К1", "К2", "К3", "К4", "К5", "К6", "К7"]
        let records = names.enumerated().map { i, name in
            record("e\(i)", "expense", Int64(700 - i * 100), "2026-05-0\(i + 1)", category: name)
        }
        let insights = FinanceInsights.compute(FinanceState(records: records), month: "2026-05", today: "2026-05-31")
        XCTAssertEqual(insights.categories.map(\.name), ["К1", "К2", "К3", "К4", "К5", "Остальное"])
        XCTAssertEqual(insights.categories.last?.amountMinor, 200 + 100)
        XCTAssertEqual(insights.categories.reduce(0) { $0 + $1.amountMinor }, insights.expenseMinor)
    }

    func testExactlySixCategoriesAreNotFoldedAndTiesSortByName() {
        let records = [
            record("a", "expense", 300, "2026-05-01", category: "Б"),
            record("b", "expense", 300, "2026-05-01", category: "А"),
            record("c", "expense", 200, "2026-05-01", category: "В"),
            record("d", "expense", 100, "2026-05-01", category: "Г"),
            record("e", "expense", 100, "2026-05-01", category: "Д"),
            record("f", "expense", 50, "2026-05-01", category: nil),
        ]
        let insights = FinanceInsights.compute(FinanceState(records: records), month: "2026-05", today: "2026-05-02")
        XCTAssertEqual(insights.categories.map(\.name), ["А", "Б", "В", "Г", "Д", "Без категории"])
        XCTAssertFalse(insights.categories.contains { $0.name == "Остальное" })
    }

    func testTopMerchantsGroupByMerchantOrTitleAndKeepFive() {
        var records: [FinanceRecord] = [
            record("m1", "expense", 1_000, "2026-06-01", merchant: "Shop A"),
            record("m2", "expense", 2_500, "2026-06-02", merchant: "Shop A"),
            record("t1", "expense", 3_000, "2026-06-03", title: "Ручной ввод"),
        ]
        for i in 0..<5 {
            records.append(record("x\(i)", "expense", Int64(100 + i), "2026-06-04", merchant: "Small \(i)"))
        }
        records.append(record("inc", "income", 90_000, "2026-06-05", merchant: "Employer"))
        let insights = FinanceInsights.compute(FinanceState(records: records), month: "2026-06", today: "2026-06-30")
        XCTAssertEqual(insights.topMerchants.count, 5)
        XCTAssertEqual(insights.topMerchants[0], FinanceInsights.Slice(name: "Shop A", amountMinor: 3_500))
        XCTAssertEqual(insights.topMerchants[1], FinanceInsights.Slice(name: "Ручной ввод", amountMinor: 3_000))
        XCTAssertEqual(insights.topMerchants.dropFirst(2).map(\.name), ["Small 4", "Small 3", "Small 2"])
        XCTAssertFalse(insights.topMerchants.contains { $0.name == "Employer" }, "Income is not a merchant expense")
    }

    func testForecastOnlyForTheCurrentMonth() {
        let state = FinanceState(records: [
            record("a", "expense", 10_000, "2026-04-03"),
            record("m", "expense", 6_000, "2026-03-10"),
        ])
        let current = FinanceInsights.compute(state, month: "2026-04", today: "2026-04-10")
        XCTAssertEqual(current.forecastExpenseMinor, 30_000, "10 000 over 10 days, 30 days in April")

        XCTAssertNil(FinanceInsights.compute(state, month: "2026-03", today: "2026-04-10").forecastExpenseMinor, "Past month")
        XCTAssertNil(FinanceInsights.compute(state, month: "2026-05", today: "2026-04-10").forecastExpenseMinor, "Future month")
    }

    func testForecastOnFirstDayAndInLeapFebruary() {
        let first = FinanceInsights.compute(
            FinanceState(records: [record("a", "expense", 500, "2026-04-01")]), month: "2026-04", today: "2026-04-01")
        XCTAssertEqual(first.forecastExpenseMinor, 15_000)

        let leap = FinanceInsights.compute(
            FinanceState(records: [record("a", "expense", 14_000, "2028-02-10")]), month: "2028-02", today: "2028-02-14")
        XCTAssertEqual(leap.forecastExpenseMinor, 29_000, "29 days in February 2028")

        let empty = FinanceInsights.compute(emptyFinance(), month: "2026-04", today: "2026-04-15")
        XCTAssertEqual(empty.forecastExpenseMinor, 0)
        XCTAssertTrue(empty.categories.isEmpty)
        XCTAssertTrue(empty.topMerchants.isEmpty)
    }
}

/// Regressions for review findings in categories and insights.
final class CategoryFindingsTests: XCTestCase {
    private func cat(_ merchant: String) -> String {
        MerchantCategories.category(operation: "Покупка", merchant: merchant, incoming: false, rules: nil)
    }

    func testMarketplacesAreShoppingNotGroceries() {
        XCTAssertEqual(cat("Яндекс Маркет"), "Покупки")
        XCTAssertEqual(cat("Wildberries Marketplace"), "Покупки")
        XCTAssertEqual(cat("Magnum Market"), "Продукты")
    }

    func testBarAtTheEndOfTheNameIsACafe() {
        XCTAssertEqual(cat("Sky Bar"), "Кафе и рестораны")
        XCTAssertEqual(cat("Barber Shop"), "Покупки", "«bar» inside a word is not a bar")
    }

    func testCoffeeShopStaysACafe() {
        XCTAssertEqual(cat("Coffee Shop"), "Кафе и рестораны")
    }

    func testTopMerchantsIgnoreCase() {
        var a = FinanceRecord(id: "a", kind: "expense", title: "x", amountMinor: 1_000, date: "2026-06-01", category: nil)
        a.merchant = "MAGNUM"
        var b = FinanceRecord(id: "b", kind: "expense", title: "x", amountMinor: 2_000, date: "2026-06-02", category: nil)
        b.merchant = "Magnum "
        let insights = FinanceInsights.compute(FinanceState(records: [a, b]), month: "2026-06", today: "2026-06-30")
        XCTAssertEqual(insights.topMerchants, [FinanceInsights.Slice(name: "MAGNUM", amountMinor: 3_000)])
    }
}
