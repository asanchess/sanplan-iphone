import SwiftUI

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var alarmCoordinator: AlarmCoordinator
    @EnvironmentObject private var workouts: WorkoutStore

    @State private var showSignOutConfirmation: Bool = false

    public init() {}

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: DS.Metrics.spacing24) {
                        if let error = authService.errorMessage {
                            ErrorBanner(message: error) {
                                authService.errorMessage = nil
                            }
                        }

                        // Учетная запись
                        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                            SectionHeader("Учетная запись")
                            Card {
                                VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                                    Text("Электронная почта")
                                        .font(.caption)
                                        .foregroundColor(DS.Colors.textSecondary)

                                    Text(accountEmailText)
                                        .font(.body)
                                        .foregroundColor(DS.Colors.textPrimary)
                                }
                            }
                        }

                        // Google Календарь
                        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                            SectionHeader("Google Календарь")
                            Card {
                                VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: DS.Metrics.spacing4) {
                                            Text("Синхронизация событий")
                                                .font(.body.weight(.medium))
                                                .foregroundColor(DS.Colors.textPrimary)
                                            Text(calendarStatusSubtitle)
                                                .font(.subheadline)
                                                .foregroundColor(DS.Colors.textSecondary)
                                        }
                                        Spacer()
                                    }

                                    if isCalendarConnected {
                                        PillButton(
                                            "Отключить календарь",
                                            style: .secondary,
                                            isLoading: authService.isAuthenticating
                                        ) {
                                            Task {
                                                await authService.disconnectCalendar()
                                            }
                                        }
                                    } else {
                                        PillButton(
                                            "Подключить календарь",
                                            style: .primary,
                                            isLoading: authService.isAuthenticating
                                        ) {
                                            Task {
                                                await authService.connectCalendar()
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Будильники
                        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                            SectionHeader("Будильники")
                            Card {
                                VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                                    HStack {
                                        Text("Системный доступ AlarmKit")
                                            .font(.body)
                                            .foregroundColor(DS.Colors.textPrimary)
                                        Spacer()
                                        Text(alarmCoordinator.authorizationStatusText)
                                            .font(.subheadline)
                                            .foregroundColor(alarmCoordinator.isAuthorized ? DS.Colors.positive : DS.Colors.textSecondary)
                                    }

                                    if !alarmCoordinator.isAuthorized {
                                        PillButton("Разрешить доступ", style: .secondary) {
                                            Task {
                                                await alarmCoordinator.requestAuthorization()
                                            }
                                        }
                                        .padding(.top, DS.Metrics.spacing8)
                                    }
                                }
                            }
                        }

                        WorkoutDefaultsSection(store: workouts)

                        // О приложении
                        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                            SectionHeader("О приложении")
                            Card {
                                HStack {
                                    Text("Версия ARNA")
                                        .font(.body)
                                        .foregroundColor(DS.Colors.textPrimary)
                                    Spacer()
                                    Text(appVersionString)
                                        .font(.body.monospacedDigit())
                                        .foregroundColor(DS.Colors.textSecondary)
                                }
                            }
                        }

                        OnboardingSettingsRow(model: onboarding, dismiss: { dismiss() })

                        AccountDataSection { dismiss() }

                        // Выход
                        PillButton(
                            "Выйти из аккаунта",
                            style: .destructive,
                            isLoading: authService.isAuthenticating
                        ) {
                            showSignOutConfirmation = true
                        }
                        .padding(.top, DS.Metrics.spacing8)
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.vertical, DS.Metrics.spacing24)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CircleIconButton(
                        icon: "xmark",
                        accessibilityLabel: "Закрыть настройки"
                    ) {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Вы уверены, что хотите выйти?",
                isPresented: $showSignOutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Выйти", role: .destructive) {
                    Task {
                        await authService.signOut()
                        // Plan titles must not keep ringing after the owner signed out on purpose.
                        // A session that merely expired keeps its alarms: a missed alarm is the worse failure.
                        if authService.phase == .signedOut {
                            await alarmCoordinator.deleteAllOwnAlarms()
                        }
                        dismiss()
                    }
                }
                Button("Отмена", role: .cancel) {}
            }
        }
    }

    private var accountEmailText: String {
        if let email = authService.status?.account?.email, !email.isEmpty {
            return email
        }
        if case .signedIn(let email) = authService.phase {
            return email
        }
        return "Неизвестно"
    }

    private var isCalendarConnected: Bool {
        authService.status?.google?.connected ?? false
    }

    private var calendarStatusSubtitle: String {
        if let google = authService.status?.google {
            if google.connected {
                if google.needsReconnect == true {
                    return "Требуется повторное подключение"
                }
                return "Подключен"
            }
            return "Не подключен"
        }
        return "Статус неизвестен"
    }
}

