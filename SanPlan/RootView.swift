import SwiftUI

public enum MainTab: Int, CaseIterable, Identifiable {
    case today = 0
    case money = 1
    case plans = 2
    case workout = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .today: return "Сегодня"
        case .money: return "Деньги"
        case .plans: return "Планы"
        case .workout: return "Тренировка"
        }
    }

    public var icon: String {
        switch self {
        case .today: return "sun.max"
        case .money: return "creditcard"
        case .plans: return "calendar"
        case .workout: return "figure.run"
        }
    }
}

public struct RootView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var authService: AuthService
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTab = .today
    @State private var showSettingsSheet: Bool = false
    @State private var fullAlarmText: String? = nil

    private var isScreenshotSignedInMode: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--screenshot-signed-in")
        #else
        return false
        #endif
    }

    private var screenshotTab: MainTab? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--screenshot-tab"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1]).flatMap(MainTab.init(rawValue:))
        #else
        return nil
        #endif
    }

    public var body: some View {
        Group {
            if isScreenshotSignedInMode {
                mainTabsView
            } else {
                switch authService.phase {
                case .checking:
                    ZStack {
                        DS.Colors.canvas.ignoresSafeArea()
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: DS.Colors.accent))
                    }
                case .signedOut:
                    LoginView()
                case .signedIn:
                    mainTabsView
                }
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
        }
        .alert("Будильник", isPresented: Binding(
            get: { fullAlarmText != nil },
            set: { if !$0 { fullAlarmText = nil } }
        )) {
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text(fullAlarmText ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SanPlan_ReadFullAlarm"))) { _ in
            openPendingAlarmText()
        }
        .task {
            if let tab = screenshotTab { selectedTab = tab }
            seedScreenshotWorkout()
            openPendingAlarmText()
            if !isScreenshotSignedInMode {
                await authService.loadStatus()
                await model.launched()
            }
        }
        .onChange(of: authService.phase, initial: true) { _, phase in
            guard !isScreenshotSignedInMode else { return }
            switch phase {
            case .signedOut:
                showSettingsSheet = false
                selectedTab = .today
                model.clearAccountData()
            case .signedIn(let email):
                model.accountSignedIn(email: email)
            case .checking:
                break
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !isScreenshotSignedInMode { model.becameActive() }
        }
    }

    /// Debug screenshots only: an in-memory workout in the phase named after the flag. Saved only if a later command runs.
    private func seedScreenshotWorkout() {
        #if DEBUG
        guard isScreenshotSignedInMode else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--screenshot-workout-history") {
            seedScreenshotHistory(now: now)
        }
        guard arguments.contains("--screenshot-active-workout") else { return }
        var bench = (try? WorkoutSessionEdit.newExercise(name: "Жим лёжа", sets: 4, reps: 8, restSeconds: 90, restAfterExercise: 90, weightKg: 62.5))
            ?? SessionExercise(name: "Жим лёжа", rests: [90, 90, 90, 90])
        bench.lastTime = [SetLog(done: true, weightKg: 60, reps: 8), SetLog(done: true, weightKg: 60, reps: 8),
                          SetLog(done: true, weightKg: 60, reps: 8), SetLog(done: true, weightKg: 60, reps: 8)]
        bench.progressed = true
        let row = (try? WorkoutSessionEdit.newExercise(name: "Тяга в наклоне", sets: 3, reps: 10, restSeconds: 90, restAfterExercise: 90, weightKg: 50))
            ?? SessionExercise(name: "Тяга в наклоне", rests: [90, 90, 90])
        let exercises = [bench, row]
        let flag = arguments.firstIndex(of: "--screenshot-active-workout")!
        let phase = flag + 1 < arguments.count ? arguments[flag + 1] : "working"
        guard let created = try? WorkoutDomain.createWorkout(exercises: exercises, now: now - 10_000) else { return }
        var session: WorkoutSessionState? = created
        switch phase {
        case "preparing":
            break
        case "alerting":
            // A 90 s rest that ran out 5 s ago.
            session = (try? WorkoutDomain.createWorkout(exercises: exercises, now: now - 100_000))
                .flatMap { try? WorkoutDomain.workoutCommand(state: $0, command: .startRest(), now: now - 95_000) }
                .flatMap { try? WorkoutDomain.workoutCommand(state: $0, command: .tick(), now: now) }
        case "last":
            // The only set of a one-exercise workout: nothing follows it.
            session = (try? WorkoutDomain.createWorkout(exercises: [SessionExercise(name: "Тяга в наклоне", rests: [90])], now: now - 10_000))
                .flatMap { try? WorkoutDomain.workoutCommand(state: $0, command: .startNow(), now: now - 9_000) }
        default:
            session = try? WorkoutDomain.workoutCommand(state: created, command: .startNow(), now: now - 9_000)
        }
        model.workouts.activeSession = session
        #endif
    }

    #if DEBUG
    /// Debug screenshots only: a few weeks of made-up workouts for the history screen.
    private func seedScreenshotHistory(now: Int64) {
        // Fixed ids, so a later run replaces them instead of adding more; workouts left by UI tests stay beside them.
        let day: Int64 = 86_400_000
        for offset in [1, 3, 6, 8, 10, 13, 15, 17, 20, 22, 27, 29] {
            let start = now - Int64(offset) * day - 3_600_000
            let sets = (0..<4).map { WorkoutRecordSet(done: $0 < 4 - offset % 2, weightKg: 60 - Double(offset / 7) * 2.5, reps: 8) }
            let record = WorkoutRecord(
                id: "screenshot-\(offset)",
                startedAt: start,
                endedAt: start + Int64(48 + offset % 5 * 4) * 60_000,
                weekday: WorkoutProgram.weekday(of: WorkoutHistory.date(start)),
                title: offset % 2 == 0 ? "Верх" : "Ноги",
                exercises: [
                    WorkoutRecordExercise(name: "Жим лёжа", targetReps: 8, sets: sets),
                    WorkoutRecordExercise(name: "Подтягивания", bodyweight: true, targetReps: 10,
                                          sets: Array(repeating: WorkoutRecordSet(done: true, reps: 10), count: 3))
                ]
            )
            model.workouts.saveRecord(record, now: now)
        }
        model.workouts.dismissUndo(model.workouts.undoOffer?.id ?? UUID())
    }
    #endif

    /// A long plan title does not fit on the alarm screen, so the alarm's button opens it here.
    private func openPendingAlarmText() {
        guard let text = UserDefaults.standard.string(forKey: "SanPlan_AlarmDetailText"), !text.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: "SanPlan_AlarmDetailText")
        fullAlarmText = text
    }

    private var mainTabsView: some View {
        TabView(selection: $selectedTab) {
            TodayScreen(
                plans: model.plans,
                finance: model.finance,
                workouts: model.workouts,
                selectedTab: $selectedTab,
                showSettings: $showSettingsSheet
            )
            .tabItem { Label(MainTab.today.title, systemImage: MainTab.today.icon) }
            .tag(MainTab.today)

            FinanceScreen(store: model.finance, inputs: model.inputs, dictation: model.dictation, client: isScreenshotSignedInMode ? nil : model.auth.client, showSettings: $showSettingsSheet)
                .keyboardDismissBar()
                .tabItem { Label(MainTab.money.title, systemImage: MainTab.money.icon) }
                .tag(MainTab.money)

            PlanScreen(
                store: model.plans,
                recorder: model.recorder,
                inputs: model.inputs,
                dictation: model.dictation,
                workouts: model.workouts,
                showSettings: $showSettingsSheet,
                onOpenWorkout: { selectedTab = .workout }
            )
                .keyboardDismissBar()
                .tabItem { Label(MainTab.plans.title, systemImage: MainTab.plans.icon) }
                .tag(MainTab.plans)

            WorkoutScreen(store: model.workouts, showSettings: $showSettingsSheet)
                .keyboardDismissBar()
                .tabItem { Label(MainTab.workout.title, systemImage: MainTab.workout.icon) }
                .tag(MainTab.workout)
        }
        .tint(DS.Colors.accent)
    }
}
