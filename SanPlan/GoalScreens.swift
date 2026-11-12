import SwiftUI

// Экраны целей и сфер внутри вкладки «Планы» (режим «Цели»). Данные — GoalStore.shared.
// Недельные самооценки сфер приходят параметром из ReviewStore; без них радар не рисуется.

/// Цель накопления из «Денег», к которой можно привязать денежную цель.
public struct GoalSavingsOption: Identifiable, Equatable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

enum GoalText {
    static func dateLabel(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        let months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]
        return "\(parts[2]) \(months[parts[1] - 1])"
    }

    static func kindLabel(_ kind: GoalProgressKind) -> String {
        switch kind {
        case .money: return "Деньги"
        case .trainingCount: return "Тренировки"
        case .trainingWeight: return "Рабочий вес"
        case .habit: return "Привычка"
        case .milestones: return "Этапы"
        }
    }
}

struct GoalsSection: View {
    @ObservedObject var goals: GoalStore
    @ObservedObject var habits: HabitStore
    let today: String
    var savings: [GoalSavingsOption] = []
    var weekRatings: [WeekReview] = []
    @State private var editorTarget: GoalEditorTarget?
    @State private var showSpheres = false

    private var open: [Goal] { goals.activeGoals }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Цели")
                Spacer()
                Button("Сферы") { showSpheres = true }
                    .frame(minHeight: DS.Metrics.minHitTarget)
            }

            if let week = goals.weekGoal(today: today) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Цель недели").font(.footnote).foregroundColor(DS.Colors.textSecondary)
                    Text(week.goal.title).font(.headline)
                    GoalProgressLine(progress: week.progress)
                }
                .padding(DS.Metrics.spacing12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                .accessibilityElement(children: .combine)
            }

            if open.isEmpty {
                EmptyState(
                    title: "Целей пока нет",
                    message: "Добавь цель: сфера, срок и способ измерять прогресс — деньги, тренировки, привычка или этапы.",
                    icon: "target"
                )
            }

            ForEach(open) { goal in
                GoalRowView(goal: goal, goals: goals, today: today) { editorTarget = .edit(goal) }
            }

            Button {
                editorTarget = .new
            } label: {
                Label("Добавить цель", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget)
            }
            .buttonStyle(.bordered)
            .disabled(goals.owner == .none)
        }
        .sheet(item: $editorTarget) { target in
            GoalEditorSheet(goals: goals, habits: habits, existing: target.goal, today: today, savings: savings)
        }
        .sheet(isPresented: $showSpheres) {
            SpheresSheet(goals: goals, habits: habits, today: today, weekRatings: weekRatings)
        }
    }
}

enum GoalEditorTarget: Identifiable {
    case new
    case edit(Goal)
    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let g): return g.id
        }
    }
    var goal: Goal? {
        if case .edit(let g) = self { return g }
        return nil
    }
}

struct GoalProgressLine: View {
    let progress: GoalProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let f = progress.fraction {
                ProgressView(value: f)
                    .tint(progress.achieved ? DS.Colors.positive : DS.Colors.accent)
                    .accessibilityHidden(true)
            }
            Text(progress.achieved ? "Достигнута · \(progress.text)" : progress.text)
                .font(.footnote.monospacedDigit())
                .foregroundColor(DS.Colors.textSecondary)
        }
    }
}

struct GoalRowView: View {
    let goal: Goal
    @ObservedObject var goals: GoalStore
    let today: String
    let onEdit: () -> Void

    var body: some View {
        let progress = goals.progress(for: goal, today: today)
        VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(goal.title).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                    Text(subtitle(progress))
                        .font(.footnote)
                        .foregroundColor(GoalEngine.isOverdue(goal, today: today, progress: progress) ? DS.Colors.destructive : DS.Colors.textSecondary)
                    GoalProgressLine(progress: progress)
                }
                .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Открывает настройки цели")

