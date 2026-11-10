import SwiftUI
import UIKit

/// Applies a pure change to the finance state; nil message means no status line. Returns nil once saved, else
/// the reason, so a sheet closes only on success and shows the reason otherwise.
struct FinanceApply {
    let run: (_ message: String?, _ change: (FinanceState) throws -> FinanceState) -> String?

    @discardableResult
    func callAsFunction(_ message: String?, _ change: (FinanceState) throws -> FinanceState) -> String? {
        run(message, change)
    }
}

// MARK: - Text and shared helpers

enum FinanceText {
    static let zone = TimeZone(identifier: "Asia/Qyzylorda") ?? TimeZone(secondsFromGMT: 5 * 3600)!

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = zone
        f.dateFormat = pattern
        return f
    }

    private static let ymd = formatter("yyyy-MM-dd")
    private static let weekdayDay = formatter("EE, d MMMM")
    private static let dayMonthFormat = formatter("d MMMM")
    private static let standaloneMonth = formatter("LLLL")

    static func today() -> String { ymd.string(from: Date()) }

    static func currentMonth() -> String { String(today().prefix(7)) }

    /// «Вт, 4 ноября»
    static func dayTitle(_ date: String) -> String {
        guard let d = ymd.date(from: date) else { return date }
        return capitalized(weekdayDay.string(from: d).replacingOccurrences(of: ".", with: ""))
    }

    /// «4 ноября»
    static func dayMonth(_ date: String) -> String {
        guard let d = ymd.date(from: date) else { return date }
        return dayMonthFormat.string(from: d)
    }

    /// «ноябрь»
    static func monthName(_ month: String) -> String {
        guard let d = ymd.date(from: month + "-01") else { return month }
        return standaloneMonth.string(from: d)
    }

    /// «октября», as in «Итоги октября».
    static func monthGenitive(_ month: String) -> String {
        guard let d = ymd.date(from: month + "-01") else { return month }
        let text = dayMonthFormat.string(from: d)
        return text.hasPrefix("1 ") ? String(text.dropFirst(2)) : text
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    static func money(_ minor: Int64) -> String {
        FinanceBudgeting.money(minor).replacingOccurrences(of: "-", with: "−")
    }

    /// «+12 000 ₸», «−3 400 ₸», «0 ₸».
    static func signed(_ minor: Int64) -> String {
        minor > 0 ? "+" + money(minor) : money(minor)
    }

    /// Whole tenge typed into a field: digits only, at most a hundred billion, so minor units never overflow.
    static func tenge(_ raw: String) -> Int64? {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty, digits.count <= 11, let value = Int64(digits), value <= 100_000_000_000 else { return nil }
        return value
    }

    /// Whole tenge for an editable field: «25000».
    static func field(_ minor: Int64?) -> String {
        guard let minor, minor > 0 else { return "" }
        return String(minor / 100)
    }
}

enum FinanceEnvelopes {
    static func goals(_ state: FinanceState) -> [FinanceRecord] {
        state.records.filter { $0.kind == "goal" }
    }

    /// The envelope incomes go into: the one the owner chose, else the first that is not full yet.
    static func savingsGoal(_ state: FinanceState) -> FinanceRecord? {
        let all = goals(state)
        if let id = state.budget?.savingsGoalId, let chosen = all.first(where: { $0.id == id }) { return chosen }
        return all.first(where: { room($0) > 0 }) ?? all.first
    }

    static func room(_ goal: FinanceRecord) -> Int64 {
        max(0, (goal.amountMinor ?? 0) - (goal.savedMinor ?? 0))
    }
}

/// A small rounded chip for filters.
struct FilterChip: View {
    let title: String
    var isActive = false
    var showsChevron = true

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundColor(isActive ? DS.Colors.onAccent : DS.Colors.textPrimary)
        .padding(.horizontal, 12)
        .frame(minHeight: DS.Metrics.minHitTarget)
        .background(isActive ? DS.Colors.accent : DS.Colors.surfaceRaised)
        .clipShape(Capsule())
        .contentShape(Capsule())
    }
}

/// One line of «label … amount».
struct MoneyRow: View {
    let label: String
    let value: String
    var emphasized = false
    var valueColor: Color = DS.Colors.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundColor(emphasized ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font((emphasized ? Font.subheadline.weight(.semibold) : Font.subheadline).monospacedDigit())
                .foregroundColor(valueColor)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Sheet chrome shared by the money sheets: title, «Готово», canvas background.
struct FinanceSheet<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                    content()
                }
                .padding(DS.Metrics.screenGutter)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(DS.Colors.canvas.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово", action: onClose)
                }
            }
        }
    }
}

// MARK: - Tabs

enum FinanceTab: String, CaseIterable, Identifiable {
    case overview, plan, operations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .plan: return "План"
        case .operations: return "Операции"
        }
    }
}

// MARK: - Pinned header

struct CleanHeader: View {
    let snapshot: BudgetSnapshot?
    let onTap: () -> Void

    /// The header rounds the daily amount down to 100 ₸; the exact one is in the breakdown.
    private var perDay: String? {
        guard let s = snapshot, s.limitsRemainingMinor > 0 else { return nil }
        let rounded = s.flexiblePerDayMinor / 10_000 * 10_000
        return "~" + FinanceText.money(rounded) + "/день на гибкие траты"
    }

    private var amountText: String {
        guard let clean = snapshot?.cleanMinor else { return "—" }
        return FinanceText.money(clean)
    }

    private var amountColor: Color {
        guard let clean = snapshot?.cleanMinor else { return DS.Colors.textSecondary }
        return clean < 0 ? DS.Colors.destructive : DS.Colors.textPrimary
    }

    private var note: (text: String, warns: Bool) {
        guard let s = snapshot, let clean = s.cleanMinor else {
            return ("Остаток не указан: добавь его через «+» или загрузи выписку", true)
        }
        if clean < 0 { return ("Не хватает \(FinanceText.money(-clean)) на план месяца", true) }
        // A stale balance comes first: the number itself may be wrong. The breakdown still says there are no limits.
        if let asOf = s.asOf, s.isStale {
            return ("остаток на \(FinanceText.dayMonth(asOf)) · пора загрузить свежую выписку", true)
        }
        // Without limits nothing is kept for everyday spending, so «Чистыми» is not money free to spend.
        if s.limits.isEmpty { return ("Лимитов нет — на повседневные траты ничего не учтено. Задать их можно в «Плане»", true) }
        guard let asOf = s.asOf else { return ("на счетах", false) }
        return ("на счетах на \(FinanceText.dayMonth(asOf))", false)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                // One line when it fits; on a small phone or with large text the daily amount moves under the sum.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        label
                        amount
                        if let perDay { perDayText("· " + perDay) }
                        Spacer(minLength: 0)
                        infoIcon
                    }
                    .lineLimit(1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            label
                            amount.minimumScaleFactor(0.6).lineLimit(1)
                            Spacer(minLength: 0)
                            infoIcon
                        }
                        if let perDay { perDayText(perDay).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                Text(note.text)
                    .font(.caption)
                    .foregroundColor(note.warns ? DS.Colors.warning : DS.Colors.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Metrics.spacing16)
            .padding(.vertical, DS.Metrics.spacing12)
            .background(DS.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Показать, из чего складывается сумма")
        .accessibilityIdentifier("clean-header")
    }

    private var label: some View {
        Text("Чистыми").font(.subheadline).foregroundColor(DS.Colors.textSecondary)
    }

    private var amount: some View {
        Text(amountText).font(.title3.weight(.semibold).monospacedDigit()).foregroundColor(amountColor)
    }

    private func perDayText(_ text: String) -> some View {
        Text(text).font(.subheadline.monospacedDigit()).foregroundColor(DS.Colors.textSecondary)
    }

    private var infoIcon: some View {
        Image(systemName: "info.circle").font(.footnote).foregroundColor(DS.Colors.textSecondary)
    }
}

struct CleanBreakdownSheet: View {
    let snapshot: BudgetSnapshot?
    let onSetLimits: () -> Void
    let onClose: () -> Void

