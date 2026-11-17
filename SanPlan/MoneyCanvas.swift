import SwiftUI

// Round 6: the pieces of «Деньги» taken 1:1 from docs/design/canvas-r5/Money.html.
// Every colour that belongs to the section comes from `sectionAccent` (money: #6FD6B0).

enum MoneyStyle {
    /// Empty part of a bar and a day without spending (#33295A on the canvas).
    static let track = DS.Colors.hex(0x33295A)
    /// Dark text on the section colour (#10241C on the canvas buttons).
    static let onAccent = DS.Colors.hex(0x10241C)
    /// Gap between the blocks of the screen.
    static let blockGap: CGFloat = 20
}

// MARK: - Days

/// Calendar days in the money's time zone, as «yyyy-MM-dd» strings.
enum MoneyDays {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = FinanceText.zone
        c.firstWeekday = 2
        return c
    }()

    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = FinanceText.zone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func shift(_ day: String, by days: Int) -> String {
        guard let date = ymd.date(from: day), let moved = calendar.date(byAdding: .day, value: days, to: date) else { return day }
        return ymd.string(from: moved)
    }

    /// Monday to Sunday of the week that holds `day`.
    static func week(of day: String) -> [String] {
        guard let date = ymd.date(from: day) else { return [] }
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        let sinceMonday = (weekday + 5) % 7
        return (0..<7).map { shift(day, by: $0 - sinceMonday) }
    }

    /// Every day of the month that holds `day`.
    static func month(of day: String) -> [String] {
        let prefix = String(day.prefix(7))
        guard let year = Int(prefix.prefix(4)), let month = Int(prefix.suffix(2)) else { return [] }
        return (1...getDaysInMonth(year: year, month: month)).map { String(format: "%@-%02d", prefix, $0) }
    }

    /// «Сегодня», «Вчера» or «Вт, 4 ноября».
    static func title(_ day: String, today: String) -> String {
        if day == today { return "Сегодня" }
        if day == shift(today, by: -1) { return "Вчера" }
        return FinanceText.dayTitle(day)
    }
}

// MARK: - Backdrop

