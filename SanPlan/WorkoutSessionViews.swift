import SwiftUI

/// A set addressed by its exercise and place, for the set editor sheet.
struct WorkoutSetRef: Identifiable, Equatable {
    let exercise: Int
    let set: Int
    var id: String { "\(exercise)-\(set)" }
}

struct WorkoutIndexRef: Identifiable, Equatable {
    let index: Int
    var id: Int { index }
}

// MARK: - Running workout

/// The workout in progress: the timer, the set at hand with its weight and reps, and every exercise with its sets,
/// each of which can be ticked, corrected, removed or jumped to.
struct ActiveWorkoutView: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState

    @State private var isConfirmingFinish = false
    @State private var editingSet: WorkoutSetRef?
    @State private var editingExercise: WorkoutIndexRef?
    @State private var replacingExercise: WorkoutIndexRef?
    @State private var isAddingExercise = false

    private var current: SessionExercise { session.exercises[session.exerciseIndex] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                if let warning = store.restAlarm.warningMessage {
                    ErrorBanner(message: warning)
                }
                if let error = store.errorMessage {
                    ErrorBanner(message: error) { store.errorMessage = nil }
                }

                WorkoutTimerCard(store: store, session: session)

                CurrentSetCard(store: store, session: session)

                WorkoutActionButtons(store: store, session: session)

                SectionHeader("Упражнения")
                ForEach(session.exercises.indices, id: \.self) { index in
                    ExerciseSetsCard(
                        store: store,
                        session: session,
                        index: index,
                        onEditSet: { editingSet = WorkoutSetRef(exercise: index, set: $0) },
                        onEditTarget: { editingExercise = WorkoutIndexRef(index: index) },
                        onReplace: { replacingExercise = WorkoutIndexRef(index: index) }
                    )
                }

                PillButton("Добавить упражнение", icon: "plus", style: .secondary) {
                    isAddingExercise = true
                }

                Button("Завершить досрочно") {
                    isConfirmingFinish = true
                }
                .font(.footnote)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget)
                .confirmationDialog(
                    "Завершить тренировку досрочно?",
                    isPresented: $isConfirmingFinish,
                    titleVisibility: .visible
                ) {
                    Button("Завершить", role: .destructive) {
                        store.dispatch(command: .finish())
                    }
                    Button("Продолжить тренировку", role: .cancel) {}
                } message: {
                    Text("Отмеченные подходы сохранятся в истории, остальные — нет.")
                }
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.top, DS.Metrics.spacing8)
            .padding(.bottom, 96)
        }
        .sensoryFeedback(trigger: session.phase) { old, new in
            WorkoutHaptics.feedback(from: old, to: new)
        }
        .sheet(item: $editingSet) { ref in
            SetEditorSheet(store: store, ref: ref)
                .presentationDetents([.medium])
        }
        .sheet(item: $editingExercise) { ref in
            ExerciseTargetSheet(store: store, index: ref.index)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $replacingExercise) { ref in
            ExerciseLibrarySheet { name in
                guard let exercise = newSessionExercise(name) else { return }
                store.editSession("Упражнение заменено") { try WorkoutSessionEdit.replaceExercise($0, index: ref.index, with: exercise) }
            }
        }
        .sheet(isPresented: $isAddingExercise) {
            ExerciseLibrarySheet { name in
                guard let exercise = newSessionExercise(name) else { return }
                store.editSession("Упражнение добавлено") { try WorkoutSessionEdit.addExercise($0, exercise) }
            }
        }
    }

    /// A new exercise with the builder's defaults and last time's results from the history.
    private func newSessionExercise(_ name: String) -> SessionExercise? {
        let defaults = WorkoutProgram.defaults(of: store.program)
        guard let exercise = try? WorkoutSessionEdit.newExercise(
            name: name,
            sets: defaults.sets,
            reps: WorkoutProgram.defaultReps,
            restSeconds: defaults.restBetweenSets,
            restAfterExercise: defaults.restBetweenExercises
        ) else { return nil }
        return WorkoutHistory.prepared([exercise], history: store.records).first
    }
}

