import SwiftUI

// «Первый запуск»: три коротких шага. Любой шаг можно пропустить; пройденный тур помнится по аккаунту
// (флаг — запись `s-app-settings` коллекции `settings`, на каждом устройстве аккаунта один и тот же).
// Время итогов — ReviewStore/ReviewReminder, сферы — GoalStore. Шага про ключ нет: ключ хранит сервер. Зеркало onboarding.mjs / OnboardingPanel.jsx.

// MARK: - Domain

public enum OnboardingStep: Int, CaseIterable, Equatable {
    case tabs, reminder, spheres

    public var title: String {
        switch self {
        case .tabs: return "Что где"
        case .reminder: return "Итоги дня"
        case .spheres: return "Сферы жизни"
        }
    }
}

public enum OnboardingAction: Equatable { case next, skip, back, finish }

/// Состояние тура: текущий шаг и что сделано с каждым. Не хранится — тур короткий.
public struct OnboardingTour: Equatable {
    public enum Result: Equatable { case done, skipped }

    public private(set) var index = 0
    public private(set) var results: [OnboardingStep: Result] = [:]
    public private(set) var finished = false

    public init() {}

    public var step: OnboardingStep? { finished ? nil : OnboardingStep(rawValue: index) }

    public mutating func apply(_ action: OnboardingAction) {
        guard !finished, let current = step else { return }
        switch action {
        case .finish:
            finished = true
        case .back:
            if index > 0 { index -= 1 }
        case .next, .skip:
            results[current] = action == .next ? .done : .skipped
            if index + 1 >= OnboardingStep.allCases.count { finished = true } else { index += 1 }
        }
    }
}

/// Одна строка на вкладку, без лозунгов.
public struct OnboardingTabLine: Identifiable, Equatable {
    public let tab: MainTab
    public let line: String
    public var id: Int { tab.rawValue }
}

public enum OnboardingTabs {
    public static let lines: [OnboardingTabLine] = [
        OnboardingTabLine(tab: .today, line: "Дела дня, итоги дня и недели, сводка по остальным разделам."),
        OnboardingTabLine(tab: .money, line: "Расходы, доходы, лимиты и накопления."),
        OnboardingTabLine(tab: .plans, line: "Календарь, привычки, цели и будильники."),
        OnboardingTabLine(tab: .workout, line: "Программа, подходы и отдых между ними."),
        OnboardingTabLine(tab: .notes, line: "Записи и списки в зашифрованном виде.")
    ]
}

/// Выбор 2–3 сфер для «Целей».
public enum OnboardingSpheres {
    public static let minCount = 2
    public static let maxCount = 3

    /// Четвёртая сфера не добавляется, повторный выбор снимает.
    public static func toggle(_ selected: [String], _ id: String) -> [String] {
        if selected.contains(id) { return selected.filter { $0 != id } }
        return selected.count >= maxCount ? selected : selected + [id]
    }

    public static func isReady(_ selected: [String]) -> Bool { (minCount...maxCount).contains(selected.count) }

    public static func hint(_ selected: [String]) -> String {
        if selected.isEmpty { return "Можно пропустить: останутся все шесть сфер." }
        if isReady(selected) { return "Выбрано: \(selected.count)." }
        return "Выберите ещё \(minCount - selected.count) или пропустите."
    }

    /// Выбранные сферы в порядке стандартного списка; пусто — выбор не применять.
    public static func chosen(_ selected: [String], from all: [GoalSphere] = GoalSphere.defaults) -> [GoalSphere] {
        isReady(selected) ? all.filter { selected.contains($0.id) } : []
    }
}

/// Флаг «тур пройден» по аккаунту (имя ключа — хэш почты, сам адрес на диск не пишется) и показ тура.
@MainActor
public final class OnboardingModel: ObservableObject {
    @Published public var isPresented = false

    private let defaults: UserDefaults
    private(set) var email: String?
    static let keyPrefix = "arna.onboarding.v1."
    /// The account-wide flag (`s-app-settings` in the `settings` collection). Nil in tests that only use the device flag.
    private weak var settings: AppSettingsStore?
    /// This sign-in's tour was already shown or skipped; a later settings update must not bring it back.
    private var handled = false

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func attach(settings: AppSettingsStore) { self.settings = settings }

    private func key(_ email: String) -> String { Self.keyPrefix + FinanceStore.accountFolderName(email) }

    /// Пройден на этом устройстве или на любом другом устройстве аккаунта.
    public func isDone(for email: String?) -> Bool {
        guard let email else { return false }
        return defaults.bool(forKey: key(email)) || settings?.onboardingDone == true
    }

    public func shouldShow(for email: String?) -> Bool { email != nil && !isDone(for: email) }

    /// Вход в аккаунт: тур показывается, только если этот аккаунт его не проходил. Выход закрывает тур.
    /// Пока настройки аккаунта не пришли с сервера, тур не решается: на втором устройстве он не должен мигнуть.
    public func accountChanged(_ next: String?) {
        email = next
        handled = false
        isPresented = false
        settingsChanged()
    }

    /// Настройки аккаунта пришли или изменились: решаем, показывать ли тур, и переносим старый флаг устройства в аккаунт.
    public func settingsChanged() {
        guard let email else { return }
        if let settings {
            guard settings.isLoaded else { return }
            if defaults.bool(forKey: key(email)), !settings.onboardingDone { settings.setOnboardingDone(true) }
        }
        guard !handled else { return }
        handled = true
        isPresented = shouldShow(for: email)
    }

    public func complete() {
        handled = true
        if let email { defaults.set(true, forKey: key(email)) }
        settings?.setOnboardingDone(true)
        isPresented = false
    }

