import Foundation

// The monthly plan on top of the records (docs/personal-hub/FINANCE-BUDGET-SPEC.md):
// envelopes, category limits, «Чистыми», payment matching, the operations feed, rule-based hints and the chat export.
// Everything here is plain arithmetic on the device; nothing leaves the phone.

/// The owner's plan and the answers already given, so the same question is never asked twice.
/// Lives inside the encrypted FinanceState; references to records that are gone are dropped on validation.
public struct FinanceBudget: Codable, Equatable {
    /// Monthly limit per spending category, in minor units.
    public var limits: [String: Int64]?
    /// Share of each income suggested for the savings envelope, 0...100. Nil means the default.
    public var savePercent: Int?
    /// Averages and hints use operations from this day on. Nil means the default.
    public var analysisStart: String?
    /// The goal that receives set-asides.
    public var savingsGoalId: String?
    /// Normalised merchant → the obligation it pays, learned from confirmed payments.
    public var obligationMerchants: [String: String]?
    /// «obligationId|recordId» pairs the owner said are not that payment.
    public var dismissedMatches: [String]?
    /// Incomes already offered for setting aside, accepted or not.
    public var handledIncomes: [String]?
    /// Months whose review card the owner closed.
    public var reviewedMonths: [String]?
    /// Payments marked paid without an operation: «obligationId|yyyy-MM» for a monthly one,
    /// «obligationId|yyyy-MM-dd» for one weekly charge.
    public var manualPaid: [String]?

    public init(
        limits: [String: Int64]? = nil,
        savePercent: Int? = nil,
        analysisStart: String? = nil,
        savingsGoalId: String? = nil,
        obligationMerchants: [String: String]? = nil,
        dismissedMatches: [String]? = nil,
        handledIncomes: [String]? = nil,
        reviewedMonths: [String]? = nil,
        manualPaid: [String]? = nil
    ) {
        self.limits = limits
        self.savePercent = savePercent
        self.analysisStart = analysisStart
        self.savingsGoalId = savingsGoalId
        self.obligationMerchants = obligationMerchants
        self.dismissedMatches = dismissedMatches
        self.handledIncomes = handledIncomes
        self.reviewedMonths = reviewedMonths
        self.manualPaid = manualPaid
    }

    static let maxLimits = 64
    static let maxAnswers = 1000

    /// Throws on values that cannot be right; quietly drops answers about records that no longer exist.
    static func validated(_ b: FinanceBudget, records: [FinanceRecord]) throws -> FinanceBudget? {
        var out = FinanceBudget()
        if let limits = b.limits {
            guard limits.count <= maxLimits else { throw FinanceError.invalidState("Too many limits") }
            var clean: [String: Int64] = [:]
            for entry in limits {
                let name = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= FinanceConstants.maxTitleLen, isValidMoney(entry.value) else {
                    throw FinanceError.invalidState("Invalid category limit")
                }
                clean[name] = entry.value
            }
            out.limits = clean.isEmpty ? nil : clean
        }
        if let percent = b.savePercent {
            guard (0...100).contains(percent) else { throw FinanceError.invalidState("Invalid save percent") }
            out.savePercent = percent
        }
        if let start = b.analysisStart {
            guard isValidDateString(start) else { throw FinanceError.invalidState("Invalid analysis start") }
            out.analysisStart = start
        }

        let ids = Set(records.map(\.id))
        let goals = Set(records.filter { $0.kind == "goal" }.map(\.id))
        let obligations = Set(records.filter { $0.kind == "obligation" }.map(\.id))
        out.savingsGoalId = b.savingsGoalId.flatMap { goals.contains($0) ? $0 : nil }
        let merchants = (b.obligationMerchants ?? [:]).filter { !$0.key.isEmpty && obligations.contains($0.value) }
        out.obligationMerchants = merchants.isEmpty ? nil : merchants
        out.dismissedMatches = answers(b.dismissedMatches) { pair in
            let parts = pair.split(separator: "|").map(String.init)
            return parts.count == 2 && obligations.contains(parts[0]) && ids.contains(parts[1])
        }
        out.handledIncomes = answers(b.handledIncomes) { ids.contains($0) }
        out.reviewedMonths = answers(b.reviewedMonths) { isValidMonthString($0) }
        out.manualPaid = answers(b.manualPaid) { mark in
            let parts = mark.split(separator: "|").map(String.init)
            return parts.count == 2 && obligations.contains(parts[0]) && (isValidMonthString(parts[1]) || isValidDateString(parts[1]))
        }
        return out == FinanceBudget() ? nil : out
    }

    private static func answers(_ list: [String]?, keep: (String) -> Bool) -> [String]? {
        var seen = Set<String>()
        let clean = (list ?? []).filter { keep($0) && seen.insert($0).inserted }
        return clean.isEmpty ? nil : Array(clean.suffix(maxAnswers))
    }
}

/// How one category limit stands this month.
public struct LimitStatus: Equatable, Identifiable {
    public var id: String { category }
    public let category: String
    public let limitMinor: Int64
    public let spentMinor: Int64
    /// Spending at the current pace by the end of the month.
    public let projectedMinor: Int64
    /// Day of the month the limit runs out at the current pace; nil when it lasts or is already spent.
    public let runsOutDay: Int?

    public var remainingMinor: Int64 { max(0, limitMinor - spentMinor) }
    public var overMinor: Int64 { max(0, spentMinor - limitMinor) }
    public var usedPercent: Int { limitMinor > 0 ? Int(spentMinor * 100 / limitMinor) : 0 }
}

/// The header numbers: what is on the accounts and what is left once every plan is taken out.
public struct BudgetSnapshot: Equatable {
    public let onAccountsMinor: Int64?
    /// Date of the balance the numbers start from: the latest statement or reconciliation.
    public let asOf: String?
    public let statementAgeDays: Int?
    /// Everything in the envelopes (savings goals).
    public let reservedMinor: Int64
    /// Payments of the plan not yet paid this month.
    public let unpaidPaymentsMinor: Int64
    public let limits: [LimitStatus]
    public let limitsRemainingMinor: Int64
    /// On the accounts − envelopes − unpaid payments − what is left on the limits. Negative: the plan does not fit.
    public let cleanMinor: Int64?
    /// What is left on the limits per remaining day, today included.
    public let flexiblePerDayMinor: Int64
    public let daysLeft: Int

