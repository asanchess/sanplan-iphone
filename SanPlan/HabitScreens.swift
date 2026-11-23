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

/// «Привычки» tab of «Планы» (canvas: two-column tiles «5 / 8» with a bar). Tap a tile — one more mark;
/// long press — «Изменить». New habits come from the bottom field «Что запланировать?» or «Новая привычка».
struct HabitsSection: View {
    @ObservedObject var habits: HabitStore
    let today: String
    /// Activity of every section for the shared streak; without it the streak line is hidden.
    var streakSources: [StreakEngine.ActivitySource]
    /// Made-up tiles for screenshots: shown as is, never saved.
    var demo: [PlansHabitTileModel]?
    /// A habit read from the bottom field; «Настроить» opens it here in the editor.
    @Binding var draftRequest: Habit?
    @State private var editorTarget: HabitEditorTarget?
    @Environment(\.sectionAccent) private var accent

    init(
        habits: HabitStore,
        today: String,
        streakSources: [StreakEngine.ActivitySource] = [],
        demo: [PlansHabitTileModel]? = nil,
        draftRequest: Binding<Habit?> = .constant(nil)
    ) {
        self.habits = habits
        self.today = today
        self.streakSources = streakSources
        self.demo = demo
        self._draftRequest = draftRequest
    }

    private var due: [Habit] { habits.dueHabits(on: today) }
    private var others: [Habit] {
        let dueIds = Set(due.map(\.id))
        return habits.activeHabits.filter { !dueIds.contains($0.id) }
    }

    private var tiles: [PlansHabitTileModel] { demo ?? due.map(tile(for:)) }

    private func tile(for habit: Habit) -> PlansHabitTileModel {
        let amount = habits.amount(habit, on: today)
        let goal = max(1, habit.target.amount)
        let done = habits.isDone(habit, on: today)
        let auto = habit.rule != nil && habits.isAutoDone(habit, on: today) && amount == 0
        let count = done ? max(amount, goal) : min(amount, goal)
        var parts: [String] = []
        if let rule = habit.rule { parts.append(auto ? "авто: \(HabitText.rule(rule))" : HabitText.rule(rule)) }
        if habit.schedule.kind == .timesPerWeek || habit.schedule.weekdays.count != 7 {
            parts.append(HabitText.schedule(habit.schedule))
        }
        if parts.isEmpty {
            let unit = habit.target.unit.isEmpty ? "" : " \(habit.target.unit)"
            parts.append(goal > 1 ? "Ещё \(goal - count)\(unit)" : "Не отмечено")
        }
        return PlansHabitTileModel(
            id: habit.id,
            title: habit.title,
            count: count,
            goal: goal,
            note: parts.joined(separator: " · "),
            streak: habits.streak(for: habit, today: today),
            isAuto: auto,
            streakToday: done
        )
    }

    private func tick(_ id: String) {
        guard demo == nil, let habit = due.first(where: { $0.id == id }) else { return }
        habits.tapUndoable(habit, on: today)
    }

    private func complete(_ id: String) {
        guard demo == nil, let habit = due.first(where: { $0.id == id }) else { return }
        habits.complete(habit, on: today)
    }

    private func edit(_ id: String) {
        guard demo == nil, let habit = habits.activeHabits.first(where: { $0.id == id }) else { return }
        editorTarget = .edit(habit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary

            if demo == nil && habits.activeHabits.isEmpty {
                EmptyState(
                    title: "Привычек пока нет",
                    message: "Напишите внизу, например: «вода 8 стаканов в день».",
                    icon: "checkmark.circle"
                )
            } else if tiles.isEmpty {
                Text("На сегодня привычек нет.")
                    .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                    .foregroundColor(DS.Colors.textSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(tiles) { model in
                        PlansHabitTile(
                            model: model,
                            onTick: { tick(model.id) },
                            onEdit: { edit(model.id) },
                            onComplete: { complete(model.id) }
                        )
                    }
                }
            }

            if demo == nil && !others.isEmpty {
                Text("НЕ НА СЕГОДНЯ")
                    .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                    .tracking(0.8)
                    .foregroundColor(DS.Colors.textMuted)
                    .padding(.top, 6)
                ForEach(others) { habit in
                    Button { editorTarget = .edit(habit) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(habit.title)
                                .font(DS.Fonts.text(16, .bold, relativeTo: .body))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(HabitText.schedule(habit.schedule))
                                .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityHint("Открывает настройки привычки")
                }
            }

            PlansOutlineLink(title: "Новая привычка", icon: "plus") { editorTarget = .new }
                .disabled(demo != nil)
        }
        .sheet(item: $editorTarget) { target in
            HabitEditorSheet(habits: habits, existing: target.habit, today: today, draft: target.draft)
                .environment(\.sectionAccent, DS.Colors.plans)
                .tint(DS.Colors.plans)
        }
        .onChange(of: draftRequest?.id) { _, _ in openDraftIfAsked() }
        .onAppear(perform: openDraftIfAsked)
    }

    private func openDraftIfAsked() {
        guard let draft = draftRequest else { return }
        draftRequest = nil
        editorTarget = .draft(draft)
    }

    @ViewBuilder
    private var summary: some View {
        let s = habits.daySummary(for: today)
        let done = demo.map { $0.filter(\.isFull).count } ?? s.done
        let total = demo?.count ?? s.total
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Сегодня")
                .font(DS.Fonts.display(20, relativeTo: .title3))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer(minLength: 0)
            if total > 0 {
                Text("\(done) из \(total)")
                    .font(DS.Fonts.text(15, .heavy, relativeTo: .subheadline))
                    .monospacedDigit()
                    .foregroundColor(accent)
                    .accessibilityLabel("Выполнено \(done) из \(total)")
            }
        }
    }
}

enum HabitEditorTarget: Identifiable {
    case new
    case edit(Habit)
    /// A new habit prefilled from the bottom field.
    case draft(Habit)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let h): return h.id
        case .draft(let h): return "draft-\(h.id)"
        }
    }

    var habit: Habit? {
        if case .edit(let h) = self { return h }
        return nil
    }

    var draft: Habit? {
        if case .draft(let h) = self { return h }
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
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: DS.Metrics.spacing12) {
            Button {
                habits.tapUndoable(habit, on: today)
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

            let streak = habits.streak(for: habit, today: today)
            if streak.count > 0 {
                StreakBadge(count: streak.count, unit: streak.unit, extendedToday: done)
            }
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
    /// A new habit prefilled from the bottom field; saved as new, like «Новая привычка».
    let draft: Habit?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sectionAccent) private var accent

    init(habits: HabitStore, existing: Habit?, today: String, draft: Habit? = nil) {
        self.habits = habits
        self.existing = existing
        self.today = today
        self.draft = draft
    }

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
                                        .foregroundColor(on ? DS.Colors.canvas : DS.Colors.textPrimary)
                                        .background(on ? accent : DS.Colors.surfaceRaised)
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
            .confirmationDialog("Удалить привычку?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    if let existing { habits.deleteKeepingTrash(id: existing.id) }
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Её можно вернуть 30 дней: Профиль → Недавно удалённые.")
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let h = existing ?? draft else { return }
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
