import Foundation

/// Switches from «Профиль → Настройки», one group per section (owner 19.11, G).
/// They live on this device in UserDefaults: views read them with @AppStorage under the same keys,
/// code outside views through the helpers below. Every default keeps the app as it was before.
enum SectionPrefs {
    enum Key {
        static let todayHidden = "today.hiddenCards"
        static let planReminders = "plans.newReminders"
        static let noteStartsAsList = "notes.startAsList"
        static let deletedKeepDays = "deleted.keepDays"
        static let lockScreenCard = "workout.lockScreenCard"
        static let raiseWeight = "workout.raiseWeight"
    }

    static var defaults: UserDefaults { .standard }

    // MARK: Сегодня

    /// The cards of «Сегодня» that can be hidden; all are on by default.
    enum TodayCard: String, CaseIterable, Identifiable {
        case now, rings, moneyRing, next, habits, goals, notes, progress, review

        var id: String { rawValue }

        var title: String {
            switch self {
            case .now: return "Сейчас"
            case .rings: return "Кольца дня"
            case .moneyRing: return "Кольцо «Можно сегодня»"
            case .next: return "Лента дня"
            case .habits: return "Привычки"
            case .goals: return "Цели"
            case .notes: return "Закреплённые заметки"
            case .progress: return "Прогресс недели"
            case .review: return "Итоги дня"
            }
        }

        /// The section the card belongs to: with that section off, the card has no switch.
        var tab: MainTab? {
            switch self {
            case .habits, .goals, .next: return .plans
            case .notes: return .notes
            case .moneyRing: return .money
            default: return nil
            }
        }
    }

    static func hiddenCards(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    static func encode(hidden: Set<String>) -> String {
        hidden.sorted().joined(separator: ",")
    }

    // MARK: Планы

    /// Reminder sets offered for a new plan, in minutes before it.
    struct ReminderChoice: Identifiable, Equatable {
        let offsets: [Int]
        let title: String
        var id: String { SectionPrefs.encode(offsets: offsets) }
    }

    static let reminderChoices: [ReminderChoice] = [
        .init(offsets: [1440, 60, 0], title: "За день, за час и в момент"),
        .init(offsets: [60, 0], title: "За час и в момент"),
        .init(offsets: [15, 0], title: "За 15 минут и в момент"),
        .init(offsets: [0], title: "Только в момент начала"),
        .init(offsets: [], title: "Без напоминаний"),
    ]

    static func encode(offsets: [Int]) -> String {
        offsets.isEmpty ? "none" : offsets.map(String.init).joined(separator: ",")
    }

    static func decodeOffsets(_ raw: String?) -> [Int]? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw == "none" { return [] }
        let values = raw.split(separator: ",").compactMap { Int($0) }
        guard !values.isEmpty, values.allSatisfy({ (0...40320).contains($0) }) else { return nil }
        return Array(Set(values)).sorted(by: >)
    }

    /// Reminders a new plan gets when it has none of its own.
    static func newPlanOffsets(in defaults: UserDefaults = defaults) -> [Int] {
        decodeOffsets(defaults.string(forKey: Key.planReminders)) ?? PlanDomain.defaultReminderOffsets
    }

    // MARK: Заметки

    static let keepDayChoices = [7, 30, 90]

    static func keepDays(in defaults: UserDefaults = defaults) -> Int {
        let value = defaults.integer(forKey: Key.deletedKeepDays)
        return keepDayChoices.contains(value) ? value : 30
    }

    static func noteStartsAsList(in defaults: UserDefaults = defaults) -> Bool {
        defaults.bool(forKey: Key.noteStartsAsList)
    }

    // MARK: Тренировка

    /// Off: no card on the lock screen and in the Dynamic Island during a workout.
    static func lockScreenCard(in defaults: UserDefaults = defaults) -> Bool {
        defaults.object(forKey: Key.lockScreenCard) as? Bool ?? true
    }

    /// Off: a workout starts with last time's weight, not raised by the step.
    static func raiseWeight(in defaults: UserDefaults = defaults) -> Bool {
        defaults.object(forKey: Key.raiseWeight) as? Bool ?? true
    }
}
