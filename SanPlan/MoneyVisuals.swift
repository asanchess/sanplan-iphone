import SwiftUI

// Round 10 (owner request 19.11, B): «Обзор» shows the month as two tiles side by side, then the money
// that is saved — the cushion in months of living and each envelope as a goal with a «where you should be» mark.

// MARK: - Numbers

enum MoneyVisuals {
    struct CategoryShare: Equatable, Identifiable {
        var id: String { name }
        let name: String
        /// Whole tenge, as `FinanceSummaries` counts them.
        let tenge: Int64
    }

    /// The biggest categories of this calendar month (from the 1st to today), the largest first.
    static func topCategories(_ state: FinanceState, today: String, count: Int = 3) -> [CategoryShare] {
        let month = String(today.prefix(7))
        let byCategory = FinanceSummaries.period(state, from: month + "-01", to: today).byCategory
        return byCategory.filter { $0.value > 0 }
            .map { CategoryShare(name: $0.key, tenge: $0.value) }
            .sorted { $0.tenge != $1.tenge ? $0.tenge > $1.tenge : $0.name < $1.name }
            .prefix(count)
            .map { $0 }
    }

    /// The share of its target an envelope should hold today to be full on its date, 0...1.
    /// Nil without a date, or when the date is not after the day it was made.
    static func paceFraction(goal: FinanceRecord, today: String) -> Double? {
        guard let due = goal.dueDate, let start = goal.date else { return nil }
        let total = MoneyDays.days(from: start, to: due)
        guard total > 0 else { return nil }
        let gone = MoneyDays.days(from: start, to: min(today, due))
        return min(max(Double(gone) / Double(total), 0), 1)
    }

    /// How far the envelope is ahead (positive) or behind (negative) of its pace, in minor units. Nil without a date.
    static func paceGap(goal: FinanceRecord, today: String) -> Int64? {
        guard let pace = paceFraction(goal: goal, today: today) else { return nil }
        let target = goal.amountMinor ?? 0
        let expected = Int64((Double(target) * pace).rounded())
        return (goal.savedMinor ?? 0) - expected
    }

    struct SavedPoint: Equatable {
        let month: String
        let minor: Int64
    }

    struct Cushion: Equatable {
        /// Everything in the envelopes, on the accounts or not.
        let savedMinor: Int64
        /// A month of living (the plan's payments or the usual spending); nil when unknown.
        let monthlyMinor: Int64?
        /// The saved total at the end of each month, oldest first; the last point is today.
        let history: [SavedPoint]

        var months: Double? {
            guard let monthlyMinor, monthlyMinor > 0 else { return nil }
            return Double(savedMinor) / Double(monthlyMinor)
        }

        /// «2,4» — one decimal, a comma, as the rest of the app writes numbers.
        var monthsText: String? {
            guard let months else { return nil }
            let tenths = Int((months * 10).rounded(.down))
            return "\(tenths / 10),\(tenths % 10)"
        }
    }

    /// Six months reads as a full cushion: the arc is closed there.
    static let fullCushionMonths = 6.0

    static func cushion(_ state: FinanceState, today: String, months: Int = 6) -> Cushion {
        let goals = state.records.filter { $0.kind == "goal" }
        let saved = goals.reduce(Int64(0)) { $0 + ($1.savedMinor ?? 0) }
        return Cushion(
            savedMinor: saved,
            monthlyMinor: FinanceBudgeting.monthlyLivingCost(state, today: today)?.minor,
            history: savedHistory(state, today: today, months: months)
        )
    }