    public var isStale: Bool { (statementAgeDays ?? 0) > 7 }
}

/// Where one payment of the plan stands this month. The header, the plan and the month review all read this.
public struct PaymentStatus: Equatable {
    /// Operations linked to it this month, up to today.
    public let paidMinor: Int64
    /// Monthly: paid this month. Weekly: today's charge is paid, or none falls today.
    public let isPaid: Bool
    public let markedByHand: Bool
    /// What «Чистыми» still keeps for it until the month ends.
    public let unpaidMinor: Int64
    /// Weekly: charges still ahead this month, today's included while unpaid. Monthly: 1 while unpaid.
    public let chargesLeft: Int
    /// Weekly: a charge falls today, so it can be marked. Monthly: always.
    public let isDue: Bool
}

public struct PaymentMatch: Equatable, Identifiable {
    public var id: String { obligationId + "|" + recordId }
    public let obligationId: String
    public let obligationTitle: String
    public let recordId: String
    public let recordTitle: String
    public let amountMinor: Int64
    public let date: String
}

public struct SetAsideOffer: Equatable, Identifiable {
    public var id: String { incomeId }
    public let incomeId: String
    public let incomeTitle: String
    public let incomeMinor: Int64
    public let suggestedMinor: Int64
    public let date: String
}

public enum LedgerKind: String, CaseIterable {
    case all, expense, income, transfer
}

public struct LedgerFilter: Equatable {
    /// «yyyy-MM»; nil means all time.
    public var month: String?
    /// One of `FinanceBudgeting.ledgerSources`.
    public var source: String?
    public var kind: LedgerKind
    public var category: String?
    public var query: String

    public init(month: String? = nil, source: String? = nil, kind: LedgerKind = .all, category: String? = nil, query: String = "") {
        self.month = month
        self.source = source
        self.kind = kind
        self.category = category
        self.query = query
    }
}

public struct LedgerEntry: Equatable, Identifiable {
    public var id: String { record.id }
    public let record: FinanceRecord
    /// «Kaspi», «Halyk» or «Вручную».
    public let source: String
    /// A transfer between the owner's own accounts: shown grey, never in a total.
    public let isOwnTransfer: Bool
    /// False for anything left out of the totals.
    public let counts: Bool
}

public struct LedgerDay: Equatable, Identifiable {
    public var id: String { date }
    public let date: String
    public var entries: [LedgerEntry]
    /// Income minus spending of the day, counting only entries that count.
    public var netMinor: Int64
}

public struct FinanceHint: Equatable, Identifiable {
    public enum Kind: String {
        case overLimit, pace, nearLimit, growth, recurring, smallFrequent, runway
    }
    public var id: String { kind.rawValue + ":" + subject }
    public let kind: Kind
    /// The category or merchant the hint is about; empty for the cushion.
    public let subject: String
    public let text: String
    public let priority: Int
}

public struct MonthReview: Equatable {
    public let month: String
    public let incomeMinor: Int64
    public let expenseMinor: Int64
    public let previousExpenseMinor: Int64
    /// Average monthly spending over whole months since the analysis start, this month left out.
    public let averageExpenseMinor: Int64?
    public let limits: [LimitStatus]
    /// Left unspent on the limits; the review offers to set it aside.
    public let savedOnLimitsMinor: Int64
    public let overspentMinor: Int64
    public let paidPayments: [String]
    public let unpaidPayments: [String]
}

public enum FinanceBudgeting {
    public static let defaultAnalysisStart = "2026-09-01"
    public static let defaultSavePercent = 10
    public static let manualSource = "Вручную"
    public static let reconcileTitle = "Сверка остатка"

    static let oneTenge: Int64 = 100
    /// A limit running out at least this many days before the month ends is worth a hint.
    static let earlyRunOutDays = 5
    /// Money coming in, never a spending category.
    static let incomeCategories: Set<String> = ["Зарплата", "Пополнения"]
    /// Categories whose merchants are people or cash, never named in hints or the export.
    static let personalCategories: Set<String> = ["Переводы", "Наличные", "Пополнения", "Зарплата"]
    /// Money the owner moved in, not earned: no set-aside offer for it.
    static let personalIncomeCategories: Set<String> = ["Пополнения"]

    // MARK: Plan settings

    /// Applies a change to the plan and validates the result.
    public static func updateBudget(_ state: FinanceState, _ change: (inout FinanceBudget) -> Void) throws -> FinanceState {
        var next = try validateFinance(state)
        var budget = next.budget ?? FinanceBudget()
        change(&budget)
        next.budget = budget
        return try validateFinance(next)
    }

    public static func setLimits(_ state: FinanceState, _ limits: [String: Int64]) throws -> FinanceState {
        let clean = limits.filter { $0.value > 0 }
        return try updateBudget(state) { $0.limits = clean.isEmpty ? nil : clean }
    }

    public static func analysisStart(_ state: FinanceState) -> String {
        state.budget?.analysisStart ?? defaultAnalysisStart
    }

    // MARK: Limits

    public static func limitStatuses(_ state: FinanceState, month: String, today: String) -> [LimitStatus] {
        guard let limits = state.budget?.limits, !limits.isEmpty, let days = dayInfo(month, today: today) else { return [] }
        let spentBy = totalsByCategory(flexibleExpenses(state, month: month, upTo: today))
        return limits.map { entry -> LimitStatus in
            let limit = entry.value
            let spent = spentBy[entry.key] ?? 0
            let projected = days.elapsed > 0 ? spent * Int64(days.total) / Int64(days.elapsed) : spent
            var runsOut: Int?
            // Fewer than five days in, one purchase would set the pace for the whole month.
            if spent > 0, spent < limit, projected > limit, days.elapsed >= 5, days.elapsed < days.total {
                // The day the running total reaches the limit at today's pace, rounded up.
                let day = Int((limit * Int64(days.elapsed) + spent - 1) / spent)
                runsOut = day <= days.total ? day : nil
            }
            return LimitStatus(category: entry.key, limitMinor: limit, spentMinor: spent, projectedMinor: projected, runsOutDay: runsOut)
        }
        .sorted { $0.limitMinor != $1.limitMinor ? $0.limitMinor > $1.limitMinor : $0.category < $1.category }
    }

