import Foundation

/// Настройки дней отдыха (RESEARCH-MYLIFE §7.5): по умолчанию 4 в месяц и до 2 постоянных выходных в неделю.
public struct StreakSettings: Codable, Equatable, Sendable {
    public static let maxWeeklyOff = 2
    public static let maxMonthlyRest = 31

    public var restDaysPerMonth: Int
    /// Постоянные выходные, 1 = Пн … 7 = Вс; не больше двух.
    public var weeklyOffWeekdays: Set<Int>

    public init(restDaysPerMonth: Int = 4, weeklyOffWeekdays: Set<Int> = []) {
        self.restDaysPerMonth = min(max(0, restDaysPerMonth), Self.maxMonthlyRest)
        self.weeklyOffWeekdays = Set(weeklyOffWeekdays.filter { (1...7).contains($0) }.sorted().prefix(Self.maxWeeklyOff))
    }

    public static let standard = StreakSettings()
}

public struct StreakState: Equatable {
    /// Дни с реальным действием в текущей серии (дни отдыха не прибавляют, но и не рвут).
    public var days: Int
    /// Сколько дней отдыха осталось в текущем месяце.
    public var restDaysLeft: Int
}

/// Общая серия приложения. День засчитан, если в нём было реальное действие в любом разделе
/// (`*ActivityDays`); просто открыть приложение не считается.
public enum StreakEngine {
    /// Объединение дней действия всех разделов.
    public static func activeDays(_ sources: [[String]]) -> Set<String> {
        Set(sources.flatMap { $0 })
    }

    /// Серия на `today`. Моделируется день за днём от первого дня действия:
    /// пропуск в постоянный выходной ничего не стоит; иначе тратится день отдыха месяца;
    /// когда они кончились — серия обрывается. Сегодняшний день без действия серию не рвёт (день ещё идёт).
    public static func current(today: String, activeDays: Set<String>, settings: StreakSettings = .standard) -> StreakState {
        let month = String(today.prefix(7))
        let before = activeDays.filter { $0 <= today }
        guard let first = before.min() else {
            return StreakState(days: 0, restDaysLeft: settings.restDaysPerMonth)
        }
        var streak = 0
        var usedByMonth: [String: Int] = [:]
        var day = first
        var steps = 0
        while day <= today && steps < 4000 {
            if activeDays.contains(day) {
                streak += 1
            } else if day == today {
                // день не закончился
            } else if settings.weeklyOffWeekdays.contains(HabitCalendar.isoWeekday(day)) {
                // постоянный выходной
            } else if streak == 0 {
                // серии нет — отдыхать нечем
            } else {
                let key = String(day.prefix(7))
                if usedByMonth[key, default: 0] < settings.restDaysPerMonth {
                    usedByMonth[key, default: 0] += 1
                } else {
                    streak = 0
                }
            }
            day = HabitCalendar.next(day)
            steps += 1
        }
        return StreakState(days: streak, restDaysLeft: max(0, settings.restDaysPerMonth - usedByMonth[month, default: 0]))
    }

    /// Дни действия одного раздела за период: `PlanStore.activityDays`, `FinanceStore.activityDays`,
    /// `WorkoutStore.activityDays`, `NotesStore.activityDays`, `ReviewStore.activityDays`, привычки.
    public typealias ActivitySource = (_ from: String, _ to: String) -> [String]

    /// Единый сборщик: берёт источники разделов параметрами, окно — `lookbackDays` до сегодня.
    public static func current(
        today: String,
        sources: [ActivitySource],
        settings: StreakSettings = .standard,
        lookbackDays: Int = 400
    ) -> StreakState {
        let from = PlanDomain.addDays(dateStr: today, days: -max(1, lookbackDays))
        let days = activeDays(sources.map { $0(from, today) })
        return current(today: today, activeDays: days, settings: settings)
    }
}