            if case .milestones(let items) = goal.kind {
                ForEach(items) { item in
                    Button {
                        goals.setMilestone(goalId: goal.id, milestoneId: item.id, done: !item.done)
                    } label: {
                        HStack {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(item.done ? DS.Colors.positive : DS.Colors.textSecondary)
                            Text(item.title).strikethrough(item.done)
                            if let due = item.dueDay {
                                Text(GoalText.dateLabel(due)).font(.footnote).foregroundColor(DS.Colors.textSecondary)
                            }
                            Spacer()
                        }
                        .frame(minHeight: DS.Metrics.minHitTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(item.done ? .isSelected : [])
                    .sensoryFeedback(.selection, trigger: item.done)
                }
            }
        }
        .padding(DS.Metrics.spacing12)
        .background(DS.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
        .overlay(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius).stroke(DS.Colors.hairline, lineWidth: 1))
    }

    private func subtitle(_ progress: GoalProgress) -> String {
        var parts: [String] = []
        if let s = goals.sphereTitle(goal.sphereId) { parts.append(s) }
        parts.append(GoalText.kindLabel(goal.kind))
        if let due = goal.dueDay {
            parts.append(GoalEngine.isOverdue(goal, today: today, progress: progress) ? "срок прошёл \(GoalText.dateLabel(due))" : "до \(GoalText.dateLabel(due))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Редактор цели

struct GoalEditorSheet: View {
    @ObservedObject var goals: GoalStore
    @ObservedObject var habits: HabitStore
    let existing: Goal?
    let today: String
    let savings: [GoalSavingsOption]
    @Environment(\.dismiss) private var dismiss

    private enum KindChoice: String, CaseIterable, Identifiable {
        case milestones = "Этапы"
        case money = "Деньги"
        case trainingCount = "Тренировки"
        case trainingWeight = "Вес"
        case habit = "Привычка"
        var id: String { rawValue }
    }

    @State private var title = ""
    @State private var sphereId = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var kind: KindChoice = .milestones
    @State private var moneyTarget = ""
    @State private var savingsId = ""
    @State private var trainingTarget = 10
    @State private var exercise = ""
    @State private var weightTarget = ""
    @State private var habitId = ""
    @State private var habitPercent = 80
    @State private var habitDays = 30
    @State private var milestones: [GoalMilestone] = []
    @State private var newMilestone = ""
    @State private var isWeekGoal = false
    @State private var confirmingDelete = false
    @State private var loaded = false

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .milestones: return !milestones.isEmpty
        case .money: return (Int(moneyTarget.filter(\.isNumber)) ?? 0) > 0
        case .trainingCount: return true
        case .trainingWeight: return !exercise.trimmingCharacters(in: .whitespaces).isEmpty && (Double(weightTarget.replacingOccurrences(of: ",", with: ".")) ?? 0) > 0
        case .habit: return !habitId.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") {
                    TextField("Например, отложить на отпуск", text: $title).frame(minHeight: DS.Metrics.minHitTarget)
                }
                Section("Сфера и срок") {
                    Picker("Сфера", selection: $sphereId) {
                        Text("Без сферы").tag("")
                        ForEach(goals.spheres) { Text($0.title).tag($0.id) }
                    }
                    Toggle("Есть срок", isOn: $hasDue).frame(minHeight: DS.Metrics.minHitTarget)
                    if hasDue { DatePicker("Срок", selection: $due, displayedComponents: .date) }
                }
                Section("Как измерять") {
                    Picker("Тип", selection: $kind) {
                        ForEach(KindChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    kindFields
                }
                if existing != nil || !title.isEmpty {
                    Section {
                        Toggle("Цель недели", isOn: $isWeekGoal).frame(minHeight: DS.Metrics.minHitTarget)
                    } footer: {
                        Text("Показывается на «Сегодня» до конца этой недели.")
                    }
                }
                if let existing {
                    Section {
                        Button(existing.archived ? "Вернуть из архива" : "В архив") {
                            goals.archive(id: existing.id, !existing.archived)
                            dismiss()
                        }
                        .frame(minHeight: DS.Metrics.minHitTarget)
                        Button("Удалить цель", role: .destructive) { confirmingDelete = true }
                            .frame(minHeight: DS.Metrics.minHitTarget)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Новая цель" : "Цель")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить") { save() }.disabled(!canSave) }
            }
            .confirmationDialog("Удалить цель?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    if let existing { goals.delete(id: existing.id) }
                    dismiss()
                }
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder private var kindFields: some View {
        switch kind {
        case .milestones:
            ForEach($milestones) { $m in
                TextField("Этап", text: $m.title).frame(minHeight: DS.Metrics.minHitTarget)
            }
            .onDelete { milestones.remove(atOffsets: $0) }
            HStack {
                TextField("Новый этап", text: $newMilestone).frame(minHeight: DS.Metrics.minHitTarget)
                Button("Добавить") {
                    let t = newMilestone.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    milestones.append(GoalMilestone(title: t))
                    newMilestone = ""
                }
                .disabled(newMilestone.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .money:
            TextField("Сумма, ₸", text: $moneyTarget).keyboardType(.numberPad).frame(minHeight: DS.Metrics.minHitTarget)
            Picker("Цель накопления в «Деньгах»", selection: $savingsId) {
                Text("Не выбрана").tag("")
                ForEach(savings) { Text($0.title).tag($0.id) }
            }
        case .trainingCount:
            Stepper("\(trainingTarget) тренировок", value: $trainingTarget, in: 1...500)
                .frame(minHeight: DS.Metrics.minHitTarget)
        case .trainingWeight:
            TextField("Упражнение", text: $exercise).frame(minHeight: DS.Metrics.minHitTarget)
            TextField("Вес, кг", text: $weightTarget).keyboardType(.decimalPad).frame(minHeight: DS.Metrics.minHitTarget)
        case .habit:
            Picker("Привычка", selection: $habitId) {
                Text("Не выбрана").tag("")
                ForEach(habits.activeHabits) { Text($0.title).tag($0.id) }
            }
            Stepper("Выполнять на \(habitPercent)%", value: $habitPercent, in: 10...100, step: 5)
                .frame(minHeight: DS.Metrics.minHitTarget)
            Stepper("За последние \(habitDays) дн.", value: $habitDays, in: 7...365, step: 7)
                .frame(minHeight: DS.Metrics.minHitTarget)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let g = existing else { return }
        title = g.title
        sphereId = g.sphereId ?? ""
        if let d = g.dueDay, let date = Self.dayFormatter.date(from: d) { hasDue = true; due = date }
        isWeekGoal = goals.weekPick?.goalId == g.id && goals.weekPick?.weekStart == HabitCalendar.weekStart(today)
        switch g.kind {
        case .milestones(let items): kind = .milestones; milestones = items
        case .money(let target, let id): kind = .money; moneyTarget = String(target); savingsId = id ?? ""
        case .trainingCount(let target): kind = .trainingCount; trainingTarget = target
        case .trainingWeight(let ex, let target): kind = .trainingWeight; exercise = ex; weightTarget = GoalEngine.trimmed(target)
        case .habit(let id, let percent, let days): kind = .habit; habitId = id; habitPercent = percent; habitDays = days
        }
    }

    private func built() -> GoalProgressKind {
        switch kind {
        case .milestones: return .milestones(milestones)
        case .money: return .money(target: Int(moneyTarget.filter(\.isNumber)) ?? 0, savingsGoalId: savingsId.isEmpty ? nil : savingsId)
        case .trainingCount: return .trainingCount(target: trainingTarget)
        case .trainingWeight:
            return .trainingWeight(exercise: exercise.trimmingCharacters(in: .whitespaces),
                                   target: Double(weightTarget.replacingOccurrences(of: ",", with: ".")) ?? 0)
        case .habit: return .habit(habitId: habitId, targetPercent: habitPercent, days: habitDays)
        }
    }

    private func save() {
        let dueDay = hasDue ? Self.dayFormatter.string(from: due) : nil
        var goal = existing ?? Goal(title: "", createdDay: today, kind: built())
        goal.title = title.trimmingCharacters(in: .whitespaces)
        goal.sphereId = sphereId.isEmpty ? nil : sphereId
        goal.dueDay = dueDay
        goal.kind = built()
        if existing == nil { goals.add(goal) } else { goals.update(goal) }
        if isWeekGoal { goals.setWeekGoal(goal.id, today: today) }
        else if goals.weekPick?.goalId == goal.id { goals.setWeekGoal(nil, today: today) }
        dismiss()
    }
}

// MARK: - Сферы

struct SpheresSheet: View {
    @ObservedObject var goals: GoalStore
    @ObservedObject var habits: HabitStore
    let today: String
    let weekRatings: [WeekReview]
    @Environment(\.dismiss) private var dismiss
    @State private var selected: GoalSphere?
    @State private var editing = false

    private var sorted: [WeekReview] { weekRatings.sorted { $0.weekStart < $1.weekStart } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                    if let latest = sorted.last, !latest.ratings.isEmpty {
                        SphereRadar(spheres: goals.spheres, ratings: latest.ratings,
                                    previous: sorted.count >= 2 ? sorted[sorted.count - 2].ratings : nil)
                            .frame(height: 260)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(radarLabel(latest))
                        Text(radarCaption(latest)).font(.footnote).foregroundColor(DS.Colors.textSecondary)
                    } else {
                        EmptyState(title: "Оценок пока нет", message: "Радар строится из недельных оценок сфер в итогах недели.", icon: "chart.pie")
                    }
                    ForEach(goals.spheres) { sphere in
                        Button { selected = sphere } label: {
                            HStack {
                                Text(sphere.title).font(.body)
                                Spacer()
                                Text(ratingText(sphere)).font(.body.monospacedDigit()).foregroundColor(DS.Colors.textSecondary)
                                Image(systemName: "chevron.right").font(.footnote).foregroundColor(DS.Colors.textSecondary)
                            }
                            .frame(minHeight: DS.Metrics.minHitTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(DS.Metrics.screenGutter)
            }
            .navigationTitle("Сферы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Изменить") { editing = true } }
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .sheet(item: $selected) { sphere in
                SphereFactsSheet(goals: goals, habits: habits, sphere: sphere, today: today, weekRatings: sorted)
            }
            .sheet(isPresented: $editing) { SphereListEditor(goals: goals) }
        }
    }

    private func ratingText(_ sphere: GoalSphere) -> String {
        guard let r = sorted.last?.ratings[sphere.id] else { return "—" }
        if sorted.count >= 2, let before = sorted[sorted.count - 2].ratings[sphere.id], before != r {
            let d = r - before
            return "\(r) (\(d > 0 ? "+" : "")\(d))"
        }
        return "\(r)"
    }

    private func radarCaption(_ latest: WeekReview) -> String {
        var text = "Сплошная линия — неделя с \(GoalText.dateLabel(latest.weekStart))"
        if sorted.count >= 2 { text += ", пунктир — с \(GoalText.dateLabel(sorted[sorted.count - 2].weekStart))" }
        return text
    }

    private func radarLabel(_ week: WeekReview) -> String {
        goals.spheres.compactMap { s in week.ratings[s.id].map { "\(s.title) \($0)" } }.joined(separator: ", ")
    }
}

struct SphereRadar: View {
    let spheres: [GoalSphere]
    let ratings: [String: Int]
    /// Прошлая неделя для сравнения: пунктиром.
    var previous: [String: Int]? = nil

    var body: some View {
        GeometryReader { geo in
            let n = spheres.count
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = min(geo.size.width, geo.size.height) / 2 - 36
            ZStack {
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { ring in
                    polygon(n: n, center: center, radius: radius * ring) { _ in 1 }
                        .stroke(DS.Colors.hairline, lineWidth: 1)
                }
                polygon(n: n, center: center, radius: radius) { i in
                    Double(ratings[spheres[i].id] ?? 0) / 10
                }
                .fill(DS.Colors.accent.opacity(0.25))
                if let previous {
                    polygon(n: n, center: center, radius: radius) { i in Double(previous[spheres[i].id] ?? 0) / 10 }
                        .stroke(DS.Colors.textSecondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                polygon(n: n, center: center, radius: radius) { i in
                    Double(ratings[spheres[i].id] ?? 0) / 10
                }
                .stroke(DS.Colors.accent, lineWidth: 2)
                ForEach(0..<n, id: \.self) { i in
                    let p = point(i, n, center, radius + 22)
                    Text(spheres[i].title)
                        .font(.caption2)
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 70)
                        .position(p)
                }
            }
        }
    }

    private func point(_ i: Int, _ n: Int, _ center: CGPoint, _ r: CGFloat) -> CGPoint {
        let angle = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(max(n, 1))
        return CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
    }

    private func polygon(n: Int, center: CGPoint, radius: CGFloat, value: @escaping (Int) -> Double) -> Path {
        var path = Path()
        guard n >= 3 else { return path }
        for i in 0..<n {
            let p = point(i, n, center, radius * CGFloat(value(i)))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

struct SphereFactsSheet: View {
    @ObservedObject var goals: GoalStore
    @ObservedObject var habits: HabitStore
    let sphere: GoalSphere
    let today: String
    let weekRatings: [WeekReview]
    @Environment(\.dismiss) private var dismiss

    private var sphereGoals: [Goal] { GoalEngine.goals(goals.goals, sphereId: sphere.id) }
    private var sphereHabits: [Habit] {
        habits.activeHabits.filter { $0.sphere == sphere.id || $0.sphere == sphere.title }
    }
    private var facts: [String] { GoalEngine.sphereFacts(sphereId: sphere.id, today: today, context: goals.context) }
    private var history: [(String, Int)] {
        weekRatings.suffix(8).compactMap { w in w.ratings[sphere.id].map { (w.weekStart, $0) } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Оценки по неделям") {
                    if history.isEmpty { Text("Оценок пока нет").foregroundColor(DS.Colors.textSecondary) }
                    ForEach(history, id: \.0) { week, value in
                        HStack {
                            Text("с \(GoalText.dateLabel(week))")
                            Spacer()
                            Text("\(value)").font(.body.monospacedDigit())
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if !facts.isEmpty {
                    Section("За 30 дней") {
                        ForEach(facts, id: \.self) { Text($0) }
                    }
                }
                Section("Цели") {
                    if sphereGoals.isEmpty { Text("Целей в этой сфере нет").foregroundColor(DS.Colors.textSecondary) }
                    ForEach(sphereGoals) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(g.title)
                            GoalProgressLine(progress: goals.progress(for: g, today: today))
                        }
                    }
                }
                Section("Привычки") {
                    if sphereHabits.isEmpty { Text("Привычек в этой сфере нет").foregroundColor(DS.Colors.textSecondary) }
                    ForEach(sphereHabits) { h in
                        HStack {
                            Text(h.title)
                            Spacer()
                            if let s = HabitText.streak(habits.streak(for: h, today: today)) {
                                Text(s).font(.footnote).foregroundColor(DS.Colors.textSecondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(sphere.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}

struct SphereListEditor: View {
    @ObservedObject var goals: GoalStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [GoalSphere] = []
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($items) { $s in
                        TextField("Название", text: $s.title).frame(minHeight: DS.Metrics.minHitTarget)
                    }
                    .onDelete { items.remove(atOffsets: $0) }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        TextField("Новая сфера", text: $newTitle).frame(minHeight: DS.Metrics.minHitTarget)
                        Button("Добавить") {
                            let t = newTitle.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty else { return }
                            items.append(GoalSphere(id: "s\(UUID().uuidString.prefix(8).lowercased())", title: t))
                            newTitle = ""
                        }
                    }
                } footer: {
                    Text("Удалённая сфера остаётся у целей без названия. Оценки прошлых недель сохраняются.")
                }
            }
            .navigationTitle("Сферы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { goals.setSpheres(items); dismiss() }
                }
            }
            .onAppear { items = goals.spheres }
        }
    }
}
