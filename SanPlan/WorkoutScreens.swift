import SwiftUI

/// «Тренировка»: the switcher «Тренировка / История» under the header. Before the start the plan of the day is folded
/// («5 упражнений · ~50 мин») and opens on tap; a workout in progress or its summary takes the place of the plan.
public struct WorkoutScreen: View {
    @Binding var showSettings: Bool
    @ObservedObject private var store: WorkoutStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.shellCapture) private var capture
    @Environment(\.sectionAccent) private var accent
    /// Read so the day's plan and «Ритм недели» follow the real day after midnight.
    @Environment(\.dayKey) private var dayKey

    @State private var isEditingPlan: Bool = false
    @State private var section: Part = WorkoutScreen.initialSection
    @State private var historyPeriod: WorkoutHistoryView.Period = .week
    @State private var openRecordId: String? = nil
    @State private var isPlanExpanded = false
    @State private var isDemoApplied = false

    enum Part: String, CaseIterable, Identifiable {
        case plan = "Тренировка"
        case history = "История"
        var id: String { rawValue }
    }

    public init(store: WorkoutStore, showSettings: Binding<Bool>) {
        self.store = store
        self._showSettings = showSettings
    }

    /// Debug screenshots can open on the history.
    private static var initialSection: Part {
        #if DEBUG
        if ScreenshotRoute.is("workout-history") { return .history }
        return ProcessInfo.processInfo.arguments.contains("--screenshot-workout-history") ? .history : .plan
        #else
        return .plan
        #endif
    }

    /// «РИТМ НЕДЕЛИ · 2 ИЗ 3»: workouts done since Monday out of the days in the program.
    private var rhythmKicker: String? {
        let planned = store.program.days.filter { !$0.exercises.isEmpty }.count
        guard planned > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = WorkoutSummary.zone
        guard let monday = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let done = WorkoutSummary.period(store.records, from: WorkoutSummary.dayKey(Int64(monday.timeIntervalSince1970 * 1000)), to: WorkoutSummary.dayKey(nowMs)).completed
        return "Ритм недели · \(done) из \(planned)"
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                TrainingBackdrop()

                VStack(spacing: 0) {
                    ScreenHeader("Тренировка", kicker: rhythmKicker) {
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.top, 18)

                    ArnaSegmented("Раздел тренировки", selection: $section, options: Part.allCases.map { ($0, $0.rawValue) })
                        .padding(.horizontal, DS.Metrics.screenGutter)
                        .padding(.vertical, DS.Metrics.spacing8)
                        .tourTarget("workout.sections")

                    switch section {
                    case .history:
                        WorkoutHistoryView(store: store, period: $historyPeriod, openRecordId: $openRecordId)
                    case .plan:
                        planContent
                    }
                }

                WorkoutUndoToast(store: store)
            }
            .shellCaptureButton()
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    store.reconcileClock()
                }
            }
            .onChange(of: store.activeSession?.recordId) { _, id in
                // A workout started from elsewhere (Today, Plans) shows here even if the history was open.
                if id != nil { section = .plan }
            }
            .onReceive(DeepLinks.shared.$pending) { link in
                open(link)
            }
            .task {
                applyDemoDataIfAsked()
            }
        }
        // The «+» works here as on every other tab, during a workout too (owner: «в тренировке не работает плюсик»).
        // RootView passes `isEnabled: store.activeSession == nil`; the section turns it back on for itself.
        .environment(\.shellCapture, capture.map { ShellCapture(isEnabled: true, action: $0.action) })
    }

    // MARK: - Deep links

    /// «.workoutHistory(.month)» opens История on that period; «.workoutSession(id)» opens that workout's editor.
    private func open(_ link: DeepLink?) {
        guard let link else { return }
        switch link {
        case .workoutHistory(let period):
            section = .history
            historyPeriod = period == .month ? .month : .week
            DeepLinks.shared.consume()
        case .workoutSession(let id):
            section = .history
            openRecordId = id
            DeepLinks.shared.consume()
        default:
            break
        }
    }

    // MARK: - Screenshot demo data

    /// Screenshots only: a five-exercise day and about six weeks of made-up workouts, in memory, never saved.
    private func applyDemoDataIfAsked() {
        #if DEBUG
        guard ScreenshotRoute.demoData, !isDemoApplied else { return }
        isDemoApplied = true
        store.training = TrainingDemoData.program(now: Date())
        store.showDemoHistory(TrainingDemoData.history(now: Date()))
        #endif
    }

    // MARK: - Plan

    @ViewBuilder
    private var planContent: some View {
        if let session = store.activeSession {
            if session.phase == .complete {
                WorkoutSummaryView(store: store, session: session)
            } else {
                ActiveWorkoutView(store: store, session: session)
            }
        } else if !store.program.days.isEmpty, !isEditingPlan {
            savedPlanOverview(training: store.program)
        } else {
            // Building from scratch stays in the builder after the first exercise, until «Готово».
            WorkoutBuilderView(store: store, onDone: { isEditingPlan = false })
                .onAppear { isEditingPlan = true }
        }
    }

    /// The day the hero card shows: today's workout, or the next one in the week.
    private func featuredDay(_ training: WorkoutTrainingPlan) -> (day: WorkoutDayPlan, label: String)? {
        let today = WorkoutProgram.weekday(of: Date())
        for offset in 0..<7 {
            let weekday = (today - 1 + offset) % 7 + 1
            if let day = WorkoutProgram.day(training, weekday: weekday), !day.exercises.isEmpty {
                let label = offset == 0 ? "Сегодня" : offset == 1 ? "Завтра" : WorkoutFormat.weekdayNames[weekday - 1]
                return (day, label)
            }
        }
        return nil
    }

    private func dayTitle(_ day: WorkoutDayPlan) -> String {
        day.title ?? WorkoutFormat.weekdayNames[day.weekday - 1]
    }

    /// This week from Monday: a workout done, today, a rest day without a plan, or a planned day.
    private func rhythmDays(_ training: WorkoutTrainingPlan) -> [TrainingRhythmRow.Day] {
        let calendar = WorkoutHistory.calendar()
        let now = Date()
        let monday = WorkoutHistory.weekStart(now, calendar: calendar)
        let doneDays = Set(store.records.map { calendar.startOfDay(for: WorkoutHistory.date($0.startedAt)) })
        return (0..<7).map { index in
            let date = calendar.date(byAdding: .day, value: index, to: monday) ?? monday
            let planned = WorkoutProgram.day(training, weekday: index + 1).map { !$0.exercises.isEmpty } ?? false
            return TrainingRhythmRow.Day(
                id: index,
                label: TrainingWords.shortWeekdays[index],
                isDone: doneDays.contains(calendar.startOfDay(for: date)),
                isToday: calendar.isDate(date, inSameDayAs: now),
                isRestDay: !planned
            )
        }
    }

    private func savedPlanOverview(training: WorkoutTrainingPlan) -> some View {
        let featured = featuredDay(training)
        let others = training.days
            .filter { $0.weekday != featured?.day.weekday && !$0.exercises.isEmpty }
            .sorted { $0.weekday < $1.weekday }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let warning = store.restAlarm.warningMessage {
                    ErrorBanner(message: warning)
                }
                if let error = store.errorMessage {
                    ErrorBanner(message: error) {
                        store.errorMessage = nil
                    }
                }

                TrainingRhythmRow(days: rhythmDays(training))
                    .tourTarget("workout.rhythm")

                if let featured {
                    heroCard(featured.day, label: featured.label)
                        .tourTarget("workout.hero")
                }

                planSection(featured?.day)
                    .tourTarget("workout.plan")

                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                        TrainingKicker(text: "Другие дни")
                        ForEach(others, id: \.weekday) { day in
                            otherDayRow(day)
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.top, 18)
            .padding(.bottom, 108)
        }
        .tourScrollHost()
    }

    /// The canvas hero: the day in the workout colour, its folded plan and «Начать тренировку».
    private func heroCard(_ day: WorkoutDayPlan, label: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 14) {
            Text(label.uppercased())
                .font(DS.Fonts.text(13, .heavy, relativeTo: .caption))
                .tracking(0.8)
            Text(dayTitle(day))
                .font(DS.Fonts.display(26, relativeTo: .title))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                withAnimation(.snappy) { isPlanExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(TrainingWords.daySummary(day))
                        .font(DS.Fonts.text(16, .semibold, relativeTo: .subheadline))
                    Image(systemName: isPlanExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: DS.Metrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isPlanExpanded ? "Свернуть упражнения" : "Показать упражнения")
            Button {
                store.startWorkout(day: day)
            } label: {
                Text("Начать тренировку")
                    .font(DS.Fonts.text(18, .heavy, relativeTo: .headline))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.canvas))
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(TrainingPalette.inkShade).offset(x: 4, y: 4))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Начать тренировку")
        }
        .foregroundColor(TrainingPalette.onAccent)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .trailing) {
                LinearGradient(colors: [TrainingPalette.heroStart, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 54, height: 420)
                    .rotationEffect(.degrees(24))
                    .offset(x: -34)
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 18, height: 420)
                    .rotationEffect(.degrees(24))
                    .offset(x: 6)
            }
            // Clipping hides the long stripes but does not stop them taking taps meant for views above the card.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipShape(shape)
        .contentShape(shape)
        .overlay(shape.stroke(DS.Colors.edge, lineWidth: 1))
        .background(shape.fill(DS.Colors.drop).offset(y: 2))
        .padding(.trailing, 6)
    }

    /// «ПЛАН» with «Изменить» and «История»; the exercises of the day once the plan is opened.
    private func planSection(_ day: WorkoutDayPlan?) -> some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            HStack(spacing: DS.Metrics.spacing16) {
                TrainingKicker(text: "План")
                Spacer()
                Button("Изменить") {
                    isEditingPlan = true
                }
                .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                .foregroundColor(accent)
                .frame(minHeight: DS.Metrics.minHitTarget)
                Button("История") {
                    withAnimation(.easeOut(duration: 0.2)) { section = .history }
                }
                .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                .foregroundColor(accent)
                .frame(minHeight: DS.Metrics.minHitTarget)
            }
            if let day, isPlanExpanded {
                ForEach(Array(day.exercises.enumerated()), id: \.offset) { item in
                    exerciseRow(number: item.offset + 1, exercise: item.element)
                }
            }
        }
    }

    private func exerciseRow(number: Int, exercise: WorkoutExercisePlan) -> some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(DS.Fonts.text(15, .heavy, relativeTo: .subheadline))
                .foregroundColor(accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(TrainingPalette.badge))
            Text(exercise.name)
                .font(DS.Fonts.text(17, .semibold, relativeTo: .body))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
            Spacer(minLength: DS.Metrics.spacing8)
            Text("\(exercise.sets) × \(exercise.reps)")
                .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                .monospacedDigit()
                .foregroundColor(DS.Colors.textSecondary)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Colors.surface))
        .accessibilityElement(children: .combine)
    }

    private func otherDayRow(_ day: WorkoutDayPlan) -> some View {
        HStack(spacing: 14) {
            Text(TrainingWords.shortWeekdays[day.weekday - 1])
                .font(DS.Fonts.text(13, .heavy, relativeTo: .caption))
                .foregroundColor(accent)
                .frame(width: 36, height: 30)
                .background(Capsule().fill(TrainingPalette.badge))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(dayTitle(day))
                    .font(DS.Fonts.text(17, .semibold, relativeTo: .body))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(day.title == nil ? TrainingWords.daySummary(day) : "\(WorkoutFormat.weekdayNames[day.weekday - 1]) · \(TrainingWords.daySummary(day))")
                    .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Spacer(minLength: DS.Metrics.spacing8)
            Button {
                store.startWorkout(day: day)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(TrainingPalette.onAccent)
                    .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                    .background(Circle().fill(accent))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Начать: \(dayTitle(day))")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Colors.surface))
    }
}
