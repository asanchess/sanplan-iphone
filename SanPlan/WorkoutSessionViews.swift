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
/// each of which can be ticked, corrected, removed or jumped to. Оформление — «Тушь» (DESIGN-INK 11.5).
struct ActiveWorkoutView: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState

    @State private var isConfirmingFinish = false
    @State private var editingSet: WorkoutSetRef?
    @State private var editingExercise: WorkoutIndexRef?
    @State private var replacingExercise: WorkoutIndexRef?
    @State private var isAddingExercise = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: SessionExercise { session.exercises[session.exerciseIndex] }

    var body: some View {
        // Панель — соседний вид под прокруткой, а не safeAreaInset: рамка ScrollView кончается над панелью,
        // поэтому UI-тесты и диктор докручивают конец списка выше неё (с inset рамка уходила под панель).
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Metrics.stack) {
                if let warning = store.restAlarm.warningMessage {
                    InkBanner(message: warning)
                }
                if let error = store.errorMessage {
                    InkBanner(message: error) { store.errorMessage = nil }
                }

                VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                    WorkoutTimerCard(store: store, session: session)
                    CurrentSetCard(store: store, session: session)
                }
                // Место под «ДЗЫНЬ!» над кадром таймера, пока отдых окончен.
                .padding(.top, session.phase == .alerting ? 48 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: session.phase == .alerting)

                // На крупных размерах текста кнопки идут в прокрутке, иначе закреплены внизу (DESIGN-INK 11.5).
                if typeSize.isAccessibilitySize {
                    WorkoutActionButtons(store: store, session: session)
                }

                VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                    InkSectionHeader(text: "Упражнения")
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
                }

                InkButton(title: "Добавить упражнение", icon: "plus", kind: .secondary) {
                    isAddingExercise = true
                }
                finishControl.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Ink.Metrics.page)
            .padding(.top, Ink.Metrics.gutter)
            .padding(.bottom, 24)
        }
        if !typeSize.isAccessibilitySize {
            WorkoutActionButtons(store: store, session: session)
                .padding(.horizontal, Ink.Metrics.page)
                .padding(.vertical, Ink.Metrics.gutter)
                .background(Ink.Colors.bg)
                .overlay(alignment: .top) { InkRule() }
        }
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

    private var finishControl: some View {
        InkButton(title: "Завершить досрочно", kind: .text, textColor: Ink.Colors.muted) {
            isConfirmingFinish = true
        }
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
/// Кадр по фазам: подготовка — `.plain`; подход — `.tone` с линиями скорости; отдых — шкала акцентом;
/// пауза — пунктир, время `muted`; отдых окончен — `.now` (акцентный фон) и «ДЗЫНЬ!».
struct WorkoutTimerCard: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState
    @State private var sfxCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let now = max(session.lastNow, Int64(context.date.timeIntervalSince1970 * 1000))
            let remaining = (try? WorkoutDomain.remainingSeconds(state: session, now: now)) ?? 0
            let elapsed = WorkoutDomain.elapsedWorkSeconds(state: session, now: now)
            let total = WorkoutDomain.totalElapsedSeconds(state: session, now: now)
            let exercise = session.exercises[session.exerciseIndex]
            let phase = session.phase
            let alerting = phase == .alerting
            let quiet = alerting ? Ink.Colors.onAccent : Ink.Colors.muted
            let strong = alerting ? Ink.Colors.onAccent : Ink.Colors.fg

            InkPanel(panelStyle(phase), dashed: phase == .paused) {
                VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(total.map(WorkoutFormat.clock) ?? "—", systemImage: "stopwatch")
                            .inkText(.subheadline, weight: .bold, numeric: true)
                            .foregroundColor(quiet)
                            .accessibilityLabel("Идёт тренировка: \(total.map(WorkoutFormat.duration) ?? "—")")
                        Spacer()
                        Text(setHeader(exercise))
                            .inkText(.subheadline, weight: .bold, numeric: true)
                            .foregroundColor(quiet)
                            .multilineTextAlignment(.trailing)
                    }
                    PhaseTag(text: phaseTitle(phase), inverted: alerting)
                    Text(exercise.name)
                        .inkPoster(20, relativeTo: .headline)
                        .foregroundColor(strong)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Text(timerText(seconds: elapsed ?? remaining, hasStopwatch: elapsed != nil))
                        .inkPoster(56)
                        .foregroundColor(phase == .paused ? Ink.Colors.muted : strong)
                        .contentTransition(.numericText(countsDown: elapsed == nil))
                        .animation(.snappy, value: elapsed ?? remaining)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background {
                            if phase == .working { InkSpeedLines().clipped() }
                        }
                    InkProgressBar(fraction: WorkoutProgress.fraction(session, remainingSeconds: remaining), onAccent: alerting)
                        .padding(.top, 0)
                    if elapsed != nil {
                        Text(alerting ? "Следующий подход уже идёт" : "Время подхода")
                            .inkText(.subheadline, weight: .medium)
                            .foregroundColor(quiet)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: phase)
            }
            .overlay(alignment: .bottomLeading) {
                if phase == .resting { InkMascotSlot(pose: .rest, size: 64) }
            }
            .overlay(alignment: .topTrailing) {
                if alerting { InkMascotSlot(pose: .ignite, size: 64) }
            }
            .overlay(alignment: .topTrailing) {
                // Над верхней кромкой, чтобы не закрывать строку «Подход N из M».
                InkSfxFlash(word: "ДЗЫНЬ!", size: 28, trigger: sfxCount)
                    .offset(x: -8, y: -36)
            }
            .onChange(of: context.date) { _, _ in
                if session.phase == .preparing || session.phase == .resting,
                   let deadline = session.deadline, now >= deadline {
                    store.dispatch(command: .tick(), now: now)
                }
            }
        }
        .onChange(of: session.phase) { old, new in
            if new == .alerting && old != .alerting { sfxCount += 1 }
        }
    }

    private func panelStyle(_ phase: WorkoutPhase) -> InkPanelStyle {
        switch phase {
        case .working: return .tone
        case .alerting: return .now
        default: return .plain
        }
    }

    /// «Подход 2 из 4». Once the rest has run out the clock already counts the next set, so the header names that one.
    private func setHeader(_ exercise: SessionExercise) -> String {
        guard session.phase == .alerting, let next = WorkoutDomain.nextSet(session) else {
            return "Подход \(session.setIndex + 1) из \(exercise.rests.count)"
        }
        guard next.exercise == session.exerciseIndex else {
            return "Далее: \(session.exercises[next.exercise].baseName)"
        }
        return "Подход \(next.set + 1) из \(exercise.rests.count)"
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
}

