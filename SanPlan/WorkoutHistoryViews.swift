import SwiftUI

/// «История»: the week streak, this week or month against the one before, a calendar of training days,
/// and every workout, each of which opens for editing. Оформление — «Тушь» (DESIGN-INK 11.8).
struct WorkoutHistoryView: View {
    @ObservedObject var store: WorkoutStore

    @State private var period: Period = .week
    @State private var editing: EditorTarget?
    @State private var deleting: WorkoutRecord?

    enum Period: String, CaseIterable, Identifiable {
        case week = "Неделя"
        case month = "Месяц"
        var id: String { rawValue }
    }

    struct EditorTarget: Identifiable {
        let record: WorkoutRecord
        let isNew: Bool
        var id: String { record.id }
    }

    private var calendar: Calendar { WorkoutHistory.calendar() }

    var body: some View {
        let now = Date()
        let records = store.records
        let streak = WorkoutHistory.streak(records, goal: store.weeklyGoal, now: now, calendar: calendar)
        let totals = WorkoutHistory.periods(records, component: period == .week ? .weekOfYear : .month, now: now, calendar: calendar)

        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Metrics.stack) {
                if let error = store.errorMessage {
                    InkBanner(message: error) { store.errorMessage = nil }
                }

                VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                    streakCard(streak)
                    InkSegmented(selection: $period, items: Period.allCases.map { (value: $0, title: $0.rawValue) })
                    totalsGrid(totals.current, previous: totals.previous)
                }

