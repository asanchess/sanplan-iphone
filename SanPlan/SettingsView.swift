import SwiftUI

/// Places inside «Профиль».
enum ProfileRoute: Hashable {
    case mascot
    case settings(ProfileSettingsSection)
    case recentlyDeleted
}

/// «Профиль» (canvas Profile.html, owner decision 17.11): avatar, name and current arc on top, then
/// «Маскот», «Настройки» by section, «Недавно удалённые» and «Аккаунт». Shared, so it stays violet.
/// The type keeps its old name: RootView opens it as the settings sheet.
public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var workouts: WorkoutStore

    @ObservedObject private var wardrobe = MascotWardrobe.shared
    @ObservedObject private var deleted = RecentlyDeleted.shared
    @ObservedObject private var names = ProfileNameStore.shared
    @AppStorage("pet.visible") private var petVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [ProfileRoute] = []

    private let onOpenProgress: (() -> Void)?
    private let onClose: (() -> Void)?
    private let plans: PlanStore?

    /// - onOpenProgress: «Открыть прогресс» in the arc card; hidden when nil. RootView closes this sheet in it.
    /// - plans: lets the profile count arc weeks itself (with the workouts from the environment).
    /// - onClose: closes the sheet through its owner's flag; the environment `dismiss` is used when nil.
    public init(onOpenProgress: (() -> Void)? = nil, onClose: (() -> Void)? = nil, plans: PlanStore? = nil) {
        self.onOpenProgress = onOpenProgress
        self.onClose = onClose
        self.plans = plans
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ProfileHeader(kicker: "Профиль и настройки", title: "Профиль", backLabel: "Закрыть профиль") { close() }
                    if let error = authService.errorMessage {
                        ErrorBanner(message: error) { authService.errorMessage = nil }
                    }
                    arcCard
                    mascotGroup
                    settingsGroup
                    ProfileGroup("Недавно удалённые") {
                        ProfileNavRow(name: "Недавно удалённые", note: "Вернуть можно \(RecentlyDeleted.keepDays) дней",
                                      value: deleted.items.isEmpty ? "Пусто" : "\(deleted.items.count)") {
                            path.append(.recentlyDeleted)
                        }
                        .accessibilityIdentifier("recently-deleted")
                    }
                    AccountDataSection(email: accountEmailText, onDeleted: { close() }, onSignedOut: { close() })
                }
                .padding(.horizontal, DS.Metrics.screenGutter)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .background(DS.Colors.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ProfileRoute.self) { route in
                switch route {
                case .mascot:
                    ProfileMascotScreen()
                case .settings(let section):
                    ProfileSettingsScreen(section: section, closeProfile: { close() })
                case .recentlyDeleted:
                    RecentlyDeletedScreen()
                }
            }
        }
        .environment(\.sectionAccent, DS.Colors.today)
        .tint(DS.Colors.today)
        .onAppear {
            countArcWeeks()
            openScreenshotRoute()
        }
    }

    // MARK: Top

    /// The nickname from «Аккаунт → Имя», or the part of the email before «@».
    private var displayName: String {
        if ScreenshotRoute.demoData { return "Алекс" }
        return ProfileNickname.display(nickname: names.nickname, email: accountEmailText)
    }

    /// «Показывать героя» on: the mascot stands as before. Off: it sits resting, faded, with a caption.
    private var arcMascot: some View {
        VStack(spacing: 4) {
            if petVisible {
                MascotSkinImage(skin: wardrobe.skinID, pose: .shrug, height: 112, fallbackToBase: true)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            } else {
                MascotSkinImage(skin: wardrobe.skinID, pose: .rest, height: 90, fallbackToBase: true)
                    .saturation(0.3)
                    .opacity(0.75)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                Text("Отдыхает")
                    .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                    .opacity(0.85)
                    .transition(.opacity)
            }
        }
        // A fixed box: the two poses differ in width, and the card's text must not move when the hero changes.
        .frame(width: 104, height: 130)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: petVisible)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(petVisible ? "Герой" : "Герой отдыхает")
    }

    private var arcCard: some View {
        let arc = wardrobe.currentArc
        let weeks = wardrobe.weeksInCurrentArc
        return HStack(alignment: .center, spacing: 14) {
            arcMascot
            VStack(alignment: .leading, spacing: 8) {
                Text("АРКА · \(arc.title.uppercased())")
                    .font(DS.Fonts.text(13, .heavy, relativeTo: .caption))
                    .tracking(0.8)
                    .opacity(0.85)
                    .accessibilityLabel("Арка «\(arc.title)»")
                Text(displayName)
                    .font(DS.Fonts.display(20, relativeTo: .title3))
                    .shadow(color: DS.Colors.ink, radius: 0, x: 3, y: 3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if wardrobe.isCounted {
                    Text("Засчитано недель: \(weeks) из \(MascotArcs.weeksPerArc)")
                        .font(DS.Fonts.text(15, .semibold, relativeTo: .subheadline))
                        .opacity(0.9)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.Colors.ink.opacity(0.45))
                            Capsule().fill(Color.white)
                                .frame(width: proxy.size.width * CGFloat(weeks) / CGFloat(MascotArcs.weeksPerArc))
                        }
                    }
                    .frame(height: 10)
                    .accessibilityElement()
                    .accessibilityLabel("Засчитано \(weeks) из \(MascotArcs.weeksPerArc) недель арки")
                } else if let next = wardrobe.nextArc {
                    Text("Дальше — «\(next.title)»: \(MascotArcs.weeksPerArc) засчитанных недель")
                        .font(DS.Fonts.text(15, .semibold, relativeTo: .subheadline))
                        .opacity(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onOpenProgress {
                    Button {
                        onOpenProgress()
                    } label: {
                        Text("Открыть прогресс")
                            .font(DS.Fonts.text(15, .heavy, relativeTo: .subheadline))
                            .underline()
                            .frame(minHeight: 32)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [DS.Colors.hex(0x6A48D7), DS.Colors.hex(0x8B6CF0)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(Color.white.opacity(0.10)).frame(width: 54, height: 400)
                    .rotationEffect(.degrees(24)).offset(x: -34, y: -60)
                Rectangle().fill(Color.white.opacity(0.10)).frame(width: 18, height: 400)
                    .rotationEffect(.degrees(24)).offset(x: 6, y: -60)
            }
            // The stripes reach far past the card; clipping hides them but does not stop them taking taps,
            // and they covered the header's «Закрыть профиль» above the card.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .inked(cornerRadius: 24, shadow: 6)
        .padding(.trailing, 6)
        .accessibilityElement(children: .contain)
    }

    // MARK: Groups

    private var mascotGroup: some View {
        ProfileGroup("Маскот") {
            ProfileToggleRow(name: "Показывать героя", note: "Гуляет внизу экрана и молчит, пока не спросите", isOn: $petVisible)
                .accessibilityIdentifier("pet-toggle")
            ProfileNavRow(name: "Образ", note: "Открытые образы можно надеть в любой арке",
                          value: MascotArcs.skin(wardrobe.skinID)?.title) {
                path.append(.mascot)
            }
            .accessibilityIdentifier("profile-mascot")
        }
    }

    private var settingsGroup: some View {
        ProfileGroup("Настройки") {
            ForEach(ProfileSettingsSection.allCases) { section in
                ProfileNavRow(name: section.title, note: section.note, marker: section.color) {
                    path.append(.settings(section))
                }
                .accessibilityIdentifier("profile-settings-\(section.rawValue)")
            }
        }
    }

    // MARK: Data

    private var accountEmailText: String {
        if ScreenshotRoute.demoData { return "alex@example.com" }
        if let email = authService.status?.account?.email, !email.isEmpty { return email }
        if case .signedIn(let email) = authService.phase { return email }
        return "Неизвестно"
    }

    private func countArcWeeks() {
        guard let plans, !ScreenshotRoute.demoData else { return }
        let today = PlanDomain.today(timeZone: plans.timeZone)
        wardrobe.update(countedWeeks: MascotArcs.countedWeeks(plans: plans, records: workouts.records, today: today))
    }

    private func openScreenshotRoute() {
        guard path.isEmpty else { return }
        if ScreenshotRoute.is("profile-mascot") { path = [.mascot] }
        if ScreenshotRoute.is("profile-settings") { path = [.settings(.general)] }
    }
}

/// Starting values for exercises added in the builder, the weekly goal and the end-of-rest sound.
/// Existing exercises keep their own numbers.
struct WorkoutDefaultsSection: View {
    @ObservedObject var store: WorkoutStore
    @ObservedObject private var sounds = AlertSoundSettings.shared
    @ObservedObject private var reminder = WorkoutReminderSettings.shared
    @EnvironmentObject private var alarms: AlarmCoordinator
    @Environment(\.sectionAccent) private var accent

    private var defaults: WorkoutDefaults { WorkoutProgram.defaults(of: store.program) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                ProfileGroup("Новые упражнения") {
                    stepper(ValueStepperRow(
                        title: "Подходов",
                        value: "\(defaults.sets)",
                        canDecrease: defaults.sets > WorkoutProgram.setsRange.lowerBound,
                        canIncrease: defaults.sets < WorkoutProgram.setsRange.upperBound,
                        onDecrease: { change { $0.sets -= 1 } },
                        onIncrease: { change { $0.sets += 1 } }
                    ))
                    stepper(ValueStepperRow(
                        title: "Отдых между подходами",
                        value: WorkoutFormat.rest(defaults.restBetweenSets),
                        canDecrease: defaults.restBetweenSets > WorkoutProgram.restRange.lowerBound,
                        canIncrease: defaults.restBetweenSets < WorkoutProgram.restRange.upperBound,
                        onDecrease: { change { $0.restBetweenSets -= WorkoutProgram.restStep } },
                        onIncrease: { change { $0.restBetweenSets += WorkoutProgram.restStep } }
                    ))
                    stepper(ValueStepperRow(
                        title: "Отдых между упражнениями",
                        value: WorkoutFormat.rest(defaults.restBetweenExercises),
                        canDecrease: defaults.restBetweenExercises > WorkoutProgram.restRange.lowerBound,
                        canIncrease: defaults.restBetweenExercises < WorkoutProgram.restRange.upperBound,
                        onDecrease: { change { $0.restBetweenExercises -= WorkoutProgram.restStep } },
                        onIncrease: { change { $0.restBetweenExercises += WorkoutProgram.restStep } }
                    ))
                }
                Text("Применяется к новым упражнениям. Уже добавленные не меняются.")
                    .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProfileGroup("Серия") {
                stepper(ValueStepperRow(
                    title: "Тренировок в неделю для серии",
                    value: "\(store.weeklyGoal)",
                    canDecrease: store.weeklyGoal > WorkoutHistory.goalRange.lowerBound,
                    canIncrease: store.weeklyGoal < WorkoutHistory.goalRange.upperBound,
                    onDecrease: { store.setWeeklyGoal(store.weeklyGoal - 1) },
                    onIncrease: { store.setWeeklyGoal(store.weeklyGoal + 1) }
                ))
                if store.history.weeklyGoal != nil {
                    Button {
                        store.setWeeklyGoal(nil)
                    } label: {
                        ProfileRow("Как в плане", note: "Цель по числу тренировочных дней") {
                            ProfileValue("\(WorkoutHistory.effectiveGoal(nil, planDays: store.program.days.count))")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ProfileRowButtonStyle())
                } else {
                    ProfileRow("Сейчас — по числу тренировочных дней в плане.")
                }
            }
            ProfileGroup("Напоминание") {
                ProfileToggleRow(
                    name: "Будильник в дни тренировок",
                    note: reminderNote,
                    isOn: Binding(get: { reminder.isOn }, set: { on in
                        reminder.setOn(on)
                        // The first time, iOS asks for alarm access; the sync runs again once it is given.
                        guard on, !alarms.isAuthorized else { return }
                        Task {
                            await alarms.requestAuthorization()
                            reminder.onChange()
                        }
                    })
                )
                .accessibilityIdentifier("workout-reminder-toggle")
                if reminder.isOn {
                    DatePicker("Время", selection: reminderTime, displayedComponents: .hourAndMinute)
                        .font(DS.Fonts.text(16, .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .environment(\.locale, Locale(identifier: "ru_RU"))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                        .accessibilityIdentifier("workout-reminder-time")
                }
            }
            ProfileGroup("Звук") {
                AlertSoundRow(title: "Звук конца отдыха", choice: sounds.rest, onSelect: sounds.setRest, volume: sounds.restVolume, onVolume: sounds.setRestVolume)
            }
        }
    }

    private func stepper(_ row: ValueStepperRow) -> some View {
        row
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 64)
            .overlay(alignment: .bottom) { ProfileDivider() }
    }

    /// «Пн, Ср, Пт», or why there is nothing to ring for.
    private var reminderNote: String {
        let names = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
        let days = reminder.days.filter { (1...7).contains($0) }
        guard !days.isEmpty else { return "В плане пока нет дней тренировок" }
        return days.map { names[$0 - 1] }.joined(separator: ", ")
    }

    private var reminderTime: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: reminder.minutes / 60, minute: reminder.minutes % 60, second: 0, of: Date()) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                reminder.setMinutes((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }
        )
    }

    private func change(_ edit: (inout WorkoutDefaults) -> Void) {
        var next = defaults
        edit(&next)
        store.updateProgram(label: nil) { try WorkoutProgram.setDefaults($0, next) }
    }
}