    /// A first draft of limits: the average monthly spending per category over whole months since the analysis
    /// start, rounded up to 1 000 ₸. Empty until one whole month is known.
    public static func suggestedLimits(_ state: FinanceState, today: String) -> [String: Int64] {
        let months = fullMonths(state, today: today)
        guard !months.isEmpty else { return [:] }
        let inRange = Set(months)
        let expenses = counted(state).filter { $0.kind == "expense" && $0.obligationId == nil && inRange.contains(monthOf($0.date)) }
        let step = 1000 * oneTenge
        var out: [String: Int64] = [:]
        for entry in totalsByCategory(expenses) where !incomeCategories.contains(entry.key) {
            let average = entry.value / Int64(months.count)
            let rounded = (average + step - 1) / step * step
            if rounded > 0 { out[entry.key] = rounded }
        }
        return out
    }

    // MARK: Header

    public static func snapshot(_ state: FinanceState, today: String) throws -> BudgetSnapshot {
        let summary = try financeSummary(state, today: today)
        let month = String(today.prefix(7))
        let limits = limitStatuses(state, month: month, today: today)
        let remaining = limits.reduce(Int64(0)) { $0 + $1.remainingMinor }
        let days = dayInfo(month, today: today) ?? (elapsed: 1, total: 30)
        let daysLeft = max(1, days.total - days.elapsed + 1)
        let asOf = state.records
            .filter { $0.kind == "balance" && $0.excluded != true && ($0.date ?? "") <= today }
            .compactMap(\.date).max()
        return BudgetSnapshot(
            onAccountsMinor: summary.balanceMinor,
            asOf: asOf,
            statementAgeDays: asOf.flatMap { daysBetween($0, today) },
            reservedMinor: summary.reservedGoalMinor,
            unpaidPaymentsMinor: summary.obligationsMinor,
            limits: limits,
            limitsRemainingMinor: remaining,
            cleanMinor: summary.balanceMinor.map { $0 - summary.reservedGoalMinor - summary.obligationsMinor - remaining },
            flexiblePerDayMinor: remaining / Int64(daysLeft),
            daysLeft: daysLeft
        )
    }

    /// The owner enters what is on the cards now; it becomes the newest balance, so the difference is neither
    /// income nor spending. A second reconciliation on the same day replaces the first.
    public static func reconcile(_ state: FinanceState, totalMinor: Int64, today: String, id: String) throws -> FinanceState {
        var next = try validateFinance(state)
        guard isValidDateString(today) else { throw FinanceError.invalidDate("Invalid reconciliation date") }
        next.records.removeAll { $0.kind == "balance" && $0.title == reconcileTitle && $0.date == today }
        next.records.append(FinanceRecord(id: id, kind: "balance", title: reconcileTitle, amountMinor: totalMinor, date: today))
        return try validateFinance(next)
    }

    // MARK: Payments of the plan

    /// Unlinked spending of this month that looks like an unpaid monthly payment: within 10 % of its amount and
    /// either from the merchant that paid it before or sharing a word with its title. One operation per payment.
    public static func paymentMatches(_ state: FinanceState, today: String) -> [PaymentMatch] {
        let month = String(today.prefix(7))
        let dismissed = Set(state.budget?.dismissedMatches ?? [])
        let learned = state.budget?.obligationMerchants ?? [:]
        let thisMonth = counted(state).filter { $0.kind == "expense" && monthOf($0.date) == month && ($0.date ?? "") <= today }
        let candidates = thisMonth.filter { $0.obligationId == nil && !isOwnTransfer($0) }

        var used = Set<String>()
        var out: [PaymentMatch] = []
        for ob in state.records where ob.kind == "obligation" && ob.frequency == "monthly" {
            guard let amount = ob.amountMinor, !paymentStatus(state, obligation: ob, today: today).isPaid else { continue }
            let words = stems(ob.title)
            let fitting = candidates.filter { r in
                guard !used.contains(r.id), !dismissed.contains(ob.id + "|" + r.id), let a = r.amountMinor,
                      abs(a - amount) * 10 <= amount else { return false }
                if learned[MerchantCategories.key(r.merchant ?? r.title)] == ob.id { return true }
                let text = [r.merchant ?? "", r.title, r.category ?? ""].joined(separator: " ").lowercased()
                return words.contains { text.contains($0) }
            }
            guard let best = fitting.min(by: { abs(($0.amountMinor ?? 0) - amount) < abs(($1.amountMinor ?? 0) - amount) }) else { continue }
            used.insert(best.id)
            out.append(PaymentMatch(
                obligationId: ob.id, obligationTitle: ob.title, recordId: best.id, recordTitle: best.merchant ?? best.title,
                amountMinor: best.amountMinor ?? 0, date: best.date ?? today
            ))
        }
        return out
    }

    /// Marks an operation as the payment of a plan item (confirmed match or chosen by hand) and remembers its
    /// merchant for the next months. The summary then stops counting that payment as unpaid.
    public static func linkPayment(_ state: FinanceState, recordId: String, obligationId: String) throws -> FinanceState {
        var next = try validateFinance(state)
        guard let ob = next.records.first(where: { $0.id == obligationId && $0.kind == "obligation" }),
              let i = next.records.firstIndex(where: { $0.id == recordId && $0.kind == "expense" }) else {
            throw FinanceError.invalidState("Платёж или операция не найдены")
        }
        guard next.records[i].obligationId == nil else {
            throw FinanceError.invalidState("Эта операция уже отмечена как оплата другого платежа")
        }
        // One monthly payment is never closed twice: once operations pay its month, no more links. A mark by hand
        // gives way to the real operation, so its merchant is learned.
        if ob.frequency == "monthly", let day = next.records[i].date {
            let mark = obligationId + "|" + String(day.prefix(7))
            var withoutMark = next
            withoutMark.budget?.manualPaid?.removeAll { $0 == mark }
            if paymentStatus(withoutMark, obligation: ob, today: lastDay(of: day)).isPaid {
                throw FinanceError.invalidState("«\(ob.title)» за этот месяц уже оплачен")
            }
            next = withoutMark
        }
        next.records[i].obligationId = obligationId
        let key = MerchantCategories.key(next.records[i].merchant ?? next.records[i].title)
        var budget = next.budget ?? FinanceBudget()
        if !key.isEmpty {
            var merchants = budget.obligationMerchants ?? [:]
            merchants[key] = obligationId
            budget.obligationMerchants = merchants
        }
        next.budget = budget
        return try validateFinance(next)
    }

