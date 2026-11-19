import SwiftUI

/// Settings sections of «Профиль» (canvas Profile.html, screen «Настройки»), one chip each.
enum ProfileSettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, plans, notes, money, workout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Общие"
        case .plans: return "Планы и будильники"
        case .notes: return "Заметки"
        case .money: return "Деньги"
        case .workout: return "Тренировка"
        }
    }

    var chipTitle: String {
        switch self {
        case .plans: return "Планы"
        default: return title
        }
    }

    var note: String {
        switch self {
        case .general: return "Краткий тур, версия"
        case .plans: return "Календарь, будильники, звук"
        case .notes: return "Как хранятся заметки"
        case .money: return "План бюджета, операции"
        case .workout: return "Подходы, отдых, серия"
        }
    }

    /// The tab whose settings these are; «Общие» belongs to «Сегодня», which is always on.
    var tab: MainTab {
        switch self {
        case .general: return .today
        case .plans: return .plans
        case .notes: return .notes
        case .money: return .money
        case .workout: return .workout
        }
    }

    /// Shared settings stay violet; a section's own settings take its colour.
    var color: Color {
        switch self {
        case .general: return DS.Colors.today
        case .plans: return DS.Colors.plans
        case .notes: return DS.Colors.notes
        case .money: return DS.Colors.money
        case .workout: return DS.Colors.workout
        }
    }
}

/// «Профиль → Настройки»: chips for the sections and the settings of the chosen one.
struct ProfileSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var alarmCoordinator: AlarmCoordinator
    @EnvironmentObject private var workouts: WorkoutStore
    @ObservedObject private var sounds = AlertSoundSettings.shared
    @ObservedObject private var sections = SectionSettings.shared

    @State private var section: ProfileSettingsSection
    /// Closes the whole profile sheet (the tour and the deep links need the tabs).
    let closeProfile: () -> Void

    init(section: ProfileSettingsSection, closeProfile: @escaping () -> Void) {
        _section = State(initialValue: section)
        self.closeProfile = closeProfile
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProfileHeader(kicker: "Профиль", title: "Настройки", backLabel: "Назад") { dismiss() }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // A section that is off has no settings chip; «Общие → Разделы» turns it back on.
                        ForEach(ProfileSettingsSection.allCases.filter { sections.isOn($0.tab) }) { item in
                            ProfileChip(title: item.chipTitle, color: item.color, selected: item == section) {
                                section = item
                            }
                            .accessibilityIdentifier("profile-chip-\(item.rawValue)")
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 6)
                }
                content
                    .environment(\.sectionAccent, section.color)
                    .tint(section.color)
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(DS.Colors.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: general
        case .plans: plans
        case .notes: notes
        case .money: money
        case .workout: WorkoutDefaultsSection(store: workouts)
        }
    }

    // MARK: Sections

    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
        ProfileGroup("Разделы") {
            ForEach(SectionSettings.optional, id: \.self) { tab in
                ProfileToggleRow(
                    name: tab.title,
                    note: sections.isOn(tab) ? nil : "Скрыт, данные сохранены",
                    isOn: Binding(get: { sections.isOn(tab) }, set: { sections.set(tab, on: $0) })
                )
                .accessibilityIdentifier("profile-section-\(SectionSettings.name(of: tab))")
            }
        }
        ProfileGroup("Общие") {
            Button {
                closeProfile()
                Task { @MainActor in
                    // The sheet closes first, so the tour starts on the tabs.
                    try? await Task.sleep(for: .milliseconds(500))
                    TourCenter.shared.start(.short)
                }
            } label: {
                ProfileRow("Краткий тур", note: "Главное в каждом разделе").contentShape(Rectangle())
            }
            .buttonStyle(ProfileRowButtonStyle())
            .accessibilityIdentifier("profile-short-tour")
            ProfileRow("Версия ARNA") { ProfileValue(appVersion) }
        }
        }
    }

    private var plans: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProfileGroup("Google Календарь") {
                ProfileRow("Синхронизация событий", note: calendarStatus)
                Button {
                    Task {
                        if isCalendarConnected { await authService.disconnectCalendar() } else { await authService.connectCalendar() }
                    }
                } label: {
                    ProfileRow(isCalendarConnected ? "Отключить календарь" : "Подключить календарь",
                               nameColor: isCalendarConnected ? DS.Colors.destructive : DS.Colors.plans) {
                        if authService.isAuthenticating { ProgressView().tint(DS.Colors.plans) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(ProfileRowButtonStyle())
                .disabled(authService.isAuthenticating)
            }
            ProfileGroup("Будильники") {
                ProfileRow("Системный доступ AlarmKit") { ProfileValue(alarmCoordinator.authorizationStatusText) }
                if !alarmCoordinator.isAuthorized {
                    Button {
                        Task { await alarmCoordinator.requestAuthorization() }
                    } label: {
                        ProfileRow("Разрешить доступ", nameColor: DS.Colors.plans).contentShape(Rectangle())
                    }
                    .buttonStyle(ProfileRowButtonStyle())
                }
                AlertSoundRow(title: "Звук напоминаний", choice: sounds.plan, onSelect: sounds.setPlan, volume: sounds.planVolume, onVolume: sounds.setPlanVolume)
                ProfileNavRow(name: "Все будильники", note: "Открыть в «Планах»") { open(.alarms) }
            }
        }
    }

    private var notes: some View {
        ProfileGroup("Заметки") {
            ProfileRow("Шифрование", note: "Заметки хранятся зашифрованными ключом данных аккаунта.")
            ProfileNavRow(name: "Все заметки", note: "Открыть «Заметки»") { open(.notes) }
        }
    }

    private var money: some View {
        ProfileGroup("Деньги") {
            ProfileNavRow(name: "План бюджета", note: "Лимиты и обязательные платежи") { open(.moneyPlan) }
            ProfileNavRow(name: "Операции", note: "Все траты и доходы, импорт выписки") { open(.moneyOperations) }
        }
    }

    // MARK: Helpers

    /// RootView closes the profile sheet and switches the tab on a deep link.
    private func open(_ link: DeepLink) {
        closeProfile()
        DeepLinks.shared.open(link)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var isCalendarConnected: Bool { authService.status?.google?.connected ?? false }

    private var calendarStatus: String {
        guard let google = authService.status?.google else { return "Статус неизвестен" }
        guard google.connected else { return "Не подключён" }
        return google.needsReconnect == true ? "Нужно подключить заново" : "Подключён"
    }
}
