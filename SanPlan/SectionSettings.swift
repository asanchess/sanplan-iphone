import SwiftUI

/// Which sections a person keeps. «Сегодня» is always on; «Деньги», «Планы», «Тренировка» and «Заметки» can be
/// turned off. A section that is off disappears whole: from the tab bar, from «Сегодня», from «+», from the other
/// sections' actions («Сделать планом», «Записать трату») and from the tour. Its data stays and comes back with it.
///
/// Kept per account on this device (under the same hashed folder name as money), so a second account on the
/// phone neither sees nor changes the first one's choice. Signing out forgets the loaded choice.
@MainActor
final class SectionSettings: ObservableObject {
    static let shared = SectionSettings()

    /// The sections that can be turned off, in the order of «Что ведём?».
    nonisolated static let optional: [MainTab] = [.money, .plans, .workout, .notes]

    /// `--sections-choice` shows «Что ведём?» even in test modes; `--screenshot-sections plans,notes` keeps only those.
    nonisolated static let choiceArgument = "--sections-choice"
    nonisolated static let keepArgument = "--screenshot-sections"

    @Published private(set) var hidden: Set<MainTab> = []
    /// The signed-in account has not answered «Что ведём?» on this device yet.
    @Published private(set) var needsChoice = false

    private var folder: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isOn(_ tab: MainTab) -> Bool { tab == .today || !hidden.contains(tab) }

    var visibleTabs: [MainTab] { MainTab.ordered.filter { isOn($0) } }

    /// Loads the account's choice; the first time, «Что ведём?» is asked (unless `ask` is false: a UI test).
    func attach(email: String, ask: Bool = true) {
        let name = FinanceStore.accountFolderName(email)
        guard name != folder else { return }
        folder = name
        hidden = Self.decode(defaults.string(forKey: Self.hiddenKey(name)))
        needsChoice = ask && !defaults.bool(forKey: Self.chosenKey(name))
    }

    /// Sign-out: nothing of the last account's choice stays on screen.
    func detach() {
        folder = nil
        hidden = []
        needsChoice = false
    }

    func set(_ tab: MainTab, on: Bool) {
        guard tab != .today else { return }
        if on { hidden.remove(tab) } else { hidden.insert(tab) }
        save()
    }

    /// The answer to «Что ведём?»: everything not kept is off.
    func choose(keep: Set<MainTab>) {
        hidden = Set(Self.optional).subtracting(keep)
        needsChoice = false
        save()
        if let folder { defaults.set(true, forKey: Self.chosenKey(folder)) }
    }

    /// Debug and screenshot launches: the choice lives in memory only and nothing is saved.
    func applyLaunchArguments(_ arguments: [String]) {
        if let flag = arguments.firstIndex(of: Self.keepArgument), flag + 1 < arguments.count {
            let keep = Set(arguments[flag + 1].split(separator: ",").compactMap { Self.tab(named: String($0)) })
            hidden = Set(Self.optional).subtracting(keep)
        }
        if arguments.contains(Self.choiceArgument) { needsChoice = true }
    }

    private func save() {
        guard let folder else { return }
        defaults.set(Self.encode(hidden), forKey: Self.hiddenKey(folder))
    }

    // MARK: Storage

    nonisolated static func hiddenKey(_ folder: String) -> String { "asan.sections.hidden.\(folder)" }
    nonisolated static func chosenKey(_ folder: String) -> String { "asan.sections.chosen.\(folder)" }

    nonisolated static func tab(named name: String) -> MainTab? {
        switch name.trimmingCharacters(in: .whitespaces) {
        case "money": return .money
        case "plans": return .plans
        case "workout": return .workout
        case "notes": return .notes
        default: return nil
        }
    }

    nonisolated static func name(of tab: MainTab) -> String {
        switch tab {
        case .money: return "money"
        case .plans: return "plans"
        case .workout: return "workout"
        case .notes: return "notes"
        case .today: return "today"
        }
    }

    /// Names, not raw numbers: the tab order may change, the stored choice must not.
    nonisolated static func encode(_ hidden: Set<MainTab>) -> String {
        optional.filter { hidden.contains($0) }.map(name(of:)).joined(separator: ",")
    }

    nonisolated static func decode(_ value: String?) -> Set<MainTab> {
        Set((value ?? "").split(separator: ",").compactMap { tab(named: String($0)) })
    }
}

// MARK: - «Что ведём?»

/// Shown once per account after sign-in, before the tour: the person picks the sections they keep.
/// Everything is on at first; turning one off only hides it, and «Профиль → Разделы» brings it back.
struct SectionChoiceScreen: View {
    let onDone: (Set<MainTab>) -> Void
    @State private var keep: Set<MainTab> = Set(SectionSettings.optional)

    var body: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Что ведём?")
                            .font(DS.Fonts.display(34))
                            .foregroundColor(DS.Colors.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Лишнее можно убрать. Данные останутся, раздел вернётся в профиле.")
                            .font(DS.Fonts.text(16, .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 24)

                    SectionChoiceRow(tab: .today, isOn: true, locked: true) { _ in }
                    ForEach(SectionSettings.optional, id: \.self) { tab in
                        SectionChoiceRow(tab: tab, isOn: keep.contains(tab), locked: false) { on in
                            if on { keep.insert(tab) } else { keep.remove(tab) }
                        }
                    }
                }
                .padding(.horizontal, DS.Metrics.screenGutter)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button { onDone(keep) } label: {
                    Text("Дальше")
                        .font(DS.Fonts.text(17, .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityIdentifier("sections-choice-done")
                .padding(.horizontal, DS.Metrics.screenGutter)
                .padding(.bottom, 12)
                .frame(maxWidth: 640)
                .background(DS.Colors.canvas)
            }
        }
        .accessibilityIdentifier("sections-choice")
    }
}

/// One section: its icon in its colour, the name, one line of what is in it, and a switch.
struct SectionChoiceRow: View {
    let tab: MainTab
    let isOn: Bool
    let locked: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { onChange($0) })) {
            HStack(spacing: 14) {
                Image(systemName: tab.barIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(tab.accent)
                    .frame(width: 44, height: 44)
                    .background(tab.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title)
                        .font(DS.Fonts.text(17, .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(Self.caption(tab, locked: locked))
                        .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(tab.accent)
        .disabled(locked)
        .padding(14)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(isOn || locked ? 1 : 0.6)
        .accessibilityIdentifier("sections-\(SectionSettings.name(of: tab))")
    }

    static func caption(_ tab: MainTab, locked: Bool) -> String {
        switch tab {
        case .today: return "Всегда: день из всех разделов"
        case .money: return "Траты, бюджет, копилки"
        case .plans: return "Дела, привычки, цели"
        case .workout: return "Программа, подходы, история"
        case .notes: return "Мысли и списки, зашифрованы"
        }
    }
}
