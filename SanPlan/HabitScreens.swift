import SwiftUI

// Экраны привычек внутри вкладки «Планы» (режим «Привычки»): одна отметка тапом,
// свайп вправо — «готово», лёгкий тактильный отклик. Данные — HabitStore.shared.

/// Подписи для расписания, нормы и правил — одни и те же в строке и в редакторе.
enum HabitText {
    static let weekdayShort = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    /// «1 раз», «3 раза», «5 раз».
    static func times(_ n: Int) -> String {
        let last = n % 10, lastTwo = n % 100
        let word = (2...4).contains(last) && !(12...14).contains(lastTwo) ? "раза" : "раз"
        return "\(n) \(word)"
    }

    static func schedule(_ s: HabitSchedule) -> String {
        switch s.kind {
        case .timesPerWeek:
            return "\(times(s.timesPerWeek)) в неделю"
        case .weekdays:
            if s.weekdays.count == 7 { return "Каждый день" }
            let names = s.weekdays.sorted().compactMap { (1...7).contains($0) ? weekdayShort[$0 - 1] : nil }
            return names.joined(separator: ", ")
        }
    }

    static func rule(_ r: HabitRule) -> String {
        switch r.kind {
        case .training:
            return "тренировка"
        case .noSpend:
            if let c = r.category, !c.isEmpty { return "нет трат: \(c)" }
            return "нет трат"
        case .spendAtMost:
            let limit = (r.limit ?? 0).formatted(.number.grouping(.automatic))
            if let c = r.category, !c.isEmpty { return "\(c): не больше \(limit) ₸" }
            return "не больше \(limit) ₸ за день"
        }
    }

    static func streak(_ s: HabitStreak) -> String? {
        guard s.count > 0 else { return nil }
        return s.unit == .days ? "серия \(s.count) дн." : "серия \(s.count) нед."
    }
}

struct HabitsSection: View {
    @ObservedObject var habits: HabitStore
    let today: String
    /// Источники активности всех разделов для общей серии; без них серия не показывается.
    var streakSources: [StreakEngine.ActivitySource] = []
    @State private var editorTarget: HabitEditorTarget?

    private var due: [Habit] { habits.dueHabits(on: today) }
    private var others: [Habit] {
        let dueIds = Set(due.map(\.id))
        return habits.activeHabits.filter { !dueIds.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Привычки сегодня")
                let s = habits.daySummary(for: today)
                if s.total > 0 {
                    Text("\(s.done) из \(s.total)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .accessibilityLabel("Выполнено \(s.done) из \(s.total)")
                }
            }

            if !streakSources.isEmpty {
                let streak = habits.appStreak(today: today, sources: streakSources)
                Text("Серия \(streak.days) дн. · дней отдыха в месяце: \(streak.restDaysLeft)")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            if habits.activeHabits.isEmpty {
                EmptyState(
                    title: "Привычек пока нет",
                    message: "Добавь привычку: расписание, норму и при желании правило автоотметки.",
                    icon: "checkmark.circle"
                )
            } else if due.isEmpty {
                Text("На сегодня привычек нет.")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            ForEach(due) { habit in
                HabitRowView(habit: habit, habits: habits, today: today) { editorTarget = .edit(habit) }
            }

            if !others.isEmpty {
                SectionHeader("Не на сегодня")
                    .padding(.top, DS.Metrics.spacing8)
                ForEach(others) { habit in
                    Button { editorTarget = .edit(habit) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(habit.title).font(.body).foregroundColor(DS.Colors.textPrimary)
                                Text(HabitText.schedule(habit.schedule))
                                    .font(.footnote).foregroundColor(DS.Colors.textSecondary)
                            }
                            Spacer()
                        }
                        .frame(minHeight: DS.Metrics.minHitTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            PillButton("Добавить привычку", icon: "plus", style: .secondary) {
                editorTarget = .new
            }
            .padding(.top, DS.Metrics.spacing8)
        }
        .sheet(item: $editorTarget) { target in
            HabitEditorSheet(habits: habits, existing: target.habit, today: today)
        }
    }
}

enum HabitEditorTarget: Identifiable {
    case new
    case edit(Habit)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let h): return h.id
        }
    }

    var habit: Habit? {
        if case .edit(let h) = self { return h }
        return nil
    }
}

struct HabitRowView: View {
    let habit: Habit
    @ObservedObject var habits: HabitStore
    let today: String
    let onEdit: () -> Void

    @State private var dragX: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let swipeThreshold: CGFloat = 90

