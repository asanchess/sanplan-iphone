import Foundation

// Сводки раздела «Деньги» для остальных разделов (docs/contracts/DOMAINS.md §2).
// Чистые функции над FinanceState. Все суммы здесь — целые тенге (не minor-единицы записей),
// даты — «YYYY-MM-DD». Ничего не уходит с телефона.

public struct FinanceDaySummary: Equatable {
    public let spent: Int64
    public let byCategory: [String: Int64]
    public let currency: String
}

public struct FinancePeriodSummary: Equatable {
    public let spent: Int64
    public let count: Int
    public let byCategory: [String: Int64]
}

/// «Можно потратить сегодня»: сумма в тенге и одна строка «почему такая сумма».
public struct CanSpendToday: Equatable {
    public let amount: Int64
    public let basis: String
}

public struct SavingsGoalSummary: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let saved: Int64
    public let target: Int64
}

public enum FinanceSummaries {
    static let currency = "KZT"

    /// Траты, которые считаются в сводках: расходы без исключённых и без переводов между своими счетами.
    static func spending(_ state: FinanceState) -> [FinanceRecord] {
        FinanceBudgeting.counted(state).filter { $0.kind == "expense" && !FinanceBudgeting.isOwnTransfer($0) }
    }

    static func name(_ r: FinanceRecord) -> String { r.category ?? "Без категории" }

    static func tenge(_ minor: Int64) -> Int64 { minor / FinanceBudgeting.oneTenge }

    static func totals(_ records: [FinanceRecord]) -> (spent: Int64, byCategory: [String: Int64]) {
        var by: [String: Int64] = [:]
        var sum: Int64 = 0
        for r in records {
            let amount = r.amountMinor ?? 0
            sum += amount
            by[name(r), default: 0] += amount
        }
        return (tenge(sum), by.mapValues(tenge))
    }

    public static func day(_ state: FinanceState, _ day: String) -> FinanceDaySummary {
        let t = totals(spending(state).filter { $0.date == day })
        return FinanceDaySummary(spent: t.spent, byCategory: t.byCategory, currency: currency)
    }

    public static func period(_ state: FinanceState, from: String, to: String, category: String? = nil) -> FinancePeriodSummary {
        let picked = spending(state).filter { r in
            guard let d = r.date, d >= from, d <= to else { return false }
            if let category, name(r) != category { return false }
            return true
        }
        let t = totals(picked)
        return FinancePeriodSummary(spent: t.spent, count: picked.count, byCategory: t.byCategory)
    }

    /// Дни с реальными операциями (доход или расход) в [from, to], по возрастанию, без повторов.
    public static func activityDays(_ state: FinanceState, from: String, to: String) -> [String] {
        let days = FinanceBudgeting.counted(state).compactMap(\.date).filter { $0 >= from && $0 <= to }
        return Array(Set(days)).sorted()
    }

    public static func savingsGoals(_ state: FinanceState) -> [SavingsGoalSummary] {
        state.records.filter { $0.kind == "goal" }.map {
            SavingsGoalSummary(id: $0.id, title: $0.title, saved: tenge($0.savedMinor ?? 0), target: tenge($0.amountMinor ?? 0))
        }
    }

    /// Правило «можно потратить сегодня» (то же самое в вебе, src/finance-summary.mjs):
    ///
    ///   остатокДоСегодня = Σ по категориям с лимитом max(0, лимит − потрачено в месяце ДО сегодняшнего дня)
    ///   долят            = остатокДоСегодня / (дней до конца месяца, считая сегодня)
    ///   сегодня          = max(0, долят − потрачено сегодня в категориях с лимитом)
    ///   свободно         = остаток на счетах − накопления на счетах − неоплаченные платежи плана
    ///   amount           = min(сегодня, max(0, свободно))   (если остаток на счетах известен)
    ///
    /// Обязательные платежи плана в лимиты не входят, поэтому они вычитаются через «свободно»:
    /// если денег после платежей и накоплений меньше доли лимитов, сумма урезается до них.
    /// Нет лимитов — nil (в Деньгах показывается подсказка задать их). Перерасход категории не уменьшает
    /// долю других: остаток по категории не уходит ниже нуля. В последний день месяца делитель 1.
    public static func canSpendToday(_ state: FinanceState, on today: String) -> CanSpendToday? {
        guard isValidDateString(today),
              let limits = state.budget?.limits, !limits.isEmpty,
              let info = FinanceBudgeting.dayInfo(String(today.prefix(7)), today: today) else { return nil }
        let month = String(today.prefix(7))
        let daysLeft = max(1, info.total - info.elapsed + 1)
        let flexible = FinanceBudgeting.flexibleExpenses(state, month: month, upTo: today)
        var before: [String: Int64] = [:]
        var todaySpent: Int64 = 0
        for r in flexible {
            let cat = name(r)
            guard limits[cat] != nil else { continue }
            if r.date == today { todaySpent += r.amountMinor ?? 0 } else { before[cat, default: 0] += r.amountMinor ?? 0 }
        }
        let remaining = limits.reduce(Int64(0)) { $0 + max(0, $1.value - (before[$1.key] ?? 0)) }
        let share = remaining / Int64(daysLeft)
        var amount = max(0, share - todaySpent)
        var basis: String
        if remaining == 0 {
            basis = "Лимиты месяца исчерпаны"
        } else {
            basis = "Остаток лимитов \(FinanceBudgeting.money(remaining)) на \(daysLeft) \(dayWord(daysLeft))"
            if todaySpent > 0 { basis += ", сегодня уже потрачено \(FinanceBudgeting.money(todaySpent))" }
        }
        if let summary = try? financeSummary(state, today: today), let balance = summary.balanceMinor {
            let free = max(0, balance - summary.reservedGoalMinor - summary.obligationsMinor)
            if free < amount {
                amount = free
                basis = "Ограничено свободными деньгами: на счетах \(FinanceBudgeting.money(balance)), накопления и платежи плана вычтены"
            }
        }
        return CanSpendToday(amount: tenge(amount), basis: basis)
    }

    static func dayWord(_ n: Int) -> String {
        if n % 10 == 1 && n % 100 != 11 { return "день" }
        if (2...4).contains(n % 10) && !(12...14).contains(n % 100) { return "дня" }
        return "дней"
    }
}

extension FinanceStore {
    public func daySummary(for day: String) -> FinanceDaySummary { FinanceSummaries.day(state, day) }

    public func periodSummary(from: String, to: String, category: String? = nil) -> FinancePeriodSummary {
        FinanceSummaries.period(state, from: from, to: to, category: category)
    }

    public func canSpendToday(on day: String) -> CanSpendToday? { FinanceSummaries.canSpendToday(state, on: day) }

    public var savingsGoals: [SavingsGoalSummary] { FinanceSummaries.savingsGoals(state) }

    public func activityDays(from: String, to: String) -> [String] {
        FinanceSummaries.activityDays(state, from: from, to: to)
    }
}
