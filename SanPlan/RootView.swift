import SwiftUI
import UIKit

/// Raw values stay fixed for `--screenshot-tab` and UI tests; tabs show in the order of `mainTabsView`.
public enum MainTab: Int, CaseIterable, Identifiable {
    case today = 0
    case money = 1
    case plans = 2
    case workout = 3
    case notes = 4

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .today: return "Сегодня"
        case .money: return "Деньги"
        case .plans: return "Планы"
        case .workout: return "Тренировка"
        case .notes: return "Заметки"
        }
    }

    public var icon: String {
        switch self {
        case .today: return "sun.max"
        case .money: return "creditcard"
        case .plans: return "calendar"
        case .workout: return "figure.run"
        case .notes: return "note.text"
        }
    }
}

public struct RootView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var authService: AuthService
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTab = .today
    @State private var goalsRequest = 0
    @State private var habitsRequest = 0
    @StateObject private var onboarding = OnboardingModel()
    @State private var showSettingsSheet: Bool = false
    @State private var fullAlarmText: String? = nil
    @State private var showCapture = false
    @State private var showProgress = false
    @State private var keyboardVisible = false
    @State private var mounted: Set<MainTab> = []
    @ObservedObject private var undoCenter = UndoCenter.shared
    @ObservedObject private var reviewNotifications = ReviewNotifications.shared

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
                        .onboardingTour(model: onboarding, review: model.reviews)
                }
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
                .environmentObject(onboarding)
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
            RecentlyDeleted.shared.register(HabitStore.shared)
            RecentlyDeleted.shared.register(GoalStore.shared)
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
                showProgress = false
                showCapture = false
                mounted = []
                undoCenter.dismiss()
                selectedTab = .today
                model.clearAccountData()
                onboarding.accountChanged(nil)
            case .signedIn(let email):
                model.accountSignedIn(email: email)
                onboarding.attach(settings: model.appSettings)
                onboarding.accountChanged(email)
            case .checking:
                break
            }
        }
        .onAppear { onboarding.attach(settings: model.appSettings) }
        // The account's settings arrive after the first sync: the tour is decided then.
        .onReceive(model.appSettings.objectWillChange.receive(on: DispatchQueue.main)) { _ in
            onboarding.settingsChanged()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !isScreenshotSignedInMode { model.becameActive() }
            if phase == .background { model.becameInactive() }
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
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()
            ForEach(MainTab.ordered) { tab in
                if mounted.contains(tab) || tab == selectedTab {
                    TabStage(isActive: tab == selectedTab) { screen(for: tab) }
                        .environment(\.sectionAccent, tab.accent)
                }
            }
        }
        .environment(\.headerShortcuts, HeaderShortcuts(
            openProfile: { showSettingsSheet = true },
            openProgress: { showProgress = true }
        ))
        .overlayPreferenceValue(PetTipKey.self) { tips in
            GeometryReader { proxy in
                PetLayer(
                    tips: tips.map { PetResolvedTip(text: $0.text, rect: proxy[$0.anchor]) },
                    area: proxy.size,
                    idleLine: "Это главное на экране «\(selectedTab.title)». Спрятать меня можно в профиле."
                )
            }
        }
        .overlay(alignment: .bottom) {
            UndoToast(center: undoCenter)
                .padding(.bottom, 80)
                .animation(.easeOut(duration: 0.2), value: undoCenter.offer?.id)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardVisible {
                ArnaTabBar(selection: $selectedTab, tabs: MainTab.ordered)
            }
        }
        .onChange(of: selectedTab, initial: true) { _, tab in mounted.insert(tab) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .tint(DS.Colors.accent)
        .onChange(of: reviewNotifications.dayReviewRequests) { _, _ in selectedTab = .today }
        .sheet(isPresented: $showProgress) {
            ProgressScreen(plans: model.plans, finance: model.finance, workouts: model.workouts) { tab in selectedTab = tab }
        }
        .sheet(isPresented: $showCapture) {
            CaptureSheet(
                inputs: model.inputs,
                dictation: model.dictation,
                notes: model.notes,
                onMakePlan: { handOff($0, to: .plans) },
                onMakeExpense: { handOff($0, to: .money) },
                onSaved: {},
                askData: { [model] in AskData.current(plans: model.plans, finance: model.finance, workouts: model.workouts) }
            )
        }
    }

    @ViewBuilder
    private func screen(for tab: MainTab) -> some View {
        switch tab {
        case .today:
            TodayScreen(
                plans: model.plans,
                finance: model.finance,
                workouts: model.workouts,
                selectedTab: $selectedTab,
                showSettings: $showSettingsSheet,
                notes: model.notes,
                reviewsVault: model.reviewsVault,
                inputs: model.inputs,
                appStreak: { [model] day in model.appStreak(today: day) },
                dictation: model.dictation,
                onOpenGoals: { selectedTab = .plans; goalsRequest += 1 },
                onOpenHabits: { selectedTab = .plans; habitsRequest += 1 },
                reviewRequest: reviewNotifications.dayReviewRequests,
                review: model.reviews
            )
            .captureButton(action: openCapture)
        case .plans:
            // Plans and Money keep their own composer at the bottom, so no second «+» there.
            PlanScreen(
                store: model.plans,
                recorder: model.recorder,
                inputs: model.inputs,
                dictation: model.dictation,
                workouts: model.workouts,
                showSettings: $showSettingsSheet,
                onOpenWorkout: { selectedTab = .workout },
                streakSources: model.streakSources,
                savingsOptions: model.finance.savingsGoals.map { GoalSavingsOption(id: $0.id, title: $0.title) },
                weekRatings: model.reviews.weeks,
                goalsRequest: goalsRequest,
                habitsRequest: habitsRequest
            )
            .keyboardDismissBar()
        case .notes:
            NotesScreen(
                store: model.notes,
                vault: model.vault,
                showSettings: $showSettingsSheet,
                onMakePlan: { handOff($0, to: .plans) },
                onMakeExpense: { handOff($0, to: .money) },
                onCapture: openCapture
            )
            .keyboardDismissBar()
        case .money:
            FinanceScreen(store: model.finance, inputs: model.inputs, dictation: model.dictation, client: isScreenshotSignedInMode ? nil : model.auth.client, showSettings: $showSettingsSheet)
                .keyboardDismissBar()
        case .workout:
            WorkoutTab(store: model.workouts, showSettings: $showSettingsSheet, onCapture: openCapture)
        }
    }

    private func openCapture() {
        // The composer shares the mic with Plans and Money: stop theirs rather than record into two places.
        if model.dictation.isListening(to: .plans) || model.dictation.isListening(to: .money) { model.dictation.stop() }
        showCapture = true
    }

    /// Puts the text into that tab's own field and opens it; nothing is parsed or saved behind the person's back.
    private func handOff(_ text: String, to tab: MainTab) {
        let target: InputDrafts.Target = tab == .money ? .money : .plans
        let existing = model.inputs.text(target).trimmingCharacters(in: .whitespacesAndNewlines)
        model.inputs.edit(existing.isEmpty ? text : existing + "\n" + text, for: target)
        selectedTab = tab
    }
}

