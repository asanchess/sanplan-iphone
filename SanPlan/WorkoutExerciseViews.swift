import SwiftUI

// «Тушь»: кадр упражнения с сеткой подходов и листы правки подхода и цели (DESIGN-INK 11.5-Г, 11.6).

/// One exercise and its sets. A cell's lower strip ticks a set or takes the tick back; a tap on the numbers opens it.
/// Текущее упражнение — рамка акцентом и фолио «СЕЙЧАС»; полностью сделанное — название зачёркнуто.
struct ExerciseSetsCard: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState
    let index: Int
    let onEditSet: (Int) -> Void
    let onEditTarget: () -> Void
    let onReplace: () -> Void

    private var exercise: SessionExercise { session.exercises[index] }
    private var isRunning: Bool { session.phase != .complete }
    private var allDone: Bool { !exercise.rests.isEmpty && exercise.doneCount == exercise.rests.count }

    var body: some View {
        let isCurrent = isRunning && index == session.exerciseIndex
        InkPanel(border: isCurrent ? Ink.Colors.accent : nil) {
            VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                VStack(alignment: .leading, spacing: 2) {
                    if isCurrent { InkFolio(text: "Сейчас") }
                    HStack(alignment: .firstTextBaseline, spacing: Ink.Metrics.gutter) {
                        Text(exercise.baseName)
                            .inkText(.headline, weight: .bold)
                            .strikethrough(allDone, color: Ink.Colors.fg)
                            .foregroundColor(Ink.Colors.fg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(exercise.doneCount)/\(exercise.rests.count)")
                            .inkText(.subheadline, weight: .bold, numeric: true)
                            .foregroundColor(Ink.Colors.muted)
                        menu
                    }
                    Text(targetText)
                        .inkText(.subheadline, weight: .medium, numeric: true)
                        .foregroundColor(Ink.Colors.muted)
                    if let best = store.bestWeight(exercise: exercise.baseName) {
                        Text("Рекорд: \(WorkoutFormat.kilograms(best))")
                            .inkText(.subheadline, weight: .medium, numeric: true)
                            .foregroundColor(Ink.Colors.muted)
                    }
                }
                InkFlowGrid(minimum: 88, spacing: Ink.Metrics.gutter) {
                    ForEach(exercise.rests.indices, id: \.self) { set in
                        setCell(set, isCurrent: isCurrent && set == session.setIndex)
                    }
                    InkAddCell(
                        title: "Подход",
                        accessibilityLabel: "Добавить подход: \(exercise.baseName)",
                        isEnabled: exercise.rests.count < 100
                    ) {
                        store.editSession("Подход добавлен") { try WorkoutSessionEdit.addSet($0, exercise: index) }
                    }
                }
            }
        }
    }

    private var targetText: String {
        let bodyweight = exercise.bodyweight ?? false
        var parts: [String] = []
        if let reps = exercise.reps {
            parts.append("\(reps) повт.\(exercise.perSide == true ? " на сторону" : "")")
        }
        if !bodyweight || (exercise.weightKg ?? 0) > 0 {
            parts.append(WorkoutFormat.weight(exercise.weightKg, bodyweight: bodyweight))
        }
        if let rest = exercise.rests.first {
            parts.append("отдых \(WorkoutFormat.rest(rest))")
        }
        return parts.joined(separator: " · ")
    }

    private var menu: some View {
        Menu {
            if isRunning {
                Button {
                    store.editSession("Переход к упражнению") {
                        try WorkoutSessionEdit.jump($0, exercise: index, set: WorkoutSessionEdit.firstOpenSet($0.exercises[index]), now: WorkoutStore.nowMs())
                    }
                } label: { Label("Перейти сюда", systemImage: "arrow.right.circle") }
            }
            Button(action: onEditTarget) { Label("Изменить цель", systemImage: "slider.horizontal.3") }
            Button(action: onReplace) { Label("Заменить", systemImage: "arrow.left.arrow.right") }
            if index > 0 {
                Button {
                    store.editSession("Упражнение перемещено") { try WorkoutSessionEdit.moveExercise($0, from: index, to: index - 1) }
                } label: { Label("Выше", systemImage: "arrow.up") }
            }
            if index < session.exercises.count - 1 {
                Button {
                    store.editSession("Упражнение перемещено") { try WorkoutSessionEdit.moveExercise($0, from: index, to: index + 1) }
                } label: { Label("Ниже", systemImage: "arrow.down") }
            }
            if session.exercises.count > 1 {
                Button(role: .destructive) {
                    store.editSession("Упражнение удалено") { try WorkoutSessionEdit.removeExercise($0, index: index, now: WorkoutStore.nowMs()) }
                } label: { Label("Удалить", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Ink.Colors.fg)
                .frame(width: Ink.Metrics.minHit, height: Ink.Metrics.minHit)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Действия с упражнением \(exercise.baseName)")
    }

    private func setCell(_ set: Int, isCurrent: Bool) -> some View {
        let entry = exercise.sets[set]
        let suggested = exercise.suggestedValues(for: set)
        let bodyweight = exercise.bodyweight ?? false
        let weight = entry.weightKg ?? suggested.weightKg
        let reps = entry.reps ?? suggested.reps
        let text = WorkoutFormat.set(weight: weight, reps: reps, bodyweight: bodyweight)
        let repsText = reps.map(String.init) ?? "—"
        let hasLoad = bodyweight ? (weight ?? 0) > 0 : weight != nil
        return InkSetCell(
            weight: hasLoad ? WorkoutFormat.weight(weight, bodyweight: bodyweight) : repsText,
            reps: hasLoad ? "× \(repsText)" : "повт.",
            state: InkSetState.state(done: entry.done, isCurrent: isCurrent),
            setNumber: set + 1,
            accessibilityText: text,
            onEdit: { onEditSet(set) },
            onToggle: {
                let done = !entry.done
                store.editSession(done ? "Подход отмечен" : "Отметка снята") {
                    try WorkoutSessionEdit.setDone($0, exercise: index, set: set, done: done, now: WorkoutStore.nowMs())
                }
            },
            toggleLabel: entry.done ? "Подход \(set + 1) сделан, снять отметку" : "Отметить подход \(set + 1)"
        )
        .sensoryFeedback(trigger: entry.done) { _, isDone in
            let tap: SensoryFeedback = isDone ? .impact(weight: .light, intensity: 0.8) : .selection
            return tap
        }
    }
}

/// One set: its weight and reps, the tick, going to it, and removing it.
struct SetEditorSheet: View {
    @ObservedObject var store: WorkoutStore
    let ref: WorkoutSetRef
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let session = store.activeSession,
                   session.exercises.indices.contains(ref.exercise),
                   session.exercises[ref.exercise].rests.indices.contains(ref.set) {
                    let exercise = session.exercises[ref.exercise]
                    let entry = exercise.sets[ref.set]
                    ScrollView {
                        VStack(alignment: .leading, spacing: Ink.Metrics.stack) {
                            SetValueSteppers(store: store, exercise: ref.exercise, set: ref.set)
                            Toggle("Подход сделан", isOn: Binding(
                                get: { entry.done },
                                set: { done in
                                    store.editSession(done ? "Подход отмечен" : "Отметка снята") {
                                        try WorkoutSessionEdit.setDone($0, exercise: ref.exercise, set: ref.set, done: done, now: WorkoutStore.nowMs())
                                    }
                                }
                            ))
                            .inkText(.body)
                            .foregroundColor(Ink.Colors.fg)
                            .tint(Ink.Colors.accent)
                            if session.phase != .complete {
                                InkButton(title: "Перейти к этому подходу", icon: "arrow.right.circle", kind: .secondary) {
                                    store.editSession("Переход к подходу") {
                                        try WorkoutSessionEdit.jump($0, exercise: ref.exercise, set: ref.set, now: WorkoutStore.nowMs())
                                    }
                                    dismiss()
                                }
                            }
                            if exercise.rests.count > 1 {
                                InkButton(title: "Удалить подход", kind: .destructive) {
                                    store.editSession("Подход удалён") {
                                        try WorkoutSessionEdit.removeSet($0, exercise: ref.exercise, set: ref.set)
                                    }
                                    dismiss()
                                }
                            }
                        }
                        .padding(Ink.Metrics.page)
                    }
                    .navigationTitle("\(exercise.baseName) · подход \(ref.set + 1)")
                } else {
                    Text("Подход уже удалён.")
                        .inkText(.body)
                        .foregroundColor(Ink.Colors.muted)
                }
            }
            .background(Ink.Colors.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .tint(Ink.Colors.accentText)
    }
}

/// Today's targets of one exercise. They apply to this workout only; the summary offers to put them in the plan.
struct ExerciseTargetSheet: View {
    @ObservedObject var store: WorkoutStore
    let index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let session = store.activeSession, session.exercises.indices.contains(index) {
                    let exercise = session.exercises[index]
                    let bodyweight = exercise.bodyweight ?? false
                    let step = exercise.weightStepKg ?? WorkoutSessionEdit.defaultStepKg
                    let weight = exercise.weightKg
                    let reps = exercise.reps ?? WorkoutProgram.defaultReps
                    let rest = exercise.rests.count > 1 ? exercise.rests[0] : exercise.rests[exercise.rests.count - 1]
                    ScrollView {
                        VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                            InkStepper(
                                title: "Повторы",
                                value: "\(reps)",
                                canDecrease: reps > WorkoutProgram.repsRange.lowerBound,
                                canIncrease: reps < WorkoutProgram.repsRange.upperBound,
                                onDecrease: { update(reps: reps - 1) },
                                onIncrease: { update(reps: reps + 1) }
                            )
                            InkStepper(
                                title: bodyweight ? "Доп. вес" : "Вес",
                                value: WorkoutFormat.weight(weight, bodyweight: bodyweight),
                                canDecrease: (weight ?? 0) > 0,
                                canIncrease: (weight ?? 0) < WorkoutSessionEdit.weightRange.upperBound,
                                onDecrease: {
                                    let next = (weight ?? 0) - step
                                    let value: Double? = next > 0 ? next : (bodyweight ? nil : 0)
                                    update(weight: .some(value))
                                },
                                onIncrease: { update(weight: .some((weight ?? 0) + step)) }
                            )
                            InkStepper(
                                title: "Отдых между подходами",
                                value: WorkoutFormat.rest(rest),
                                canDecrease: rest > WorkoutProgram.restRange.lowerBound,
                                canIncrease: rest < WorkoutProgram.restRange.upperBound,
                                onDecrease: { update(rest: rest - WorkoutProgram.restStep) },
                                onIncrease: { update(rest: rest + WorkoutProgram.restStep) }
                            )
                            InkStepper(
                                title: "Шаг прибавки",
                                value: WorkoutFormat.kilograms(step),
                                canDecrease: step > (WorkoutFormat.steps.first ?? step),
                                canIncrease: step < (WorkoutFormat.steps.last ?? step),
                                onDecrease: { update(step: WorkoutFormat.steps.last(where: { $0 < step })) },
                                onIncrease: { update(step: WorkoutFormat.steps.first(where: { $0 > step })) }
                            )
                            Toggle("Свой вес", isOn: Binding(
                                get: { bodyweight },
                                set: { value in
                                    store.editSession(nil) { try WorkoutSessionEdit.updateExercise($0, index: index, bodyweight: value) }
                                }
                            ))
                            .inkText(.body)
                            .foregroundColor(Ink.Colors.fg)
                            .tint(Ink.Colors.accent)
                            Text("Меняется только эта тренировка. В конце можно сохранить изменения в план.")
                                .inkText(.subheadline, weight: .medium)
                                .foregroundColor(Ink.Colors.muted)
                        }
                        .padding(Ink.Metrics.page)
                    }
                    .navigationTitle(exercise.baseName)
                } else {
                    Text("Упражнение уже удалено.")
                        .inkText(.body)
                        .foregroundColor(Ink.Colors.muted)
                }
            }
            .background(Ink.Colors.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .tint(Ink.Colors.accentText)
    }

    private func update(reps: Int? = nil, weight: Double?? = nil, rest: Int? = nil, step: Double? = nil) {
        store.editSession(nil) {
            try WorkoutSessionEdit.updateExercise($0, index: index, reps: reps, weightKg: weight, restSeconds: rest, weightStepKg: step)
        }
    }
}

/// Сетка колонок одинаковой ширины, как `LazyVGrid(.adaptive)`, но без ленивости: все ячейки существуют сразу,
/// поэтому экранный диктор и UI-тесты видят подходы и «+ Подход» и за краем экрана.
struct InkFlowGrid: Layout {
    var minimum: CGFloat
    var spacing: CGFloat

    private func columns(for width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimum
        let rows = layoutRows(width: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = columns(for: bounds.width)
        let cell = (bounds.width - spacing * CGFloat(count - 1)) / CGFloat(count)
        var y = bounds.minY
        for row in layoutRows(width: bounds.width, subviews: subviews) {
            for (offset, index) in row.indices.enumerated() {
                let x = bounds.minX + CGFloat(offset) * (cell + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: cell, height: row.height))
            }
            y += row.height + spacing
        }
    }

    private func layoutRows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], height: CGFloat)] {
        let count = columns(for: width)
        let cell = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        var rows: [(indices: [Int], height: CGFloat)] = []
        var start = 0
        while start < subviews.count {
            let end = min(start + count, subviews.count)
            let indices = Array(start..<end)
            let height = indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0
            rows.append((indices, height))
            start = end
        }
        return rows
    }
}