    /// The saved total going back month by month: today's total less every move after the month's last day,
    /// and less the money an envelope started with when it was made after that day.
    static func savedHistory(_ state: FinanceState, today: String, months: Int) -> [SavedPoint] {
        let goals = state.records.filter { $0.kind == "goal" }
        let ids = Set(goals.map(\.id))
        let log = (state.budget?.envelopeLog ?? []).filter { ids.contains($0.goalId) }
        let now = goals.reduce(Int64(0)) { $0 + ($1.savedMinor ?? 0) }
        let current = String(today.prefix(7))
        var list = [current]
        while list.count < max(months, 1) { list.insert(FinanceInsights.previousMonth(list[0]), at: 0) }
        return list.map { month in
            let end = month == current ? today : (MoneyDays.month(of: month + "-01").last ?? today)
            var total = now
            for entry in log where entry.date > end { total -= entry.amountMinor }
            for goal in goals where (goal.date ?? "") > end {
                let logged = log.filter { $0.goalId == goal.id }.reduce(Int64(0)) { $0 + $1.amountMinor }
                total -= (goal.savedMinor ?? 0) - logged
            }
            return SavedPoint(month: month, minor: max(total, 0))
        }
    }
}

// MARK: - Shapes

/// An open arc from bottom-left over the top to bottom-right (`span` of a full turn), filled to `fraction`.
struct MoneyArc: View {
    let fraction: Double
    var span: Double = 0.75
    var lineWidth: CGFloat = 8
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: span)
                .stroke(MoneyStyle.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: span * min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        .rotationEffect(.degrees(90 + (1 - span) * 180))
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// An envelope: a rounded body with the flap folded in.
struct EnvelopeOutline: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: r, cornerRadius: 12, style: .continuous)
        p.move(to: CGPoint(x: r.minX + 6, y: r.minY + 5))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.36))
        p.addLine(to: CGPoint(x: r.maxX - 6, y: r.minY + 5))
        return p
    }
}

/// A bar with a thin upright mark where the money should be today.
struct MoneyPaceBar: View {
    let fraction: Double
    let mark: Double?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(MoneyStyle.track).frame(height: 8)
                Capsule().fill(color).frame(width: max(8, width * min(max(fraction, 0), 1)), height: 8)
                    .opacity(fraction > 0 ? 1 : 0)
                if let mark {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(DS.Colors.textPrimary)
                        .frame(width: 3, height: 16)
                        .offset(x: min(max(width * mark - 1.5, 0), width - 3))
                }
            }
            .frame(height: 16)
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

