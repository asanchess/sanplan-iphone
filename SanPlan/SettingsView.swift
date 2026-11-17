import SwiftUI

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var alarmCoordinator: AlarmCoordinator
    @EnvironmentObject private var workouts: WorkoutStore
    @EnvironmentObject private var onboarding: OnboardingModel

    @State private var showSignOutConfirmation: Bool = false
    @ObservedObject private var sounds = AlertSoundSettings.shared
    @AppStorage("pet.visible") private var petVisible = true

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
                        ScreenHeader("Профиль", kicker: "Настройки и данные") {
                            CircleIconButton(icon: "xmark", accessibilityLabel: "Закрыть профиль") { dismiss() }
                        }
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
                            Card {
                                AlertSoundRow(title: "Звук напоминаний", choice: sounds.plan, onSelect: sounds.setPlan, volume: sounds.planVolume, onVolume: sounds.setPlanVolume)
                            }
                        }

                        WorkoutDefaultsSection(store: workouts)

                        // Герой
                        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                            SectionHeader("Герой")
                            Card {
                                VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                                    Toggle(isOn: $petVisible) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Показывать героя")
                                                .font(DS.Fonts.body)
                                                .foregroundColor(DS.Colors.textPrimary)
                                            Text("Ходит внизу экрана. Нажмите на него — покажет главное.")
                                                .font(DS.Fonts.text(14, relativeTo: .footnote))
                                                .foregroundColor(DS.Colors.textSecondary)
                                        }
                                    }
                                    .tint(DS.Colors.today)
                                    .accessibilityIdentifier("pet-toggle")
                                }
                            }
                        }

                        // Недавно удалённые
                        NavigationLink {
                            RecentlyDeletedScreen()
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                    .foregroundColor(DS.Colors.textSecondary)
                                Text("Недавно удалённые")
                                    .font(DS.Fonts.body)
                                    .foregroundColor(DS.Colors.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(DS.Colors.textMuted)
                            }
                            .padding(DS.Metrics.spacing16)
                            .frame(minHeight: DS.Metrics.minHitTarget)
                            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Metrics.cardRadius))
                        }
                        .accessibilityIdentifier("recently-deleted")

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
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.sectionAccent, DS.Colors.today)
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
    @ObservedObject private var sounds = AlertSoundSettings.shared

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
            Card {
                AlertSoundRow(title: "Звук конца отдыха", choice: sounds.rest, onSelect: sounds.setRest, volume: sounds.restVolume, onVolume: sounds.setRestVolume)
            }
        }
    }

    private func change(_ edit: (inout WorkoutDefaults) -> Void) {
        var next = defaults
        edit(&next)
        store.updateProgram(label: nil) { try WorkoutProgram.setDefaults($0, next) }
    }
}

