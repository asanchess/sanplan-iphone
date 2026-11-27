import Foundation

/// Numbers behind the money charts, from records that count (excluded ones never do).
public struct FinanceInsights: Equatable {
    public struct Slice: Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let amountMinor: Int64
    }

    public let month: String
    public let expenseMinor: Int64
    public let previousExpenseMinor: Int64
    public let incomeMinor: Int64
    public let previousIncomeMinor: Int64
    public let categories: [Slice]
    public let topMerchants: [Slice]
    /// Spending at the current pace until the end of the month; nil for past or future months.
    public let forecastExpenseMinor: Int64?

    public static func compute(_ state: FinanceState, month: String, today: String) -> FinanceInsights {
        // A refund takes its money back out of the spending category.
        let counted = state.records.filter { $0.excluded != true && ($0.kind == "income" || $0.kind == "expense") }
            .map(FinanceLedger.netted)
        let previous = previousMonth(month)
        func total(_ kind: String, _ m: String) -> Int64 {
            counted.filter { $0.kind == kind && ($0.date ?? "").hasPrefix(m) && ($0.date ?? "") <= today }
                .reduce(0) { $0 + ($1.amountMinor ?? 0) }
        }
        let expenses = counted.filter { $0.kind == "expense" && ($0.date ?? "").hasPrefix(month) && ($0.date ?? "") <= today }

        // Typed steps: as one chain the compiler gives up on type-checking these.
        func ranked(_ groups: [String: [FinanceRecord]], name: (String, [FinanceRecord]) -> String) -> [Slice] {
            var slices: [Slice] = []
            for (key, records) in groups {
                let sum = records.reduce(Int64(0)) { $0 + ($1.amountMinor ?? 0) }
                if sum > 0 { slices.append(Slice(name: name(key, records), amountMinor: sum)) }
            }
            return slices.sorted { (a: Slice, b: Slice) -> Bool in
                if a.amountMinor != b.amountMinor { return a.amountMinor > b.amountMinor }
                return a.name < b.name
            }
        }
        let categoryGroups = Dictionary(grouping: expenses) { (r: FinanceRecord) -> String in r.category ?? "Без категории" }
        let byCategory = ranked(categoryGroups) { key, _ in key }
        let categories = byCategory.count > 6
            ? Array(byCategory.prefix(5)) + [Slice(name: "Остальное", amountMinor: byCategory.dropFirst(5).reduce(0) { $0 + $1.amountMinor })]
            : byCategory

        // «MAGNUM» and «Magnum» are one merchant; the name shown is the one seen first.
        let merchantGroups = Dictionary(grouping: expenses) { (r: FinanceRecord) -> String in MerchantCategories.key(r.merchant ?? r.title) }
        let byMerchant = ranked(merchantGroups) { _, records in records[0].merchant ?? records[0].title }

        let expense = total("expense", month)
        var forecast: Int64?
        if today.hasPrefix(month), let day = Int(today.suffix(2)),
           let year = Int(month.prefix(4)), let monthNumber = Int(month.suffix(2)) {
            let days = getDaysInMonth(year: year, month: monthNumber)
            forecast = day > 0 ? expense * Int64(days) / Int64(day) : nil
        }

        return FinanceInsights(
            month: month,
            expenseMinor: expense,
            previousExpenseMinor: total("expense", previous),
            incomeMinor: total("income", month),
            previousIncomeMinor: total("income", previous),
            categories: categories,
            topMerchants: Array(byMerchant.prefix(5)),
            forecastExpenseMinor: forecast
        )
    }

    public static func previousMonth(_ month: String) -> String {
        guard let year = Int(month.prefix(4)), let m = Int(month.suffix(2)) else { return month }
        return m == 1 ? String(format: "%04d-12", year - 1) : String(format: "%04d-%02d", year, m - 1)
    }
}