    var body: some View {
        FinanceSheet(title: "Из чего складывается", onClose: onClose) {
            if let s = snapshot, let accounts = s.onAccountsMinor, let clean = s.cleanMinor {
                Card {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                        MoneyRow(label: s.asOf.map { "На счетах на \(FinanceText.dayMonth($0))" } ?? "На счетах",
                                 value: FinanceText.money(accounts))
                        MoneyRow(label: s.outsideMinor > 0 ? "− Отложено в конвертах со счетов" : "− Отложено в конвертах",
                                 value: FinanceText.money(s.reservedMinor))
                        MoneyRow(label: "− Платежи месяца, ещё не оплачены", value: FinanceText.money(s.unpaidPaymentsMinor))
                        MoneyRow(label: "− Остатки лимитов", value: FinanceText.money(s.limitsRemainingMinor))
                        Divider().background(DS.Colors.hairline)
                        MoneyRow(label: "= Чистыми", value: FinanceText.money(clean), emphasized: true,
                                 valueColor: clean < 0 ? DS.Colors.destructive : DS.Colors.textPrimary)
                        Text("Деньги, которые не заняты ни конвертами, ни планом месяца. Перерасход лимита уже есть в остатке на счетах.")
                            .font(.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                        if s.outsideMinor > 0 {
                            Text("Ещё \(FinanceText.money(s.outsideMinor)) в конвертах лежит вне счетов, поэтому не вычитается.")
                                .font(.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                        SectionHeader("Гибкие траты")
                        MoneyRow(label: "Остатки лимитов", value: FinanceText.money(s.limitsRemainingMinor))
                        MoneyRow(label: "Дней до конца месяца, с сегодняшним", value: "\(s.daysLeft)")
                        MoneyRow(label: "В день", value: FinanceText.money(s.flexiblePerDayMinor), emphasized: true)
                        if s.limits.isEmpty {
                            Text("Лимитов на этот месяц нет, поэтому на повседневные траты в «Чистыми» ничего не оставлено.")
                                .font(.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                            PillButton("Задать лимиты", style: .secondary, action: onSetLimits)
                        }
                    }
                }
            } else {
                Text("Остаток на счетах ещё не известен. Добавь его через «+» («у меня сейчас 150000») или загрузи выписку во вкладке «Операции».")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Обзор

struct MonthRef: Identifiable {
    let id: String
}

struct FinanceOverviewTab: View {
    @ObservedObject var store: FinanceStore
    let today: String
    let apply: FinanceApply
    let onCategory: (String) -> Void
    let onOpenPlan: () -> Void

    @State private var reviewMonth: MonthRef? = nil
    @State private var creatingEnvelope = false

    private var month: String { String(today.prefix(7)) }

    var body: some View {
        let hints = FinanceBudgeting.hints(store.state, today: today)
        VStack(spacing: DS.Metrics.spacing24) {
            if !hints.isEmpty {
                hintsCard(Array(hints.prefix(3)))
            }
            if let pending = FinanceBudgeting.pendingReviewMonth(store.state, today: today) {
                pendingReviewCard(pending)
            }
            setAsideCard
            MoneyChartsSection(
                insights: FinanceInsights.compute(store.state, month: month, today: today),
                onCategory: onCategory
            )
            envelopesSummary
            PillButton("Обзор месяца", icon: "doc.text.magnifyingglass", style: .secondary) {
                reviewMonth = MonthRef(id: month)
            }
        }
        .sheet(item: $reviewMonth) { ref in
            MonthReviewSheet(store: store, today: today, month: ref.id, apply: apply) { reviewMonth = nil }
        }
        .sheet(isPresented: $creatingEnvelope) {
            NewEnvelopeSheet(today: today, apply: apply) { creatingEnvelope = false }
        }
    }

    private func hintsCard(_ hints: [FinanceHint]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                SectionHeader("Стоит посмотреть")
                ForEach(hints) { hint in
                    HintRow(hint: hint)
                }
            }
        }
    }

    private func pendingReviewCard(_ pending: String) -> some View {
        let review = FinanceBudgeting.review(store.state, month: pending, today: today)
        let goal = FinanceEnvelopes.savingsGoal(store.state)
        let offer = goal == nil ? 0 : review.savedOnLimitsMinor
        return Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                SectionHeader("Итоги \(FinanceText.monthGenitive(pending))")
                MoneyRow(label: "Доходы", value: FinanceText.money(review.incomeMinor))
                MoneyRow(label: "Расходы", value: FinanceText.money(review.expenseMinor))
                if review.previousExpenseMinor > 0 {
                    MoneyRow(label: "Расходы месяцем раньше", value: FinanceText.money(review.previousExpenseMinor))
                }
                if !review.limits.isEmpty {
                    let kept = review.limits.filter { $0.overMinor == 0 }.count
                    MoneyRow(label: "Уложился в лимиты", value: "\(kept) из \(review.limits.count)")
                    if review.overspentMinor > 0 {
                        MoneyRow(label: "Перерасход", value: FinanceText.money(review.overspentMinor), valueColor: DS.Colors.destructive)
                    }
                    if review.savedOnLimitsMinor > 0 {
                        MoneyRow(label: "Осталось от лимитов", value: FinanceText.money(review.savedOnLimitsMinor), valueColor: DS.Colors.positive)
                    }
                }
                if let goal, offer > 0 {
                    if FinanceEnvelopes.room(goal) < offer {
                        Text("Цель «\(goal.title)» вырастет до \(FinanceText.money((goal.savedMinor ?? 0) + offer)).")
                            .font(.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    PillButton("Отложить \(FinanceText.money(offer)) в «\(goal.title)»", style: .primary) {
                        apply("Отложено \(FinanceText.money(offer)).") { state in
                            let saved = try FinanceBudgeting.setAside(state, amountMinor: offer, goalId: goal.id, raiseTarget: true)
                            return try FinanceBudgeting.markReviewed(saved, month: pending)
                        }
                    }
                }
                HStack(spacing: DS.Metrics.spacing12) {
                    PillButton("Подробнее", style: .secondary) { reviewMonth = MonthRef(id: pending) }
                    PillButton("Закрыть", style: .secondary) {
                        apply(nil) { try FinanceBudgeting.markReviewed($0, month: pending) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var setAsideCard: some View {
        let offers = FinanceBudgeting.setAsideOffers(store.state, today: today)
        if !offers.isEmpty {
            let goal = FinanceEnvelopes.savingsGoal(store.state)
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                    SectionHeader("Отложить с дохода")
                    if goal == nil {
                        Text("Конверта для накоплений пока нет.")
                            .font(.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                        PillButton("Создать конверт", icon: "plus", style: .primary) { creatingEnvelope = true }
                    }
                    ForEach(offers.prefix(3)) { offer in
                        SetAsideOfferRow(offer: offer, goal: goal, apply: apply)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var envelopesSummary: some View {
        let goals = FinanceEnvelopes.goals(store.state)
        if !goals.isEmpty {
            let total = goals.reduce(Int64(0)) { $0 + ($1.savedMinor ?? 0) }
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                    MoneyRow(label: "Отложено в конвертах", value: FinanceText.money(total), emphasized: true)
                    ForEach(goals) { g in
                        MoneyRow(label: g.title, value: "\(FinanceText.money(g.savedMinor ?? 0)) из \(FinanceText.money(g.amountMinor ?? 0))")
                    }
                    Button("Конверты в «Плане»", action: onOpenPlan)
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.accent)
                        .frame(minHeight: DS.Metrics.minHitTarget)
                }
            }
        }
    }
}

struct HintRow: View {
    let hint: FinanceHint

    private var icon: (name: String, color: Color) {
        switch hint.kind {
        case .overLimit: return ("exclamationmark.circle", DS.Colors.destructive)
        case .pace, .nearLimit: return ("speedometer", DS.Colors.warning)
        case .growth: return ("arrow.up.right", DS.Colors.warning)
        case .recurring: return ("arrow.triangle.2.circlepath", DS.Colors.textSecondary)
        case .smallFrequent: return ("cart", DS.Colors.textSecondary)
        case .runway: return ("shield", hint.priority >= 70 ? DS.Colors.warning : DS.Colors.textSecondary)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Metrics.spacing12) {
            Image(systemName: icon.name)
                .foregroundColor(icon.color)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(hint.text)
                .font(.subheadline)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SetAsideOfferRow: View {
    let offer: SetAsideOffer
    let goal: FinanceRecord?
    let apply: FinanceApply

    var body: some View {
        let amount = offer.suggestedMinor
        let grows = goal.map { FinanceEnvelopes.room($0) < amount } ?? false
        VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
            Text("\(offer.incomeTitle) · \(FinanceText.money(offer.incomeMinor)) · \(FinanceText.dayMonth(offer.date))")
                .font(.subheadline)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
            if let goal, grows {
                Text("Цель «\(goal.title)» вырастет до \(FinanceText.money((goal.savedMinor ?? 0) + amount)).")
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            HStack(spacing: DS.Metrics.spacing12) {
                if let goal, amount > 0 {
                    PillButton("Отложить \(FinanceText.money(amount))", style: .primary) {
                        apply("Отложено \(FinanceText.money(amount)) в «\(goal.title)».") {
                            try FinanceBudgeting.setAside($0, amountMinor: amount, goalId: goal.id, incomeId: offer.incomeId, raiseTarget: true)
                        }
                    }
                }
                PillButton("Не сейчас", style: .secondary) {
                    apply(nil) { try FinanceBudgeting.skipSetAside($0, incomeId: offer.incomeId) }
                }
            }
        }
        .padding(12)
        .background(DS.Colors.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
    }
}

// MARK: - Обзор месяца

struct MonthReviewSheet: View {
    @ObservedObject var store: FinanceStore
    let today: String
    let month: String
    let apply: FinanceApply
    let onClose: () -> Void

    @State private var confirmExport = false
    @State private var copied = false

    var body: some View {
        let review = FinanceBudgeting.review(store.state, month: month, today: today)
        let isCurrent = month == String(today.prefix(7))
        FinanceSheet(title: "Обзор: \(FinanceText.monthName(month))", onClose: onClose) {
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                    MoneyRow(label: "Доходы", value: FinanceText.money(review.incomeMinor))
                    MoneyRow(label: isCurrent ? "Расходы на сегодня" : "Расходы", value: FinanceText.money(review.expenseMinor), emphasized: true)
                    MoneyRow(label: "Месяцем раньше", value: FinanceText.money(review.previousExpenseMinor))
                    if let average = review.averageExpenseMinor {
                        MoneyRow(label: "В среднем за полный месяц", value: FinanceText.money(average))
                    }
                }
            }
            if !review.limits.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                        SectionHeader("Лимиты")
                        ForEach(review.limits) { l in
                            MoneyRow(
                                label: l.category,
                                value: l.overMinor > 0
                                    ? "перерасход \(FinanceText.money(l.overMinor))"
                                    : "\(FinanceText.money(l.spentMinor)) из \(FinanceText.money(l.limitMinor))",
                                valueColor: l.overMinor > 0 ? DS.Colors.destructive : DS.Colors.textPrimary
                            )
                        }
                        if !isCurrent && review.savedOnLimitsMinor > 0 {
                            MoneyRow(label: "Осталось от лимитов", value: FinanceText.money(review.savedOnLimitsMinor), valueColor: DS.Colors.positive)
                        }
                    }
                }
            }
            if !review.paidPayments.isEmpty || !review.unpaidPayments.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                        SectionHeader("Платежи")
                        if !review.paidPayments.isEmpty {
                            Text("Оплачено: " + review.paidPayments.joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.textPrimary)
                        }
                        if !review.unpaidPayments.isEmpty {
                            Text((isCurrent ? "Ещё не оплачено: " : "Не оплачено: ") + review.unpaidPayments.joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundColor(isCurrent ? DS.Colors.textSecondary : DS.Colors.warning)
                        }
                    }
                }
            }
            if isCurrent {
                let hints = FinanceBudgeting.hints(store.state, today: today)
                if !hints.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                            SectionHeader("Все подсказки")
                            ForEach(hints) { HintRow(hint: $0) }
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                    SectionHeader("Разбор в чате")
                    Text("Скопирует сводку с \(FinanceText.dayMonth(FinanceBudgeting.analysisStart(store.state))) и готовый запрос для Claude или ChatGPT. Имён людей и номеров счетов в тексте нет.")
                        .font(.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                    PillButton(copied ? "Скопировано" : "Скопировать для чата", icon: "doc.on.doc", style: .secondary) {
                        confirmExport = true
                    }
                }
            }
        }
        .alert("Скопировать сводку?", isPresented: $confirmExport) {
            Button("Отмена", role: .cancel) {}
            Button("Скопировать") {
                UIPasteboard.general.string = FinanceBudgeting.exportText(store.state, today: today)
                copied = true
            }
        } message: {
            Text("Всё, что ты вставишь в чат, уйдёт в сторонний сервис. В тексте — итоги по месяцам и категориям, магазины, план и лимиты.")
        }
    }
}

// MARK: - План

struct FinancePlanTab: View {
    @ObservedObject var store: FinanceStore
    let today: String
    let apply: FinanceApply

    @State private var editingLimits = false
    @State private var payingObligation: FinanceRecord? = nil
    @State private var movingEnvelope: EnvelopeMove? = nil
    @State private var creatingEnvelope = false

    private var month: String { String(today.prefix(7)) }

    var body: some View {
        VStack(spacing: DS.Metrics.spacing24) {
            matchesCard
            paymentsCard
            limitsCard
            envelopesCard
        }
        .sheet(isPresented: $editingLimits) {
            LimitsEditSheet(store: store, today: today, apply: apply) { editingLimits = false }
        }
        .sheet(item: $payingObligation) { ob in
            PaymentLinkSheet(store: store, today: today, obligation: ob, apply: apply) { payingObligation = nil }
        }
        .sheet(item: $movingEnvelope) { move in
            EnvelopeMoveSheet(move: move, apply: apply) { movingEnvelope = nil }
        }
        .sheet(isPresented: $creatingEnvelope) {
            NewEnvelopeSheet(today: today, apply: apply) { creatingEnvelope = false }
        }
    }

    @ViewBuilder
    private var matchesCard: some View {
        let matches = FinanceBudgeting.paymentMatches(store.state, today: today)
        if !matches.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                    SectionHeader("Похоже на оплату")
                    ForEach(matches) { m in
                        VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                            Text("Это «\(m.obligationTitle)» за \(FinanceText.monthName(month))?")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("\(m.recordTitle) · \(FinanceText.money(m.amountMinor)) · \(FinanceText.dayMonth(m.date))")
                                .font(.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                            HStack(spacing: DS.Metrics.spacing12) {
                                PillButton("Да", style: .primary) {
                                    apply("«\(m.obligationTitle)» оплачен.") {
                                        try FinanceBudgeting.linkPayment($0, recordId: m.recordId, obligationId: m.obligationId)
                                    }
                                }
                                PillButton("Нет", style: .secondary) {
                                    apply(nil) { try FinanceBudgeting.dismissMatch($0, m) }
                                }
                            }
                        }
                        .padding(12)
                        .background(DS.Colors.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                    }
                }
            }
        }
    }

    private var paymentsCard: some View {
        let obligations = store.state.records.filter { $0.kind == "obligation" }
        return Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                SectionHeader("Обязательные платежи")
                if obligations.isEmpty {
                    Text("Платежей пока нет. Добавь через «+», например «аренда 120000 каждый месяц».")
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                ForEach(obligations) { ob in
                    PaymentRow(
                        obligation: ob,
                        status: FinanceBudgeting.paymentStatus(store.state, obligation: ob, today: today),
                        onMark: { payingObligation = ob },
                        onUnmark: {
                            apply("Отметка об оплате «\(ob.title)» снята.") {
                                try FinanceBudgeting.togglePaidByHand($0, obligationId: ob.id, today: today)
                            }
                        }
                    )
                }
            }
        }
    }

    private var limitsCard: some View {
        let limits = FinanceBudgeting.limitStatuses(store.state, month: month, today: today)
        return Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                SectionHeader("Лимиты на \(FinanceText.monthName(month))")
                if limits.isEmpty {
                    Text("Лимитов пока нет. Приложение предложит их по средним тратам с \(FinanceText.dayMonth(FinanceBudgeting.analysisStart(store.state))) — останется поправить.")
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                ForEach(limits) { LimitBar(status: $0) }
                PillButton(limits.isEmpty ? "Задать лимиты" : "Изменить лимиты", style: .secondary) {
                    editingLimits = true
                }
            }
        }
    }

    private var envelopesCard: some View {
        let goals = FinanceEnvelopes.goals(store.state)
        let savingsId = FinanceEnvelopes.savingsGoal(store.state)?.id
        let percent = store.state.budget?.savePercent ?? FinanceBudgeting.defaultSavePercent
        return Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                SectionHeader("Конверты")
                Text("Деньги остаются на картах, но не входят в «Чистыми».")
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                ForEach(goals) { g in
                    EnvelopeRow(
                        goal: g,
                        receivesIncome: g.id == savingsId,
                        canChoose: goals.count > 1,
                        onAdd: { movingEnvelope = EnvelopeMove(goal: g, isWithdraw: false) },
                        onWithdraw: { movingEnvelope = EnvelopeMove(goal: g, isWithdraw: true) },
                        onChoose: { apply(nil) { try FinanceBudgeting.updateBudget($0) { $0.savingsGoalId = g.id } } }
                    )
                }
                PillButton("Новый конверт", icon: "plus", style: .secondary) { creatingEnvelope = true }
                Stepper(value: Binding(
                    get: { percent },
                    set: { value in apply(nil) { try FinanceBudgeting.updateBudget($0) { $0.savePercent = value } } }
                ), in: 0...50, step: 5) {
                    Text(percent == 0 ? "С дохода не предлагать" : "Предлагать отложить \(percent)% дохода")
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.textPrimary)
                }
            }
        }
    }
}

struct PaymentRow: View {
    let obligation: FinanceRecord
    let status: PaymentStatus
    let onMark: () -> Void
    let onUnmark: () -> Void

    private var isMonthly: Bool { obligation.frequency == "monthly" }
    /// A weekly payment shows a tick only on the day its charge is paid.
    private var isPaid: Bool { status.isDue && status.isPaid }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Metrics.spacing12) {
            Image(systemName: isPaid ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isPaid ? DS.Colors.positive : DS.Colors.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(obligation.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Spacer(minLength: 8)
            Text(FinanceText.money(obligation.amountMinor ?? 0))
                .font(.subheadline.monospacedDigit())
                .foregroundColor(DS.Colors.textPrimary)
            if status.isDue && !status.isPaid {
                Button("Оплачен", action: onMark)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DS.Colors.accent)
                    .frame(minWidth: DS.Metrics.minHitTarget, minHeight: DS.Metrics.minHitTarget)
                    .accessibilityLabel("Отметить оплату «\(obligation.title)»")
            } else if status.markedByHand {
                Button("Снять", action: onUnmark)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DS.Colors.accent)
                    .frame(minWidth: DS.Metrics.minHitTarget, minHeight: DS.Metrics.minHitTarget)
                    .accessibilityLabel("Снять отметку об оплате «\(obligation.title)»")
            }
        }
    }