                InkPanel {
                    VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                        Text("Последние 16 недель")
                            .inkText(.headline, weight: .bold)
                            .foregroundColor(Ink.Colors.fg)
                        WorkoutHeatmap(days: WorkoutHistory.activeDays(records, calendar: calendar), now: now, calendar: calendar)
                    }
                }

                VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                    HStack {
                        InkSectionHeader(text: "Тренировки")
                        Spacer()
                        InkButton(title: "Добавить", icon: "plus", kind: .text) {
                            editing = EditorTarget(record: WorkoutHistory.manualRecord(endingAt: WorkoutStore.nowMs()), isNew: true)
                        }
                        .disabled(store.isSignedOut)
                    }

                    if records.isEmpty {
                        InkPanel {
                            HStack(alignment: .center, spacing: Ink.Metrics.framePadding) {
                                InkMascotSlot(pose: .sleepy, size: 72)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Пока пусто")
                                        .inkText(.headline, weight: .bold)
                                        .foregroundColor(Ink.Colors.fg)
                                    Text("Завершённые тренировки появятся здесь. Прошлую можно добавить вручную.")
                                        .inkText(.body)
                                        .foregroundColor(Ink.Colors.muted)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } else {
                        ForEach(monthGroups(records), id: \.title) { group in
                            Text(group.title)
                                .inkText(.subheadline, weight: .bold)
                                .foregroundColor(Ink.Colors.muted)
                                .padding(.top, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.records) { record in
                                WorkoutSwipeRow(actions: [
                                    WorkoutSwipeAction(id: "repeat", title: "Повторить", icon: "arrow.counterclockwise", color: Ink.Colors.accent, textColor: Ink.Colors.onAccent) {
                                        store.repeatWorkout(from: record)
                                    },
                                    WorkoutSwipeAction(id: "delete", title: "Удалить", icon: "trash", color: Ink.Colors.fg, textColor: Ink.Colors.bg) {
                                        // Без вопроса: внизу экрана появится «Отменить».
                                        store.deleteRecord(id: record.id)
                                    },
                                ]) {
                                    recordRow(record)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Ink.Metrics.page)
            .padding(.top, Ink.Metrics.gutter)
            .padding(.bottom, 96)
        }
        .sheet(item: $editing) { target in
            WorkoutRecordEditor(store: store, original: target.record, isNew: target.isNew)
        }
        .confirmationDialog(
            "Удалить тренировку?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let record = deleting { store.deleteRecord(id: record.id) }
                deleting = nil
            }
            Button("Отмена", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting.map { "\(Self.dayFormatter.string(from: WorkoutHistory.date($0.startedAt))) · \(WorkoutFormat.duration($0.durationSeconds))" } ?? "")
        }
    }

    // MARK: - Streak and totals

    private func streakCard(_ streak: WeekStreak) -> some View {
        InkPanel {
            HStack(alignment: .center, spacing: Ink.Metrics.page) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Серия")
                        .inkText(.subheadline, weight: .medium)
                        .foregroundColor(Ink.Colors.muted)
                    Text(weeksText(streak.weeks))
                        .inkPoster(20, relativeTo: .headline)
                        .foregroundColor(Ink.Colors.fg)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(weekProgressText(streak))
                        .inkText(.subheadline, weight: .bold, numeric: true)
                        .foregroundColor(Ink.Colors.fg)
                        .multilineTextAlignment(.trailing)
                    HStack(spacing: 4) {
                        ForEach(0..<max(streak.goal, streak.thisWeek), id: \.self) { i in
                            Rectangle()
                                .fill(i < streak.thisWeek ? Ink.Colors.accent : Ink.Colors.soft)
                                .frame(width: 14, height: 10)
                                .overlay(Rectangle().strokeBorder(Ink.Colors.fg, lineWidth: 1.5))
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// «Эта неделя: 1 из 3»; past the goal it says so instead of «2 из 1».
    private func weekProgressText(_ streak: WeekStreak) -> String {
        streak.thisWeek > streak.goal
            ? "Эта неделя: \(streak.thisWeek), цель \(streak.goal) выполнена"
            : "Эта неделя: \(streak.thisWeek) из \(streak.goal)"
    }

    private func totalsGrid(_ current: PeriodSummary, previous: PeriodSummary) -> some View {
        let against = period == .week ? "к прошлой неделе" : "к прошлому месяцу"
        let footnote = period == .week
            ? "Сравнение с прошлой неделей по этот же день"
            : "Сравнение с прошлым месяцем по это же число"
        return VStack(alignment: .leading, spacing: 4) {
            statTiles(current, previous: previous, against: against)
            Text(footnote)
                .inkText(.subheadline, weight: .medium)
                .foregroundColor(Ink.Colors.muted)
        }
    }

    private func statTiles(_ current: PeriodSummary, previous: PeriodSummary, against: String) -> some View {
        let columns = [GridItem(.flexible(), spacing: Ink.Metrics.gutter), GridItem(.flexible(), spacing: Ink.Metrics.gutter)]
        return LazyVGrid(columns: columns, spacing: Ink.Metrics.gutter) {
            WorkoutStatTile(
                title: "Тренировки",
                value: "\(current.workouts)",
                detail: delta(Double(current.workouts - previous.workouts), against: against) { String(Int($0)) }
            )
            WorkoutStatTile(
                title: "Время всего",
                value: WorkoutFormat.duration(current.totalSeconds),
                detail: delta(Double(current.totalSeconds - previous.totalSeconds), against: against) { WorkoutFormat.duration(Int($0)) }
            )
            WorkoutStatTile(
                title: "В среднем",
                value: current.workouts == 0 ? "—" : WorkoutFormat.duration(current.averageSeconds),
                detail: previous.workouts == 0 || current.workouts == 0 ? nil
                    : delta(Double(current.averageSeconds - previous.averageSeconds), against: against) { WorkoutFormat.duration(Int($0)) }
            )
            WorkoutStatTile(
                title: "Тоннаж",
                value: WorkoutFormat.tonnage(current.tonnageKg),
                detail: delta(current.tonnageKg - previous.tonnageKg, against: against) { WorkoutFormat.tonnage($0) }
            )
        }
    }

    /// «+2 к прошлой неделе», «−15 мин …», «как в прошлый раз».
    private func delta(_ value: Double, against: String, format: (Double) -> String) -> String {
        if abs(value) < 0.5 { return "столько же" }
        return (value > 0 ? "+" : "−") + format(abs(value)) + " " + against
    }

    private func weeksText(_ weeks: Int) -> String {
        let mod10 = weeks % 10
        let mod100 = weeks % 100
        let word: String
        if mod10 == 1 && mod100 != 11 { word = "неделя" }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "недели" }
        else { word = "недель" }
        return "\(weeks) \(word)"
    }

    // MARK: - Records

    private struct MonthGroup {
        let title: String
        let records: [WorkoutRecord]
    }

    private func monthGroups(_ records: [WorkoutRecord]) -> [MonthGroup] {
        var groups: [MonthGroup] = []
        for record in records {
            let title = Self.monthFormatter.string(from: WorkoutHistory.date(record.startedAt)).capitalized
            if let last = groups.last, last.title == title {
                groups[groups.count - 1] = MonthGroup(title: title, records: last.records + [record])
            } else {
                groups.append(MonthGroup(title: title, records: [record]))
            }
        }
        return groups
    }

    private func recordRow(_ record: WorkoutRecord) -> some View {
        Button {
            editing = EditorTarget(record: record, isNew: false)
        } label: {
            InkPanel {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: Ink.Metrics.gutter) {
                        Text(record.title ?? record.weekday.map { WorkoutFormat.weekdayNames[$0 - 1] } ?? "Тренировка")
                            .inkText(.headline, weight: .bold)
                            .foregroundColor(Ink.Colors.fg)
                        if record.manual {
                            Text("вручную")
                                .inkText(.subheadline, weight: .medium)
                                .foregroundColor(Ink.Colors.muted)
                        }
                        Spacer(minLength: 0)
                        Text(WorkoutFormat.duration(record.durationSeconds))
                            .inkText(.subheadline, weight: .bold, numeric: true)
                            .foregroundColor(Ink.Colors.muted)
                    }
                    Text(Self.dayFormatter.string(from: WorkoutHistory.date(record.startedAt)))
                        .inkText(.subheadline, weight: .medium)
                        .foregroundColor(Ink.Colors.muted)
                    if !record.exercises.isEmpty {
                        Text(record.exercises.map(\.name).joined(separator: " · "))
                            .inkText(.body)
                            .foregroundColor(Ink.Colors.fg)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: Ink.Metrics.framePadding) {
                        Label("\(record.doneSetCount) из \(record.plannedSetCount)", systemImage: "checkmark.circle")
                        if record.tonnageKg > 0 {
                            Label(WorkoutFormat.tonnage(record.tonnageKg), systemImage: "scalemass")
                        }
                        if record.note != nil {
                            Image(systemName: "note.text")
                                .accessibilityLabel("Есть заметка")
                        }
                    }
                    .inkText(.subheadline, weight: .bold, numeric: true)
                    .foregroundColor(Ink.Colors.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { store.repeatWorkout(from: record) } label: { Label("Повторить", systemImage: "arrow.counterclockwise") }
            Button(role: .destructive) { deleting = record } label: { Label("Удалить", systemImage: "trash") }
        }
        .accessibilityAction(named: "Повторить") { store.repeatWorkout(from: record) }
        .accessibilityAction(named: "Удалить") { store.deleteRecord(id: record.id) }
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "EEEEEE, d MMMM · HH:mm"
        return formatter
    }()

    static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()
}

/// Sixteen weeks of training days, Monday on top, the current week on the right.
/// Клетки квадратные: пустой день — `soft`, один подход дня — точки акцентом, два и больше — сплошной акцент, сегодня — рамка `fg`.
struct WorkoutHeatmap: View {
    let days: [Date: Int]
    let now: Date
    let calendar: Calendar

    private let weeks = 16
    private let gap: CGFloat = 2

    var body: some View {
        let thisWeek = WorkoutHistory.weekStart(now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let total = days.filter { $0.key >= (calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek) }
            .values.reduce(0, +)
        GeometryReader { proxy in
            let cell = max(10, min(18, (proxy.size.width - gap * CGFloat(weeks - 1)) / CGFloat(weeks)))
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<weeks, id: \.self) { column in
                    let start = calendar.date(byAdding: .weekOfYear, value: column - (weeks - 1), to: thisWeek) ?? thisWeek
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: row, to: start) ?? start)
                            HeatCell(count: days[day] ?? 0, future: day > today, isToday: day == today)
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
        .frame(height: 7 * 18 + 6 * gap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("Календарь тренировок: \(total) за последние \(weeks) недель")
    }
}

private struct HeatCell: View {
    let count: Int
    let future: Bool
    let isToday: Bool

    var body: some View {
        ZStack {
            if !future {
                Rectangle().fill(count >= 2 ? Ink.Colors.accent : Ink.Colors.soft)
                if count == 1 {
                    Canvas { context, size in
                        var y: CGFloat = 1
                        while y < size.height {
                            var x: CGFloat = 1
                            while x < size.width {
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(Ink.Colors.accent))
                                x += 4
                            }
                            y += 4
                        }
                    }
                }
            }
        }
        .overlay(Rectangle().strokeBorder(Ink.Colors.fg, lineWidth: isToday ? 2 : 0))
    }
}
