import SwiftUI

/// «Прогресс» from the canvas: four numbers from the person's own data, the arc of counted weeks
/// and tasks that may have been forgotten. Nothing here is invented: an empty section says so.
struct ProgressScreen: View {
    @ObservedObject var plans: PlanStore
    @ObservedObject var finance: FinanceStore
    @ObservedObject var workouts: WorkoutStore
    let onOpen: (MainTab) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var month = false

    private var today: String { PlanDomain.today(timeZone: plans.timeZone) }

    private struct Trend: Identifiable {
        let id: String
        let tab: MainTab
        let value: String
        let note: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ScreenHeader("Прогресс", kicker: "Собрано из ваших данных") {
                        CircleIconButton(icon: "xmark", accessibilityLabel: "Закрыть") { dismiss() }
                    }
                    Picker("Период", selection: $month) {
                        Text("Неделя").tag(false)
                        Text("Месяц").tag(true)
                    }
                    .pickerStyle(.segmented)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(trends) { trend in
                            Button { dismiss(); onOpen(trend.tab) } label: { trendCard(trend) }
                                .buttonStyle(PressScaleStyle())
                        }
                    }
                    .petTip("Цифры из ваших данных. Нажмите — откроется раздел.")
                    arcCard
                        .petTip("Неделя засчитана, если были 3 тренировки или 5 дней с закрытыми планами. Пропуск ничего не обнуляет.")
                    forgottenSection
                }
                .padding(DS.Metrics.screenGutter)
            }
            .background(DS.Colors.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.sectionAccent, DS.Colors.today)
        }
    }

    // MARK: Numbers

    private var range: (from: String, to: String, prevFrom: String, prevTo: String) {
        let days = month ? 30 : 7
        let from = PlanDomain.addDays(dateStr: today, days: -(days - 1))
        let prevTo = PlanDomain.addDays(dateStr: from, days: -1)
        return (from, today, PlanDomain.addDays(dateStr: prevTo, days: -(days - 1)), prevTo)
    }

    private var trends: [Trend] {
        let r = range
        let spent = finance.periodSummary(from: r.from, to: r.to).spent
        let spentBefore = finance.periodSummary(from: r.prevFrom, to: r.prevTo).spent
        let done = WorkoutSummary.period(workouts.records, from: r.from, to: r.to).completed
        let doneBefore = WorkoutSummary.period(workouts.records, from: r.prevFrom, to: r.prevTo).completed
        let (closed, total) = taskCounts(from: r.from, to: r.to)
        let gym = gymMinutes(from: r.from, to: r.to)
        let periodWord = month ? "прошлых 30 дней" : "прошлой недели"
        return [
            Trend(id: "money", tab: .money, value: ReviewFormat.tenge(spent * 100),
                  note: compare(spent, spentBefore, more: "больше", less: "меньше", word: periodWord)),
            Trend(id: "workouts", tab: .workout, value: "\(done)",
                  note: "было \(doneBefore) за период раньше"),
            Trend(id: "plans", tab: .plans, value: total == 0 ? "—" : "\(closed * 100 / total)%",
                  note: total == 0 ? "задач с датой не было" : "\(closed) из \(total) закрыто"),
            Trend(id: "gym", tab: .workout, value: duration(gym.total),
                  note: gym.count == 0 ? "тренировок не было" : "в среднем \(duration(gym.total / gym.count))")
        ]
    }

    private func compare(_ now: Int64, _ before: Int64, more: String, less: String, word: String) -> String {
        guard before > 0 else { return now == 0 ? "трат не было" : "раньше трат не было" }
        let pct = Int((Double(now - before) / Double(before) * 100).rounded())
        if pct == 0 { return "как и у \(word)" }
        return "на \(abs(pct))% \(pct > 0 ? more : less) \(word)"
    }

    private func taskCounts(from: String, to: String) -> (Int, Int) {
        var closed = 0, total = 0
        var day = from
        while day <= to {
            let summary = plans.daySummary(for: day)
            closed += summary.done
            total += summary.total
            day = PlanDomain.addDays(dateStr: day, days: 1)
        }
        return (closed, total)
    }

    private func gymMinutes(from: String, to: String) -> (total: Int, count: Int) {
        let records = workouts.records.filter {
            let day = WorkoutSummary.dayKey($0.startedAt)
            return day >= from && day <= to && $0.endedAt > $0.startedAt
        }
        let minutes = records.reduce(0) { $0 + Int(($1.endedAt - $1.startedAt) / 60_000) }
        return (minutes, records.count)
    }

    private func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) м" : "\(minutes) мин"
    }

    private func trendCard(_ trend: Trend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(trendName(trend.id))
                .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                .tracking(0.8)
                .foregroundColor(trend.tab.accent)
            Text(trend.value)
                .font(DS.Fonts.display(24, relativeTo: .title2))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(trend.note)
                .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(16)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func trendName(_ id: String) -> String {
        switch id {
        case "money": return "ТРАТЫ"
        case "workouts": return "ТРЕНИРОВКИ"
        case "plans": return "ПЛАНЫ"
        default: return "ВРЕМЯ В ЗАЛЕ"
        }
    }

    // MARK: Arc

    /// Weeks (Mon–Sun) of the last six that count: 3 workouts or 5 days with closed tasks.
    private var countedWeeks: Int {
        var counted = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = WorkoutSummary.zone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let now = formatter.date(from: today),
              let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return 0 }
        for back in 1...6 {
            guard let start = calendar.date(byAdding: .day, value: -7 * back, to: weekStart) else { continue }
            let from = formatter.string(from: start)
            let to = PlanDomain.addDays(dateStr: from, days: 6)
            let trainings = WorkoutSummary.period(workouts.records, from: from, to: to).completed
            var closedDays = 0
            var day = from
            while day <= to {
                if plans.daySummary(for: day).done > 0 { closedDays += 1 }
                day = PlanDomain.addDays(dateStr: day, days: 1)
            }
            if trainings >= 3 || closedDays >= 5 { counted += 1 }
        }
        return counted
    }

    private var arcCard: some View {
        let weeks = countedWeeks
        return VStack(alignment: .leading, spacing: 10) {
            Text("АРКА · ПОСЛЕДНИЕ 6 НЕДЕЛЬ")
                .font(DS.Fonts.label)
                .tracking(0.8)
                .foregroundColor(DS.Colors.today)
            Text("Засчитано недель: \(weeks) из 6")
                .font(DS.Fonts.text(19, .bold, relativeTo: .headline))
                .foregroundColor(DS.Colors.textPrimary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.canvas)
                    Capsule().fill(DS.Colors.today).frame(width: proxy.size.width * CGFloat(weeks) / 6)
                }
            }
            .frame(height: 10)
            .accessibilityElement()
            .accessibilityLabel("Засчитано \(weeks) из 6 недель")
            Text("Неделя засчитана, если были 3 тренировки или 5 дней с закрытыми планами. Пропуск ничего не обнуляет.")
                .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 22))
        .inked(cornerRadius: 22, shadow: 6)
        .padding(.trailing, 6)
    }

    // MARK: Forgotten

    /// Tasks with a date a week or more ago that were never closed.
    private var forgotten: [PlanItem] {
        let limit = PlanDomain.addDays(dateStr: today, days: -7)
        return PlanDomain.visibleItems(plans.plans)
            .filter { $0.kind == "task" && $0.completed != true && $0.alarmDeleted != true && ($0.date ?? "9999") <= limit }
            .sorted { ($0.date ?? "") > ($1.date ?? "") }
            .prefix(5)
            .map { $0 }
    }

    private var forgottenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Может, забыли?")
            if forgotten.isEmpty {
                Text("Хвостов нет.")
                    .font(DS.Fonts.text(16, .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            ForEach(forgotten, id: \.id) { plan in
                Button { dismiss(); onOpen(.plans) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.title)
                            .font(DS.Fonts.text(17, .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(2)
                        Text("План на \(plan.date ?? "") — не отмечен")
                            .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }
}