    private var statusText: String {
        if !isMonthly {
            let left = status.chargesLeft == 0 ? "в этом месяце больше нет" : "до конца месяца ещё \(status.chargesLeft)"
            return (isPaid ? "сегодня оплачен · " : "каждую неделю · ") + left
        }
        if status.markedByHand { return "оплачен, отмечен вручную" }
        if status.isPaid { return "оплачен" }
        if status.paidMinor > 0 { return "оплачено \(FinanceText.money(status.paidMinor)), ожидается остаток" }
        return "ожидается"
    }
}

struct LimitBar: View {
    let status: LimitStatus

    private var tint: Color {
        if status.overMinor > 0 { return DS.Colors.destructive }
        if status.runsOutDay != nil { return DS.Colors.warning }
        return DS.Colors.accent
    }

    private var note: String {
        if status.overMinor > 0 { return "перерасход \(FinanceText.money(status.overMinor))" }
        if let day = status.runsOutDay { return "осталось \(FinanceText.money(status.remainingMinor)) · при таком темпе закончится \(day)-го" }
        return "осталось \(FinanceText.money(status.remainingMinor))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status.category)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text("\(FinanceText.money(status.spentMinor)) из \(FinanceText.money(status.limitMinor))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(DS.Colors.textSecondary)
            }
            ProgressView(value: Double(min(status.spentMinor, status.limitMinor)), total: Double(max(status.limitMinor, 1)))
                .tint(tint)
            Text(note)
                .font(.caption)
                .foregroundColor(status.overMinor > 0 ? DS.Colors.destructive : DS.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EnvelopeMove: Identifiable {
    var id: String { goal.id + (isWithdraw ? "-out" : "-in") }
    let goal: FinanceRecord
    let isWithdraw: Bool
}

struct EnvelopeRow: View {
    let goal: FinanceRecord
    let receivesIncome: Bool
    let canChoose: Bool
    let onAdd: () -> Void
    let onWithdraw: () -> Void
    let onChoose: () -> Void

    var body: some View {
        let saved = goal.savedMinor ?? 0
        let target = max(goal.amountMinor ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(goal.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                if receivesIncome && canChoose {
                    Text("сюда с дохода")
                        .font(.caption2)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                Spacer()
                Text("\(FinanceText.money(saved)) из \(FinanceText.money(goal.amountMinor ?? 0))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(DS.Colors.textSecondary)
            }
            ProgressView(value: Double(min(saved, target)), total: Double(target))
                .tint(DS.Colors.accent)
            if let outside = goal.outsideMinor, outside > 0 {
                Text("из них вне счетов \(FinanceText.money(outside))")
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            HStack(spacing: DS.Metrics.spacing16) {
                Button("Отложить", action: onAdd)
                    .disabled(FinanceEnvelopes.room(goal) == 0)
                Button("Забрать", action: onWithdraw)
                    .disabled(saved == 0)
                if canChoose && !receivesIncome {
                    Button("Откладывать сюда", action: onChoose)
                }
            }
            .font(.subheadline)
            .foregroundColor(DS.Colors.accent)
            .frame(minHeight: DS.Metrics.minHitTarget)
        }
        .padding(12)
        .background(DS.Colors.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
    }
}

// MARK: - Plan sheets

struct LimitsEditSheet: View {
    @ObservedObject var store: FinanceStore
    let today: String
    let apply: FinanceApply
    let onClose: () -> Void

    @State private var values: [String: String] = [:]
    @State private var categories: [String] = []
    @State private var error: String? = nil

    /// Income-like categories never get a limit.
    private static let skipped: Set<String> = ["Пополнения", "Зарплата"]

    var body: some View {
        FinanceSheet(title: "Лимиты месяца", onClose: onClose) {
            Text("Лимит — сколько готов потратить на категорию за месяц. Обязательные платежи сюда не входят.")
                .font(.caption)
                .foregroundColor(DS.Colors.textSecondary)
            PillButton("Предложить по тратам с \(FinanceText.dayMonth(FinanceBudgeting.analysisStart(store.state)))", icon: "wand.and.stars", style: .secondary) {
                suggest()
            }
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                    ForEach(categories, id: \.self) { category in
                        HStack {
                            Text(category)
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.textPrimary)
                            Spacer()
                            TextField("0", text: binding(category))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 110)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Лимит «\(category)», тенге")
                            Text("₸").foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                    if !remaining.isEmpty {
                        Menu {
                            ForEach(remaining, id: \.self) { c in
                                Button(c) { categories.append(c) }
                            }
                        } label: {
                            Label("Добавить категорию", systemImage: "plus")
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.accent)
                                .frame(minHeight: DS.Metrics.minHitTarget)
                        }
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundColor(DS.Colors.destructive)
            }
            PillButton("Сохранить", style: .primary) { save() }
        }
        .onAppear(perform: load)
    }

    private var remaining: [String] {
        MerchantCategories.all.filter { !Self.skipped.contains($0) && !categories.contains($0) }
    }

    private func binding(_ category: String) -> Binding<String> {
        Binding(get: { values[category] ?? "" }, set: { values[category] = $0.filter(\.isNumber) })
    }

    private func load() {
        let limits = store.state.budget?.limits ?? [:]
        values = limits.mapValues { FinanceText.field($0) }
        var names = Set(limits.keys)
        let start = FinanceBudgeting.analysisStart(store.state)
        for r in store.state.records where r.kind == "expense" && r.excluded != true && r.obligationId == nil && (r.date ?? "") >= start {
            let c = r.category ?? "Без категории"
            if !Self.skipped.contains(c) { names.insert(c) }
        }
        categories = ordered(names)
    }

    private func suggest() {
        let suggested = FinanceBudgeting.suggestedLimits(store.state, today: today)
        guard !suggested.isEmpty else {
            error = "Пока нет ни одного полного месяца трат с начала анализа — предложить нечего."
            return
        }
        error = nil
        for (c, v) in suggested where !Self.skipped.contains(c) { values[c] = FinanceText.field(v) }
        categories = ordered(Set(categories).union(suggested.keys.filter { !Self.skipped.contains($0) }))
    }

    private func ordered(_ names: Set<String>) -> [String] {
        let known = MerchantCategories.all.filter { names.contains($0) }
        return known + names.subtracting(known).sorted()
    }

    private func save() {
        var limits: [String: Int64] = [:]
        for (c, raw) in values where !raw.isEmpty {
            guard let tenge = FinanceText.tenge(raw), tenge > 0, tenge < 1_000_000_000 else {
                error = "Проверь сумму у «\(c)»."
                return
            }
            limits[c] = tenge * 100
        }
        if let failure = apply("Лимиты сохранены.", { try FinanceBudgeting.setLimits($0, limits) }) {
            error = failure
        } else {
            onClose()
        }
    }
}

struct PaymentLinkSheet: View {
    @ObservedObject var store: FinanceStore
    let today: String
    let obligation: FinanceRecord
    let apply: FinanceApply
    let onClose: () -> Void

    @State private var error: String? = nil

    var body: some View {
        let candidates = FinanceBudgeting.paymentCandidates(store.state, obligation: obligation, today: today)
        FinanceSheet(title: "Чем оплачен «\(obligation.title)»", onClose: onClose) {
            PillButton("Оплачен без операции", icon: "checkmark", style: .primary) {
                finish(apply("«\(obligation.title)» отмечен оплаченным.") {
                    try FinanceBudgeting.togglePaidByHand($0, obligationId: obligation.id, today: today)
                })
            }
            Text("Наличными, с чужой карты или выписки ещё нет. Или выбери операцию ниже — сначала самые близкие по сумме; получатель запомнится, и в следующий раз приложение предложит его само.")
                .font(.caption)
                .foregroundColor(DS.Colors.textSecondary)
            if let error {
                Text(error).font(.caption).foregroundColor(DS.Colors.destructive)
            }
            if candidates.isEmpty {
                Text("В этом месяце нет расходов без отметки. Можно добавить расход через «+» или загрузить выписку.")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(candidates) { r in
                        Button {
                            finish(apply("«\(obligation.title)» оплачен.") {
                                try FinanceBudgeting.linkPayment($0, recordId: r.id, obligationId: obligation.id)
                            })
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title).font(.subheadline).foregroundColor(DS.Colors.textPrimary).lineLimit(2)
                                    Text(FinanceText.dayMonth(r.date ?? "")).font(.caption).foregroundColor(DS.Colors.textSecondary)
                                }
                                Spacer()
                                Text(FinanceText.money(r.amountMinor ?? 0))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(DS.Colors.textPrimary)
                            }
                            .frame(minHeight: DS.Metrics.minHitTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().background(DS.Colors.hairline)
                    }
                }
            }
        }
    }

    private func finish(_ failure: String?) {
        if let failure { error = failure } else { onClose() }
    }
}

struct EnvelopeMoveSheet: View {
    let move: EnvelopeMove
    let apply: FinanceApply
    let onClose: () -> Void

    @State private var amount = ""
    @State private var error: String? = nil
    /// Set when the amount is above what is left to the target; the next tap grows the target.
    @State private var growTarget = false
    /// The money is not on the accounts (cash, a deposit), so «Чистыми» does not change.
    @State private var outside: Bool

    init(move: EnvelopeMove, apply: FinanceApply, onClose: @escaping () -> Void) {
        self.move = move
        self.apply = apply
        self.onClose = onClose
        // Taking back from an envelope that holds only outside money starts on that part.
        let held = move.goal.outsideMinor ?? 0
        _outside = State(initialValue: move.isWithdraw && held > 0 && held == (move.goal.savedMinor ?? 0))
    }

    private var outsideHeld: Int64 { move.goal.outsideMinor ?? 0 }
    private var onAccountsHeld: Int64 { (move.goal.savedMinor ?? 0) - outsideHeld }

    private var limit: Int64 {
        guard move.isWithdraw else { return FinanceEnvelopes.room(move.goal) }
        return outside ? outsideHeld : onAccountsHeld
    }

    /// Taking back offers the choice only when both parts hold money.
    private var showsSource: Bool { !move.isWithdraw || (outsideHeld > 0 && onAccountsHeld > 0) }

    private var sourceNote: String {
        switch (move.isWithdraw, outside) {
        case (false, false): return "Деньги остаются на карте, но перестают быть «Чистыми»."
        case (false, true): return "Наличные или вклад, которых нет в выписках. «Чистыми» не изменится."
        case (true, false): return "Сумма снова станет «Чистыми»."
        case (true, true): return "Деньги вне счетов: «Чистыми» не изменится."
        }
    }

    var body: some View {
        FinanceSheet(title: move.isWithdraw ? "Забрать из «\(move.goal.title)»" : "Отложить в «\(move.goal.title)»", onClose: onClose) {
            Text(move.isWithdraw ? "Сейчас отложено \(FinanceText.money(limit))." : "До цели осталось \(FinanceText.money(limit)).")
                .font(.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
            if showsSource {
                Picker(move.isWithdraw ? "Откуда" : "Где лежат деньги", selection: $outside) {
                    Text("На счетах").tag(false)
                    Text("Вне счетов").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: outside) { _, _ in
                    growTarget = false
                    error = nil
                }
            }
            Text(sourceNote)
                .font(.caption)
                .foregroundColor(DS.Colors.textSecondary)
            TextField("Сумма, ₸", text: $amount)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .onChange(of: amount) { _, _ in
                    growTarget = false
                    error = nil
                }
            if let error {
                Text(error).font(.caption).foregroundColor(growTarget ? DS.Colors.textSecondary : DS.Colors.destructive)
            }
            PillButton(growTarget ? "Отложить и поднять цель" : (move.isWithdraw ? "Забрать" : "Отложить"),
                       style: .primary, isEnabled: !amount.isEmpty) { save() }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let tenge = FinanceText.tenge(amount), tenge > 0 else {
            error = "Введи сумму в тенге."
            return
        }
        let minor = tenge * 100
        if minor > limit {
            if move.isWithdraw {
                error = "Отложено меньше."
                return
            }
            if !growTarget {
                growTarget = true
                error = "Это больше, чем осталось до цели. Цель вырастет до \(FinanceText.money((move.goal.savedMinor ?? 0) + minor))."
                return
            }
        }
        let goalId = move.goal.id
        let raise = growTarget
        let fromOutside = outside
        let failure: String?
        if move.isWithdraw {
            failure = apply("Забрано \(FinanceText.money(minor)).") {
                try FinanceBudgeting.withdraw($0, amountMinor: minor, goalId: goalId, outsideAccounts: fromOutside)
            }
        } else {
            failure = apply("Отложено \(FinanceText.money(minor))\(fromOutside ? " вне счетов" : "").") {
                try FinanceBudgeting.setAside($0, amountMinor: minor, goalId: goalId, raiseTarget: raise, outsideAccounts: fromOutside)
            }
        }
        if let failure { error = failure; growTarget = false } else { onClose() }
    }
}

struct NewEnvelopeSheet: View {
    let today: String
    let apply: FinanceApply
    let onClose: () -> Void

    @State private var title = "Подушка"
    @State private var target = ""
    @State private var saved = ""
    @State private var savedOutside = false
    @State private var error: String? = nil

    var body: some View {
        FinanceSheet(title: "Новый конверт", onClose: onClose) {
            TextField("Название", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Сколько хочешь собрать, ₸", text: $target)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            TextField("Уже отложено, ₸ — необязательно", text: $saved)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            if !saved.filter(\.isNumber).isEmpty {
                Picker("Где лежат деньги", selection: $savedOutside) {
                    Text("На счетах").tag(false)
                    Text("Вне счетов").tag(true)
                }
                .pickerStyle(.segmented)
                Text(savedOutside ? "Наличные или вклад, которых нет в выписках. «Чистыми» не изменится."
                                  : "Деньги остаются на карте, но перестают быть «Чистыми».")
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            if let error {
                Text(error).font(.caption).foregroundColor(DS.Colors.destructive)
            }
            PillButton("Создать", style: .primary, isEnabled: !title.trimmingCharacters(in: .whitespaces).isEmpty && !target.isEmpty) { save() }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let goal = FinanceText.tenge(target), goal > 0 else {
            error = "Введи сумму цели в тенге."
            return
        }
        guard saved.filter(\.isNumber).isEmpty || FinanceText.tenge(saved) != nil else {
            error = "Проверь, сколько уже отложено."
            return
        }
        let already = FinanceText.tenge(saved) ?? 0
        guard already <= goal else {
            error = "Отложено больше, чем цель."
            return
        }
        let draft = FinanceDraft(kind: "goal", title: name, amountMinor: goal * 100, savedMinor: already * 100)
        let date = today
        let outsideMinor = savedOutside && already > 0 ? already * 100 : nil
        let failure = apply("Конверт «\(name)» создан.") { state in
            let before = Set(state.records.map(\.id))
            var next = try commitFinance(state: state, drafts: [draft], batchId: UUID().uuidString, nowDate: date)
            if let outsideMinor, let i = next.records.firstIndex(where: { $0.kind == "goal" && !before.contains($0.id) }) {
                next.records[i].outsideMinor = outsideMinor
            }
            return next
        }
        if let failure { error = failure } else { onClose() }
    }
}

// MARK: - Операции

struct OperationsFeed: View {
    @ObservedObject var store: FinanceStore
    @Binding var filter: LedgerFilter
    @Binding var expanded: Bool
    let onEdit: (FinanceRecord) -> Void

    @State private var pageSize = 60

    private static let page = 60

    var body: some View {
        let days = FinanceBudgeting.ledger(store.state, filter: filter)
        let totals = FinanceBudgeting.ledgerTotals(days)
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack {
                        Text("Операции · \(periodTitle) · \(totals.count)")
                            .font(.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .frame(minHeight: DS.Metrics.minHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("operations-feed-toggle")
                .accessibilityHint(expanded ? "Свернуть ленту" : "Раскрыть ленту")

                if expanded {
                    filters
                    searchField
                    if isFiltered {
                        Text("Найдено: \(MoneyFormat.operations(totals.count)) · расходы \(FinanceText.money(totals.expenseMinor)) · доходы \(FinanceText.money(totals.incomeMinor))")
                            .font(.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    if days.isEmpty {
                        Text("Ничего не найдено.")
                            .font(.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    ForEach(paged(days)) { day in
                        dayHeader(day)
                        ForEach(day.entries) { entry in
                            LedgerRow(entry: entry, pairSource: pairSource(entry)) { onEdit(entry.record) }
                        }
                    }
                    if totals.count > pageSize {
                        Button("Показать ещё") { pageSize += Self.page }
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(DS.Colors.accent)
                            .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget)
                    }
                }
            }
        }
        .onChange(of: filter) { _, _ in pageSize = Self.page }
    }

    private var periodTitle: String {
        filter.month.map(FinanceText.monthName) ?? "всё время"
    }

    private var isFiltered: Bool {
        filter.source != nil || filter.kind != .all || filter.category != nil
            || !filter.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var months: [String] {
        let all = Set(store.state.records.compactMap { r -> String? in
            guard r.kind == "income" || r.kind == "expense", let d = r.date, d.count >= 7 else { return nil }
            return String(d.prefix(7))
        })
        return all.union([FinanceText.currentMonth()]).sorted(by: >)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Metrics.spacing8) {
                Menu {
                    ForEach(months, id: \.self) { m in
                        Button(monthLabel(m)) { filter.month = m }
                    }
                    Button("Всё время") { filter.month = nil }
                } label: {
                    FilterChip(title: FinanceText.capitalized(periodTitle))
                }
                Menu {
                    Button("Все счета") { filter.source = nil }
                    ForEach(FinanceBudgeting.ledgerSources(store.state), id: \.self) { s in
                        Button(s) { filter.source = s }
                    }
                } label: {
                    FilterChip(title: filter.source ?? "Все счета", isActive: filter.source != nil)
                }
                Menu {
                    ForEach(LedgerKind.allCases, id: \.self) { kind in
                        Button(kindTitle(kind)) { filter.kind = kind }
                    }
                } label: {
                    FilterChip(title: kindTitle(filter.kind), isActive: filter.kind != .all)
                }
                if let category = filter.category {
                    Button {
                        filter.category = nil
                    } label: {
                        HStack(spacing: 4) {
                            Text(category)
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(DS.Colors.onAccent)
                        .padding(.horizontal, 12)
                        .frame(minHeight: DS.Metrics.minHitTarget)
                        .background(DS.Colors.accent)
                        .clipShape(Capsule())
                    }
                    .accessibilityLabel("Убрать фильтр «\(category)»")
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: DS.Metrics.spacing8) {
            Image(systemName: "magnifyingglass").foregroundColor(DS.Colors.textSecondary)
            TextField("Поиск: магазин, описание", text: $filter.query)
                .accessibilityIdentifier("operations-search")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !filter.query.isEmpty {
                Button {
                    filter.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(DS.Colors.textSecondary)
                }
                .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: DS.Metrics.minHitTarget)
        .background(DS.Colors.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
    }

    private func dayHeader(_ day: LedgerDay) -> some View {
        Text("\(FinanceText.dayTitle(day.date)) · \(FinanceText.signed(day.netMinor))")
            .font(.caption.weight(.semibold))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.top, DS.Metrics.spacing8)
            .accessibilityAddTraits(.isHeader)
    }

    private func monthLabel(_ month: String) -> String {
        let name: String = FinanceText.capitalized(FinanceText.monthName(month))
        return name + " " + String(month.prefix(4))
    }

    private func kindTitle(_ kind: LedgerKind) -> String {
        switch kind {
        case .all: return "Все типы"
        case .expense: return "Расходы"
        case .income: return "Доходы"
        case .transfer: return "Переводы"
        }
    }

    /// The bank on the other side of a transfer between own accounts.
    private func pairSource(_ entry: LedgerEntry) -> String? {
        guard entry.isOwnTransfer, let other = entry.record.pairedWith,
              let record = store.state.records.first(where: { $0.id == other }) else { return nil }
        return FinanceBudgeting.source(of: record, imports: FinanceBudgeting.importsById(store.state))
    }

    /// Whole pages of operations; a day cut by the page keeps its full total.
    private func paged(_ days: [LedgerDay]) -> [LedgerDay] {
        var out: [LedgerDay] = []
        var left = pageSize
        for day in days {
            if left <= 0 { break }
            var copy = day
            if copy.entries.count > left { copy.entries = Array(copy.entries.prefix(left)) }
            left -= copy.entries.count
            out.append(copy)
        }
        return out
    }
}

struct LedgerRow: View {
    let entry: LedgerEntry
    let pairSource: String?
    let onTap: () -> Void

    private var record: FinanceRecord { entry.record }
    private var muted: Bool { entry.isOwnTransfer || !entry.counts }

    private var subtitle: String {
        if entry.isOwnTransfer {
            guard let other = pairSource else { return "\(entry.source) · свой перевод, вне итогов" }
            let route = record.kind == "expense" ? "\(entry.source) → \(other)" : "\(other) → \(entry.source)"
            return route + " · вне итогов"
        }
        var parts: [String] = []
        if let c = record.category { parts.append(c) }
        parts.append(entry.source)
        if record.obligationId != nil { parts.append("платёж плана") }
        if !entry.counts { parts.append("не учитывается") }
        return parts.joined(separator: " · ")
    }

    private var amount: String {
        let value = record.amountMinor ?? 0
        return record.kind == "income" ? "+" + FinanceText.money(value) : "−" + FinanceText.money(value)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: DS.Metrics.spacing12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(muted ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(amount)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundColor(muted ? DS.Colors.textSecondary : (record.kind == "income" ? DS.Colors.positive : DS.Colors.textPrimary))
                    .strikethrough(!entry.counts && !entry.isOwnTransfer)
            }
            .frame(minHeight: DS.Metrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Открыть запись для изменения")
    }
}

struct ReconcileCard: View {
    let snapshot: BudgetSnapshot?
    let onReconcile: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                SectionHeader("Остаток на счетах")
                if let s = snapshot, let accounts = s.onAccountsMinor {
                    MoneyRow(label: s.asOf.map { "на \(FinanceText.dayMonth($0))" } ?? "сейчас", value: FinanceText.money(accounts), emphasized: true)
                    if s.isStale, let age = s.statementAgeDays {
                        Text("Последнему остатку \(age) дн. Загрузи свежие выписки или сверь остаток.")
                            .font(.caption)
                            .foregroundColor(DS.Colors.warning)
                    }
                } else {
                    Text("Остаток ещё не указан.")
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                Text("Между выписками можно ввести, сколько сейчас на картах. Разница станет поправкой остатка — не доходом и не расходом.")
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                PillButton("Сверить", icon: "checkmark.circle", style: .secondary, action: onReconcile)
            }
        }
    }
}

struct ReconcileSheet: View {
    let today: String
    let apply: FinanceApply
    let onClose: () -> Void

    @State private var amount = ""
    @State private var error: String? = nil

    var body: some View {
        FinanceSheet(title: "Сверка остатка", onClose: onClose) {
            Text("Сколько сейчас на всех картах и счетах вместе, без отложенного наличными.")
                .font(.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
            TextField("Сумма, ₸", text: $amount)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Остаток на всех счетах, тенге")
            if let error {
                Text(error).font(.caption).foregroundColor(DS.Colors.destructive)
            }
            PillButton("Сохранить", style: .primary, isEnabled: !amount.isEmpty) { save() }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let tenge = FinanceText.tenge(amount) else {
            error = "Введи сумму в тенге."
            return
        }
        let date = today
        let failure = apply("Остаток сверен.") {
            try FinanceBudgeting.reconcile($0, totalMinor: tenge * 100, today: date, id: UUID().uuidString)
        }
        if let failure { error = failure } else { onClose() }
    }
}

// MARK: - Hand-entered history

enum ManualKind {
    static func title(_ kind: String) -> String {
        switch kind {
        case "balance": return "Остаток"
        case "income": return "Доход"
        case "expense": return "Расход"
        case "obligation": return "Регулярный платёж"
        case "planned_income": return "Ожидаемый доход"
        case "goal": return "Конверт"
        default: return "Запись"
        }
    }

    static func frequency(_ value: String?) -> String? {
        switch value {
        case "monthly": return "каждый месяц"
        case "weekly": return "каждую неделю"
        default: return nil
        }
    }
}

/// What the owner added by «+», voice or text, the last added first; a tap opens it for a fix or removal.
struct ManualEntriesCard: View {
    let state: FinanceState
    let onEdit: (FinanceRecord) -> Void

    @State private var showsAll = false
    private static let shortList = 5

    var body: some View {
        let entries = FinanceBudgeting.manualEntries(state)
        let shown = showsAll ? entries : Array(entries.prefix(Self.shortList))
        if !entries.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                    SectionHeader("Добавлено вручную · \(entries.count)")
                    ForEach(shown, id: \.id) { record in
                        ManualEntryRow(record: record) { onEdit(record) }
                        if record.id != shown.last?.id {
                            Divider()
                        }
                    }
                    if entries.count > Self.shortList {
                        Button(showsAll ? "Свернуть" : "Показать все (\(entries.count))") {
                            withAnimation(.easeInOut(duration: 0.2)) { showsAll.toggle() }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(DS.Colors.accent)
                        .frame(minHeight: DS.Metrics.minHitTarget)
                        .accessibilityIdentifier("manual-entries-toggle")
                    }
                }
            }
            .accessibilityIdentifier("manual-entries")
        }
    }
}

struct ManualEntryRow: View {
    let record: FinanceRecord
    let onTap: () -> Void

    private var subtitle: String {
        var parts = [ManualKind.title(record.kind)]
        switch record.kind {
        case "income", "expense":
            if let c = record.category { parts.append(c) }
            if let d = record.date { parts.append(FinanceText.dayMonth(d)) }
            if record.excluded == true { parts.append("не учитывается") }
        case "balance":
            if let d = record.date { parts.append("на " + FinanceText.dayMonth(d)) }
        case "obligation", "planned_income":
            if let f = ManualKind.frequency(record.frequency) { parts.append(f) }
        case "goal":
            parts.append("отложено " + FinanceText.money(record.savedMinor ?? 0))
        default:
            break
        }
        return parts.joined(separator: " · ")
    }

    private var amount: String {
        let value = record.amountMinor ?? 0
        switch record.kind {
        case "income": return "+" + FinanceText.money(value)
        case "expense": return "−" + FinanceText.money(value)
        default: return FinanceText.money(value)
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: DS.Metrics.spacing12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(amount)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundColor(record.kind == "income" ? DS.Colors.positive : DS.Colors.textPrimary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(minHeight: DS.Metrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Изменить или удалить")
    }
}

/// Fix or remove a hand-entered record; «Чистыми», the plan and the envelopes recount at once.
struct ManualEditSheet: View {
    let record: FinanceRecord
    /// Nil when saved; otherwise the reason, and the sheet stays open.
    let onSave: (FinanceBudgeting.ManualEdit) -> String?
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var kind = ""
    @State private var title = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var category = ""
    @State private var frequency = "monthly"
    @State private var note = ""
    @State private var excluded = false
    @State private var error: String?

    private var isFlow: Bool { record.kind == "income" || record.kind == "expense" }
    private var hasDate: Bool { isFlow || record.kind == "balance" }
    private var hasFrequency: Bool { record.kind == "obligation" || record.kind == "planned_income" }

    private static let ymd = PlanDateTime.formatter("yyyy-MM-dd", timeZone: "Asia/Qyzylorda")

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isFlow {
                        Picker("Тип", selection: $kind) {
                            Text("Расход").tag("expense")
                            Text("Доход").tag("income")
                        }
                        .pickerStyle(.segmented)
                    } else {
                        LabeledContent("Тип", value: ManualKind.title(record.kind))
                    }
                    TextField("Название", text: $title)
                    TextField(record.kind == "goal" ? "Цель, ₸" : "Сумма, ₸", text: $amount)
                        .keyboardType(.decimalPad)
                    if hasDate {
                        DatePicker("Дата", selection: $date, displayedComponents: .date)
                            .environment(\.locale, Locale(identifier: "ru_RU"))
                            .environment(\.timeZone, TimeZone(identifier: "Asia/Qyzylorda") ?? .current)
                    }
                    if hasFrequency {
                        Picker("Как часто", selection: $frequency) {
                            Text("Каждый месяц").tag("monthly")
                            Text("Каждую неделю").tag("weekly")
                        }
                        .pickerStyle(.segmented)
                    }
                    if record.kind == "goal" {
                        Text("Отложено \(FinanceText.money(record.savedMinor ?? 0)). Положить или забрать деньги можно в самом конверте на вкладке «План».")
                            .font(.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                if isFlow {
                    Section("Категория") {
                        Picker("Категория", selection: $category) {
                            ForEach(categoryOptions, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                Section {
                    TextField("Заметка", text: $note, axis: .vertical)
                    if hasDate {
                        Toggle("Не учитывать в итогах", isOn: $excluded)
                    }
                }
                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundColor(DS.Colors.destructive)
                    }
                }
                Section {
                    Button("Удалить запись", role: .destructive, action: onDelete)
                }
            }
            .navigationTitle("Запись")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save).bold() }
            }
            .onAppear(perform: load)
        }
    }

    private var categoryOptions: [String] {
        var options = MerchantCategories.all
        if let current = record.category, !options.contains(current) { options.insert(current, at: 0) }
        return options
    }

    private func load() {
        kind = record.kind
        title = record.title
        amount = record.amountMinor.map { String(format: "%.2f", Double($0) / 100).replacingOccurrences(of: ".00", with: "") } ?? ""
        if let day = record.date, let parsed = Self.ymd.date(from: day) { date = parsed }
        category = record.category ?? "Без категории"
        frequency = record.frequency ?? "monthly"
        note = record.note ?? ""
        excluded = record.excluded == true
    }

    private func save() {
        let typed = amount.replacingOccurrences(of: ",", with: ".").filter { !$0.isWhitespace }
        guard let minor = try? parseKzt(typed) else {
            error = "Введите сумму числом."
            return
        }
        let edit = FinanceBudgeting.ManualEdit(
            kind: kind,
            title: title,
            amountMinor: minor,
            date: hasDate ? Self.ymd.string(from: date) : nil,
            category: isFlow ? category : nil,
            frequency: hasFrequency ? frequency : nil,
            note: note,
            excluded: hasDate ? excluded : nil
        )
        error = onSave(edit)
    }
}