    /// Marks a payment paid when no operation shows it (cash, someone else paid). Monthly: for the month of today;
    /// weekly: today's charge. Marking again takes the mark back.
    public static func togglePaidByHand(_ state: FinanceState, obligationId: String, today: String) throws -> FinanceState {
        guard let ob = state.records.first(where: { $0.id == obligationId && $0.kind == "obligation" }) else {
            throw FinanceError.invalidState("Платёж не найден")
        }
        let mark = obligationId + "|" + (ob.frequency == "weekly" ? today : String(today.prefix(7)))
        return try updateBudget(state) { budget in
            var marks = budget.manualPaid ?? []
            if let i = marks.firstIndex(of: mark) { marks.remove(at: i) } else { marks.append(mark) }
            budget.manualPaid = marks.isEmpty ? nil : marks
        }
    }

    /// The shared rule for «paid»: linked operations reach 90 % of the amount, or the owner marked it by hand.
    /// Weekly payments keep only the charges still ahead this month; the ones already past are in the balance.
    public static func paymentStatus(_ state: FinanceState, obligation ob: FinanceRecord, today: String) -> PaymentStatus {
        let month = String(today.prefix(7))
        let amount = ob.amountMinor ?? 0
        let marks = Set(state.budget?.manualPaid ?? [])
        var paid: Int64 = 0
        var paidToday: Int64 = 0
        for r in state.records where r.kind == "expense" && r.excluded != true && r.obligationId == ob.id {
            guard let day = r.date, day <= today, day.hasPrefix(month) else { continue }
            paid += r.amountMinor ?? 0
            if day == today { paidToday += r.amountMinor ?? 0 }
        }
        func covers(_ sum: Int64) -> Bool { amount > 0 && sum * 10 >= amount * 9 }

        if ob.frequency == "weekly" {
            let start = ob.date ?? today
            guard let anchor = parseYmd(start), let t = parseYmd(today) else {
                return PaymentStatus(paidMinor: paid, isPaid: true, markedByHand: false, unpaidMinor: 0, chargesLeft: 0, isDue: false)
            }
            let weekday = weekdayFromEpochDays(daysSinceEpoch(year: anchor.year, month: anchor.month, day: anchor.day))
            let end = String(format: "%04d-%02d-%02d", t.year, t.month, getDaysInMonth(year: t.year, month: t.month))
            var left = countWeekdayDates(fromYmd: max(start, today), toYmd: end, targetWeekday: weekday)
            let todayWeekday = weekdayFromEpochDays(daysSinceEpoch(year: t.year, month: t.month, day: t.day))
            let isDue = start <= today && todayWeekday == weekday
            let byHand = isDue && marks.contains(ob.id + "|" + today)
            let todayPaid = isDue && (byHand || covers(paidToday))
            if todayPaid { left = max(0, left - 1) }
            return PaymentStatus(paidMinor: paid, isPaid: !isDue || todayPaid, markedByHand: byHand,
                                 unpaidMinor: amount * Int64(left), chargesLeft: left, isDue: isDue)
        }
        guard ob.frequency == "monthly" else {
            return PaymentStatus(paidMinor: paid, isPaid: true, markedByHand: false, unpaidMinor: 0, chargesLeft: 0, isDue: false)
        }
        let byHand = marks.contains(ob.id + "|" + month)
        let isPaid = byHand || covers(paid)
        return PaymentStatus(paidMinor: paid, isPaid: isPaid, markedByHand: byHand,
                             unpaidMinor: isPaid ? 0 : max(0, amount - paid), chargesLeft: isPaid ? 0 : 1, isDue: true)
    }

    /// Spending of this month not linked to any payment, the closest in amount first, for choosing by hand.
    public static func paymentCandidates(_ state: FinanceState, obligation ob: FinanceRecord, today: String) -> [FinanceRecord] {
        let month = String(today.prefix(7))
        let amount = ob.amountMinor ?? 0
        let list = counted(state).filter {
            $0.kind == "expense" && $0.obligationId == nil && !isOwnTransfer($0) && monthOf($0.date) == month && ($0.date ?? "") <= today
        }
        return list.sorted { a, b in
            let da = abs((a.amountMinor ?? 0) - amount)
            let db = abs((b.amountMinor ?? 0) - amount)
            return da != db ? da < db : (a.date ?? "") > (b.date ?? "")
        }
    }

    static func lastDay(of date: String) -> String {
        guard let d = parseYmd(date) else { return date }
        return String(format: "%04d-%02d-%02d", d.year, d.month, getDaysInMonth(year: d.year, month: d.month))
    }

    public static func dismissMatch(_ state: FinanceState, _ match: PaymentMatch) throws -> FinanceState {
        try updateBudget(state) { $0.dismissedMatches = ($0.dismissedMatches ?? []) + [match.id] }
    }

    // MARK: Envelopes

    /// Incomes of this month not yet offered for setting aside, with the share the owner chose.
    public static func setAsideOffers(_ state: FinanceState, today: String) -> [SetAsideOffer] {
        let percent = Int64(state.budget?.savePercent ?? defaultSavePercent)
        guard percent > 0 else { return [] }
        let handled = Set(state.budget?.handledIncomes ?? [])
        let month = String(today.prefix(7))
        let step = 100 * oneTenge
        return counted(state)
            .filter {
                $0.kind == "income" && monthOf($0.date) == month && ($0.date ?? "") <= today && !handled.contains($0.id)
                    && !isOwnTransfer($0) && !personalIncomeCategories.contains($0.category ?? "")
            }
            .compactMap { r -> SetAsideOffer? in
                let amount = r.amountMinor ?? 0
                let suggested = amount * percent / 100 / step * step
                guard suggested > 0 else { return nil }
                return SetAsideOffer(incomeId: r.id, incomeTitle: r.merchant ?? r.title, incomeMinor: amount, suggestedMinor: suggested, date: r.date ?? today)
            }
    }