    private var done: Bool { habits.isDone(habit, on: today) }
    private var auto: Bool { habit.rule != nil && habits.isAutoDone(habit, on: today) && habits.amount(habit, on: today) == 0 }
    private var amount: Int { habits.amount(habit, on: today) }

    private var subtitle: String {
        var parts: [String] = []
        if habit.target.isCountable {
            let unit = habit.target.unit.isEmpty ? "" : " \(habit.target.unit)"
            parts.append("\(amount) из \(habit.target.amount)\(unit)")
        }
        if let rule = habit.rule { parts.append(auto ? "авто: \(HabitText.rule(rule))" : HabitText.rule(rule)) }
        if habit.schedule.kind == .timesPerWeek || habit.schedule.weekdays.count != 7 {
            parts.append(HabitText.schedule(habit.schedule))
        }
        if let s = HabitText.streak(habits.streak(for: habit, today: today)) { parts.append(s) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: DS.Metrics.spacing12) {
            Button {
                habits.tap(habit, on: today)
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title)
                    .foregroundColor(done ? DS.Colors.positive : DS.Colors.textSecondary)
                    .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(auto)
            .accessibilityLabel(habit.title)
            .accessibilityValue(done ? "выполнено" : "не выполнено")
            .accessibilityHint(habit.target.isCountable ? "Добавляет одну отметку" : "Отмечает привычку")

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(habit.title)
                        .font(.body.weight(.medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .strikethrough(done, color: DS.Colors.textSecondary)
                        .multilineTextAlignment(.leading)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundColor(DS.Colors.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Открывает настройки привычки")
        }
        .padding(.horizontal, DS.Metrics.spacing8)
        .background(DS.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
        .overlay(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius).stroke(DS.Colors.hairline, lineWidth: 1))
        .offset(x: dragX)
        .background(alignment: .leading) {
            if dragX > 0 {
                HStack(spacing: DS.Metrics.spacing8) {
                    Image(systemName: "checkmark")
                    Text("Готово")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DS.Colors.positive)
                .padding(.leading, DS.Metrics.spacing16)
                .opacity(min(1, Double(dragX / swipeThreshold)))
            }
        }
        .gesture(
            HorizontalSwipe(
                onChanged: { dx in
                    guard !done, !auto, dx > 0 else { return }
                    dragX = min(dx, 120)
                },
                onEnded: { dx, _ in
                    let reached = dx >= swipeThreshold && !done && !auto
                    if reached { habits.complete(habit, on: today) }
                    withAnimation(reduceMotion ? nil : .snappy) { dragX = 0 }
                }
            )
        )
        .sensoryFeedback(trigger: amount) { (old: Int, new: Int) -> SensoryFeedback? in
            guard new > old else { return nil }
            if new >= habit.target.amount { return SensoryFeedback.success }
            return SensoryFeedback.impact(weight: .light)
        }
        .accessibilityAction(named: "Готово") {
            if !done && !auto { habits.complete(habit, on: today) }
        }
    }
}

// MARK: - Редактор

struct HabitEditorSheet: View {
    @ObservedObject var habits: HabitStore
    let existing: Habit?
    let today: String
    @Environment(\.dismiss) private var dismiss

    private enum ScheduleChoice: String, CaseIterable, Identifiable {
        case everyDay = "Каждый день"
        case weekdays = "Дни недели"
        case timesPerWeek = "Раз в неделю"
        var id: String { rawValue }
    }

    private enum RuleChoice: String, CaseIterable, Identifiable {
        case none = "Вручную"
        case training = "Тренировка"
        case noSpend = "Нет трат"
        case spendAtMost = "Не больше суммы"
        var id: String { rawValue }
    }

    @State private var title = ""
    @State private var scheduleChoice: ScheduleChoice = .everyDay
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    @State private var timesPerWeek = 3
    @State private var amount = 1
    @State private var unit = ""
    @State private var ruleChoice: RuleChoice = .none
    @State private var category = ""
    @State private var limitText = ""
    @State private var confirmingDelete = false
    @State private var loaded = false

    private var limitValue: Int? { Int(limitText.filter(\.isNumber)) }

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if scheduleChoice == .weekdays && weekdays.isEmpty { return false }
        if ruleChoice == .spendAtMost && (limitValue ?? 0) <= 0 { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") {
                    TextField("Например, стакан воды", text: $title)
                        .frame(minHeight: DS.Metrics.minHitTarget)
                }

                Section("Расписание") {
                    Picker("Расписание", selection: $scheduleChoice) {
                        ForEach(ScheduleChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if scheduleChoice == .weekdays {
                        HStack(spacing: 4) {
                            ForEach(1...7, id: \.self) { day in
                                let on = weekdays.contains(day)
                                Button {
                                    if on { weekdays.remove(day) } else { weekdays.insert(day) }
                                } label: {
                                    Text(HabitText.weekdayShort[day - 1])
                                        .font(.subheadline.weight(.medium))
                                        .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget)
                                        .foregroundColor(on ? DS.Colors.onAccent : DS.Colors.textPrimary)
                                        .background(on ? DS.Colors.accent : DS.Colors.surfaceRaised)
                                        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                        .sensoryFeedback(.selection, trigger: weekdays)
                    }
                    if scheduleChoice == .timesPerWeek {
                        Stepper("\(HabitText.times(timesPerWeek)) в неделю", value: $timesPerWeek, in: 1...7)
                            .frame(minHeight: DS.Metrics.minHitTarget)
                    }
                }

                Section("Норма за день") {
                    Stepper(amount == 1 ? "Один раз" : HabitText.times(amount), value: $amount, in: 1...99)
                        .frame(minHeight: DS.Metrics.minHitTarget)
                    if amount > 1 {
                        TextField("Что считаем (стаканов, страниц)", text: $unit)
                            .frame(minHeight: DS.Metrics.minHitTarget)
                    }
                }

                Section {
                    Picker("Отметка", selection: $ruleChoice) {
                        ForEach(RuleChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if ruleChoice == .noSpend || ruleChoice == .spendAtMost {
                        TextField("Категория трат (необязательно)", text: $category)
                            .frame(minHeight: DS.Metrics.minHitTarget)
                    }
                    if ruleChoice == .spendAtMost {
                        TextField("Сумма в ₸", text: $limitText)
                            .keyboardType(.numberPad)
                            .frame(minHeight: DS.Metrics.minHitTarget)
                    }
                } header: {
                    Text("Автоотметка")
                } footer: {
                    Text("Правило проверяется на этом устройстве по тренировкам и тратам. Отметить вручную можно всегда.")
                }

                if let existing {
                    Section {
                        Button(existing.archived ? "Вернуть из архива" : "В архив") {
                            habits.archive(id: existing.id, !existing.archived)
                            dismiss()
                        }
                        .frame(minHeight: DS.Metrics.minHitTarget)
                        Button("Удалить привычку", role: .destructive) { confirmingDelete = true }
                            .frame(minHeight: DS.Metrics.minHitTarget)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.canvas)
            .navigationTitle(existing == nil ? "Новая привычка" : "Привычка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }.disabled(!canSave)
                }
            }
            .confirmationDialog("Удалить привычку и все её отметки?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    if let existing { habits.delete(id: existing.id) }
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let h = existing else { return }
        title = h.title
        switch h.schedule.kind {
        case .timesPerWeek:
            scheduleChoice = .timesPerWeek
            timesPerWeek = max(1, h.schedule.timesPerWeek)
        case .weekdays:
            if h.schedule.weekdays.count == 7 {
                scheduleChoice = .everyDay
            } else {
                scheduleChoice = .weekdays
                weekdays = h.schedule.weekdays
            }
        }
        amount = h.target.amount
        unit = h.target.unit
        if let r = h.rule {
            switch r.kind {
            case .training: ruleChoice = .training
            case .noSpend: ruleChoice = .noSpend
            case .spendAtMost: ruleChoice = .spendAtMost
            }
            category = r.category ?? ""
            limitText = r.limit.map(String.init) ?? ""
        }
    }

    private func save() {
        let schedule: HabitSchedule
        switch scheduleChoice {
        case .everyDay: schedule = .everyDay
        case .weekdays: schedule = .onWeekdays(weekdays)
        case .timesPerWeek: schedule = .timesPerWeek(timesPerWeek)
        }
        let cat = category.trimmingCharacters(in: .whitespaces)
        let rule: HabitRule?
        switch ruleChoice {
        case .none: rule = nil
        case .training: rule = .training
        case .noSpend: rule = .noSpend(category: cat.isEmpty ? nil : cat)
        case .spendAtMost: rule = .spendAtMost(limitValue ?? 0, category: cat.isEmpty ? nil : cat)
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let target = HabitTarget(amount: amount, unit: amount > 1 ? unit.trimmingCharacters(in: .whitespaces) : "")
        if var h = existing {
            h.title = cleanTitle
            h.schedule = schedule
            h.target = target
            h.rule = rule
            habits.update(h)
        } else {
            habits.add(Habit(title: cleanTitle, schedule: schedule, target: target, rule: rule, createdDay: today))
        }
        dismiss()
    }
}