/// Watches the workout, so the «+» hides as soon as one starts.
private struct WorkoutTab: View {
    @ObservedObject var store: WorkoutStore
    @Binding var showSettings: Bool
    let onCapture: () -> Void

    var body: some View {
        WorkoutScreen(store: store, showSettings: $showSettings)
            .keyboardDismissBar()
            // A running workout owns the screen: no stray tap opens a composer over the timer.
            .captureButton(isEnabled: store.activeSession == nil, action: onCapture)
    }
}

/// The round «+» that opens the shared composer, hidden while the keyboard is up. It sits in the safe area, so lists scroll clear of it.
private struct CaptureButton: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void
    @State private var keyboardVisible = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                if isEnabled && !keyboardVisible {
                    Button(action: action) {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(DS.Colors.accentDeep, in: Circle())
                            .overlay(Circle().stroke(DS.Colors.ink, lineWidth: 2))
                            .background(Circle().fill(DS.Colors.ink).offset(x: 4, y: 4))
                    }
                    .buttonStyle(PressScaleStyle())
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel("Записать")
                    .accessibilityHint("Заметка, план или трата")
                    .padding(.trailing, DS.Metrics.screenGutter)
                    .padding(.bottom, DS.Metrics.spacing12)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }
}

extension View {
    func captureButton(isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(CaptureButton(isEnabled: isEnabled, action: action))
    }
}
