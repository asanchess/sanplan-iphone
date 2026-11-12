import Foundation

// Доменная модель привычек (этап 3, RESEARCH-MYLIFE §7.3). Только чистая логика, без экранов и хранения.
// Дни — «ГГГГ-ММ-ДД» в часовом поясе владельца, недели с понедельника, дни недели 1 = Пн … 7 = Вс.

/// Календарные хелперы над строками дней. Не зависят от часового пояса устройства.
public enum HabitCalendar {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return c
    }()

    static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// 1 = понедельник … 7 = воскресенье; 0 для некорректного дня.
    public static func isoWeekday(_ day: String) -> Int {
        guard let d = date(day) else { return 0 }
        return (calendar.component(.weekday, from: d) + 5) % 7 + 1
    }

    /// Понедельник недели, в которую попадает день.
    public static func weekStart(_ day: String) -> String {
        let w = isoWeekday(day)
        return w == 0 ? day : PlanDomain.addDays(dateStr: day, days: -(w - 1))
    }

    public static func previous(_ day: String) -> String { PlanDomain.addDays(dateStr: day, days: -1) }
    public static func next(_ day: String) -> String { PlanDomain.addDays(dateStr: day, days: 1) }

    /// Все дни `from...to` по порядку; пусто, если границы перепутаны или некорректны.
    public static func days(from: String, to: String) -> [String] {
        guard date(from) != nil, date(to) != nil, from <= to else { return [] }
        var result: [String] = []
        var day = from
        while day <= to && result.count < 4000 {
            result.append(day)
            day = next(day)
        }
        return result
    }
}

public struct HabitSchedule: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case weekdays, timesPerWeek }
    public var kind: Kind
    /// Для `.weekdays`: дни недели 1…7.
    public var weekdays: Set<Int>
    /// Для `.timesPerWeek`: сколько дней в неделю (1…7).
    public var timesPerWeek: Int

    public init(kind: Kind, weekdays: Set<Int> = [], timesPerWeek: Int = 0) {
        self.kind = kind
        self.weekdays = weekdays
        self.timesPerWeek = timesPerWeek
    }

    public static let everyDay = HabitSchedule(kind: .weekdays, weekdays: Set(1...7))
    public static func onWeekdays(_ days: Set<Int>) -> HabitSchedule { HabitSchedule(kind: .weekdays, weekdays: days) }
    public static func timesPerWeek(_ n: Int) -> HabitSchedule { HabitSchedule(kind: .timesPerWeek, timesPerWeek: n) }
}

/// Норма за день: один раз или количество («8 стаканов»).
public struct HabitTarget: Codable, Equatable, Hashable, Sendable {
    public var amount: Int
    public var unit: String

    public init(amount: Int = 1, unit: String = "") {
        self.amount = max(1, amount)
        self.unit = unit
    }

    public static let once = HabitTarget()
    public var isCountable: Bool { amount > 1 }
}

/// Правило автоотметки. Проверяется на устройстве по сводкам соседних разделов.
public struct HabitRule: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case training      // завершена тренировка
        case noSpend       // нет трат (в категории, если она указана)
        case spendAtMost   // потрачено не больше `limit` тенге (в категории, если указана)
    }
    public var kind: Kind
    public var category: String?
    public var limit: Int?

    public init(kind: Kind, category: String? = nil, limit: Int? = nil) {
        self.kind = kind
        self.category = category
        self.limit = limit
    }

    public static let training = HabitRule(kind: .training)
    public static func noSpend(category: String? = nil) -> HabitRule { HabitRule(kind: .noSpend, category: category) }
    public static func spendAtMost(_ limit: Int, category: String? = nil) -> HabitRule {
        HabitRule(kind: .spendAtMost, category: category, limit: limit)
    }
}

public struct Habit: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var schedule: HabitSchedule
    public var target: HabitTarget
    public var rule: HabitRule?
    public var sphere: String?
    /// День создания: до него привычка не считается и не ломает серию.
    public var createdDay: String
    public var archived: Bool

    public init(
        id: String = UUID().uuidString,
        title: String,
        schedule: HabitSchedule = .everyDay,
        target: HabitTarget = .once,
        rule: HabitRule? = nil,
        sphere: String? = nil,
        createdDay: String,
        archived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.schedule = schedule
        self.target = target
        self.rule = rule
        self.sphere = sphere
        self.createdDay = createdDay
        self.archived = archived
    }
}

// MARK: - Сводки соседей (временные заглушки по сигнатуре DOMAINS.md §2)

/// `trainingDay(history, day) → {completed, …}` раздела «Тренировка».
public struct HabitTrainingDay: Equatable {
    public var completed: Bool
    public init(completed: Bool) { self.completed = completed }
}

/// `financeDay(snapshot, day) → {spent, byCategory, currency}` раздела «Деньги»; суммы в целых тенге.
public struct HabitFinanceDay: Equatable {
    public var spent: Int
    public var byCategory: [String: Int]
    public init(spent: Int, byCategory: [String: Int] = [:]) {
        self.spent = spent
        self.byCategory = byCategory
    }
}

/// Откуда привычки берут данные соседей. nil = данных нет, правило не выполнено (проверить нечем).
/// ВРЕМЕННО: пока в ветке нет `WorkoutStore.daySummary` и `FinanceStore.daySummary`, координатор подставляет их при слиянии.
public struct HabitContext {
    public var trainingDay: (String) -> HabitTrainingDay?
    public var financeDay: (String) -> HabitFinanceDay?

