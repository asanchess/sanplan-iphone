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

/// The workout in progress. Only the exercise at hand is large: the timer, its name, the main button and its sets.
/// Every other exercise, and editing them, lives in the «Все упражнения» panel. «Завершить» stays at the top;
/// before the first set is ticked it is «Закрыть без сохранения».
struct ActiveWorkoutView: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState

    @State private var isConfirmingFinish = false
    @State private var showsAllExercises = false
    @State private var editingSet: WorkoutSetRef?
    @State private var editingExercise: WorkoutIndexRef?
    @State private var replacingExercise: WorkoutIndexRef?
    @State private var isAddingExercise = false

    private var doneSets: Int { session.exercises.reduce(0) { $0 + $1.doneCount } }
    private var plannedSets: Int { session.exercises.reduce(0) { $0 + $1.rests.count } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                topBar

                if let warning = store.restAlarm.warningMessage {
                    ErrorBanner(message: warning)
                }
                if let error = store.errorMessage {
                    ErrorBanner(message: error) { store.errorMessage = nil }
                }

                WorkoutTimerCard(store: store, session: session)

                // During a rest its controls (+30 s, pause, skip) come right under the timer, above the set's numbers.
                if session.phase == .resting || session.phase == .paused || session.phase == .alerting {
                    WorkoutActionButtons(store: store, session: session)
                    CurrentSetCard(store: store, session: session)
                } else {
                    CurrentSetCard(store: store, session: session)
                    WorkoutActionButtons(store: store, session: session)
                }

                ExerciseSetsCard(
                    store: store,
                    session: session,
                    index: session.exerciseIndex,
                    onEditSet: { editingSet = WorkoutSetRef(exercise: session.exerciseIndex, set: $0) },
                    onEditTarget: { editingExercise = WorkoutIndexRef(index: session.exerciseIndex) },
                    onReplace: { replacingExercise = WorkoutIndexRef(index: session.exerciseIndex) },
                    showsName: false
                )

                allExercisesPanel
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.top, DS.Metrics.spacing8)
            .padding(.bottom, 108)
        }
        .sensoryFeedback(trigger: session.phase) { old, new in
            WorkoutHaptics.feedback(from: old, to: new)
        }
        .confirmationDialog(
            "Завершить тренировку?",
            isPresented: $isConfirmingFinish,
            titleVisibility: .visible
        ) {
            Button("Завершить и сохранить") {
                store.dispatch(command: .finish())
            }
            Button("Продолжить тренировку", role: .cancel) {}
        } message: {
            Text("Отмеченные подходы сохранятся в истории, остальные — нет.")
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

    /// «Вся тренировка: 12:40» and the finish button, always on top.
    private var topBar: some View {
        HStack(spacing: DS.Metrics.spacing12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = max(session.lastNow, Int64(context.date.timeIntervalSince1970 * 1000))
                let total = WorkoutDomain.totalElapsedSeconds(state: session, now: now)
                Text("Вся тренировка: \(total.map(WorkoutFormat.clock) ?? "—")")
                    .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                    .monospacedDigit()
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel("Идёт тренировка: \(total.map(WorkoutFormat.duration) ?? "—")")
            }
            Spacer(minLength: 0)
            finishButton
        }
    }

    /// Nothing ticked yet: closing keeps nothing, and «Отменить» at the bottom brings it back.
    /// Something ticked: finishing asks first and saves the ticked sets.
    private var finishButton: some View {
        let title = doneSets == 0 ? "Закрыть без сохранения" : "Завершить"
        return Button {
            if doneSets == 0 {
                store.discardWorkout()
            } else {
                isConfirmingFinish = true
            }
        } label: {
            Text(title)
                .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 14)
                .frame(minHeight: DS.Metrics.minHitTarget)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.Colors.hairline, lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(title)
        .accessibilityIdentifier("workout-finish")
    }

    /// The other exercises, folded by default: each opens to its sets and its menu (target, replace, move, delete, go to it).
    private var allExercisesPanel: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            Button {
                withAnimation(.snappy) { showsAllExercises.toggle() }
            } label: {
                HStack {
                    TrainingKicker(text: "Все упражнения")
                    Text("\(doneSets)/\(plannedSets)")
                        .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                        .monospacedDigit()
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Image(systemName: showsAllExercises ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(minHeight: DS.Metrics.minHitTarget)
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Colors.surface))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Все упражнения: \(session.exercises.count), подходов сделано \(doneSets) из \(plannedSets)")
            .accessibilityHint(showsAllExercises ? "Свернуть" : "Развернуть")

            if showsAllExercises {
                ForEach(session.exercises.indices, id: \.self) { index in
                    if index != session.exerciseIndex {
                        ExerciseSetsCard(
                            store: store,
                            session: session,
                            index: index,
                            onEditSet: { editingSet = WorkoutSetRef(exercise: index, set: $0) },
                            onEditTarget: { editingExercise = WorkoutIndexRef(index: index) },
                            onReplace: { replacingExercise = WorkoutIndexRef(index: index) },
                            startsExpanded: false
                        )
                    }
                }
                PillButton("Добавить упражнение", icon: "plus", style: .secondary) {
                    isAddingExercise = true
                }
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

/// The exercise at hand, large: its name, last time, the progression hint and the weight and reps of the current set.
/// Today's target before the set, what was done during the rest after it. The steppers correct it.
struct CurrentSetCard: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState

    var body: some View {
        let index = session.exerciseIndex
        let set = session.setIndex
        let exercise = session.exercises[index]
        let after = session.phase == .resting || session.phase == .paused || session.phase == .alerting
        VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
            Text(exercise.name)
                .font(DS.Fonts.text(22, .heavy, relativeTo: .title2))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let last = lastTimeText(exercise) {
                Text("В прошлый раз: \(last)")
                    .font(DS.Fonts.text(16, .medium, relativeTo: .subheadline))
                    .monospacedDigit()
                    .foregroundColor(DS.Colors.textSecondary)
            }
            if exercise.progressed == true {
                Label(progressionText(exercise), systemImage: "arrow.up.right")
                    .font(DS.Fonts.text(14, .semibold, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.positive)
            }
            TrainingKicker(text: after ? "Подход \(set + 1): сколько сделали" : "Подход \(set + 1): цель")
                .padding(.top, DS.Metrics.spacing4)
            SetValueSteppers(store: store, exercise: index, set: set)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Metrics.cardRadius, style: .continuous).fill(DS.Colors.surface))
    }

    private func lastTimeText(_ exercise: SessionExercise) -> String? {
        guard let last = exercise.lastTime?.filter(\.done), !last.isEmpty else { return nil }
        return WorkoutFormat.sets(last.map { ($0.weightKg, $0.reps) }, bodyweight: exercise.bodyweight ?? false)
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
            let knownReps = entry.reps ?? suggested.reps
            let reps = knownReps ?? 0
            let bodyweight = item.bodyweight ?? false
            let step = item.weightStepKg ?? WorkoutSessionEdit.defaultStepKg
            VStack(spacing: DS.Metrics.spacing4) {
                ValueStepperRow(
                    title: bodyweight ? "Доп. вес" : "Вес",
                    value: WorkoutFormat.weight(weight, bodyweight: bodyweight),
                    canDecrease: (weight ?? 0) > 0,
                    canIncrease: (weight ?? 0) < WorkoutSessionEdit.weightRange.upperBound,
                    onDecrease: { setWeight(max(0, (weight ?? 0) - step)) },
                    onIncrease: { setWeight(min(WorkoutSessionEdit.weightRange.upperBound, (weight ?? 0) + step)) },
                    onEnter: { text in
                        guard let value = ValueStepperRow.number(text), WorkoutSessionEdit.weightRange.contains(value) else { return false }
                        setWeight(value)
                        return true
                    },
                    allowsDecimal: true
                )
                ValueStepperRow(
                    title: "Повторы",
                    value: knownReps.map(String.init) ?? "—",
                    canDecrease: reps > 0,
                    canIncrease: reps < WorkoutSessionEdit.repsRange.upperBound,
                    onDecrease: { setReps(reps - 1) },
                    onIncrease: { setReps(reps + 1) },
                    onEnter: { text in
                        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), WorkoutSessionEdit.repsRange.contains(value) else { return false }
                        setReps(value)
                        return true
                    }
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
            HStack(spacing: DS.Metrics.spacing12) {
                if session.phase == .resting {
                    TrainingOutlineButton(title: "Пауза", icon: "pause.fill") {
                        store.dispatch(command: .pause())
                    }
                    TrainingOutlineButton(title: "+30 сек", accessibilityTitle: "Добавить 30 секунд") {
                        store.dispatch(command: .adjust(seconds: 30))
                    }
                    TrainingOutlineButton(title: "+60 сек", accessibilityTitle: "Добавить 60 секунд") {
                        store.dispatch(command: .adjust(seconds: 60))
                    }
                } else if session.phase == .paused {
                    TrainingOutlineButton(title: "+30 сек", accessibilityTitle: "Добавить 30 секунд") {
                        store.dispatch(command: .adjust(seconds: 30))
                    }
                    TrainingOutlineButton(title: "Пропустить", icon: "forward.end.fill", accessibilityTitle: "Пропустить отдых") {
                        store.dispatch(command: .skipRest())
                    }
                } else if session.phase == .alerting {
                    TrainingOutlineButton(title: "Ещё отдых", icon: "arrow.counterclockwise", accessibilityTitle: "Повторить отдых") {
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
                TrainingMainButton(title: "Начать сейчас", icon: "play.fill") {
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
                TrainingMainButton(title: "Подход сделан, отдых", icon: "bed.double.fill") {
                    store.dispatch(command: .startRest())
                }
            }
        case .resting:
            PillButton("Пропустить отдых", icon: "forward.fill", style: .secondary) {
                store.dispatch(command: .skipRest())
            }
        case .paused:
            TrainingMainButton(title: "Продолжить", icon: "play.fill") {
                store.dispatch(command: .resume())
            }
        case .alerting:
            if last {
                finishButton
            } else {
                VStack(spacing: DS.Metrics.spacing12) {
                    TrainingMainButton(title: "Начать подход", icon: "play.fill") {
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
        TrainingMainButton(title: "Подход сделан, завершить", icon: "checkmark") {
            store.dispatch(command: .finishSet())
        }
    }
}

/// One exercise and its sets. A tap on the circle ticks a set or takes the tick back; a tap on the row opens it.
/// Folded (in «Все упражнения») it shows the name, the target and the count; a tap on the head opens the sets.
struct ExerciseSetsCard: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState
    let index: Int
    let onEditSet: (Int) -> Void
    let onEditTarget: () -> Void
    let onReplace: () -> Void
    /// False for the exercise at hand, whose name is already large above.
    var showsName: Bool = true
    var startsExpanded: Bool = true

    @State private var expandedOverride: Bool? = nil
    /// The set being dragged by its ≡ handle, how far, and the height of one row with the gap.
    @State private var draggingSet: Int? = nil
    @State private var dragY: CGFloat = 0
    @State private var rowPitch: CGFloat = 48
    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var exercise: SessionExercise { session.exercises[index] }

    /// Where the dragged set would land now.
    private var dropIndex: Int? {
        guard let from = draggingSet, rowPitch > 0 else { return nil }
        let steps = Int((dragY / rowPitch).rounded())
        return min(max(from + steps, 0), exercise.rests.count - 1)
    }

    /// The dragged row follows the finger; the rows it passes step aside by one row.
    private func shift(of set: Int) -> CGFloat {
        guard let from = draggingSet, let to = dropIndex else { return 0 }
        if set == from { return dragY }
        if from < set && set <= to { return -rowPitch }
        if to <= set && set < from { return rowPitch }
        return 0
    }

    private func moveSet(from: Int, to: Int) {
        guard from != to, exercise.rests.indices.contains(to) else { return }
        store.editSession("Подход перемещён") { try WorkoutSessionEdit.moveSet($0, exercise: index, from: from, to: to) }
    }

    /// ≡: drag a set up or down. VoiceOver gets «Выше» and «Ниже» instead.
    private func handle(_ set: Int) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.body.weight(.semibold))
            .foregroundColor(draggingSet == set ? accent : DS.Colors.textSecondary.opacity(0.7))
            .frame(width: 30, height: DS.Metrics.minHitTarget)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if draggingSet == nil {
                            draggingSet = set
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        let before = dropIndex
                        dragY = value.translation.height
                        if dropIndex != before { UISelectionFeedbackGenerator().selectionChanged() }
                    }
                    .onEnded { _ in
                        let from = draggingSet
                        let to = dropIndex
                        var still = Transaction()
                        still.disablesAnimations = true
                        withTransaction(still) {
                            if let from, let to { moveSet(from: from, to: to) }
                            draggingSet = nil
                            dragY = 0
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Переместить подход \(set + 1)")
            .accessibilityAction(named: "Выше") { moveSet(from: set, to: set - 1) }
            .accessibilityAction(named: "Ниже") { moveSet(from: set, to: set + 1) }
    }

    /// «…» of a set: only edit and delete.
    private func setMenu(_ set: Int) -> some View {
        Menu {
            Button { onEditSet(set) } label: { Label("Редактировать", systemImage: "pencil") }
            if exercise.rests.count > 1 {
                Button(role: .destructive) {
                    store.editSession("Подход удалён") { try WorkoutSessionEdit.removeSet($0, exercise: index, set: set) }
                } label: { Label("Удалить подход", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 36, height: DS.Metrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Действия с подходом \(set + 1)")
        .accessibilityIdentifier("set-menu-\(index)-\(set)")
    }
    private var isRunning: Bool { session.phase != .complete }
    private var isExpanded: Bool { expandedOverride ?? startsExpanded }

    var body: some View {
        let isCurrent = isRunning && index == session.exerciseIndex
        VStack(alignment: .leading, spacing: DS.Metrics.spacing4) {
            HStack(alignment: .center, spacing: DS.Metrics.spacing12) {
                Text("\(index + 1)")
                    .font(DS.Fonts.text(15, .heavy, relativeTo: .subheadline))
                    .foregroundColor(accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(TrainingPalette.badge))
                    .accessibilityHidden(true)
                Button {
                    withAnimation(.snappy) { expandedOverride = !isExpanded }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        if showsName {
                            Text(exercise.baseName)
                                .font(DS.Fonts.text(17, .semibold, relativeTo: .headline))
                                .foregroundColor(isCurrent ? accent : DS.Colors.textPrimary)
                                .multilineTextAlignment(.leading)
                        } else {
                            TrainingKicker(text: "Подходы")
                        }
                        Text(targetText)
                            .font(DS.Fonts.text(13, .medium, relativeTo: .caption))
                            .monospacedDigit()
                            .foregroundColor(DS.Colors.textSecondary)
                            .multilineTextAlignment(.leading)
                        if let best = store.bestWeight(exercise: exercise.baseName) {
                            Text("Рекорд: \(WorkoutFormat.kilograms(best))")
                                .font(DS.Fonts.text(13, .medium, relativeTo: .caption))
                                .monospacedDigit()
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Свернуть подходы" : "Показать подходы")
                Text("\(exercise.doneCount)/\(exercise.rests.count)")
                    .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                    .monospacedDigit()
                    .foregroundColor(DS.Colors.textSecondary)
                menu
            }
            if isExpanded {
                ForEach(exercise.rests.indices, id: \.self) { set in
                    setRow(set, isCurrent: isCurrent && set == session.setIndex)
                        .offset(y: shift(of: set))
                        .zIndex(draggingSet == set ? 1 : 0)
                        .background {
                            if draggingSet == set {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(DS.Colors.surfaceRaised)
                                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                                    .offset(y: dragY)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if set == 0 { rowPitch = height + DS.Metrics.spacing4 }
                        }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: dropIndex)
                Button {
                    store.editSession("Подход добавлен") { try WorkoutSessionEdit.addSet($0, exercise: index) }
                } label: {
                    Label("Подход", systemImage: "plus")
                        .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                        .frame(minHeight: DS.Metrics.minHitTarget)
                }
                .accessibilityLabel("Добавить подход: \(exercise.baseName)")
                .foregroundColor(accent)
                .disabled(exercise.rests.count >= 100)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Colors.surface))
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
        return HStack(spacing: DS.Metrics.spacing4) {
            if exercise.rests.count > 1 { handle(set) }
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
            .sensoryFeedback(trigger: entry.done) { _, isDone in
                let tap: SensoryFeedback = isDone ? .impact(weight: .light, intensity: 0.8) : .selection
                return tap
            }
            .speedLines(on: entry.done)
            .accessibilityLabel(entry.done ? "Подход \(set + 1) сделан, снять отметку" : "Отметить подход \(set + 1)")

            Button {
                onEditSet(set)
            } label: {
                HStack {
                    Text("Подход \(set + 1)")
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? accent : DS.Colors.textPrimary)
                    Spacer()
                    Text(text)
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(entry.done ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                }
                .frame(minHeight: DS.Metrics.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Подход \(set + 1): \(text)\(isCurrent ? ", сейчас" : "")")
            setMenu(set)
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
                            .tint(DS.Colors.workout)
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
                            .tint(DS.Colors.workout)
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
    @State private var confirmingPlanReplace = false
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
                        .foregroundColor(done == 0 ? DS.Colors.textSecondary : DS.Colors.workout)
                    Text("Тренировка завершена")
                        .font(DS.Fonts.display(26, relativeTo: .title))
                        .foregroundColor(DS.Colors.textPrimary)
                        .shadow(color: DS.Colors.drop, radius: 3, y: 2)
                        .multilineTextAlignment(.center)
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
                                // Разовая тренировка («Повторить») не заменяет день плана молча.
                                if store.planDayToReplace != nil { confirmingPlanReplace = true }
                                else { store.saveSessionChangesToPlan() }
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
        .confirmationDialog(
            "Заменить тренировку на \(store.planDayToReplace.map { $0.title ?? WorkoutFormat.weekdayNames[$0.weekday - 1] } ?? "этот день")?",
            isPresented: $confirmingPlanReplace,
            titleVisibility: .visible
        ) {
            Button("Заменить", role: .destructive) { store.saveSessionChangesToPlan() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("В плане уже есть другая тренировка на этот день недели. Она будет заменена этой.")
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
    @Environment(\.sectionAccent) private var accent

    /// The canvas stat tile: accent kicker, Dela value, a short note.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                .tracking(0.8)
                .foregroundColor(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(DS.Fonts.display(24, relativeTo: .title2))
                .monospacedDigit()
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let detail {
                Text(detail)
                    .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                    .monospacedDigit()
                    .foregroundColor(detailColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: DS.Metrics.cardRadius, style: .continuous).fill(DS.Colors.surface))
        .accessibilityElement(children: .combine)
    }
}

/// «Отменить» for the last change, at the bottom of the workout section for five seconds.
struct WorkoutUndoToast: View {
    @ObservedObject var store: WorkoutStore
    @Environment(\.sectionAccent) private var accent

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
                    .foregroundColor(accent)
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