/// A smooth line through the points with a soft fill under it and a dot on the last point.
struct MoneySparkline: View {
    let values: [Int64]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let points = Self.points(values, in: proxy.size)
            ZStack(alignment: .topLeading) {
                if points.count > 1 {
                    Self.area(points, height: proxy.size.height)
                        .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Self.line(points)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                if let last = points.last {
                    Circle().fill(color).frame(width: 8, height: 8).position(last)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static func points(_ values: [Int64], in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let low = values.min() ?? 0, high = values.max() ?? 0
        let inset: CGFloat = 5
        let height = size.height - inset * 2
        let step = values.count > 1 ? (size.width - inset * 2) / CGFloat(values.count - 1) : 0
        return values.enumerated().map { index, value in
            let share = high > low ? CGFloat(value - low) / CGFloat(high - low) : 0.5
            return CGPoint(x: inset + step * CGFloat(index), y: inset + height * (1 - share))
        }
    }

    private static func line(_ points: [CGPoint]) -> Path {
        var p = Path()
        p.move(to: points[0])
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let mid = (a.x + b.x) / 2
            p.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
        }
        return p
    }

    private static func area(_ points: [CGPoint], height: CGFloat) -> Path {
        var p = line(points)
        p.addLine(to: CGPoint(x: points[points.count - 1].x, y: height))
        p.addLine(to: CGPoint(x: points[0].x, y: height))
        p.closeSubpath()
        return p
    }
}

// MARK: - Обзор: two tiles

/// «Ноябрь» with its total and a bar per day, and «Куда уходит» with the three biggest categories, side by side.
/// A tap opens a tile across the whole width (the week/month switch, every category); «Свернуть» puts them back.
struct MoneyOverviewTiles: View {
    let state: FinanceState
    let today: String
    @Binding var period: DeepLink.Period
    let onCategory: (String) -> Void

    enum Tile: Equatable { case days, categories }
    @State private var open: Tile? = nil
    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tileHeight: CGFloat = 172

    var body: some View {
        Group {
            switch open {
            case .days:
                VStack(alignment: .trailing, spacing: 0) {
                    collapse
                    MoneyDailySpendCard(state: state, today: today, period: $period)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            case .categories:
                VStack(alignment: .trailing, spacing: 0) {
                    collapse
                    Card { MoneyCategoryList(state: state, today: today, onCategory: onCategory) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            case nil:
                HStack(alignment: .top, spacing: 12) {
                    daysTile
                    categoriesTile
                }
                .transition(.opacity)
            }
        }
        .onChange(of: period) { _, _ in
            if open != .days { toggle(.days) }
        }
    }

    private func toggle(_ tile: Tile?) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.15)) { open = tile }
    }

    private var collapse: some View {
        MoneyTextButton("Свернуть") { toggle(nil) }
            .padding(.trailing, 4)
    }

    // MARK: Days

    private var daysTile: some View {
        let days = MoneyDays.month(of: today)
        let amounts: [Int64] = days.map { $0 > today ? 0 : FinanceSummaries.day(state, $0).spent }
        let total = amounts.reduce(0, +)
        let monthTitle = FinanceText.capitalized(FinanceText.monthName(String(today.prefix(7))))
        return Button { toggle(.days) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(monthTitle)
                    .font(DS.Fonts.text(14, .bold, relativeTo: .subheadline))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Text(FinanceText.money(total * FinanceBudgeting.oneTenge))
                    .font(DS.Fonts.text(22, .heavy, relativeTo: .title3))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                miniBars(days: days, amounts: amounts)
            }
            .tile(height: tileHeight)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(monthTitle): потрачено \(FinanceText.money(total * FinanceBudgeting.oneTenge))")
        .accessibilityHint("Открыть траты по дням")
        .accessibilityIdentifier("money-daily-spend")
    }

    private func miniBars(days: [String], amounts: [Int64]) -> some View {
        let top = max(amounts.max() ?? 0, 1)
        let tallest: CGFloat = 64
        return HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(days.indices, id: \.self) { index in
                let day = days[index], amount = amounts[index]
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(day == today ? accent : (amount > 0 ? accent.opacity(0.42) : MoneyStyle.track))
                    .frame(height: amount > 0 ? max(4, tallest * CGFloat(amount) / CGFloat(top)) : 3)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: tallest, alignment: .bottom)
    }

    // MARK: Categories

    private var categoriesTile: some View {
        let rows = MoneyVisuals.topCategories(state, today: today)
        let top = max(rows.first?.tenge ?? 1, 1)
        return Button { toggle(.categories) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Куда уходит")
                    .font(DS.Fonts.text(14, .bold, relativeTo: .subheadline))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                if rows.isEmpty {
                    Text("Трат пока нет")
                        .font(DS.Fonts.text(15, .semibold))
                        .foregroundColor(DS.Colors.textMuted)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(row.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 2)
                            Text(Self.short(row.tenge))
                                .fixedSize()
                        }
                        .font(DS.Fonts.text(13, .semibold, relativeTo: .caption))
                        .foregroundColor(DS.Colors.textPrimary)
                        MoneyBar(fraction: Double(row.tenge) / Double(top), height: 7, color: accent)
                    }
                }
                Spacer(minLength: 0)
            }
            .tile(height: tileHeight)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Куда уходит: " + rows.map { "\($0.name) \(FinanceText.money($0.tenge * FinanceBudgeting.oneTenge))" }.joined(separator: ", "))
        .accessibilityHint("Открыть все категории")
        .accessibilityIdentifier("money-categories")
    }

    /// «48 тыс.», «950 ₸»: the tile is narrow, the full sum is one tap away.
    static func short(_ tenge: Int64) -> String {
        if tenge >= 1_000_000 {
            let tenths = tenge / 100_000
            return tenths % 10 == 0 ? "\(tenths / 10) млн" : "\(tenths / 10),\(tenths % 10) млн"
        }
        if tenge >= 10_000 { return "\((tenge + 500) / 1000) тыс." }
        return FinanceText.money(tenge * FinanceBudgeting.oneTenge)
    }
}

