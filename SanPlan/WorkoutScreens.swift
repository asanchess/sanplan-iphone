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

    private var sectionItems: [(value: Part, title: String)] {
        let running = store.activeSession.map { $0.phase != .complete } == true
        return Part.allCases.map { (value: $0, title: $0 == .plan && running ? "Тренировка" : $0.rawValue) }
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                InkStarBackground()

                VStack(spacing: 0) {
                    InkScreenHeader(title: "Тренировка") { showSettings = true }
                        .padding(.horizontal, Ink.Metrics.page)
                        .padding(.top, Ink.Metrics.page)

                    InkSegmented(selection: $section, items: sectionItems)
                        .padding(.horizontal, Ink.Metrics.page)
                        .padding(.vertical, Ink.Metrics.gutter)

                    switch section {
                    case .history:
                        WorkoutHistoryView(store: store)
                    case .plan:
                        planContent
                    }

                    // Тост занимает место под панелью кнопок, а не лежит поверх неё: главная кнопка остаётся доступной.
                    WorkoutUndoToast(store: store)
                }
                .frame(maxWidth: Ink.Metrics.maxWidth)
            }
            .frame(maxWidth: .infinity)
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
            VStack(alignment: .leading, spacing: Ink.Metrics.stack) {
                if let warning = store.restAlarm.warningMessage {
                    InkBanner(message: warning)
                }
                if let error = store.errorMessage {
                    InkBanner(message: error) {
                        store.errorMessage = nil
                    }
                }

                HStack {
                    InkSectionHeader(text: "Дни тренировок")
                    Spacer()
                    InkButton(title: "Изменить", kind: .text) {
                        isEditingPlan = true
                    }
                }

                // Одна главная кнопка на экран: у сегодняшнего дня, а если сегодня отдых — у первого в списке.
                let todayIndex = Self.weekday(of: Date())
                let primary = Self.primaryWeekday(in: training.days)
                VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                    ForEach(Array(training.days.enumerated()), id: \.element.weekday) { offset, day in
                        InkDayPanel(
                            day: day,
                            isPrimary: day.weekday == primary,
                            isToday: day.weekday == todayIndex,
                            showsMascot: offset == 0
                        ) {
                            store.startWorkout(day: day)
                        }
                    }
                }
            }
            .padding(.horizontal, Ink.Metrics.page)
            .padding(.vertical, Ink.Metrics.gutter)
            .padding(.bottom, 96)
        }
    }

    /// Номер дня недели: 1 — понедельник.
    static func weekday(of date: Date) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        return (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    /// День с главной кнопкой: сегодняшний, а если сегодня тренировки нет — первый в списке.
    static func primaryWeekday(in days: [WorkoutDayPlan], today: Date = Date()) -> Int? {
        let todayIndex = weekday(of: today)
        if days.contains(where: { $0.weekday == todayIndex }) { return todayIndex }
        return days.first?.weekday
    }
}
