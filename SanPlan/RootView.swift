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

public struct TodayView: View {
    @Binding var showSettings: Bool

    public var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                EmptyState(
                    title: "Сегодня",
                    message: "Сводка планов, финансов и тренировок появится здесь.",
                    icon: "sun.max"
                )
            }
            .navigationTitle("Сегодня")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CircleIconButton(
                        icon: "person.crop.circle",
                        accessibilityLabel: "Настройки"
                    ) {
                        showSettings = true
                    }
                }
            }
        }
    }
}

public struct MoneyView: View {
    @Binding var showSettings: Bool

    public var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                EmptyState(
                    title: "Деньги",
                    message: "Локальный сейф расходов и доходов.",
                    icon: "creditcard"
                )
            }
            .navigationTitle("Деньги")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CircleIconButton(
                        icon: "person.crop.circle",
                        accessibilityLabel: "Настройки"
                    ) {
                        showSettings = true
                    }
                }
            }
        }
    }
}

public struct PlansView: View {
    @Binding var showSettings: Bool

    public var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                EmptyState(
                    title: "Планы",
                    message: "Расписание событий, задачи и напоминания.",
                    icon: "calendar"
                )
            }
            .navigationTitle("Планы")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CircleIconButton(
                        icon: "person.crop.circle",
                        accessibilityLabel: "Настройки"
                    ) {
                        showSettings = true
                    }
                }
            }
        }
    }
}

public struct WorkoutView: View {
    @Binding var showSettings: Bool

    public var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                EmptyState(
                    title: "Тренировка",
                    message: "Таймер подходов, периоды отдыха и упражнения.",
                    icon: "figure.run"
                )
            }
            .navigationTitle("Тренировка")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CircleIconButton(
                        icon: "person.crop.circle",
                        accessibilityLabel: "Настройки"
                    ) {
                        showSettings = true
                    }
                }
            }
        }
    }
}

public struct RootView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var selectedTab: MainTab = .today
    @State private var showSettingsSheet: Bool = false

    public init() {}

    private var isScreenshotSignedInMode: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--screenshot-signed-in")
        #else
        return false
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
        .task {
            if !isScreenshotSignedInMode {
                await authService.loadStatus()
            }
        }
    }

    private var mainTabsView: some View {
        TabView(selection: $selectedTab) {
            TodayView(showSettings: $showSettingsSheet)
                .tabItem {
                    Label(MainTab.today.title, systemImage: MainTab.today.icon)
                }
                .tag(MainTab.today)

            MoneyView(showSettings: $showSettingsSheet)
                .tabItem {
                    Label(MainTab.money.title, systemImage: MainTab.money.icon)
                }
                .tag(MainTab.money)

            PlansView(showSettings: $showSettingsSheet)
                .tabItem {
                    Label(MainTab.plans.title, systemImage: MainTab.plans.icon)
                }
                .tag(MainTab.plans)

            WorkoutView(showSettings: $showSettingsSheet)
                .tabItem {
                    Label(MainTab.workout.title, systemImage: MainTab.workout.icon)
                }
                .tag(MainTab.workout)
        }
        .tint(DS.Colors.accent)
    }
}