/// Starting values for exercises added in the builder. Existing exercises keep their own numbers.
struct WorkoutDefaultsSection: View {
    @ObservedObject var store: WorkoutStore

    private var defaults: WorkoutDefaults { WorkoutProgram.defaults(of: store.program) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            SectionHeader("Тренировка")
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                    ValueStepperRow(
                        title: "Подходов",
                        value: "\(defaults.sets)",
                        canDecrease: defaults.sets > WorkoutProgram.setsRange.lowerBound,
                        canIncrease: defaults.sets < WorkoutProgram.setsRange.upperBound,
                        onDecrease: { change { $0.sets -= 1 } },
                        onIncrease: { change { $0.sets += 1 } }
                    )
                    ValueStepperRow(
                        title: "Отдых между подходами",
                        value: WorkoutFormat.rest(defaults.restBetweenSets),
                        canDecrease: defaults.restBetweenSets > WorkoutProgram.restRange.lowerBound,
                        canIncrease: defaults.restBetweenSets < WorkoutProgram.restRange.upperBound,
                        onDecrease: { change { $0.restBetweenSets -= WorkoutProgram.restStep } },
                        onIncrease: { change { $0.restBetweenSets += WorkoutProgram.restStep } }
                    )
                    ValueStepperRow(
                        title: "Отдых между упражнениями",
                        value: WorkoutFormat.rest(defaults.restBetweenExercises),
                        canDecrease: defaults.restBetweenExercises > WorkoutProgram.restRange.lowerBound,
                        canIncrease: defaults.restBetweenExercises < WorkoutProgram.restRange.upperBound,
                        onDecrease: { change { $0.restBetweenExercises -= WorkoutProgram.restStep } },
                        onIncrease: { change { $0.restBetweenExercises += WorkoutProgram.restStep } }
                    )
                    Text("Применяется к новым упражнениям. Уже добавленные не меняются.")
                        .font(.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                    ValueStepperRow(
                        title: "Тренировок в неделю для серии",
                        value: "\(store.weeklyGoal)",
                        canDecrease: store.weeklyGoal > WorkoutHistory.goalRange.lowerBound,
                        canIncrease: store.weeklyGoal < WorkoutHistory.goalRange.upperBound,
                        onDecrease: { store.setWeeklyGoal(store.weeklyGoal - 1) },
                        onIncrease: { store.setWeeklyGoal(store.weeklyGoal + 1) }
                    )
                    if store.history.weeklyGoal != nil {
                        Button("Как в плане: \(WorkoutHistory.effectiveGoal(nil, planDays: store.program.days.count))") {
                            store.setWeeklyGoal(nil)
                        }
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.accent)
                    } else {
                        Text("Сейчас — по числу тренировочных дней в плане.")
                            .font(.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
            }
            WorkoutHealthRow(store: store, health: WorkoutHealthExport.shared)
        }
    }

    private func change(_ edit: (inout WorkoutDefaults) -> Void) {
        var next = defaults
        edit(&next)
        store.updateProgram(label: nil) { try WorkoutProgram.setDefaults($0, next) }
    }
}

/// Writing finished workouts to Apple Health. Off until turned on here.
struct WorkoutHealthRow: View {
    @ObservedObject var store: WorkoutStore
    @ObservedObject var health: WorkoutHealthExport

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                Toggle(isOn: Binding(
                    get: { health.isEnabled },
                    set: { health.setEnabled($0, records: store.records) }
                )) {
                    Text("Записывать в «Здоровье»")
                        .font(.body)
                        .foregroundColor(DS.Colors.textPrimary)
                }
                .tint(DS.Colors.accent)
                .disabled(health.isWorking)
                Text(health.problem ?? "Тренировки из истории, с правками и удалениями.")
                    .font(.caption)
                    .foregroundColor(health.problem == nil ? DS.Colors.textSecondary : DS.Colors.destructive)
            }
        }
    }
}