    /// Moves money into an envelope. Nothing moves in the bank; the amount only stops being «Чистыми».
    /// With `raiseTarget` an envelope that is full or nearly full grows its target instead of refusing.
    public static func setAside(_ state: FinanceState, amountMinor: Int64, goalId: String, incomeId: String? = nil,
                                raiseTarget: Bool = false) throws -> FinanceState {
        var next = try validateFinance(state)
        guard amountMinor > 0, let i = next.records.firstIndex(where: { $0.id == goalId && $0.kind == "goal" }) else {
            throw FinanceError.invalidAmount("Нечего откладывать: сумма должна быть больше нуля")
        }
        if let incomeId, (next.budget?.handledIncomes ?? []).contains(incomeId) {
            throw FinanceError.invalidState("С этого дохода уже отложено")
        }
        let (saved, overflow) = (next.records[i].savedMinor ?? 0).addingReportingOverflow(amountMinor)
        guard !overflow, isValidMoney(saved) else { throw FinanceError.invalidAmount("Слишком большая сумма") }
        if saved > (next.records[i].amountMinor ?? 0) {
            guard raiseTarget else { throw FinanceError.invalidAmount("Больше, чем осталось до цели") }
            next.records[i].amountMinor = saved
        }
        next.records[i].savedMinor = saved
        var budget = next.budget ?? FinanceBudget()
        budget.savingsGoalId = goalId
        if let incomeId { budget.handledIncomes = (budget.handledIncomes ?? []) + [incomeId] }
        next.budget = budget
        return try validateFinance(next)
    }

    /// Takes money back out of an envelope.
    public static func withdraw(_ state: FinanceState, amountMinor: Int64, goalId: String) throws -> FinanceState {
        var next = try validateFinance(state)
        guard amountMinor > 0, let i = next.records.firstIndex(where: { $0.id == goalId && $0.kind == "goal" }),
              (next.records[i].savedMinor ?? 0) >= amountMinor else {
            throw FinanceError.invalidAmount("Нельзя забрать больше, чем отложено")
        }
        next.records[i].savedMinor = (next.records[i].savedMinor ?? 0) - amountMinor
        return try validateFinance(next)
    }

    public static func skipSetAside(_ state: FinanceState, incomeId: String) throws -> FinanceState {
        try updateBudget(state) { $0.handledIncomes = ($0.handledIncomes ?? []) + [incomeId] }
    }

    // MARK: Operations feed

    public static func isOwnTransfer(_ r: FinanceRecord) -> Bool {
        r.pairedWith != nil || r.note == StatementImport.ownTransferNote
    }

    public static func source(of r: FinanceRecord, imports: [String: FinanceImport]) -> String {
        guard let importId = r.importId else { return manualSource }
        return imports[importId]?.bank ?? "Выписка"
    }

    /// Sources present in the records, banks first, hand-entered last.
    public static func ledgerSources(_ state: FinanceState) -> [String] {
        let imports = importsById(state)
        let all = Set(state.records.filter { $0.kind == "income" || $0.kind == "expense" }.map { source(of: $0, imports: imports) })
        return all.filter { $0 != manualSource }.sorted() + (all.contains(manualSource) ? [manualSource] : [])
    }

    /// One feed across all banks and hand-entered records, newest day first, grouped by day.
    public static func ledger(_ state: FinanceState, filter: LedgerFilter = LedgerFilter()) -> [LedgerDay] {
        let imports = importsById(state)
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var picked: [(index: Int, entry: LedgerEntry)] = []
        for (index, r) in state.records.enumerated() where r.kind == "income" || r.kind == "expense" {
            guard let date = r.date else { continue }
            if let month = filter.month, !date.hasPrefix(month) { continue }
            let src = source(of: r, imports: imports)
            if let wanted = filter.source, wanted != src { continue }
            let own = isOwnTransfer(r)
            switch filter.kind {
            case .all: break
            case .expense: if r.kind != "expense" || own { continue }
            case .income: if r.kind != "income" || own { continue }
            case .transfer: if !own && r.category != "Переводы" { continue }
            }
            if let category = filter.category, (r.category ?? "Без категории") != category { continue }
            if !query.isEmpty {
                let text = [r.title, r.merchant ?? "", r.note ?? "", r.category ?? ""].joined(separator: " ").lowercased()
                if !text.contains(query) { continue }
            }
            picked.append((index: index, entry: LedgerEntry(record: r, source: src, isOwnTransfer: own, counts: r.excluded != true)))
        }
        // Newest date first; on one day the record added later comes first.
        picked.sort { a, b in
            let da = a.entry.record.date ?? "", db = b.entry.record.date ?? ""
            return da != db ? da > db : a.index > b.index
        }
        var days: [LedgerDay] = []
        for item in picked {
            let date = item.entry.record.date ?? ""
            if days.last?.date != date { days.append(LedgerDay(date: date, entries: [], netMinor: 0)) }
            let last = days.count - 1
            days[last].entries.append(item.entry)
            if item.entry.counts {
                let amount = item.entry.record.amountMinor ?? 0
                days[last].netMinor += item.entry.record.kind == "income" ? amount : -amount
            }
        }
        return days
    }

    /// Income and spending of what a filter found, for the line under the search field.
    public static func ledgerTotals(_ days: [LedgerDay]) -> (incomeMinor: Int64, expenseMinor: Int64, count: Int) {
        var income: Int64 = 0, expense: Int64 = 0, count = 0
        for entry in days.flatMap(\.entries) {
            count += 1
            guard entry.counts else { continue }
            if entry.record.kind == "income" { income += entry.record.amountMinor ?? 0 } else { expense += entry.record.amountMinor ?? 0 }
        }
        return (income, expense, count)
    }

    // MARK: Hints