    public init(
        trainingDay: @escaping (String) -> HabitTrainingDay? = { _ in nil },
        financeDay: @escaping (String) -> HabitFinanceDay? = { _ in nil }
    ) {
        self.trainingDay = trainingDay
        self.financeDay = financeDay
    }

    public static let empty = HabitContext()
}

// MARK: - Вычисления

public struct HabitStreak: Equatable {
    public enum Unit: String { case days, weeks }
    public var count: Int
    public var unit: Unit
}

public struct HabitDaySummary: Equatable {
    public var done: Int
    public var total: Int
}

public enum HabitEngine {
    /// Правило выполнено в этот день. Без данных соседа — нет.
    public static func ruleSatisfied(_ rule: HabitRule, day: String, context: HabitContext) -> Bool {
        switch rule.kind {
        case .training:
            return context.trainingDay(day)?.completed == true
        case .noSpend:
            guard let f = context.financeDay(day) else { return false }
            return spent(f, category: rule.category) == 0
        case .spendAtMost:
            guard let f = context.financeDay(day), let limit = rule.limit else { return false }
            return spent(f, category: rule.category) <= limit
        }
    }

    private static func spent(_ f: HabitFinanceDay, category: String?) -> Int {
        guard let category, !category.isEmpty else { return f.spent }
        return f.byCategory[category] ?? 0
    }

    /// Привычка выполнена в день: ручная отметка набрала норму либо сработало правило.
    /// `marks` — количество по дням для этой привычки.
    public static func isDone(_ habit: Habit, day: String, marks: [String: Int], context: HabitContext) -> Bool {
        if (marks[day] ?? 0) >= habit.target.amount { return true }
        if let rule = habit.rule { return ruleSatisfied(rule, day: day, context: context) }
        return false
    }

    /// Сколько дней недели (до `through` включительно) привычка выполнена.
    static func doneCountInWeek(_ habit: Habit, containing day: String, through: String? = nil,
                                marks: [String: Int], context: HabitContext) -> Int {
        let start = HabitCalendar.weekStart(day)
        let end = min(through ?? PlanDomain.addDays(dateStr: start, days: 6), PlanDomain.addDays(dateStr: start, days: 6))
        return HabitCalendar.days(from: start, to: end)
            .filter { $0 >= habit.createdDay && isDone(habit, day: $0, marks: marks, context: context) }
            .count
    }

    /// Нужно ли отметить привычку в этот день. Для «N раз в неделю» — пока не набрана недельная норма
    /// (или уже отмечена сегодня).
    public static func isDue(_ habit: Habit, day: String, marks: [String: Int], context: HabitContext) -> Bool {
        guard !habit.archived, day >= habit.createdDay else { return false }
        switch habit.schedule.kind {
        case .weekdays:
            return habit.schedule.weekdays.contains(HabitCalendar.isoWeekday(day))
        case .timesPerWeek:
            if isDone(habit, day: day, marks: marks, context: context) { return true }
            let before = HabitCalendar.previous(day)
            let doneBefore = HabitCalendar.weekStart(before) == HabitCalendar.weekStart(day)
                ? doneCountInWeek(habit, containing: day, through: before, marks: marks, context: context)
                : 0
            return doneBefore < max(1, habit.schedule.timesPerWeek)
        }
    }

    public static func daySummary(habits: [Habit], day: String, marks: [String: [String: Int]],
                                  context: HabitContext) -> HabitDaySummary {
        var done = 0
        var total = 0
        for habit in habits {
            let m = marks[habit.id] ?? [:]
            guard isDue(habit, day: day, marks: m, context: context) else { continue }
            total += 1
            if isDone(habit, day: day, marks: m, context: context) { done += 1 }
        }
        return HabitDaySummary(done: done, total: total)
    }

    /// Серия привычки. По дням недели — подряд выполненные «нужные» дни (дни вне расписания не рвут серию);
    /// «N раз в неделю» — подряд недели с выполненной нормой. Незавершённый сегодня/эта неделя серию не рвут.
    public static func streak(_ habit: Habit, today: String, marks: [String: Int], context: HabitContext) -> HabitStreak {
        switch habit.schedule.kind {
        case .weekdays:
            var count = 0
            var day = today
            var steps = 0
            while day >= habit.createdDay && steps < 800 {
                if habit.schedule.weekdays.contains(HabitCalendar.isoWeekday(day)) {
                    if isDone(habit, day: day, marks: marks, context: context) {
                        count += 1
                    } else if day != today {
                        break
                    }
                }
                day = HabitCalendar.previous(day)
                steps += 1
            }
            return HabitStreak(count: count, unit: .days)
        case .timesPerWeek:
            let need = max(1, habit.schedule.timesPerWeek)
            var count = 0
            var weekStart = HabitCalendar.weekStart(today)
            let firstWeek = HabitCalendar.weekStart(habit.createdDay)
            var steps = 0
            while weekStart >= firstWeek && steps < 200 {
                let n = doneCountInWeek(habit, containing: weekStart, marks: marks, context: context)
                if n >= need {
                    count += 1
                } else if weekStart != HabitCalendar.weekStart(today) {
                    break
                }
                weekStart = PlanDomain.addDays(dateStr: weekStart, days: -7)
                steps += 1
            }
            return HabitStreak(count: count, unit: .weeks)
        }
    }
}
