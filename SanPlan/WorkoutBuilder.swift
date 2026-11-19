import SwiftUI

/// The weekly program builder: weekday chips on top, the chosen day's exercises as cards with steppers.
struct WorkoutBuilderView: View {
    @ObservedObject var store: WorkoutStore
    /// Shown as «Готово» once the program has at least one training day.
    var onDone: (() -> Void)?

    @State private var weekday: Int = WorkoutProgram.weekday(of: Date())
    @State private var showLibrary = false
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var titleDraft = ""
    /// Exercises start folded: number, name, one line of the target. A tap opens the steppers.
    @State private var expanded: Set<String> = []
    /// The exercise being dragged (by ≡ or a long press on its head), how far, and the cards' frames.
    @State private var dragID: String?
    @State private var dragY: CGFloat = 0
    @State private var cardFrames: [String: CGRect] = [:]
    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct RenameTarget: Identifiable {
        let id: String
        let name: String
    }

    private static let shortNames = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
    private static let fullNames = ["Понедельник", "Вторник", "Среда", "Четверг", "Пятница", "Суббота", "Воскресенье"]

    private var day: WorkoutDayPlan? {
        WorkoutProgram.day(store.program, weekday: weekday)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                if let error = store.errorMessage {
                    ErrorBanner(message: error) { store.errorMessage = nil }
                }

                dayChips

                if let day {
                    dayTitleField(day)
                    exerciseList(day)
                } else {
                    Card {
                        Text("\(Self.fullNames[weekday - 1]) — день отдыха")
                            .font(.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Добавьте упражнение, и день станет тренировочным.")
                            .font(.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }

                PillButton("Добавить упражнение", icon: "plus", style: day == nil ? .primary : .secondary) {
                    showLibrary = true
                }

                if let onDone, !store.program.days.isEmpty {
                    PillButton("Готово", icon: "checkmark") { onDone() }
                }
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.vertical, DS.Metrics.spacing16)
        }
        .sensoryFeedback(.selection, trigger: weekday)
        .onAppear { titleDraft = day?.title ?? "" }
        .onChange(of: weekday) { _, _ in
            titleDraft = day?.title ?? ""
            expanded = []
        }
        .sheet(isPresented: $showLibrary) {
            ExerciseLibrarySheet { name in
                store.updateProgram(label: "Упражнение добавлено") { try WorkoutProgram.addExercise($0, weekday: weekday, name: name) }
                // The new one opens so its sets and weight can be set at once; the rest stay folded.
                if let added = day?.exercises.last?.id { expanded.insert(added) }
            }
        }
        .alert("Название упражнения", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $renameText)
            Button("Сохранить") {
                if let target = renaming {
                    let name = renameText
                    store.updateProgram(label: "Упражнение переименовано") { try WorkoutProgram.updateExercise($0, weekday: weekday, id: target.id) { $0.name = name } }
                }
                renaming = nil
            }
            Button("Отмена", role: .cancel) { renaming = nil }
        }
    }

    // MARK: - Parts