/// The soft glow and dot grid in the top right corner of the canvas stage.
struct MoneyBackdrop: View {
    let accent: Color

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.22), accent.opacity(0)], center: .center, startRadius: 0, endRadius: 154))
                .frame(width: 320, height: 320)
                .offset(x: 90, y: -110)
            Canvas { context, size in
                let center = CGPoint(x: size.width * 0.72, y: size.height * 0.28)
                let fade: CGFloat = 159
                var y: CGFloat = 5.5
                while y < size.height {
                    var x: CGFloat = 5.5
                    while x < size.width {
                        let strength = 1 - hypot(x - center.x, y - center.y) / fade
                        if strength > 0 {
                            context.opacity = strength
                            context.fill(Path(ellipseIn: CGRect(x: x - 1.9, y: y - 1.9, width: 3.8, height: 3.8)), with: .color(accent))
                        }
                        x += 11
                    }
                    y += 11
                }
            }
            .frame(width: 230, height: 230)
            .opacity(0.3)
            .offset(x: 30, y: -30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons and fields

/// The canvas main button: 56 high, radius 18, section colour, dark heavy text.
struct MoneyPrimaryButton: View {
    let title: String
    var icon: String? = nil
    var isEnabled = true
    let action: () -> Void
    @Environment(\.sectionAccent) private var accent

    init(_ title: String, icon: String? = nil, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 16, weight: .bold)) }
                Text(title)
                    .font(DS.Fonts.text(17, .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundColor(MoneyStyle.onAccent)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The canvas outline link («Выписки из банка»): 52 high, radius 18, hairline border.
struct MoneyOutlineButton: View {
    let title: String
    var icon: String? = nil
    var isLoading = false
    let action: () -> Void

    init(_ title: String, icon: String? = nil, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(DS.Colors.textPrimary)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(DS.Fonts.text(16, .bold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DS.Colors.hairline, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(isLoading)
    }
}

/// A small text action in the section colour, at least 44 points high.
struct MoneyTextButton: View {
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void
    @Environment(\.sectionAccent) private var accent

    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                .foregroundColor(role == .destructive ? DS.Colors.destructive : accent)
                .frame(minHeight: DS.Metrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A money input field: dark well, the section colour around it while it has focus.
struct MoneyFieldModifier: ViewModifier {
    @FocusState private var focused: Bool
    @Environment(\.sectionAccent) private var accent

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .font(DS.Fonts.text(17, .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(focused ? accent : DS.Colors.hairline, lineWidth: focused ? 1.5 : 1)
            )
    }
}

extension View {
    func moneyField() -> some View { modifier(MoneyFieldModifier()) }
}

/// A thin rounded bar: track #33295A, fill in the given colour.
struct MoneyBar: View {
    let fraction: Double
    var height: CGFloat = 8
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(MoneyStyle.track)
                Capsule().fill(color)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Bottom composer («+» of the section)

/// The canvas bottom bar: «Кофе 1200» field with the mic inside and «Добавить». Voice or text; the parsed
/// records are checked above and then land in «Операции».
struct MoneyComposerBar: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let isListening: Bool
    let level: Float
    let isBusy: Bool
    let onMic: () -> Void
    let onAdd: () -> Void
    let onClear: () -> Void

    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .center, spacing: 2) {
                TextField("Новая операция", text: $text, prompt: Text("Кофе 1200").foregroundColor(DS.Colors.textMuted), axis: .vertical)
                    .lineLimit(1...4)
                    .font(DS.Fonts.text(17, .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .tint(accent)
                    .focused(focus)
                    .padding(.vertical, 14)
                    .accessibilityLabel("Новая операция")
                if hasText && !isListening {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(DS.Colors.textMuted)
                            .frame(width: 36, height: DS.Metrics.minHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить")
                }
                micButton
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .frame(minHeight: 56)
            .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(isListening || focus.wrappedValue ? accent : .clear, lineWidth: 1.5)
            )
            .petTip("Пишите как удобно: «кофе 1200» — категорию подберу сам.")

            Button(action: onAdd) {
                ZStack {
                    Text("Добавить")
                        .font(DS.Fonts.text(15, .heavy))
                        .opacity(isBusy ? 0 : 1)
                    if isBusy { ProgressView().tint(MoneyStyle.onAccent) }
                }
                .foregroundColor(MoneyStyle.onAccent)
                .padding(.horizontal, 18)
                .frame(height: 56)
                .background(accent, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(isBusy)
            .accessibilityLabel(isBusy ? "Разбираю" : "Добавить")
            .accessibilityIdentifier("money-add")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var micButton: some View {
        Button(action: onMic) {
            ZStack {
                Circle().fill(isListening ? accent : accent.opacity(0.16))
                if isListening && !reduceMotion {
                    Circle()
                        .stroke(accent.opacity(0.45), lineWidth: 2)
                        .scaleEffect(1 + CGFloat(level) * 0.5)
                        .animation(.linear(duration: 0.1), value: level)
                }
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isListening ? MoneyStyle.onAccent : accent)
            }
            .frame(width: 38, height: 38)
            .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isListening ? "Остановить диктовку" : "Диктовать")
        .sensoryFeedback(.impact(weight: .light), trigger: isListening)
    }
}

// MARK: - Small switch (week / month)

/// The compact two-way switch inside a card: skewed section-colour pill with an ink shadow on a dark track.
struct MoneyMiniSwitch<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isOn = option.value == selection
                Button {
                    withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.2)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(DS.Fonts.text(14, .bold, relativeTo: .subheadline))
                        .foregroundColor(isOn ? DS.Colors.canvas : DS.Colors.textSecondary)
                        .lineLimit(1)
                        .frame(width: 86, height: 34)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(accent)
                                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(DS.Colors.ink).offset(x: 3, y: 3))
                                    .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.087, d: 1, tx: 1.5, ty: 0))
                            }
                        }
                        .frame(minHeight: DS.Metrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 3)
        .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Обзор: «Траты по дням»

/// Spending per day of this week or this month: today in the section colour, past days in its dark shade,
/// empty days as a low stub. Week or month comes from the switch or a deep link (`.moneyOverview(.week/.month)`).
struct MoneyDailySpendCard: View {
    let state: FinanceState
    let today: String
    @Binding var period: DeepLink.Period
    @Environment(\.sectionAccent) private var accent

    private static let weekLabels = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
    private let chartHeight: CGFloat = 110

    var body: some View {
        let days = period == .week ? MoneyDays.week(of: today) : MoneyDays.month(of: today)
        let amounts: [Int64] = days.map { $0 > today ? 0 : FinanceSummaries.day(state, $0).spent }
        let total = amounts.reduce(0, +)
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionHeader("Траты по дням")
                Text("\(periodName): \(FinanceText.money(total * FinanceBudgeting.oneTenge))")
                    .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: true, vertical: false)
            }
            MoneyMiniSwitch(title: "Период", selection: $period, options: [(.week, "Неделя"), (.month, "Месяц")])
            chart(days: days, amounts: amounts)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(chartLabel(days: days, amounts: amounts))
        }
        .accessibilityIdentifier("money-daily-spend")
    }

    private var periodName: String {
        period == .week ? "Неделя" : FinanceText.capitalized(FinanceText.monthName(String(today.prefix(7))))
    }

    private func chart(days: [String], amounts: [Int64]) -> some View {
        let isWeek = period == .week
        let top = max(amounts.max() ?? 0, 1)
        let labelSpace: CGFloat = isWeek ? 22 : 19
        let tallest = chartHeight - labelSpace
        return HStack(alignment: .bottom, spacing: isWeek ? 8 : 3) {
            ForEach(days.indices, id: \.self) { index in
                let day = days[index]
                let amount = amounts[index]
                VStack(spacing: isWeek ? 6 : 4) {
                    RoundedRectangle(cornerRadius: isWeek ? 8 : 3, style: .continuous)
                        .fill(color(day: day, amount: amount))
                        .frame(height: amount > 0 ? max(8, tallest * CGFloat(amount) / CGFloat(top)) : 6)
                    Text(label(index: index, isWeek: isWeek))
                        .font(DS.Fonts.text(isWeek ? 12 : 10, .bold, relativeTo: .caption2))
                        .foregroundColor(day == today ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: isWeek ? 16 : 15)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: chartHeight, alignment: .bottom)
        .animation(.easeOut(duration: 0.25), value: period)
    }

    private func label(index: Int, isWeek: Bool) -> String {
        if isWeek { return Self.weekLabels[index % 7] }
        let day = index + 1
        return [1, 8, 15, 22, 29].contains(day) ? "\(day)" : " "
    }

    private func color(day: String, amount: Int64) -> Color {
        if day == today { return amount > 0 ? accent : accent.opacity(0.7) }
        return amount > 0 ? accent.opacity(0.42) : MoneyStyle.track
    }

    private func chartLabel(days: [String], amounts: [Int64]) -> String {
        let scope = period == .week ? "Траты по дням недели" : "Траты по дням месяца"
        guard let top = amounts.max(), top > 0, let index = amounts.firstIndex(of: top) else { return scope + ", трат нет" }
        return scope + ", больше всего \(FinanceText.dayMonth(days[index])): \(FinanceText.money(top * FinanceBudgeting.oneTenge))"
    }
}

// MARK: - Обзор: «Куда уходит»

/// This month's spending by category, the biggest first; a tap opens «Операции» filtered by that category.
struct MoneyCategoryList: View {
    let state: FinanceState
    let today: String
    let onCategory: (String) -> Void
    @Environment(\.sectionAccent) private var accent

    private struct Row: Identifiable {
        var id: String { name }
        let name: String
        let tenge: Int64
    }

    var body: some View {
        let month = String(today.prefix(7))
        let summary = FinanceSummaries.period(state, from: month + "-01", to: today)
        let rows = Self.rows(summary.byCategory)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Куда уходит · \(FinanceText.monthName(month)) \(FinanceText.money(summary.spent * FinanceBudgeting.oneTenge))")
            if rows.isEmpty {
                Text("В этом месяце трат пока нет.")
                    .font(DS.Fonts.text(16, .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            ForEach(rows) { row in
                Button { onCategory(row.name) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(row.name)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(FinanceText.money(row.tenge * FinanceBudgeting.oneTenge))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .font(DS.Fonts.text(17, .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        MoneyBar(fraction: share(row.tenge, of: summary.spent) * 2.2, color: accent)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityElement(children: .combine)
                .accessibilityHint("Показать операции категории")
            }
        }
        .accessibilityIdentifier("money-categories")
    }

    private func share(_ value: Int64, of total: Int64) -> Double {
        total > 0 ? Double(value) / Double(total) : 0
    }

    /// The four biggest categories and «Остальное» when there are more than five.
    private static func rows(_ byCategory: [String: Int64]) -> [Row] {
        let sorted = byCategory.filter { $0.value > 0 }
            .map { Row(name: $0.key, tenge: $0.value) }
            .sorted { $0.tenge != $1.tenge ? $0.tenge > $1.tenge : $0.name < $1.name }
        guard sorted.count > 5 else { return sorted }
        return Array(sorted.prefix(4)) + [Row(name: "Остальное", tenge: sorted.dropFirst(4).reduce(0) { $0 + $1.tenge })]
    }
}

// MARK: - План: envelope cards

/// One envelope in the horizontal row: name, what it holds, the target, and its latest move.
struct MoneyEnvelopeCard: View {
    let goal: FinanceRecord
    let lastMove: EnvelopeLogEntry?
    let receivesIncome: Bool
    let onTap: () -> Void
    @Environment(\.sectionAccent) private var accent

    private var note: String {
        let saved = goal.savedMinor ?? 0
        let target = goal.amountMinor ?? 0
        if target > 0 && saved >= target { return "цель собрана" }
        return "цель " + FinanceText.money(target)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(goal.title)
                    .font(DS.Fonts.text(15, .bold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Text(FinanceText.money(goal.savedMinor ?? 0))
                    .font(DS.Fonts.text(21, .heavy, relativeTo: .title3))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(note)
                    .font(DS.Fonts.text(13, .semibold, relativeTo: .caption))
                    .foregroundColor(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let lastMove {
                    Text("\(lastMove.amountMinor > 0 ? "+" : "−")\(FinanceText.money(abs(lastMove.amountMinor))) · \(FinanceText.dayMonth(lastMove.date))")
                        .font(DS.Fonts.text(12, .medium, relativeTo: .caption2))
                        .foregroundColor(DS.Colors.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else if receivesIncome {
                    Text("сюда с дохода")
                        .font(DS.Fonts.text(12, .medium, relativeTo: .caption2))
                        .foregroundColor(DS.Colors.textMuted)
                }
            }
            .frame(width: 118, alignment: .leading)
            .padding(16)
            .frame(minHeight: 118, alignment: .topLeading)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Открыть конверт: история, отложить, забрать")
    }
}

/// The last card of the row: a dashed outline that creates an envelope.
struct MoneyNewEnvelopeCard: View {
    let onTap: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(accent)
                Text("Новый конверт")
                    .font(DS.Fonts.text(15, .bold))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .frame(width: 118, alignment: .leading)
            .padding(16)
            .frame(minHeight: 118, alignment: .topLeading)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(DS.Colors.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Новый конверт")
    }
}
