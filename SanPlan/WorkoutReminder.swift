import Foundation

/// «Настройки → Тренировка → Напоминание»: a system alarm at a set time on the program's training days.
/// It rides the plan alarms: each coming training day becomes a plan-like entry the alarm sync schedules,
/// with an id of its own («workout-reminder-<date>»), so it never touches the owner's plans.
public enum WorkoutReminder {
    static let onKey = "workout.reminder.on"
    static let minutesKey = "workout.reminder.minutes"
    static let daysKey = "workout.reminder.days"
    static let idPrefix = "workout-reminder-"
    /// Days ahead to schedule; every sync (each plan load) moves the window on.
    static let horizonDays = 14
    /// 18:00 until the owner picks a time.
    static let defaultMinutes = 18 * 60

    /// Entries for the alarm sync: training days in the next two weeks whose time is still ahead.
    public static func plans(defaults: UserDefaults, now: Date, timeZone: TimeZone = .current) -> [NativePlan] {
        guard defaults.bool(forKey: onKey) else { return [] }
        let days = Set((defaults.array(forKey: daysKey) as? [Int]) ?? [])
        guard !days.isEmpty else { return [] }
        let minutes = minutes(in: defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: now)
        let time = String(format: "%02d:%02d", minutes / 60, minutes % 60)
        return (0..<horizonDays).compactMap { offset -> NativePlan? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  days.contains(WorkoutProgram.weekday(of: day, timeZone: timeZone)),
                  let fire = calendar.date(byAdding: .minute, value: minutes, to: day), fire > now
            else { return nil }
            let comps = calendar.dateComponents([.year, .month, .day], from: day)
            let date = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
            return NativePlan(id: idPrefix + date, title: "Тренировка", date: date, time: time,
                              reminderOffsets: [0], timeZone: timeZone.identifier)
        }
    }

    static func minutes(in defaults: UserDefaults) -> Int {
        let stored = defaults.object(forKey: minutesKey) as? Int
        return min(max(stored ?? defaultMinutes, 0), 24 * 60 - 1)
    }
}

/// The switch and time on the settings screen. A change re-runs the alarm sync through `onChange`.
@MainActor
final class WorkoutReminderSettings: ObservableObject {
    static let shared = WorkoutReminderSettings()

    @Published private(set) var isOn: Bool
    @Published private(set) var minutes: Int
    @Published private(set) var days: [Int]
    /// Set by AppModel: syncs the system alarms once plans are loaded.
    var onChange: () -> Void = {}

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: WorkoutReminder.onKey)
        minutes = WorkoutReminder.minutes(in: defaults)
        days = (defaults.array(forKey: WorkoutReminder.daysKey) as? [Int]) ?? []
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        defaults.set(on, forKey: WorkoutReminder.onKey)
        onChange()
    }

    func setMinutes(_ value: Int) {
        let value = min(max(value, 0), 24 * 60 - 1)
        guard value != minutes else { return }
        minutes = value
        defaults.set(value, forKey: WorkoutReminder.minutesKey)
        if isOn { onChange() }
    }

    /// Training days of the program (1…7, Monday first), kept in step with the builder.
    func setDays(_ value: [Int]) {
        let value = Array(Set(value)).sorted()
        guard value != days else { return }
        days = value
        defaults.set(value, forKey: WorkoutReminder.daysKey)
        if isOn { onChange() }
    }
}