private extension View {
    func tile(height: CGFloat) -> some View {
        padding(14)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Обзор: the cushion

/// What is saved, in tenge and in months of living, an arc that closes at six months, and how it grew.
struct MoneyCushionCard: View {
    let cushion: MoneyVisuals.Cushion
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    MoneyArc(fraction: (cushion.months ?? 0) / MoneyVisuals.fullCushionMonths, lineWidth: 9, color: accent)
                    VStack(spacing: 0) {
                        Text(cushion.monthsText ?? "—")
                            .font(DS.Fonts.text(20, .heavy, relativeTo: .title3))
                            .foregroundColor(DS.Colors.textPrimary)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text("мес.")
                            .font(DS.Fonts.text(12, .bold, relativeTo: .caption2))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .padding(.horizontal, 12)
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Сохранено")
                        .font(DS.Fonts.text(14, .bold, relativeTo: .subheadline))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(FinanceText.money(cushion.savedMinor))
                        .font(DS.Fonts.text(26, .heavy, relativeTo: .title2))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(cushion.monthsText.map { "≈ \($0) мес. жизни" } ?? "месяц жизни посчитается по тратам")
                        .font(DS.Fonts.text(14, .semibold, relativeTo: .caption))
                        .foregroundColor(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            if cushion.history.count > 1 {
                MoneySparkline(values: cushion.history.map(\.minor), color: accent)
                    .frame(height: 48)
                HStack {
                    Text(FinanceText.monthName(cushion.history[0].month))
                    Spacer()
                    Text("сейчас")
                }
                .font(DS.Fonts.text(12, .semibold, relativeTo: .caption2))
                .foregroundColor(DS.Colors.textMuted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("money-cushion")
    }

    private var label: String {
        var text = "Сохранено \(FinanceText.money(cushion.savedMinor))"
        if let months = cushion.monthsText { text += ", это примерно \(months) месяца жизни" }
        if let first = cushion.history.first, cushion.history.count > 1 {
            text += ". В \(FinanceText.monthName(first.month)) было \(FinanceText.money(first.minor))"
        }
        return text
    }
}

// MARK: - Обзор: an envelope as a goal

/// An envelope with an arc inside that fills towards the target, the sum, and a bar with a mark
/// where the money should be today if the envelope has a date.
struct MoneyGoalCard: View {
    let goal: FinanceRecord
    let today: String
    let receivesIncome: Bool
    let onTap: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        let saved = goal.savedMinor ?? 0
        let target = max(goal.amountMinor ?? 0, 1)
        let share = Double(saved) / Double(target)
        let pace = MoneyVisuals.paceFraction(goal: goal, today: today)
        let gap = MoneyVisuals.paceGap(goal: goal, today: today)
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottom) {
                    EnvelopeOutline()
                        .stroke(share >= 1 ? accent : DS.Colors.hairline, lineWidth: 1.5)
                    ZStack(alignment: .bottom) {
                        MoneyArc(fraction: share, span: 0.5, lineWidth: 7, color: accent)
                            .frame(width: 62, height: 62)
                            .offset(y: 31)
                        Text("\(min(Int((share * 100).rounded(.down)), 100))%")
                            .font(DS.Fonts.text(14, .heavy, relativeTo: .caption))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.bottom, 2)
                    }
                    .frame(width: 70, height: 36)
                    .clipped()
                    .padding(.bottom, 8)
                }
                .frame(height: 74)
                Text(goal.title)
                    .font(DS.Fonts.text(15, .bold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Text(FinanceText.money(saved))
                    .font(DS.Fonts.text(19, .heavy, relativeTo: .title3))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                MoneyPaceBar(fraction: share, mark: pace, color: gap.map { $0 < 0 ? DS.Colors.warning : accent } ?? accent)
                Text(note(saved: saved, gap: gap))
                    .font(DS.Fonts.text(12, .semibold, relativeTo: .caption2))
                    .foregroundColor(gap.map { $0 < 0 ? DS.Colors.warning : accent } ?? DS.Colors.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 132, alignment: .leading)
            .padding(14)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(saved: saved, gap: gap))
        .accessibilityHint("Открыть конверт: история, отложить, забрать")
    }

    private func note(saved: Int64, gap: Int64?) -> String {
        let target = goal.amountMinor ?? 0
        if target > 0 && saved >= target { return "цель собрана" }
        if let gap, let due = goal.dueDate {
            return gap < 0 ? "отстаёт на \(FinanceText.money(-gap))" : "по графику · к \(FinanceText.dayMonth(due))"
        }
        return receivesIncome ? "сюда с дохода" : "из \(FinanceText.money(target))"
    }

    private func accessibilityText(saved: Int64, gap: Int64?) -> String {
        var text = "\(goal.title): \(FinanceText.money(saved)) из \(FinanceText.money(goal.amountMinor ?? 0))"
        if let gap, let due = goal.dueDate {
            text += gap < 0 ? ", к \(FinanceText.dayMonth(due)) отстаёт на \(FinanceText.money(-gap))" : ", идёт по графику к \(FinanceText.dayMonth(due))"
        }
        return text
    }
}

/// The last card of the row: a dashed envelope that creates a new one.
struct MoneyNewGoalCard: View {
    let onTap: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                ZStack {
                    EnvelopeOutline()
                        .stroke(DS.Colors.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(accent)
                        .offset(y: 8)
                }
                .frame(height: 74)
                Text("Новый конверт")
                    .font(DS.Fonts.text(15, .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 112)
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Новый конверт")
    }
}

// MARK: - Обзор: everything about saving, in one block

/// The cushion, the envelopes, the income offers, «Отложить с дохода» and the percent to offer.
struct MoneySavingsBlock: View {
    @ObservedObject var store: FinanceStore
    let today: String
    let apply: FinanceApply

    @State private var creatingEnvelope = false
    @State private var openedEnvelope: MonthRef? = nil
    @State private var choosingSetAside = false
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        let goals = FinanceEnvelopes.goals(store.state)
        let savingsGoal = FinanceEnvelopes.savingsGoal(store.state)
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            if !goals.isEmpty {
                MoneyCushionCard(cushion: MoneyVisuals.cushion(store.state, today: today))
            }
            SectionHeader("Конверты")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DS.Metrics.spacing12) {
                    ForEach(goals) { g in
                        MoneyGoalCard(goal: g, today: today, receivesIncome: g.id == savingsGoal?.id && goals.count > 1) {
                            openedEnvelope = MonthRef(id: g.id)
                        }
                    }
                    MoneyNewGoalCard { creatingEnvelope = true }
                }
            }
            .scrollClipDisabled()
            .accessibilityIdentifier("money-envelopes")
            if goals.isEmpty {
                Text("Деньги в конвертах остаются на картах, но не входят в «Чистыми».")
                    .font(DS.Fonts.text(13, .medium, relativeTo: .caption))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            offers(goals: goals, savingsGoal: savingsGoal)
            MoneyPrimaryButton("Отложить с дохода", icon: "arrow.down.to.line") {
                if goals.isEmpty { creatingEnvelope = true } else { choosingSetAside = true }
            }
            .accessibilityIdentifier("money-set-aside")
            percentStepper
        }
        .sheet(isPresented: $creatingEnvelope) {
            NewEnvelopeSheet(today: today, apply: apply) { creatingEnvelope = false }
                .environment(\.sectionAccent, accent)
        }
        .sheet(item: $openedEnvelope) { ref in
            EnvelopeSheet(store: store, goalId: ref.id, apply: apply) { openedEnvelope = nil }
                .environment(\.sectionAccent, accent)
        }
        .sheet(isPresented: $choosingSetAside) {
            let offer = FinanceBudgeting.setAsideOffers(store.state, today: today).first
            SetAsideChoiceSheet(
                goals: FinanceEnvelopes.goals(store.state),
                initialGoalId: FinanceEnvelopes.savingsGoal(store.state)?.id,
                suggestedMinor: offer?.suggestedMinor ?? 0,
                commit: { goalId, amount in setAside(goalId, amount, incomeId: offer?.incomeId) },
                onClose: { choosingSetAside = false }
            )
            .environment(\.sectionAccent, accent)
        }
    }

    /// Incomes that wait for an answer, then the money left free this month.
    @ViewBuilder
    private func offers(goals: [FinanceRecord], savingsGoal: FinanceRecord?) -> some View {
        if !goals.isEmpty {
            ForEach(FinanceBudgeting.setAsideOffers(store.state, today: today).prefix(3)) { offer in
                SetAsideOfferRow(offer: offer, goal: savingsGoal, goals: goals, apply: apply)
            }
            if let free = FinanceBudgeting.freeBalanceOffer(store.state, today: today) {
                FreeOfferRow(offer: free, goal: savingsGoal, goals: goals, apply: apply)
            }
        }
    }

    private var percentStepper: some View {
        let percent = store.state.budget?.savePercent ?? FinanceBudgeting.defaultSavePercent
        return Stepper(value: Binding(
            get: { percent },
            set: { value in apply(nil) { try FinanceBudgeting.updateBudget($0) { $0.savePercent = value } } }
        ), in: 0...50, step: 5) {
            Text(percent == 0 ? "С дохода не предлагать" : "Предлагать отложить \(percent)% дохода")
                .font(DS.Fonts.text(15, .medium))
                .foregroundColor(DS.Colors.textPrimary)
        }
        .tint(accent)
    }

    @discardableResult
    private func setAside(_ goalId: String, _ amount: Int64, incomeId: String?) -> String? {
        let title = FinanceEnvelopes.goals(store.state).first { $0.id == goalId }?.title ?? ""
        return apply("Отложено \(FinanceText.money(amount)) в «\(title)».") {
            try FinanceBudgeting.setAside($0, amountMinor: amount, goalId: goalId, incomeId: incomeId, raiseTarget: true)
        }
    }
}

// MARK: - План: a new payment right where the payments are

struct NewPaymentSheet: View {
    let today: String
    let apply: FinanceApply
    let onClose: () -> Void

