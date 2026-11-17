import SwiftUI

public struct WorkoutScreen: View {
    @Binding var showSettings: Bool
    @ObservedObject private var store: WorkoutStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var isEditingPlan: Bool = false
    @State private var section: Part = WorkoutScreen.initialSection

    enum Part: String, CaseIterable, Identifiable {
        case plan = "План"
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
                DS.Colors.canvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    ScreenHeader("Тренировка", kicker: rhythmKicker) {
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.top, DS.Metrics.spacing16)

                    ArnaSegmented("Раздел тренировки", selection: $section, options: Part.allCases.map { item in
                        (item, item == .plan && store.activeSession.map { $0.phase != .complete } == true ? "Тренировка" : item.rawValue)
                    })
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.vertical, DS.Metrics.spacing8)
                    .petTip("Здесь план тренировки и история. Время считается от старта до финиша.")

                    switch section {
                    case .history:
                        WorkoutHistoryView(store: store)
                    case .plan:
                        planContent
                    }
                }

                WorkoutUndoToast(store: store)
            }
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
        }
    }

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
                        isEditingPlan = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(DS.Colors.accent)
                    .frame(minHeight: DS.Metrics.minHitTarget)
                }

                ForEach(training.days, id: \.weekday) { day in
                    Card {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(day.title ?? WorkoutFormat.weekdayNames[day.weekday - 1])
                                    .font(.headline.weight(.semibold))
                                    .foregroundColor(DS.Colors.textPrimary)
                                if day.title != nil {
                                    Text(WorkoutFormat.weekdayNames[day.weekday - 1])
                                        .font(.caption)
                                        .foregroundColor(DS.Colors.textSecondary)
                                }
                            }
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
                                Text(WorkoutFormat.exerciseSummary(ex))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundColor(DS.Colors.textSecondary)
                            }
                            .padding(.vertical, 2)
                        }

                        PillButton("Начать тренировку", icon: "play.fill", style: .primary) {
                            store.startWorkout(day: day)
                        }
                        .padding(.top, DS.Metrics.spacing8)
                    }
                }
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.vertical, DS.Metrics.spacing16)
            .padding(.bottom, 80)
        }
    }
}
