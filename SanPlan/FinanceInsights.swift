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
        let counted = state.records.filter { $0.excluded != true && ($0.kind == "income" || $0.kind == "expense") }
        let previous = previousMonth(month)
        func total(_ kind: String, _ m: String) -> Int64 {
            counted.filter { $0.kind == kind && ($0.date ?? "").hasPrefix(m) && ($0.date ?? "") <= today }
                .reduce(0) { $0 + ($1.amountMinor ?? 0) }
        }
        let expenses = counted.filter { $0.kind == "expense" && ($0.date ?? "").hasPrefix(month) && ($0.date ?? "") <= today }

        let byCategory = Dictionary(grouping: expenses, by: { $0.category ?? "Без категории" })
            .map { Slice(name: $0.key, amountMinor: $0.value.reduce(0) { $0 + ($1.amountMinor ?? 0) }) }
            .sorted { $0.amountMinor != $1.amountMinor ? $0.amountMinor > $1.amountMinor : $0.name < $1.name }
        let categories = byCategory.count > 6
            ? Array(byCategory.prefix(5)) + [Slice(name: "Остальное", amountMinor: byCategory.dropFirst(5).reduce(0) { $0 + $1.amountMinor })]
            : byCategory

        let byMerchant = Dictionary(grouping: expenses, by: { $0.merchant ?? $0.title })
            .map { Slice(name: $0.key, amountMinor: $0.value.reduce(0) { $0 + ($1.amountMinor ?? 0) }) }
            .sorted { $0.amountMinor != $1.amountMinor ? $0.amountMinor > $1.amountMinor : $0.name < $1.name }

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