    @State private var title = ""
    @State private var amount = ""
    @State private var weekly = false
    @State private var error: String? = nil

    var body: some View {
        FinanceSheet(title: "Новый платёж", onClose: onClose) {
            TextField("Название, например «Аренда»", text: $title)
                .moneyField()
            TextField("Сумма, ₸", text: $amount)
                .keyboardType(.numberPad)
                .moneyField()
            Picker("Как часто", selection: $weekly) {
                Text("Каждый месяц").tag(false)
                Text("Каждую неделю").tag(true)
            }
            .pickerStyle(.segmented)
            if let error {
                Text(error).font(.caption).foregroundColor(DS.Colors.destructive)
            }
            MoneyPrimaryButton("Добавить", isEnabled: !title.trimmingCharacters(in: .whitespaces).isEmpty && !amount.isEmpty) { save() }
                .accessibilityIdentifier("money-payment-save")
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tenge = FinanceText.tenge(amount), tenge > 0, tenge < 1_000_000_000 else {
            error = "Введи сумму в тенге."
            return
        }
        let draft = FinanceDraft(kind: "obligation", title: name, amountMinor: tenge * 100, date: today,
                                 frequency: weekly ? "weekly" : "monthly")
        let date = today
        let failure = apply("Платёж «\(name)» добавлен.") { state in
            try commitFinance(state: state, drafts: [draft], batchId: UUID().uuidString, nowDate: date)
        }
        if let failure { error = failure } else { onClose() }
    }
}