/// Название фазы: плашка по ширине текста, плакатный 15 pt. На акцентном кадре цвета меняются местами.
private struct PhaseTag: View {
    let text: String
    let inverted: Bool

    var body: some View {
        Text(text)
            .inkPoster(15, relativeTo: .footnote)
            .foregroundColor(inverted ? Ink.Colors.accent : Ink.Colors.bg)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(inverted ? Ink.Colors.onAccent : Ink.Colors.fg)
    }
}

/// Weight and reps of the set at hand: today's target before it, what was done during the rest after it.
/// Prefilled from last time or the plan; the steppers correct it.
struct CurrentSetCard: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState
    @State private var sfxCount = 0

    var body: some View {
        let index = session.exerciseIndex
        let set = session.setIndex
        let exercise = session.exercises[index]
        let after = session.phase == .resting || session.phase == .paused || session.phase == .alerting
        InkPanel {
            VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                Text(after ? "Подход \(set + 1): сколько сделали" : "Подход \(set + 1): цель")
                    .inkText(.headline, weight: .bold)
                    .foregroundColor(Ink.Colors.fg)
                SetValueSteppers(store: store, exercise: index, set: set)
                if let last = lastTimeText(exercise) {
                    Text("В прошлый раз: \(last)")
                        .inkText(.subheadline, weight: .medium, numeric: true)
                        .foregroundColor(Ink.Colors.muted)
                }
                if exercise.progressed == true {
                    Label(progressionText(exercise), systemImage: "arrow.up.right")
                        .inkText(.subheadline, weight: .bold)
                        .foregroundColor(Ink.Colors.accentText)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            // «ТЫЩ!» один раз, когда подход засчитан и пошёл отдых.
            InkSfxFlash(word: "ТЫЩ!", size: 28, trigger: sfxCount)
                .offset(x: -8, y: -20)
        }
        .onChange(of: session.phase) { old, new in
            if new == .resting && (old == .working || old == .preparing) { sfxCount += 1 }
        }
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
            VStack(spacing: Ink.Metrics.gutter) {
                InkStepper(
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
                InkStepper(
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

/// The main button for the phase and the rest controls under it. Главная кнопка одна, остальные вторичные.
struct WorkoutActionButtons: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState

    var body: some View {
        VStack(spacing: Ink.Metrics.gutter) {
            primary
            if hasRestControls {
            HStack(spacing: Ink.Metrics.gutter) {
                if session.phase == .resting {
                    InkIconButton(icon: "pause.fill", accessibilityLabel: "Пауза") {
                        store.dispatch(command: .pause())
                    }
                    InkIconButton(icon: "goforward.30", accessibilityLabel: "Добавить 30 секунд") {
                        store.dispatch(command: .adjust(seconds: 30))
                    }
                    InkIconButton(icon: "goforward.60", accessibilityLabel: "Добавить 60 секунд") {
                        store.dispatch(command: .adjust(seconds: 60))
                    }
                } else if session.phase == .paused {
                    InkIconButton(icon: "goforward.30", accessibilityLabel: "Добавить 30 секунд") {
                        store.dispatch(command: .adjust(seconds: 30))
                    }
                    InkIconButton(icon: "forward.end.fill", accessibilityLabel: "Пропустить отдых") {
                        store.dispatch(command: .skipRest())
                    }
                } else if session.phase == .alerting {
                    InkIconButton(icon: "arrow.counterclockwise", accessibilityLabel: "Повторить отдых") {
                        store.dispatch(command: .repeatRest())
                    }
                }
            }
            }
        }
    }

    /// В подготовке и в подходе ряда значков нет: пустой ряд не должен добавлять отступ в панель.
    private var hasRestControls: Bool {
        session.phase == .resting || session.phase == .paused || session.phase == .alerting
    }

    @ViewBuilder
    private var primary: some View {
        let last = WorkoutDomain.isLastSet(session)
        switch session.phase {
        case .preparing:
            VStack(spacing: Ink.Metrics.gutter) {
                InkButton(title: "Начать сейчас", icon: "play.fill") {
                    store.dispatch(command: .startNow())
                }
                if !last {
                    InkButton(title: "Подход сделан, отдых", icon: "bed.double.fill", kind: .secondary) {
                        store.dispatch(command: .startRest())
                    }
                }
            }
        case .working:
            if last {
                finishButton
            } else {
                InkButton(title: "Подход сделан, отдых", icon: "bed.double.fill") {
                    store.dispatch(command: .startRest())
                }
            }
        case .resting:
            InkButton(title: "Пропустить отдых", icon: "forward.fill", kind: .secondary) {
                store.dispatch(command: .skipRest())
            }
        case .paused:
            InkButton(title: "Продолжить", icon: "play.fill") {
                store.dispatch(command: .resume())
            }
        case .alerting:
            if last {
                finishButton
            } else {
                VStack(spacing: Ink.Metrics.gutter) {
                    InkButton(title: "Начать подход", icon: "play.fill") {
                        store.dispatch(command: .acknowledge())
                    }
                    // For a set already done while the alert was showing.
                    InkButton(title: "Подход сделан, отдых", icon: "bed.double.fill", kind: .secondary) {
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
        InkButton(title: "Подход сделан, завершить", icon: "checkmark") {
            store.dispatch(command: .finishSet())
        }
    }
}