    private var dayChips: some View {
        HStack(spacing: DS.Metrics.spacing4) {
            ForEach(1...7, id: \.self) { value in
                let isSelected = value == weekday
                let isTraining = WorkoutProgram.day(store.program, weekday: value) != nil
                Button {
                    weekday = value
                } label: {
                    VStack(spacing: 3) {
                        Text(Self.shortNames[value - 1])
                            .font(.subheadline.weight(.semibold))
                        Circle()
                            .fill(isSelected ? DS.Colors.canvas : accent)
                            .frame(width: 5, height: 5)
                            .opacity(isTraining ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget)
                    .foregroundColor(isSelected ? DS.Colors.canvas : DS.Colors.textPrimary)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Metrics.innerRadius)
                            .fill(isSelected ? accent : DS.Colors.surface)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(Self.fullNames[value - 1])\(isTraining ? ", тренировка" : ", отдых")")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func dayTitleField(_ day: WorkoutDayPlan) -> some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing4) {
            Text(Self.fullNames[day.weekday - 1])
                .font(.caption.weight(.semibold))
                .foregroundColor(DS.Colors.textSecondary)
            TextField("Название дня, например «Ноги»", text: $titleDraft)
                .font(.title3.weight(.semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .submitLabel(.done)
                .onChange(of: titleDraft) { _, text in
                    // Each typed letter is too small a change to offer «Отменить».
                    store.updateProgram(label: nil) { WorkoutProgram.setDayTitle($0, weekday: weekday, title: text) }
                }
        }
    }

    // MARK: - Exercises: folded, numbered, dragged into place

    private func exerciseList(_ day: WorkoutDayPlan) -> some View {
        let ids = day.exercises.compactMap(\.id)
        return VStack(spacing: DS.Metrics.spacing12) {
            ForEach(Array(day.exercises.enumerated()), id: \.element.id) { offset, exercise in
                if let id = exercise.id {
                    exerciseCard(exercise, id: id, number: offset + 1, isFirst: offset == 0, isLast: offset == day.exercises.count - 1)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            // Frozen while dragging: the offsets below must not feed back into the targets.
                            if dragID == nil { cardFrames[id] = frame }
                        }
                        .scaleEffect(dragID == id ? 1.03 : 1)
                        .shadow(color: .black.opacity(dragID == id ? 0.45 : 0), radius: 14, y: 8)
                        .offset(y: shift(of: id, ids: ids))
                        // The card under the finger follows it exactly; only the others glide.
                        .transaction(value: dragID == id ? dragY : 0) { $0.animation = nil }
                        .zIndex(dragID == id ? 1 : 0)
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78), value: dropIndex(ids))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: dragID)
    }

    /// Where the dragged card would land: the number of other cards whose middle is above its middle now.
    private func dropIndex(_ ids: [String]) -> Int? {
        guard let dragID, let frame = cardFrames[dragID] else { return nil }
        let center = frame.midY + dragY
        return ids.filter { $0 != dragID && (cardFrames[$0]?.midY ?? .infinity) < center }.count
    }

    private func shift(of id: String, ids: [String]) -> CGFloat {
        guard let dragID, let from = ids.firstIndex(of: dragID), let to = dropIndex(ids),
              let index = ids.firstIndex(of: id) else { return 0 }
        if id == dragID { return dragY }
        let pitch = (cardFrames[dragID]?.height ?? 0) + DS.Metrics.spacing12
        if from < index && index <= to { return -pitch }
        if to <= index && index < from { return pitch }
        return 0
    }

    private func dragChanged(_ id: String, _ translation: CGFloat, ids: [String]) {
        if dragID == nil {
            dragID = id
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        let before = dropIndex(ids)
        dragY = translation
        if dropIndex(ids) != before { UISelectionFeedbackGenerator().selectionChanged() }
    }

    private func dragEnded(ids: [String]) {
        guard let id = dragID, let from = ids.firstIndex(of: id) else {
            dragID = nil
            dragY = 0
            return
        }
        let to = dropIndex(ids) ?? from
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            if to != from {
                store.updateProgram(label: "Упражнение перемещено") { try WorkoutProgram.moveExercise($0, weekday: weekday, id: id, by: to - from) }
            }
            dragID = nil
            dragY = 0
        }
    }

    private func exerciseCard(_ exercise: WorkoutExercisePlan, id: String, number: Int, isFirst: Bool, isLast: Bool) -> some View {
        let ids = day?.exercises.compactMap(\.id) ?? []
        let isOpen = expanded.contains(id)
        let drag = DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { dragChanged(id, $0.translation.height, ids: ids) }
            .onEnded { _ in dragEnded(ids: ids) }
        let longPressDrag = LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                if case .second(true, let moved) = value {
                    dragChanged(id, moved?.translation.height ?? 0, ids: ids)
                }
            }
            .onEnded { _ in dragEnded(ids: ids) }
        return Card {
            HStack(alignment: .center, spacing: DS.Metrics.spacing8) {
                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.semibold))
                    .foregroundColor(dragID == id ? accent : DS.Colors.textSecondary.opacity(0.7))
                    .frame(width: 28, height: DS.Metrics.minHitTarget)
                    .contentShape(Rectangle())
                    .highPriorityGesture(drag)
                    .accessibilityElement()
                    .accessibilityLabel("Переместить: \(exercise.name)")
                    .accessibilityAction(named: "Выше") {
                        store.updateProgram { try WorkoutProgram.moveExercise($0, weekday: weekday, id: id, by: -1) }
                    }
                    .accessibilityAction(named: "Ниже") {
                        store.updateProgram { try WorkoutProgram.moveExercise($0, weekday: weekday, id: id, by: 1) }
                    }
                Text("\(number)")
                    .font(DS.Fonts.text(15, .heavy, relativeTo: .subheadline))
                    .monospacedDigit()
                    .foregroundColor(accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(TrainingPalette.badge))
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)
                HStack(spacing: DS.Metrics.spacing8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.name)
                            .font(.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                            .multilineTextAlignment(.leading)
                        if !isOpen {
                            Text(WorkoutFormat.exerciseSummary(exercise))
                                .font(.footnote.monospacedDigit())
                                .foregroundColor(DS.Colors.textSecondary)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .frame(minHeight: DS.Metrics.minHitTarget)
                .contentShape(Rectangle())
                .onTapGesture { toggle(id) }
                .gesture(longPressDrag)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(number). \(exercise.name)")
                .accessibilityValue(isOpen ? "раскрыто" : WorkoutFormat.exerciseSummary(exercise))
                .accessibilityHint(isOpen ? "Свернуть" : "Показать подходы, повторы и вес")
                Menu {
                    Button { renameText = exercise.name; renaming = RenameTarget(id: id, name: exercise.name) } label: {
                        Label("Переименовать", systemImage: "pencil")
                    }
                    Button { store.updateProgram(label: "Упражнение продублировано") { try WorkoutProgram.duplicateExercise($0, weekday: weekday, id: id) } } label: {
                        Label("Дублировать", systemImage: "plus.square.on.square")
                    }
                    if !isFirst {
                        Button { store.updateProgram { try WorkoutProgram.moveExercise($0, weekday: weekday, id: id, by: -1) } } label: {
                            Label("Выше", systemImage: "arrow.up")
                        }
                    }
                    if !isLast {
                        Button { store.updateProgram { try WorkoutProgram.moveExercise($0, weekday: weekday, id: id, by: 1) } } label: {
                            Label("Ниже", systemImage: "arrow.down")
                        }
                    }
                    // No question first: the toast offers «Отменить».
                    Button(role: .destructive) {
                        store.updateProgram(label: "Упражнение удалено") { try WorkoutProgram.deleteExercise($0, weekday: weekday, id: id) }
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                }
                .accessibilityLabel("Действия с упражнением")
            }

            if isOpen {
                exerciseDetails(exercise, id: id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func toggle(_ id: String) {
        guard dragID == nil else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    @ViewBuilder
    private func exerciseDetails(_ exercise: WorkoutExercisePlan, id: String) -> some View {
            ValueStepperRow(
                title: "Подходы",
                value: "\(exercise.sets)",
                canDecrease: exercise.sets > WorkoutProgram.setsRange.lowerBound,
                canIncrease: exercise.sets < WorkoutProgram.setsRange.upperBound,
                onDecrease: { edit(id) { $0.sets -= 1 } },
                onIncrease: { edit(id) { $0.sets += 1 } }
            )
            ValueStepperRow(
                title: exercise.perSide ? "Повторы на сторону" : "Повторы",
                value: "\(exercise.reps)",
                canDecrease: exercise.reps > WorkoutProgram.repsRange.lowerBound,
                canIncrease: exercise.reps < WorkoutProgram.repsRange.upperBound,
                onDecrease: { edit(id) { $0.reps -= 1 } },
                onIncrease: { edit(id) { $0.reps += 1 } }
            )
            ValueStepperRow(
                title: "Отдых между подходами",
                value: WorkoutFormat.rest(exercise.restSeconds),
                canDecrease: exercise.restSeconds > WorkoutProgram.restRange.lowerBound,
                canIncrease: exercise.restSeconds < WorkoutProgram.restRange.upperBound,
                onDecrease: { edit(id) { $0.restSeconds -= WorkoutProgram.restStep } },
                onIncrease: { edit(id) { $0.restSeconds += WorkoutProgram.restStep } }
            )
            let afterExercise = exercise.restAfterExercise ?? exercise.restSeconds
            ValueStepperRow(
                title: "Отдых после упражнения",
                value: WorkoutFormat.rest(afterExercise),
                canDecrease: afterExercise > WorkoutProgram.restRange.lowerBound,
                canIncrease: afterExercise < WorkoutProgram.restRange.upperBound,
                onDecrease: { edit(id) { $0.restAfterExercise = afterExercise - WorkoutProgram.restStep } },
                onIncrease: { edit(id) { $0.restAfterExercise = afterExercise + WorkoutProgram.restStep } }
            )
            Toggle("На каждую сторону", isOn: Binding(
                get: { exercise.perSide },
                set: { value in edit(id) { $0.perSide = value } }
            ))
            .font(.subheadline)
            .foregroundColor(DS.Colors.textPrimary)
            .tint(DS.Colors.workout)
            Toggle("Свой вес", isOn: Binding(
                get: { exercise.bodyweight ?? false },
                set: { value in edit(id) { $0.bodyweight = value } }
            ))
            .font(.subheadline)
            .foregroundColor(DS.Colors.textPrimary)
            .tint(DS.Colors.workout)
            weightRows(exercise, id: id)
    }

    /// Working weight (added load for a bodyweight exercise) and the step the progression hint adds.
    @ViewBuilder
    private func weightRows(_ exercise: WorkoutExercisePlan, id: String) -> some View {
        let bodyweight = exercise.bodyweight ?? false
        let step = exercise.weightStepKg ?? WorkoutSessionEdit.defaultStepKg
        let weight = exercise.weightKg
        ValueStepperRow(
            title: bodyweight ? "Доп. вес" : "Вес",
            value: WorkoutFormat.weight(weight, bodyweight: bodyweight),
            canDecrease: (weight ?? 0) > 0,
            canIncrease: (weight ?? 0) < WorkoutSessionEdit.weightRange.upperBound,
            onDecrease: {
                edit(id) {
                    let next = WorkoutSessionEdit.roundWeight(($0.weightKg ?? 0) - step)
                    $0.weightKg = next <= 0 ? (bodyweight ? nil : 0) : next
                }
            },
            onIncrease: {
                edit(id) { $0.weightKg = WorkoutSessionEdit.roundWeight(min(($0.weightKg ?? 0) + step, WorkoutSessionEdit.weightRange.upperBound)) }
            }
        )
        ValueStepperRow(
            title: "Шаг прибавки",
            value: WorkoutFormat.kilograms(step),
            canDecrease: step > (WorkoutFormat.steps.first ?? step),
            canIncrease: step < (WorkoutFormat.steps.last ?? step),
            onDecrease: { edit(id) { $0.weightStepKg = WorkoutFormat.steps.last(where: { $0 < step }) ?? step } },
            onIncrease: { edit(id) { $0.weightStepKg = WorkoutFormat.steps.first(where: { $0 > step }) ?? step } }
        )
    }

    private func edit(_ id: String, _ change: @escaping (inout WorkoutExercisePlan) -> Void) {
        store.updateProgram { try WorkoutProgram.updateExercise($0, weekday: weekday, id: id, change) }
    }
}

/// «Подходы   −  3  +»: a label, the value and two round buttons, with a tick on every change.
struct ValueStepperRow: View {
    let title: String
    let value: String
    let canDecrease: Bool
    let canIncrease: Bool
    let onDecrease: () -> Void
    let onIncrease: () -> Void
    /// When set, a tap on the value opens a field for typing it; the closure returns false for a number it cannot take.
    var onEnter: ((String) -> Bool)? = nil
    var allowsDecimal = false

    @State private var entering = false
    @State private var typed = ""
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        HStack(spacing: DS.Metrics.spacing8) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            stepButton("minus", label: "Меньше: \(title)", enabled: canDecrease, action: onDecrease)
            valueView
            stepButton("plus", label: "Больше: \(title)", enabled: canIncrease, action: onIncrease)
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .contain)
        .alert(title, isPresented: $entering) {
            TextField(title, text: $typed)
                .keyboardType(allowsDecimal ? .decimalPad : .numberPad)
            Button("Готово") { _ = onEnter?(typed) }
            Button("Отмена", role: .cancel) {}
        }
    }

    @ViewBuilder private var valueView: some View {
        let text = Text(value)
            .font(.body.weight(.semibold).monospacedDigit())
            .foregroundColor(DS.Colors.textPrimary)
            .contentTransition(.numericText())
            .frame(minWidth: 52)
            .animation(.snappy, value: value)
        if onEnter != nil {
            Button {
                typed = ""
                entering = true
            } label: {
                text
                    .padding(.vertical, DS.Metrics.spacing4)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(DS.Colors.textSecondary.opacity(0.35)).frame(height: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title): \(value)")
            .accessibilityHint("Ввести число")
        } else {
            text
        }
    }

    /// «62,5» or «62.5» → 62.5; nil for anything that is not a number.
    static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private func stepButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(DS.Colors.surfaceRaised))
                .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
        }
        .buttonStyle(.plain)
        .foregroundColor(enabled ? accent : DS.Colors.textSecondary.opacity(0.4))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Picks an exercise from the library or takes the typed name as a new one.
struct ExerciseLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty && !ExerciseLibrary.allExercises.contains(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) {
                    Section {
                        Button {
                            pick(typed)
                        } label: {
                            Label("Добавить «\(typed)»", systemImage: "plus.circle.fill")
                                .foregroundColor(DS.Colors.workout)
                        }
                    }
                }
                ForEach(ExerciseLibrary.search(query)) { group in
                    Section(group.title) {
                        ForEach(group.exercises, id: \.self) { name in
                            Button(name) { pick(name) }
                                .foregroundColor(DS.Colors.textPrimary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.canvas.ignoresSafeArea())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Найти или ввести своё")
            .navigationTitle("Упражнение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    private func pick(_ name: String) {
        onPick(name)
        dismiss()
    }
}

enum WorkoutFormat {
    /// 45 → «45 с», 90 → «1:30», 120 → «2:00».
    static func rest(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) с" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func exerciseSummary(_ exercise: WorkoutExercisePlan) -> String {
        var text = "\(exercise.sets) × \(exercise.reps)\(exercise.perSide ? " на сторону" : "")"
        if let weight = exercise.weightKg, weight > 0 {
            text += (exercise.bodyweight == true ? " · +" : " · ") + kilograms(weight)
        }
        return text + " · отдых \(rest(exercise.restSeconds))"
    }

    /// Steps the progression hint can add, in kilograms.
    static let steps: [Double] = [0.5, 1, 1.25, 2.5, 5, 10]

    /// 60 → «60 кг», 57.5 → «57,5 кг».
    static func kilograms(_ value: Double) -> String {
        number(value) + " кг"
    }

    static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// The weight of a target: «свой вес», «+10 кг» on top of it, «60 кг», or «—» when not set.
    static func weight(_ value: Double?, bodyweight: Bool) -> String {
        if bodyweight {
            guard let value, value > 0 else { return "свой вес" }
            return "+" + kilograms(value)
        }
        guard let value else { return "—" }
        return kilograms(value)
    }

    /// One logged set: «60 кг × 8», «+10 кг × 8», «12 повт.».
    /// Several sets in one line: «4 × 8 по 60 кг» when they are all alike, else each set in turn.
    static func sets(_ sets: [(weightKg: Double?, reps: Int?)], bodyweight: Bool) -> String {
        guard let first = sets.first else { return "" }
        let alike = sets.allSatisfy { $0.weightKg == first.weightKg && $0.reps == first.reps }
        guard alike, sets.count > 1 else {
            return sets.map { set(weight: $0.weightKg, reps: $0.reps, bodyweight: bodyweight) }.joined(separator: " · ")
        }
        let reps = first.reps.map(String.init) ?? "—"
        let load = weight(first.weightKg, bodyweight: bodyweight)
        if first.weightKg == nil && !bodyweight { return "\(sets.count) × \(reps)" }
        return "\(sets.count) × \(reps) · \(load)"
    }

    static func set(weight: Double?, reps: Int?, bodyweight: Bool) -> String {
        let repsText = reps.map(String.init) ?? "—"
        if bodyweight {
            guard let weight, weight > 0 else { return "\(repsText) повт." }
            return "+\(number(weight)) кг × \(repsText)"
        }
        guard let weight else { return "\(repsText) повт." }
        return "\(number(weight)) кг × \(repsText)"
    }

    /// 754 s → «12:34», 4000 s → «1:06:40».
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 754 s → «13 мин», 4000 s → «1 ч 7 мин».
    static func duration(_ seconds: Int) -> String {
        let minutes = Int((Double(max(0, seconds)) / 60).rounded())
        if minutes < 60 { return "\(minutes) мин" }
        return minutes % 60 == 0 ? "\(minutes / 60) ч" : "\(minutes / 60) ч \(minutes % 60) мин"
    }

    /// 1234.5 → «1,2 т», 850 → «850 кг».
    static func tonnage(_ kg: Double) -> String {
        kg >= 1000 ? number((kg / 100).rounded() / 10) + " т" : number(kg.rounded()) + " кг"
    }

    static let weekdayNames = ["Понедельник", "Вторник", "Среда", "Четверг", "Пятница", "Суббота", "Воскресенье"]
}
