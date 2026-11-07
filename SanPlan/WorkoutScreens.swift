import SwiftUI

public struct WorkoutScreen: View {
    @Binding var showSettings: Bool
    @ObservedObject private var store: WorkoutStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var planInputText: String = ""
    @State private var isEditingPlan: Bool = false
    @State private var isConfirmingFinish: Bool = false
    private static let programExample = "вт\nПриседания, 12 раз\nОтжимания, 10 раз\nчт\nВыпады, 10 раз на каждую ногу"
    @State private var parseError: String?

    public init(store: WorkoutStore, showSettings: Binding<Bool>) {
        self.store = store
        self._showSettings = showSettings
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    ScreenHeader("Тренировка") {
                        CircleIconButton(
                            icon: "person.crop.circle",
                            accessibilityLabel: "Настройки"
                        ) {
                            showSettings = true
                        }
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.top, DS.Metrics.spacing16)

                    if let session = store.activeSession {
                        if session.phase == .complete {
                            workoutSummaryView(session: session)
                        } else {
                            activeWorkoutSessionView(session: session)
                        }
                    } else if let training = store.training, !training.days.isEmpty, !isEditingPlan {
                        savedPlanOverview(training: training)
                    } else {
                        planEditorView
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    store.reconcileClock(now: now)
                }
            }
        }
    }

    private var planEditorView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                if let error = parseError ?? store.errorMessage {
                    ErrorBanner(message: error) {
                        parseError = nil
                        store.errorMessage = nil
                    }
                }

                Card {
                    SectionHeader("Программа тренировок")
                    Text("Каждый день недели — отдельной строкой (пн, вт, …), под ним упражнения: «название, 12 раз». Для одной стороны: «Выпады, 10 раз на каждую ногу».")
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)

                    TextEditor(text: $planInputText)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 180)
                        .overlay(alignment: .topLeading) {
                            if planInputText.isEmpty {
                                Text(Self.programExample)
                                    .font(.body)
                                    .foregroundColor(DS.Colors.textSecondary.opacity(0.7))
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(DS.Metrics.spacing8)
                        .background(DS.Colors.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Metrics.innerRadius)
                                .stroke(DS.Colors.hairline, lineWidth: 1)
                        )
                }

                PillButton("Сохранить программу", icon: "checkmark") {
                    parseAndSavePlan()
                }

                if store.training != nil {
                    PillButton("Отмена", style: .secondary) {
                        isEditingPlan = false
                        parseError = nil
                    }
                }
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.vertical, DS.Metrics.spacing16)
        }
    }

    private func savedPlanOverview(training: WorkoutTrainingPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                if let warning = store.restAlarm.warningMessage {
                    ErrorBanner(message: warning)
                }
                if let error = store.errorMessage {
                    ErrorBanner(message: error) {
                        store.errorMessage = nil
                    }
                }

                HStack {
                    SectionHeader("Дни тренировок")
                    Spacer()
                    Button("Изменить") {
                        reopenPlanEditor(from: training)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(DS.Colors.accent)
                }

                ForEach(training.days, id: \.weekday) { day in
                    Card {
                        HStack {
                            Text(weekdayTitle(day.weekday))
                                .font(.headline.weight(.semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                            Spacer()
                            Text("\(day.exercises.count) упр.")
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.textSecondary)
                        }

                        ForEach(day.exercises, id: \.self) { ex in
                            HStack {
                                Text(ex.name)
                                    .font(.subheadline)
                                    .foregroundColor(DS.Colors.textPrimary)
                                Spacer()
                                Text("\(ex.sets) × \(ex.reps)\(ex.perSide ? " на сторону" : "")")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundColor(DS.Colors.textSecondary)
                            }
                            .padding(.vertical, 2)
                        }

                        PillButton("Начать тренировку", icon: "play.fill", style: .primary) {
                            let now = Int64(Date().timeIntervalSince1970 * 1000)
                            store.startWorkout(day: day, now: now)
                        }
                        .padding(.top, DS.Metrics.spacing8)
                    }
                }
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.vertical, DS.Metrics.spacing16)
        }
    }

    private func activeWorkoutSessionView(session: WorkoutSessionState) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let currentNow = Int64(context.date.timeIntervalSince1970 * 1000)
            let remaining = (try? WorkoutDomain.remainingSeconds(state: session, now: max(session.lastNow, currentNow))) ?? 0
            let elapsed = WorkoutDomain.elapsedWorkSeconds(state: session, now: max(session.lastNow, currentNow))

            VStack(spacing: DS.Metrics.spacing24) {
                if let warning = store.restAlarm.warningMessage {
                    ErrorBanner(message: warning)
                        .padding(.horizontal, DS.Metrics.screenGutter)
                }

                Spacer()

                VStack(spacing: DS.Metrics.spacing8) {
                    Text(phaseDisplayTitle(session.phase))
                        .font(.title2.weight(.medium))
                        .foregroundColor(phaseTextColor(session.phase))

                    let currentEx = session.exercises[session.exerciseIndex]
                    Text(currentEx.name)
                        .font(.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Metrics.screenGutter)

                    setsStepper(session: session, now: currentNow)
                }

                Card {
                    VStack(alignment: .center, spacing: DS.Metrics.spacing8) {
                        Text(formatTimer(seconds: elapsed ?? remaining, phase: session.phase, hasStopwatch: elapsed != nil))
                            .font(.system(size: 64, weight: .light, design: .rounded).monospacedDigit())
                            .foregroundColor(DS.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .center)

                        if session.phase == .paused {
                            Text("Пауза")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(DS.Colors.warning)
                        } else if session.phase == .alerting {
                            Text("Отдых окончен")
                                .font(.headline.weight(.bold))
                                .foregroundColor(DS.Colors.positive)
                        } else if session.phase == .working {
                            Text("Время подхода")
                                .font(.footnote)
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                    .padding(.vertical, DS.Metrics.spacing16)
                }
                .padding(.horizontal, DS.Metrics.screenGutter)

                VStack(spacing: DS.Metrics.spacing16) {
                    primaryActionButton(session: session, now: currentNow)

                    HStack(spacing: DS.Metrics.spacing16) {
                        if session.phase == .resting {
                            CircleIconButton(icon: "pause.fill", accessibilityLabel: "Пауза") {
                                store.dispatch(command: .pause(), now: currentNow)
                            }
                            CircleIconButton(icon: "goforward.30", accessibilityLabel: "Добавить 30 секунд") {
                                store.dispatch(command: .adjust(seconds: 30), now: currentNow)
                            }
                            CircleIconButton(icon: "goforward.60", accessibilityLabel: "Добавить 60 секунд") {
                                store.dispatch(command: .adjust(seconds: 60), now: currentNow)
                            }
                        } else if session.phase == .paused {
                            CircleIconButton(icon: "goforward.30", accessibilityLabel: "Добавить 30 секунд") {
                                store.dispatch(command: .adjust(seconds: 30), now: currentNow)
                            }
                            CircleIconButton(icon: "goforward.60", accessibilityLabel: "Добавить 60 секунд") {
                                store.dispatch(command: .adjust(seconds: 60), now: currentNow)
                            }
                            CircleIconButton(icon: "forward.end.fill", accessibilityLabel: "Пропустить отдых") {
                                store.dispatch(command: .skipRest(), now: currentNow)
                            }
                        } else if session.phase == .alerting {
                            CircleIconButton(icon: "arrow.counterclockwise", accessibilityLabel: "Повторить отдых") {
                                store.dispatch(command: .repeatRest(), now: currentNow)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Metrics.screenGutter)

                Spacer()

                Button("Завершить досрочно") {
                    isConfirmingFinish = true
                }
                .font(.footnote)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(minHeight: DS.Metrics.minHitTarget)
                .padding(.bottom, DS.Metrics.spacing16)
                .confirmationDialog(
                    "Завершить тренировку досрочно?",
                    isPresented: $isConfirmingFinish,
                    titleVisibility: .visible
                ) {
                    Button("Завершить", role: .destructive) {
                        store.dispatch(command: .finish(), now: Int64(Date().timeIntervalSince1970 * 1000))
                    }
                    Button("Продолжить тренировку", role: .cancel) {}
                } message: {
                    Text("Оставшиеся подходы не будут выполнены.")
                }
            }
            .onChange(of: context.date) { _ in
                if session.phase == .preparing || session.phase == .resting {
                    if let deadline = session.deadline, currentNow >= deadline {
                        store.dispatch(command: .tick(), now: currentNow)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func primaryActionButton(session: WorkoutSessionState, now: Int64) -> some View {
        switch session.phase {
        case .preparing:
            VStack(spacing: DS.Metrics.spacing12) {
                PillButton("Начать сейчас", icon: "play.fill") {
                    store.dispatch(command: .startNow(), now: now)
                }
                // A one-set workout has no rest after the warm-up; finishing it stays behind «Завершить досрочно».
                if !WorkoutDomain.isLastSet(session) {
                    PillButton("Начать отдых", icon: "bed.double.fill", style: .secondary) {
                        store.dispatch(command: .startRest(), now: now)
                    }
                }
            }
        case .working:
            if WorkoutDomain.isLastSet(session) {
                finishButton(style: .primary, now: now)
            } else {
                PillButton("Начать отдых", icon: "bed.double.fill") {
                    store.dispatch(command: .startRest(), now: now)
                }
            }
        case .resting:
            PillButton("Пропустить отдых", icon: "forward.fill", style: .secondary) {
                store.dispatch(command: .skipRest(), now: now)
            }
        case .paused:
            PillButton("Продолжить", icon: "play.fill") {
                store.dispatch(command: .resume(), now: now)
            }
        case .alerting:
            if WorkoutDomain.isLastSet(session) {
                finishButton(style: .primary, now: now)
            } else {
                VStack(spacing: DS.Metrics.spacing12) {
                    PillButton("Начать подход", icon: "play.fill", style: .primary) {
                        store.dispatch(command: .acknowledge(), now: now)
                    }
                    // For a set already done while the alert was showing.
                    PillButton("Начать отдых", icon: "bed.double.fill", style: .secondary) {
                        store.dispatch(command: .startRest(), now: now)
                    }
                }
            }
        case .complete:
            PillButton("Завершено", icon: "checkmark", isEnabled: false) {}
        }
    }

    private func workoutSummaryView(session: WorkoutSessionState) -> some View {
        VStack(spacing: DS.Metrics.spacing24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(DS.Colors.positive)

            Text("Тренировка завершена")
                .font(.largeTitle.weight(.light))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Все упражнения и подходы выполнены.")
                .font(.subheadline)
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            PillButton("Вернуться к списку", icon: "arrow.left") {
                store.discardWorkout()
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.bottom, DS.Metrics.spacing24)
        }
    }

    private func parseAndSavePlan() {
        do {
            let parsed = try WorkoutDomain.parseWorkoutText(planInputText)
            store.setTrainingPlan(parsed)
            isEditingPlan = false
            parseError = nil
        } catch {
            parseError = error.localizedDescription
        }
    }

    private func reopenPlanEditor(from training: WorkoutTrainingPlan) {
        var lines: [String] = []
        let dayNames = ["пн", "вт", "ср", "чт", "пт", "сб", "вс"]
        for day in training.days {
            let name = (day.weekday >= 1 && day.weekday <= 7) ? dayNames[day.weekday - 1] : "пн"
            lines.append(name)
            for ex in day.exercises {
                let sideStr = ex.perSide ? " на каждую сторону" : ""
                lines.append("\(ex.name), \(ex.reps) раз\(sideStr)")
            }
        }
        planInputText = lines.joined(separator: "\n")
        isEditingPlan = true
    }

    private func weekdayTitle(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "Понедельник"
        case 2: return "Вторник"
        case 3: return "Среда"
        case 4: return "Четверг"
        case 5: return "Пятница"
        case 6: return "Суббота"
        case 7: return "Воскресенье"
        default: return "День"
        }
    }

    private func phaseDisplayTitle(_ phase: WorkoutPhase) -> String {
        switch phase {
        case .preparing: return "Подготовка"
        case .working: return "Рабочий подход"
        case .resting: return "Отдых"
        case .paused: return "Отдых на паузе"
        case .alerting: return "Отдых завершён"
        case .complete: return "Завершено"
        }
    }

    private func phaseTextColor(_ phase: WorkoutPhase) -> Color {
        switch phase {
        case .alerting: return DS.Colors.positive
        case .paused: return DS.Colors.warning
        case .resting: return DS.Colors.accent
        default: return DS.Colors.textPrimary
        }
    }

    /// The last set of the workout: no rest or next set follows, so the button says what happens.
    private func finishButton(style: PillButton.Style, now: Int64) -> some View {
        PillButton("Завершить тренировку", icon: "checkmark", style: style) {
            store.dispatch(command: .finish(), now: now)
        }
    }

    /// "Подход 2 из 4" above a separate «Всего подходов» stepper, so − / + reads as a count, not as moving between sets.
    @ViewBuilder
    private func setsStepper(session: WorkoutSessionState, now: Int64) -> some View {
        let total = session.exercises[session.exerciseIndex].rests.count
        VStack(spacing: DS.Metrics.spacing4) {
            Text("Подход \(session.setIndex + 1) из \(total)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundColor(DS.Colors.textSecondary)
                .contentTransition(.numericText())
            setsCountStepper(session: session, total: total, now: now)
        }
    }

    private func setsCountStepper(session: WorkoutSessionState, total: Int, now: Int64) -> some View {
        HStack(spacing: DS.Metrics.spacing12) {
            Button {
                store.dispatch(command: .setSets(total - 1), now: now)
            } label: {
                Image(systemName: "minus")
                    .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
            }
            .disabled(total - 1 < session.setIndex + 1 || session.phase == .complete)
            .accessibilityLabel("Убрать подход")

            Text("Всего подходов: \(total)")
                .font(.footnote.monospacedDigit())
                .foregroundColor(DS.Colors.textSecondary)
                .contentTransition(.numericText())
                .accessibilityLabel("Всего подходов: \(total)")

            Button {
                store.dispatch(command: .setSets(total + 1), now: now)
            } label: {
                Image(systemName: "plus")
                    .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
            }
            .disabled(total >= 100 || session.phase == .complete)
            .accessibilityLabel("Добавить подход")
        }
        .font(.body.weight(.semibold))
        .tint(DS.Colors.accent)
    }

    private func formatTimer(seconds: Int, phase: WorkoutPhase, hasStopwatch: Bool) -> String {
        if phase == .working && !hasStopwatch {
            return "—:—"
        }
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
