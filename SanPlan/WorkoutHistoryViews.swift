import SwiftUI

/// «История»: the week streak, this week or month against the one before, a calendar of training days,
/// and every workout, each of which opens for editing.
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
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                if let error = store.errorMessage {
                    ErrorBanner(message: error) { store.errorMessage = nil }
                }

                streakCard(streak)

                Picker("Период", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                totalsGrid(totals.current, previous: totals.previous)

                Card {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                        Text("Последние 16 недель")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                        WorkoutHeatmap(days: WorkoutHistory.activeDays(records, calendar: calendar), now: now, calendar: calendar)
                    }
                }

                HStack {
                    SectionHeader("Тренировки")
                    Spacer()
                    Button {
                        editing = EditorTarget(record: WorkoutHistory.manualRecord(endingAt: WorkoutStore.nowMs()), isNew: true)
                    } label: {
                        Label("Добавить", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: DS.Metrics.minHitTarget)
                    }
                    .foregroundColor(DS.Colors.accent)
                    .disabled(store.isSignedOut)
                }

                if records.isEmpty {
                    EmptyState(
                        title: "Пока пусто",
                        message: "Завершённые тренировки появятся здесь. Прошлую можно добавить вручную.",
                        icon: "calendar"
                    )
                } else {
                    ForEach(monthGroups(records), id: \.title) { group in
                        Text(group.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.top, DS.Metrics.spacing4)
                        ForEach(group.records) { record in
                            recordRow(record)
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.top, DS.Metrics.spacing8)
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
        Card {
            HStack(alignment: .center, spacing: DS.Metrics.spacing16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Серия")
                        .font(.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(weeksText(streak.weeks))
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundColor(streak.weeks > 0 ? DS.Colors.accent : DS.Colors.textPrimary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(weekProgressText(streak))
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(DS.Colors.textPrimary)
                    HStack(spacing: 4) {
                        ForEach(0..<max(streak.goal, streak.thisWeek), id: \.self) { i in
                            Capsule()
                                .fill(i < streak.thisWeek ? DS.Colors.accent : DS.Colors.textSecondary.opacity(0.2))
                                .frame(width: 14, height: 6)
                        }
                    }
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
        return VStack(alignment: .leading, spacing: DS.Metrics.spacing4) {
            statTiles(current, previous: previous, against: against)
            Text(footnote)
                .font(.caption)
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    private func statTiles(_ current: PeriodSummary, previous: PeriodSummary, against: String) -> some View {
        let columns = [GridItem(.flexible(), spacing: DS.Metrics.spacing8), GridItem(.flexible(), spacing: DS.Metrics.spacing8)]
        return LazyVGrid(columns: columns, spacing: DS.Metrics.spacing8) {
            WorkoutStatTile(
                title: "Тренировки",
                value: "\(current.workouts)",
                detail: delta(Double(current.workouts - previous.workouts), against: against) { String(Int($0)) },
                detailColor: deltaColor(current.workouts - previous.workouts)
            )
            WorkoutStatTile(
                title: "Время всего",
                value: WorkoutFormat.duration(current.totalSeconds),
                detail: delta(Double(current.totalSeconds - previous.totalSeconds), against: against) { WorkoutFormat.duration(Int($0)) },
                detailColor: deltaColor(current.totalSeconds - previous.totalSeconds)
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
                detail: delta(current.tonnageKg - previous.tonnageKg, against: against) { WorkoutFormat.tonnage($0) },
                detailColor: deltaColor(Int(current.tonnageKg - previous.tonnageKg))
            )
        }
    }

    /// «+2 к прошлой неделе», «−15 мин …», «как в прошлый раз».
    private func delta(_ value: Double, against: String, format: (Double) -> String) -> String {
        if abs(value) < 0.5 { return "столько же" }
        return (value > 0 ? "+" : "−") + format(abs(value)) + " " + against
    }

    private func deltaColor(_ value: Int) -> Color {
        value > 0 ? DS.Colors.positive : DS.Colors.textSecondary
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
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(record.title ?? record.weekday.map { WorkoutFormat.weekdayNames[$0 - 1] } ?? "Тренировка")
                            .font(.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        if record.manual {
                            Text("вручную")
                                .font(.caption2)
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        Spacer()
                        Text(WorkoutFormat.duration(record.durationSeconds))
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    Text(Self.dayFormatter.string(from: WorkoutHistory.date(record.startedAt)))
                        .font(.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                    if !record.exercises.isEmpty {
                        Text(record.exercises.map(\.name).joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: DS.Metrics.spacing12) {
                        Label("\(record.doneSetCount) из \(record.plannedSetCount)", systemImage: "checkmark.circle")
                        if record.tonnageKg > 0 {
                            Label(WorkoutFormat.tonnage(record.tonnageKg), systemImage: "scalemass")
                        }
                        if record.note != nil {
                            Image(systemName: "text.bubble")
                                .accessibilityLabel("Есть заметка")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { deleting = record } label: { Label("Удалить", systemImage: "trash") }
        }
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
struct WorkoutHeatmap: View {
    let days: [Date: Int]
    let now: Date
    let calendar: Calendar

    private let weeks = 16
    private let cell: CGFloat = 14
    private let gap: CGFloat = 3

    var body: some View {
        let thisWeek = WorkoutHistory.weekStart(now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let total = days.filter { $0.key >= (calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek) }
            .values.reduce(0, +)
        HStack(alignment: .top, spacing: gap) {
            ForEach(0..<weeks, id: \.self) { column in
                let start = calendar.date(byAdding: .weekOfYear, value: column - (weeks - 1), to: thisWeek) ?? thisWeek
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: row, to: start) ?? start)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(count: days[day] ?? 0, future: day > today))
                            .frame(width: cell, height: cell)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(DS.Colors.textPrimary.opacity(day == today ? 0.6 : 0), lineWidth: 1)
                            )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("Календарь тренировок: \(total) за последние \(weeks) недель")
    }

    private func color(count: Int, future: Bool) -> Color {
        if future { return .clear }
        switch count {
        case 0: return DS.Colors.textSecondary.opacity(0.14)
        case 1: return DS.Colors.accent.opacity(0.55)
        default: return DS.Colors.accent
        }
    }
}

// MARK: - Editing a past workout

/// Everything about one workout in the history: when it started and ended, its exercises and sets, a note.
/// Also used to add a workout afterwards. Saved only with «Сохранить»; deleting asks first and can be undone.
struct WorkoutRecordEditor: View {
    @ObservedObject var store: WorkoutStore
    let original: WorkoutRecord
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkoutRecord
    @State private var problem: String?
    @State private var isConfirmingDelete = false
    @State private var isAddingExercise = false

    init(store: WorkoutStore, original: WorkoutRecord, isNew: Bool) {
        self.store = store
        self.original = original
        self.isNew = isNew
        self._draft = State(initialValue: original)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let problem {
                    Section {
                        Text(problem)
                            .foregroundColor(DS.Colors.destructive)
                    }
                }
                Section("Когда") {
                    DatePicker("Начало", selection: startBinding, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Конец", selection: endBinding, displayedComponents: [.date, .hourAndMinute])
                    LabeledContent("Длительность", value: WorkoutFormat.duration(draft.durationSeconds))
                }
                Section("Название") {
                    TextField("Например, «Ноги»", text: Binding(
                        get: { draft.title ?? "" },
                        set: { draft.title = $0.isEmpty ? nil : $0 }
                    ))
                }
                ForEach(draft.exercises.indices, id: \.self) { index in
                    exerciseSection(index)
                }
                Section {
                    Button {
                        isAddingExercise = true
                    } label: {
                        Label("Добавить упражнение", systemImage: "plus")
                    }
                }
                Section("Заметка") {
                    TextField("Как прошло", text: Binding(
                        get: { draft.note ?? "" },
                        set: { draft.note = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                    .lineLimit(2...6)
                }
                if !isNew {
                    Section {
                        Button("Удалить тренировку", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.canvas.ignoresSafeArea())
            .navigationTitle(isNew ? "Новая тренировка" : "Тренировка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .disabled(draft == original && !isNew)
                }
            }
            .confirmationDialog("Удалить тренировку?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    store.deleteRecord(id: original.id)
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Её можно будет вернуть кнопкой «Отменить» в течение нескольких секунд.")
            }
            .sheet(isPresented: $isAddingExercise) {
                ExerciseLibrarySheet { name in addExercise(name) }
            }
        }
    }

    private func exerciseSection(_ index: Int) -> some View {
        Section {
            TextField("Упражнение", text: Binding(
                get: { draft.exercises.indices.contains(index) ? draft.exercises[index].name : "" },
                set: { if draft.exercises.indices.contains(index) { draft.exercises[index].name = $0 } }
            ))
            .font(.headline)
            Toggle("Свой вес", isOn: Binding(
                get: { draft.exercises.indices.contains(index) && draft.exercises[index].bodyweight },
                set: { if draft.exercises.indices.contains(index) { draft.exercises[index].bodyweight = $0 } }
            ))
            .tint(DS.Colors.controlTint)
            if draft.exercises.indices.contains(index) {
                ForEach(draft.exercises[index].sets.indices, id: \.self) { set in
                    setRow(index, set)
                }
                .onDelete { offsets in
                    guard draft.exercises.indices.contains(index) else { return }
                    draft.exercises[index].sets.remove(atOffsets: offsets)
                }
            }
            Button {
                guard draft.exercises.indices.contains(index) else { return }
                let last = draft.exercises[index].sets.last
                draft.exercises[index].sets.append(WorkoutRecordSet(done: true, weightKg: last?.weightKg, reps: last?.reps))
            } label: {
                Label("Подход", systemImage: "plus")
            }
            Button("Удалить упражнение", role: .destructive) {
                guard draft.exercises.indices.contains(index) else { return }
                draft.exercises.remove(at: index)
            }
        }
    }

    private func setRow(_ exercise: Int, _ set: Int) -> some View {
        HStack(spacing: DS.Metrics.spacing8) {
            Button {
                update(exercise, set) { $0.done.toggle() }
            } label: {
                Image(systemName: value(exercise, set)?.done == true ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(value(exercise, set)?.done == true ? DS.Colors.positive : DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(value(exercise, set)?.done == true ? "Сделан" : "Не сделан")
            Text("\(set + 1)")
                .font(.subheadline.monospacedDigit())
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 22, alignment: .leading)
            TextField("0", value: Binding(
                get: { value(exercise, set)?.weightKg ?? 0 },
                set: { new in update(exercise, set) { $0.weightKg = new > 0 ? new : nil } }
            ), format: .number)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 80)
            Text("кг")
                .foregroundColor(DS.Colors.textSecondary)
            TextField("0", value: Binding(
                get: { value(exercise, set)?.reps ?? 0 },
                set: { new in update(exercise, set) { $0.reps = new } }
            ), format: .number)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 56)
            Text("повт.")
                .foregroundColor(DS.Colors.textSecondary)
        }
        .font(.subheadline.monospacedDigit())
    }

    private func value(_ exercise: Int, _ set: Int) -> WorkoutRecordSet? {
        guard draft.exercises.indices.contains(exercise), draft.exercises[exercise].sets.indices.contains(set) else { return nil }
        return draft.exercises[exercise].sets[set]
    }

    private func update(_ exercise: Int, _ set: Int, _ change: (inout WorkoutRecordSet) -> Void) {
        guard draft.exercises.indices.contains(exercise), draft.exercises[exercise].sets.indices.contains(set) else { return }
        change(&draft.exercises[exercise].sets[set])
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { WorkoutHistory.date(draft.startedAt) },
            set: { date in
                // Moving the start keeps the length, so changing the day moves the whole workout.
                let length = max(0, draft.endedAt - draft.startedAt)
                draft.startedAt = Int64(date.timeIntervalSince1970 * 1000)
                draft.endedAt = draft.startedAt + length
            }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { WorkoutHistory.date(draft.endedAt) },
            set: { draft.endedAt = Int64($0.timeIntervalSince1970 * 1000) }
        )
    }

    /// A plan exercise of the same name lends its id, so the history and «В прошлый раз» stay together.
    private func addExercise(_ name: String) {
        let planned = store.program.days.flatMap(\.exercises).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let reps = planned?.reps ?? WorkoutProgram.defaultReps
        let sets = planned?.sets ?? WorkoutProgram.defaults(of: store.program).sets
        draft.exercises.append(WorkoutRecordExercise(
            exerciseId: planned?.id,
            name: name,
            bodyweight: planned?.bodyweight ?? false,
            targetReps: reps,
            perSide: planned?.perSide ?? false,
            sets: Array(repeating: WorkoutRecordSet(done: true, weightKg: planned?.weightKg, reps: reps), count: sets)
        ))
    }

    private func save() {
        do {
            guard !draft.exercises.isEmpty else { throw WorkoutDomainError("Добавьте хотя бы одно упражнение") }
            _ = try WorkoutHistory.validated(draft)
            store.saveRecord(draft)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