    /// Facts worth a look, most urgent first. No judgement, only numbers.
    public static func hints(_ state: FinanceState, today: String) -> [FinanceHint] {
        let month = String(today.prefix(7))
        guard let days = dayInfo(month, today: today) else { return [] }
        var out: [FinanceHint] = []

        // Only what matters: a limit already gone, or one that runs out more than five days early. Early run-outs
        // are one hint, so three tight limits do not crowd the overview; the plan's bars show the rest.
        var early: [LimitStatus] = []
        for s in limitStatuses(state, month: month, today: today) {
            if s.spentMinor > s.limitMinor {
                out.append(FinanceHint(kind: .overLimit, subject: s.category, text: "«\(s.category)»: лимит превышен на \(money(s.overMinor))", priority: 100))
            } else if let day = s.runsOutDay, day <= days.total - earlyRunOutDays {
                early.append(s)
            }
        }
        early.sort { ($0.runsOutDay ?? 0) != ($1.runsOutDay ?? 0) ? ($0.runsOutDay ?? 0) < ($1.runsOutDay ?? 0) : $0.category < $1.category }
        if let first = early.first, let day = first.runsOutDay {
            let text = early.count == 1
                ? "«\(first.category)»: при таком темпе лимит закончится \(day)-го"
                : "При таком темпе раньше срока закончатся: " + early.map { "«\($0.category)» \($0.runsOutDay ?? 0)-го" }.joined(separator: ", ")
            out.append(FinanceHint(kind: .pace, subject: early.map(\.category).joined(separator: ","), text: text, priority: 90))
        }

        // Growth against the usual month; too early in the month the pace is noise.
        let months = fullMonths(state, today: today)
        if !months.isEmpty, days.elapsed >= 10 {
            let inRange = Set(months)
            let base = totalsByCategory(counted(state).filter { $0.kind == "expense" && $0.obligationId == nil && inRange.contains(monthOf($0.date)) })
            let current = totalsByCategory(flexibleExpenses(state, month: month, upTo: today))
            for entry in current where !incomeCategories.contains(entry.key) {
                let average = (base[entry.key] ?? 0) / Int64(months.count)
                let projected = entry.value * Int64(days.total) / Int64(days.elapsed)
                guard average > 0, projected * 100 >= average * 130, projected - average >= 5000 * oneTenge else { continue }
                let percent = (projected - average) * 100 / average
                out.append(FinanceHint(
                    kind: .growth, subject: entry.key,
                    text: "«\(entry.key)»: к концу месяца выйдет около \(money(projected)), обычно \(money(average)) (+\(percent)%)",
                    priority: 60
                ))
            }
        }

        out += recurringHints(state, today: today)
        out += smallFrequentHints(state, month: month, today: today)
        if let cushion = runwayHint(state, today: today) { out.append(cushion) }
        return out.sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.id < $1.id }
    }

    /// The same merchant charging about the same amount once a month, two or three months running, outside the plan.
    static func recurringHints(_ state: FinanceState, today: String) -> [FinanceHint] {
        let current = String(today.prefix(7))
        let previous = FinanceInsights.previousMonth(current)
        let window: Set<String> = [current, previous, FinanceInsights.previousMonth(previous)]
        let learned = Set((state.budget?.obligationMerchants ?? [:]).keys)
        let ops = counted(state).filter {
            $0.kind == "expense" && $0.obligationId == nil && !isOwnTransfer($0) && !personalCategories.contains($0.category ?? "")
                && window.contains(monthOf($0.date)) && ($0.date ?? "") <= today
        }
        var out: [FinanceHint] = []
        for entry in Dictionary(grouping: ops, by: { MerchantCategories.key($0.merchant ?? $0.title) }) {
            guard !entry.key.isEmpty, !learned.contains(entry.key) else { continue }
            let perMonth = Dictionary(grouping: entry.value, by: { monthOf($0.date) })
            guard perMonth.count >= 2, perMonth.values.allSatisfy({ $0.count == 1 }) else { continue }
            let monthsSeen = perMonth.keys.sorted()
            guard zip(monthsSeen, monthsSeen.dropFirst()).allSatisfy({ nextMonth($0.0) == $0.1 }) else { continue }
            let amounts = entry.value.compactMap(\.amountMinor).sorted()
            let median = amounts[amounts.count / 2]
            guard median > 0, amounts.allSatisfy({ abs($0 - median) * 100 <= median * 15 }) else { continue }
            let first = entry.value[0]
            guard let name = safeName(first.merchant ?? first.title) else { continue }
            out.append(FinanceHint(kind: .recurring, subject: name, text: "«\(name)» списывается каждый месяц, около \(money(median)), — этого нет в плане", priority: 50))
        }
        return out
    }

    /// Many small purchases at one place that add up.
    static func smallFrequentHints(_ state: FinanceState, month: String, today: String) -> [FinanceHint] {
        let ops = flexibleExpenses(state, month: month, upTo: today).filter { !isOwnTransfer($0) && !personalCategories.contains($0.category ?? "") }
        var out: [FinanceHint] = []
        for entry in Dictionary(grouping: ops, by: { MerchantCategories.key($0.merchant ?? $0.title) }) where !entry.key.isEmpty {
            let amounts = entry.value.compactMap(\.amountMinor)
            let total = amounts.reduce(0, +)
            guard amounts.count >= 8, amounts.allSatisfy({ $0 <= 3000 * oneTenge }), total >= 15000 * oneTenge else { continue }
            guard let name = safeName(entry.value[0].merchant ?? entry.value[0].title) else { continue }
            out.append(FinanceHint(kind: .smallFrequent, subject: name, text: "«\(name)»: \(amounts.count) покупок в этом месяце, всего \(money(total))", priority: 40))
        }
        return out
    }

    /// How many months the envelopes cover the plan's payments (or, with no payments, the usual spending).
    static func runwayHint(_ state: FinanceState, today: String) -> FinanceHint? {
        var base: Int64 = 0
        for r in state.records where r.kind == "obligation" {
            let amount = r.amountMinor ?? 0
            base += r.frequency == "weekly" ? amount * 52 / 12 : amount
        }
        var basis = "обязательных трат"
        if base == 0 {
            let months = fullMonths(state, today: today)
            guard !months.isEmpty else { return nil }
            let inRange = Set(months)
            let spent = counted(state).filter { $0.kind == "expense" && inRange.contains(monthOf($0.date)) }.reduce(Int64(0)) { $0 + ($1.amountMinor ?? 0) }
            base = spent / Int64(months.count)
            basis = "обычных расходов"
        }
        guard base > 0 else { return nil }
        let reserved = state.records.filter { $0.kind == "goal" }.reduce(Int64(0)) { $0 + ($1.savedMinor ?? 0) }
        let tenths = reserved * 10 / base
        let text = reserved == 0
            ? "Ничего не отложено: подушки нет"
            : "Отложенного хватит на \(tenths / 10),\(tenths % 10) мес. \(basis)"
        return FinanceHint(kind: .runway, subject: "", text: text, priority: tenths < 10 ? 75 : 30)
    }

    // MARK: Month review

    public static func review(_ state: FinanceState, month: String, today: String) -> MonthReview {
        let ops = counted(state).filter { monthOf($0.date) == month && ($0.date ?? "") <= today }
        func sum(_ list: [FinanceRecord]) -> Int64 { list.reduce(0) { $0 + ($1.amountMinor ?? 0) } }
        let previous = FinanceInsights.previousMonth(month)
        let previousSpent = sum(counted(state).filter { $0.kind == "expense" && monthOf($0.date) == previous })
        let others = fullMonths(state, today: today).filter { $0 != month }
        var average: Int64?
        if !others.isEmpty {
            let inRange = Set(others)
            average = sum(counted(state).filter { $0.kind == "expense" && inRange.contains(monthOf($0.date)) }) / Int64(others.count)
        }
        let limits = limitStatuses(state, month: month, today: today)
        var paid: [String] = [], unpaid: [String] = []
        let asOf = month < String(today.prefix(7)) ? lastDay(of: month + "-01") : today
        for ob in state.records where ob.kind == "obligation" && ob.frequency == "monthly" {
            if paymentStatus(state, obligation: ob, today: asOf).isPaid { paid.append(ob.title) } else { unpaid.append(ob.title) }
        }
        return MonthReview(
            month: month,
            incomeMinor: sum(ops.filter { $0.kind == "income" }),
            expenseMinor: sum(ops.filter { $0.kind == "expense" }),
            previousExpenseMinor: previousSpent,
            averageExpenseMinor: average,
            limits: limits,
            savedOnLimitsMinor: limits.reduce(0) { $0 + $1.remainingMinor },
            overspentMinor: limits.reduce(0) { $0 + $1.overMinor },
            paidPayments: paid,
            unpaidPayments: unpaid
        )
    }

    /// Last month, when it has operations, falls inside the analysis period and its card was not closed yet.
    public static func pendingReviewMonth(_ state: FinanceState, today: String) -> String? {
        let last = FinanceInsights.previousMonth(String(today.prefix(7)))
        guard last >= monthOf(analysisStart(state)),
              !(state.budget?.reviewedMonths ?? []).contains(last),
              counted(state).contains(where: { monthOf($0.date) == last }) else { return nil }
        return last
    }

    public static func markReviewed(_ state: FinanceState, month: String) throws -> FinanceState {
        try updateBudget(state) { $0.reviewedMonths = ($0.reviewedMonths ?? []) + [month] }
    }

    // MARK: Export for a chat

    public static let exportPrompt = """
    Ты — объективный финансовый советник. Мой доход нестабилен примерно с сентября 2026. Ниже сводка моих финансов \
    в тенге, посчитанная приложением (без имён людей и номеров счетов). Разбери её: куда уходит больше всего, что можно \
    сократить без вреда, какие риски ты видишь, сколько реально откладывать и какой лимит на месяц разумен. \
    Отвечай конкретно, с цифрами из сводки, без общих советов. Если данных не хватает для вывода — скажи, чего именно.
    """

    /// Text the owner copies into Claude or ChatGPT: totals only, no names of people, no account or card numbers.
    public static func exportText(_ state: FinanceState, today: String) -> String {
        let start = analysisStart(state)
        let ops = counted(state).filter { ($0.date ?? "") >= start && ($0.date ?? "") <= today && !isOwnTransfer($0) }
        var lines = [exportPrompt, "", "Период: с \(start) по \(today)."]

        var month = monthOf(start)
        let current = String(today.prefix(7))
        while month <= current {
            let list = ops.filter { monthOf($0.date) == month }
            let income = list.filter { $0.kind == "income" }.reduce(Int64(0)) { $0 + ($1.amountMinor ?? 0) }
            let spending = list.filter { $0.kind == "expense" }
            let expense = spending.reduce(Int64(0)) { $0 + ($1.amountMinor ?? 0) }
            let partial = month == current ? " (месяц ещё идёт)" : ""
            lines.append("")
            lines.append("\(month)\(partial): доходы \(money(income)), расходы \(money(expense)).")
            let byCategory = totalsByCategory(spending).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            for entry in byCategory.prefix(8) {
                lines.append("  - \(entry.key): \(money(entry.value))")
            }
            month = nextMonth(month)
        }

        let named = ops.filter { $0.kind == "expense" && !personalCategories.contains($0.category ?? "") }
        var byMerchant: [(name: String, total: Int64, count: Int)] = []
        for group in Dictionary(grouping: named, by: { MerchantCategories.key($0.merchant ?? $0.title) }).values {
            guard let name = safeName(group[0].merchant ?? group[0].title) else { continue }
            let total = group.reduce(Int64(0)) { $0 + ($1.amountMinor ?? 0) }
            byMerchant.append((name: name, total: total, count: group.count))
        }
        byMerchant.sort { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
        if !byMerchant.isEmpty {
            lines.append("")
            lines.append("Больше всего потрачено у:")
            for m in byMerchant.prefix(10) { lines.append("  - \(m.name): \(money(m.total)), \(m.count) раз") }
        }
        let toPeople = ops.filter { $0.kind == "expense" && $0.category == "Переводы" }.reduce(Int64(0)) { $0 + ($1.amountMinor ?? 0) }
        if toPeople > 0 { lines.append("Переводы людям за период: \(money(toPeople)) (без имён).") }

        let obligations = state.records.filter { $0.kind == "obligation" }
        if !obligations.isEmpty {
            lines.append("")
            lines.append("Обязательные платежи:")
            for o in obligations {
                lines.append("  - \(o.title): \(money(o.amountMinor ?? 0)) \(o.frequency == "weekly" ? "в неделю" : "в месяц")")
            }
        }
        if let limits = state.budget?.limits, !limits.isEmpty {
            let parts: [String] = limits.keys.sorted().map { "\($0) \(money(limits[$0] ?? 0))" }
            lines.append("Лимиты на месяц: " + parts.joined(separator: "; ") + ".")
        }
        if let snap = try? snapshot(state, today: today) {
            lines.append("")
            if let onAccounts = snap.onAccountsMinor { lines.append("На счетах: \(money(onAccounts)) (на \(snap.asOf ?? today)).") }
            lines.append("Отложено: \(money(snap.reservedMinor)). Откладываю \(state.budget?.savePercent ?? defaultSavePercent)% от каждого дохода.")
            if let clean = snap.cleanMinor { lines.append("Свободно после всех планов: \(money(clean)).") }
        }
        let found = hints(state, today: today)
        if !found.isEmpty {
            lines.append("")
            lines.append("Что заметило приложение:")
            for h in found { lines.append("  - \(h.text)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// Whole tenge with spaces between thousands: «12 400 ₸», «-3 000 ₸».
    public static func money(_ minor: Int64) -> String {
        let tenge = (abs(minor) + oneTenge / 2) / oneTenge
        var digits = String(tenge)
        var groups: [String] = []
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
        }
        groups.insert(digits, at: 0)
        return (minor < 0 ? "-" : "") + groups.joined(separator: " ") + " ₸"
    }

    /// How banks show a person: «Иван И.», «Aigerim K», «Иванов А.А.», «А. Иванов», «ИП Сейткали», «ИВАНОВ АЛЕКСЕЙ»,
    /// «Айгерим Кайратовна». Such names never go into hints or the export.
    static func looksLikePerson(_ name: String) -> Bool {
        let text = name.trimmingCharacters(in: .whitespaces)
        let patterns = [
            // A name and one initial, or two initials with a dot between: «Apple TV» and «Beeline KZ» are not people.
            #"^[А-ЯЁӘҒҚҢӨҰҮҺІA-Z][а-яёәғқңөұүһіa-z]+\s+[А-ЯЁӘҒҚҢӨҰҮҺІA-Z](\.?|\.\s?[А-ЯЁӘҒҚҢӨҰҮҺІA-Z]\.?)$"#,
            #"^[А-ЯЁӘҒҚҢӨҰҮҺІA-Z]\.\s?([А-ЯЁӘҒҚҢӨҰҮҺІA-Z]\.\s?)?[А-ЯЁӘҒҚҢӨҰҮҺІA-Z][а-яёәғқңөұүһіa-z]+$"#,
            #"^(ИП|IP|И\.П\.)\s"#,
            // An all-caps Cyrillic pair or triple is a person unless it carries a company form or a shop word.
            #"^(?!.*\b(ТОО|АО|ОАО|ООО|ЗАО|ГКП|РГП|КГП|ОФ|ПК|АПТЕКА|МАГАЗИН|КАФЕ|ТАКСИ|ЯНДЕКС|РЕСТОРАН|САЛОН|МАРКЕТ|СУПЕРМАРКЕТ|ФИТНЕС|ЦЕНТР|АЗС|ДОСТАВКА|ПЛЮС|ШОП|КЛИНИКА|БАР)\b)[А-ЯЁӘҒҚҢӨҰҮҺІ]{2,}\s+[А-ЯЁӘҒҚҢӨҰҮҺІ]{2,}(\s+[А-ЯЁӘҒҚҢӨҰҮҺІ]{2,})?$"#,
            #"^[A-Z]{2,}\s+[A-Z]\.?$"#,
            #"^[А-ЯЁӘҒҚҢӨҰҮҺІ][а-яёәғқңөұүһі]+\s+[А-ЯЁӘҒҚҢӨҰҮҺІ][а-яёәғқңөұүһі]+(вич|вна|ична|улы|ұлы|кызы|қызы)$"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// A merchant name fit for a hint or the export: nil for a person, card and account digits cut out.
    static func safeName(_ name: String) -> String? {
        guard !looksLikePerson(name) else { return nil }
        let cut = name
            .replacingOccurrences(of: #"[\d*][\d*\s-]{2,}[\d*]"#, with: "…", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !cut.isEmpty, cut != "…" else { return nil }
        return cut
    }

    static func counted(_ state: FinanceState) -> [FinanceRecord] {
        state.records.filter { $0.excluded != true && ($0.kind == "income" || $0.kind == "expense") && $0.date != nil }
    }

    /// Everyday spending the limits watch: not the payments of the plan.
    static func flexibleExpenses(_ state: FinanceState, month: String, upTo today: String) -> [FinanceRecord] {
        counted(state).filter { $0.kind == "expense" && $0.obligationId == nil && monthOf($0.date) == month && ($0.date ?? "") <= today }
    }

    static func totalsByCategory(_ records: [FinanceRecord]) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for r in records { out[r.category ?? "Без категории", default: 0] += r.amountMinor ?? 0 }
        return out
    }

    /// Whole calendar months from the analysis start up to, not including, the month of today.
    static func fullMonths(_ state: FinanceState, today: String) -> [String] {
        let start = analysisStart(state)
        var month = start.hasSuffix("-01") ? monthOf(start) : nextMonth(monthOf(start))
        let current = String(today.prefix(7))
        var out: [String] = []
        while month < current && out.count < 120 {
            out.append(month)
            month = nextMonth(month)
        }
        return out
    }

    static func monthOf(_ date: String?) -> String { String((date ?? "").prefix(7)) }

    static func nextMonth(_ month: String) -> String {
        guard let year = Int(month.prefix(4)), let m = Int(month.suffix(2)) else { return month }
        return m == 12 ? String(format: "%04d-01", year + 1) : String(format: "%04d-%02d", year, m + 1)
    }

    /// Days passed in the month by today (all of them for a past month, none for a future one) and its length.
    static func dayInfo(_ month: String, today: String) -> (elapsed: Int, total: Int)? {
        guard isValidMonthString(month), let year = Int(month.prefix(4)), let m = Int(month.suffix(2)) else { return nil }
        let total = getDaysInMonth(year: year, month: m)
        let current = String(today.prefix(7))
        if month < current { return (total, total) }
        if month > current { return (0, total) }
        guard let day = Int(today.suffix(2)) else { return nil }
        return (min(day, total), total)
    }

    static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let a = parseYmd(from), let b = parseYmd(to) else { return nil }
        return daysSinceEpoch(year: b.year, month: b.month, day: b.day) - daysSinceEpoch(year: a.year, month: a.month, day: a.day)
    }

    /// Word stems of a plan title, so «Аренда» finds «аренду» and «Связь» finds «Связь и интернет».
    static func stems(_ title: String) -> [String] {
        let words: [Substring] = title.lowercased().split(whereSeparator: { (c: Character) -> Bool in
            !c.isLetter && !c.isNumber
        })
        var out: [String] = []
        for word in words where word.count >= 4 {
            let keep: Int = max(4, word.count - 2)
            out.append(String(word.prefix(keep)))
        }
        return out
    }

    static func importsById(_ state: FinanceState) -> [String: FinanceImport] {
        Dictionary((state.imports ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