/// The phase, the set in progress and both clocks: the whole workout and the set or rest.
struct WorkoutTimerCard: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let now = max(session.lastNow, Int64(context.date.timeIntervalSince1970 * 1000))
            let remaining = (try? WorkoutDomain.remainingSeconds(state: session, now: now)) ?? 0
            let elapsed = WorkoutDomain.elapsedWorkSeconds(state: session, now: now)
            let total = WorkoutDomain.totalElapsedSeconds(state: session, now: now)
            let exercise = session.exercises[session.exerciseIndex]

            Card {
                VStack(spacing: DS.Metrics.spacing8) {
                    HStack {
                        Label(total.map(WorkoutFormat.clock) ?? "—", systemImage: "stopwatch")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundColor(DS.Colors.textSecondary)
                            .accessibilityLabel("Идёт тренировка: \(total.map(WorkoutFormat.duration) ?? "—")")
                        Spacer()
                        Text("Подход \(session.setIndex + 1) из \(exercise.rests.count)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    Text(phaseTitle(session.phase))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(phaseColor(session.phase))
                    Text(exercise.name)
                        .font(.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                        .multilineTextAlignment(.center)
                    ZStack(alignment: .bottom) {
                        ARNAProgressMark(
                            progress: WorkoutProgress.fraction(session, remainingSeconds: remaining),
                            tint: session.phase == .alerting ? DS.Colors.positive : DS.Colors.accent,
                            track: DS.Colors.textSecondary.opacity(0.18)
                        )
                        .frame(width: 220, height: 166)
                        Text(timerText(seconds: elapsed ?? remaining, hasStopwatch: elapsed != nil))
                            .font(.system(size: 48, weight: .light, design: .rounded).monospacedDigit())
                            .foregroundColor(DS.Colors.textPrimary)
                            .contentTransition(.numericText(countsDown: elapsed == nil))
                            .animation(.snappy, value: elapsed ?? remaining)
                            .padding(.bottom, DS.Metrics.spacing4)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
            .onChange(of: context.date) { _, _ in
                if session.phase == .preparing || session.phase == .resting,
                   let deadline = session.deadline, now >= deadline {
                    store.dispatch(command: .tick(), now: now)
                }
            }
        }
    }

    private func timerText(seconds: Int, hasStopwatch: Bool) -> String {
        if session.phase == .working && !hasStopwatch { return "—:—" }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func phaseTitle(_ phase: WorkoutPhase) -> String {
        switch phase {
        case .preparing: return "Подготовка"
        case .working: return "Рабочий подход"
        case .resting: return "Отдых"
        case .paused: return "Отдых на паузе"
        case .alerting: return "Отдых окончен"
        case .complete: return "Завершено"
        }
    }

    private func phaseColor(_ phase: WorkoutPhase) -> Color {
        switch phase {
        case .alerting: return DS.Colors.positive
        case .paused: return DS.Colors.warning
        case .resting: return DS.Colors.accent
        default: return DS.Colors.textPrimary
        }
    }
}

/// Weight and reps of the set at hand: today's target before it, what was done during the rest after it.
/// Prefilled from last time or the plan; the steppers correct it.
struct CurrentSetCard: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState

    var body: some View {
        let index = session.exerciseIndex
        let set = session.setIndex
        let exercise = session.exercises[index]
        let after = session.phase == .resting || session.phase == .paused || session.phase == .alerting
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                Text(after ? "Подход \(set + 1): сколько сделали" : "Подход \(set + 1): цель")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                SetValueSteppers(store: store, exercise: index, set: set)
                if let last = lastTimeText(exercise) {
                    Text("В прошлый раз: \(last)")
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(DS.Colors.textSecondary)
                }
                if exercise.progressed == true {
                    Label(progressionText(exercise), systemImage: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(DS.Colors.positive)
                }
            }
        }
    }

    private func lastTimeText(_ exercise: SessionExercise) -> String? {
        guard let last = exercise.lastTime?.filter(\.done), !last.isEmpty else { return nil }
        return last.map { WorkoutFormat.set(weight: $0.weightKg, reps: $0.reps, bodyweight: exercise.bodyweight ?? false) }
            .joined(separator: " · ")
    }

    private func progressionText(_ exercise: SessionExercise) -> String {
        if exercise.bodyweight == true && (exercise.weightKg ?? 0) == 0 {
            return "В прошлый раз все подходы сделаны: попробуйте +1 повтор"
        }
        let step = exercise.weightStepKg ?? WorkoutSessionEdit.defaultStepKg
        return "В прошлый раз все подходы сделаны: +\(WorkoutFormat.kilograms(step))"
    }
}

/// «Вес» and «Повторы» steppers for one logged set. Weight moves by the exercise's step.
struct SetValueSteppers: View {
    @ObservedObject var store: WorkoutStore
    let exercise: Int
    let set: Int

    var body: some View {
        if let session = store.activeSession,
           session.exercises.indices.contains(exercise),
           session.exercises[exercise].rests.indices.contains(set) {
            let item = session.exercises[exercise]
            let entry = item.sets[set]
            let suggested = item.suggestedValues(for: set)
            let weight = entry.weightKg ?? suggested.weightKg
            let reps = entry.reps ?? suggested.reps ?? 0
            let bodyweight = item.bodyweight ?? false
            let step = item.weightStepKg ?? WorkoutSessionEdit.defaultStepKg
            VStack(spacing: DS.Metrics.spacing4) {
                ValueStepperRow(
                    title: bodyweight ? "Доп. вес" : "Вес",
                    value: WorkoutFormat.weight(weight, bodyweight: bodyweight),
                    canDecrease: (weight ?? 0) > 0,
                    canIncrease: (weight ?? 0) < WorkoutSessionEdit.weightRange.upperBound,
                    onDecrease: { setWeight(max(0, (weight ?? 0) - step)) },
                    onIncrease: { setWeight(min(WorkoutSessionEdit.weightRange.upperBound, (weight ?? 0) + step)) }
                )
                ValueStepperRow(
                    title: "Повторы",
                    value: "\(reps)",
                    canDecrease: reps > 0,
                    canIncrease: reps < WorkoutSessionEdit.repsRange.upperBound,
                    onDecrease: { setReps(reps - 1) },
                    onIncrease: { setReps(reps + 1) }
                )
            }
        }
    }

    private func setWeight(_ value: Double) {
        store.editSession(nil) { try WorkoutSessionEdit.setValues($0, exercise: exercise, set: set, weightKg: value) }
    }

    private func setReps(_ value: Int) {
        store.editSession(nil) { try WorkoutSessionEdit.setValues($0, exercise: exercise, set: set, reps: value) }
    }
}

/// The main button for the phase and the rest controls under it.
struct WorkoutActionButtons: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState

    var body: some View {
        VStack(spacing: DS.Metrics.spacing12) {
            primary
            HStack(spacing: DS.Metrics.spacing16) {
                if session.phase == .resting {
                    CircleIconButton(icon: "pause.fill", accessibilityLabel: "Пауза") {
                        store.dispatch(command: .pause())
                    }
                    CircleIconButton(icon: "goforward.30", accessibilityLabel: "Добавить 30 секунд") {
                        store.dispatch(command: .adjust(seconds: 30))
                    }
                    CircleIconButton(icon: "goforward.60", accessibilityLabel: "Добавить 60 секунд") {
                        store.dispatch(command: .adjust(seconds: 60))
                    }
                } else if session.phase == .paused {
                    CircleIconButton(icon: "goforward.30", accessibilityLabel: "Добавить 30 секунд") {
                        store.dispatch(command: .adjust(seconds: 30))
                    }
                    CircleIconButton(icon: "forward.end.fill", accessibilityLabel: "Пропустить отдых") {
                        store.dispatch(command: .skipRest())
                    }
                } else if session.phase == .alerting {
                    CircleIconButton(icon: "arrow.counterclockwise", accessibilityLabel: "Повторить отдых") {
                        store.dispatch(command: .repeatRest())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var primary: some View {
        let last = WorkoutDomain.isLastSet(session)
        switch session.phase {
        case .preparing:
            VStack(spacing: DS.Metrics.spacing12) {
                PillButton("Начать сейчас", icon: "play.fill") {
                    store.dispatch(command: .startNow())
                }
                if !last {
                    PillButton("Подход сделан, отдых", icon: "bed.double.fill", style: .secondary) {
                        store.dispatch(command: .startRest())
                    }
                }
            }
        case .working:
            if last {
                finishButton
            } else {
                PillButton("Подход сделан, отдых", icon: "bed.double.fill") {
                    store.dispatch(command: .startRest())
                }
            }
        case .resting:
            PillButton("Пропустить отдых", icon: "forward.fill", style: .secondary) {
                store.dispatch(command: .skipRest())
            }
        case .paused:
            PillButton("Продолжить", icon: "play.fill") {
                store.dispatch(command: .resume())
            }
        case .alerting:
            if last {
                finishButton
            } else {
                VStack(spacing: DS.Metrics.spacing12) {
                    PillButton("Начать подход", icon: "play.fill") {
                        store.dispatch(command: .acknowledge())
                    }
                    // For a set already done while the alert was showing.
                    PillButton("Подход сделан, отдых", icon: "bed.double.fill", style: .secondary) {
                        store.dispatch(command: .startRest())
                    }
                }
            }
        case .complete:
            EmptyView()
        }
    }

    /// The last set: nothing follows it, so the button says the workout ends and counts the set as done.
    private var finishButton: some View {
        PillButton("Подход сделан, завершить", icon: "checkmark") {
            store.dispatch(command: .finishSet())
        }
    }
}

/// One exercise and its sets. A tap on the circle ticks a set or takes the tick back; a tap on the row opens it.
struct ExerciseSetsCard: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState
    let index: Int
    let onEditSet: (Int) -> Void
    let onEditTarget: () -> Void
    let onReplace: () -> Void

    private var exercise: SessionExercise { session.exercises[index] }
    private var isRunning: Bool { session.phase != .complete }

    var body: some View {
        let isCurrent = isRunning && index == session.exerciseIndex
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing4) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.baseName)
                            .font(.headline)
                            .foregroundColor(isCurrent ? DS.Colors.accent : DS.Colors.textPrimary)
                        Text(targetText)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(exercise.doneCount)/\(exercise.rests.count)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundColor(DS.Colors.textSecondary)
                    menu
                }
                ForEach(exercise.rests.indices, id: \.self) { set in
                    setRow(set, isCurrent: isCurrent && set == session.setIndex)
                }
                Button {
                    store.editSession("Подход добавлен") { try WorkoutSessionEdit.addSet($0, exercise: index) }
                } label: {
                    Label("Подход", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: DS.Metrics.minHitTarget)
                }
                .foregroundColor(DS.Colors.accent)
                .disabled(exercise.rests.count >= 100)
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
                .font(.body.weight(.semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
        }
        .accessibilityLabel("Действия с упражнением \(exercise.baseName)")
    }

    private func setRow(_ set: Int, isCurrent: Bool) -> some View {
        let entry = exercise.sets[set]
        let suggested = exercise.suggestedValues(for: set)
        let bodyweight = exercise.bodyweight ?? false
        let text = WorkoutFormat.set(
            weight: entry.weightKg ?? suggested.weightKg,
            reps: entry.reps ?? suggested.reps,
            bodyweight: bodyweight
        )
        return HStack(spacing: DS.Metrics.spacing8) {
            Button {
                let done = !entry.done
                store.editSession(done ? "Подход отмечен" : "Отметка снята") {
                    try WorkoutSessionEdit.setDone($0, exercise: index, set: set, done: done, now: WorkoutStore.nowMs())
                }
            } label: {
                Image(systemName: entry.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(entry.done ? DS.Colors.positive : DS.Colors.textSecondary)
                    .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.done ? "Подход \(set + 1) сделан, снять отметку" : "Отметить подход \(set + 1)")

            Button {
                onEditSet(set)
            } label: {
                HStack {
                    Text("Подход \(set + 1)")
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? DS.Colors.accent : DS.Colors.textPrimary)
                    Spacer()
                    Text(text)
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(entry.done ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(DS.Colors.textSecondary.opacity(0.6))
                }
                .frame(minHeight: DS.Metrics.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Подход \(set + 1): \(text)\(isCurrent ? ", сейчас" : "")")
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
                        VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                            SetValueSteppers(store: store, exercise: ref.exercise, set: ref.set)
                            Toggle("Подход сделан", isOn: Binding(
                                get: { entry.done },
                                set: { done in
                                    store.editSession(done ? "Подход отмечен" : "Отметка снята") {
                                        try WorkoutSessionEdit.setDone($0, exercise: ref.exercise, set: ref.set, done: done, now: WorkoutStore.nowMs())
                                    }
                                }
                            ))
                            .tint(DS.Colors.controlTint)
                            if session.phase != .complete {
                                PillButton("Перейти к этому подходу", icon: "arrow.right.circle", style: .secondary) {
                                    store.editSession("Переход к подходу") {
                                        try WorkoutSessionEdit.jump($0, exercise: ref.exercise, set: ref.set, now: WorkoutStore.nowMs())
                                    }
                                    dismiss()
                                }
                            }
                            if exercise.rests.count > 1 {
                                PillButton("Удалить подход", icon: "trash", style: .destructive) {
                                    store.editSession("Подход удалён") {
                                        try WorkoutSessionEdit.removeSet($0, exercise: ref.exercise, set: ref.set)
                                    }
                                    dismiss()
                                }
                            }
                        }
                        .padding(DS.Metrics.screenGutter)
                    }
                    .navigationTitle("\(exercise.baseName) · подход \(ref.set + 1)")
                } else {
                    Text("Подход уже удалён.")
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .background(DS.Colors.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
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
                        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                            ValueStepperRow(
                                title: "Повторы",
                                value: "\(reps)",
                                canDecrease: reps > WorkoutProgram.repsRange.lowerBound,
                                canIncrease: reps < WorkoutProgram.repsRange.upperBound,
                                onDecrease: { update(reps: reps - 1) },
                                onIncrease: { update(reps: reps + 1) }
                            )
                            ValueStepperRow(
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
                            ValueStepperRow(
                                title: "Отдых между подходами",
                                value: WorkoutFormat.rest(rest),
                                canDecrease: rest > WorkoutProgram.restRange.lowerBound,
                                canIncrease: rest < WorkoutProgram.restRange.upperBound,
                                onDecrease: { update(rest: rest - WorkoutProgram.restStep) },
                                onIncrease: { update(rest: rest + WorkoutProgram.restStep) }
                            )
                            ValueStepperRow(
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
                            .tint(DS.Colors.controlTint)
                            Text("Меняется только эта тренировка. В конце можно сохранить изменения в план.")
                                .font(.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        .padding(DS.Metrics.screenGutter)
                    }
                    .navigationTitle(exercise.baseName)
                } else {
                    Text("Упражнение уже удалено.")
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .background(DS.Colors.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func update(reps: Int? = nil, weight: Double?? = nil, rest: Int? = nil, step: Double? = nil) {
        store.editSession(nil) {
            try WorkoutSessionEdit.updateExercise($0, index: index, reps: reps, weightKg: weight, restSeconds: rest, weightStepKg: step)
        }
    }
}

// MARK: - Finished workout

/// What was done, how long it took, the sets for last corrections, and «Сохранить изменения в план» when it differed.
struct WorkoutSummaryView: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState

    @State private var editingSet: WorkoutSetRef?
    @State private var editingExercise: WorkoutIndexRef?
    @State private var replacingExercise: WorkoutIndexRef?

    var body: some View {
        let done = session.exercises.reduce(0) { $0 + $1.doneCount }
        let planned = session.exercises.reduce(0) { $0 + $1.rests.count }
        let seconds = WorkoutDomain.totalElapsedSeconds(state: session, now: session.endedAt ?? session.lastNow) ?? 0
        let record = WorkoutHistory.record(from: session, now: session.endedAt ?? session.lastNow)

        ScrollView {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                if let error = store.errorMessage {
                    ErrorBanner(message: error) { store.errorMessage = nil }
                }
                VStack(spacing: DS.Metrics.spacing8) {
                    Image(systemName: done == planned ? "checkmark.circle.fill" : "flag.checkered")
                        .font(.system(size: 48))
                        .foregroundColor(done == 0 ? DS.Colors.textSecondary : DS.Colors.positive)
                    Text("Тренировка завершена")
                        .font(.title.weight(.light))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(done == planned ? "Все подходы сделаны." : "\(done) из \(planned) подходов.")
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: DS.Metrics.spacing8) {
                    WorkoutStatTile(title: "Время", value: WorkoutFormat.duration(seconds))
                    WorkoutStatTile(title: "Подходы", value: "\(done)/\(planned)")
                    WorkoutStatTile(title: "Тоннаж", value: WorkoutFormat.tonnage(record?.tonnageKg ?? 0))
                }

                if done == 0 {
                    Card {
                        Text("Ни один подход не отмечен, поэтому в историю тренировка не попадёт. Отметьте сделанные подходы ниже или закройте её.")
                            .font(.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }

                if store.pendingPlanChanges != nil {
                    Card {
                        VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                            Text("Тренировка отличалась от плана")
                                .font(.headline)
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Упражнения, подходы, повторы, вес или отдых менялись по ходу. Без сохранения план останется прежним.")
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.textSecondary)
                            PillButton("Сохранить изменения в план", icon: "square.and.arrow.down", style: .secondary) {
                                store.saveSessionChangesToPlan()
                            }
                        }
                    }
                }

                SectionHeader("Упражнения")
                ForEach(session.exercises.indices, id: \.self) { index in
                    ExerciseSetsCard(
                        store: store,
                        session: session,
                        index: index,
                        onEditSet: { editingSet = WorkoutSetRef(exercise: index, set: $0) },
                        onEditTarget: { editingExercise = WorkoutIndexRef(index: index) },
                        onReplace: { replacingExercise = WorkoutIndexRef(index: index) }
                    )
                }

                PillButton(done == 0 ? "Закрыть без сохранения" : "Готово", icon: "checkmark") {
                    store.discardWorkout()
                }
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.vertical, DS.Metrics.spacing16)
            .padding(.bottom, 80)
        }
        .sheet(item: $editingSet) { ref in
            SetEditorSheet(store: store, ref: ref)
                .presentationDetents([.medium])
        }
        .sheet(item: $editingExercise) { ref in
            ExerciseTargetSheet(store: store, index: ref.index)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $replacingExercise) { ref in
            ExerciseLibrarySheet { name in
                guard let exercise = try? WorkoutSessionEdit.newExercise(
                    name: name, sets: 1, reps: WorkoutProgram.defaultReps, restSeconds: 60, restAfterExercise: 60
                ) else { return }
                store.editSession("Упражнение заменено") { try WorkoutSessionEdit.replaceExercise($0, index: ref.index, with: exercise) }
            }
        }
    }
}

struct WorkoutStatTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var detailColor: Color = DS.Colors.textSecondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(DS.Colors.textSecondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(detailColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Metrics.spacing12)
        .background(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius).fill(DS.Colors.surface))
        .accessibilityElement(children: .combine)
    }
}

/// «Отменить» for the last change, at the bottom of the workout section for five seconds.
struct WorkoutUndoToast: View {
    @ObservedObject var store: WorkoutStore

    var body: some View {
        ZStack {
            if let offer = store.undoOffer {
                HStack(spacing: DS.Metrics.spacing12) {
                    Text(offer.label)
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Отменить") {
                        store.undoLast()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(DS.Colors.accent)
                    .frame(minHeight: DS.Metrics.minHitTarget)
                }
                .padding(.horizontal, DS.Metrics.spacing16)
                .background(
                    RoundedRectangle(cornerRadius: DS.Metrics.innerRadius)
                        .fill(DS.Colors.surfaceRaised)
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                )
                .padding(.horizontal, DS.Metrics.screenGutter)
                .padding(.bottom, DS.Metrics.spacing8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: offer.id) {
                    try? await Task.sleep(for: .seconds(5))
                    store.dismissUndo(offer.id)
                }
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.snappy, value: store.undoOffer)
    }
}