    /// «Показать вводный тур» в настройках. Флаг аккаунта не сбрасывается: другие устройства тур не увидят.
    public func requestTour() {
        guard let email else { return }
        defaults.removeObject(forKey: key(email))
        handled = true
        isPresented = true
    }
}

// MARK: - Screens

struct OnboardingScreen: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var review: ReviewStore
    @ObservedObject var goals: GoalStore

    @State private var tour = OnboardingTour()
    @State private var picked: [String] = []
    @State private var reminder = ReviewReminderSettings.standard
    @State private var reminderDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                        if let step = tour.step {
                            Text("Шаг \(step.rawValue + 1) из \(OnboardingStep.allCases.count) · \(step.title)")
                                .font(.footnote)
                                .foregroundColor(DS.Colors.textSecondary)
                                .accessibilityAddTraits(.isHeader)
                            content(for: step)
                            actions(for: step)
                        }
                        Button("Пропустить тур") { model.complete() }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget)
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.vertical, DS.Metrics.spacing16)
                }
            }
            .navigationTitle("Первый запуск")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { reminder = review.reminder }
    }

    @ViewBuilder
    private func content(for step: OnboardingStep) -> some View {
        switch step {
        case .tabs:
            VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                ForEach(OnboardingTabs.lines) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(item.tab.title, systemImage: item.tab.icon).font(.headline)
                        Text(item.line).font(.subheadline).foregroundColor(DS.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Metrics.spacing12)
                    .background(DS.Colors.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                    .accessibilityElement(children: .combine)
                }
            }
        case .reminder:
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                Toggle("Напоминать каждый день", isOn: Binding(get: { reminder.enabled }, set: { updateReminder(enabled: $0) }))
                    .frame(minHeight: DS.Metrics.minHitTarget)
                if reminder.enabled {
                    DatePicker("Время", selection: Binding(get: { reminderDate }, set: { setReminderTime($0) }), displayedComponents: .hourAndMinute)
                        .frame(minHeight: DS.Metrics.minHitTarget)
                }
                Text(reminderDenied ? "Уведомления выключены в настройках iPhone: напоминание не придёт." : "По умолчанию 21:00.")
                    .font(.footnote)
                    .foregroundColor(reminderDenied ? DS.Colors.destructive : DS.Colors.textSecondary)
            }
        case .spheres:
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                Text("Сферы для целей, 2–3 по желанию").font(.headline)
                ForEach(GoalSphere.defaults) { sphere in
                    let on = picked.contains(sphere.id)
                    Button {
                        picked = OnboardingSpheres.toggle(picked, sphere.id)
                    } label: {
                        HStack {
                            Text(sphere.title)
                            Spacer()
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        }
                        .padding(DS.Metrics.spacing12)
                        .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget)
                        .background(DS.Colors.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Text(OnboardingSpheres.hint(picked)).font(.footnote).foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func actions(for step: OnboardingStep) -> some View {
        HStack(spacing: DS.Metrics.spacing8) {
            if tour.index > 0 {
                PillButton("Назад", style: .secondary) { tour.apply(.back) }
            }
            PillButton("Пропустить", style: .secondary) { advance(.skip) }
            PillButton(step == .spheres ? "Готово" : "Далее", style: .primary) { advance(.next) }
                .disabled(step == .spheres && !picked.isEmpty && !OnboardingSpheres.isReady(picked))
        }
    }

    private func advance(_ action: OnboardingAction) {
        if action == .next, tour.step == .spheres {
            let chosen = OnboardingSpheres.chosen(picked)
            if !chosen.isEmpty { goals.setSpheres(chosen) }
        }
        tour.apply(action)
        if tour.finished { model.complete() }
    }

    private var reminderDate: Date {
        var parts = DateComponents()
        parts.hour = reminder.hour
        parts.minute = reminder.minute
        return Calendar.current.date(from: parts) ?? Date()
    }

    private func setReminderTime(_ date: Date) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        updateReminder(enabled: reminder.enabled, hour: parts.hour ?? 21, minute: parts.minute ?? 0)
    }

    private func updateReminder(enabled: Bool, hour: Int? = nil, minute: Int? = nil) {
        reminder = ReviewReminderSettings(enabled: enabled, hour: hour ?? reminder.hour, minute: minute ?? reminder.minute)
        review.setReminder(reminder)
        Task { reminderDenied = !(await ReviewReminder.apply(reminder)) }
    }
}

// MARK: - Hooks

/// Хук для RootView: показывает тур листом, пока аккаунт его не прошёл.
///   .onboardingTour(model: model.onboarding-или-@StateObject, review: model.reviews, goals: GoalStore.shared)
/// и в `onChange(of: authService.phase)`: signedIn(email) → onboarding.accountChanged(email); signedOut → accountChanged(nil).
struct OnboardingHost: ViewModifier {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var review: ReviewStore
    @ObservedObject var goals: GoalStore

    func body(content: Content) -> some View {
        // Closing the sheet any other way (swipe down) counts as skipping the tour.
        content.sheet(isPresented: $model.isPresented, onDismiss: { model.complete() }) {
            OnboardingScreen(model: model, review: review, goals: goals)
        }
    }
}

extension View {
    func onboardingTour(model: OnboardingModel, review: ReviewStore, goals: GoalStore = .shared) -> some View {
        modifier(OnboardingHost(model: model, review: review, goals: goals))
    }
}

/// Строка для «Настроек»: `OnboardingSettingsRow(model: onboarding, dismiss: { dismiss() })`.
struct OnboardingSettingsRow: View {
    @ObservedObject var model: OnboardingModel
    let dismiss: () -> Void

    var body: some View {
        PillButton("Показать вводный тур", style: .secondary) {
            dismiss()
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                model.requestTour()
            }
        }
    }
}
