import Foundation

// Цели и сферы (этап 4, RESEARCH-MYLIFE §7.4). Только чистая логика: модель, прогресс по данным соседних разделов,
// факты сферы. Хранение — GoalStore, экраны — GoalScreens. Дни «ГГГГ-ММ-ДД» в часовом поясе владельца.

/// Сфера жизни. Список по умолчанию можно менять.
public struct GoalSphere: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }

    public static let defaults: [GoalSphere] = [
        GoalSphere(id: "health", title: "Здоровье"),
        GoalSphere(id: "money", title: "Деньги"),
        GoalSphere(id: "work", title: "Работа и учёба"),
        GoalSphere(id: "people", title: "Отношения"),
        GoalSphere(id: "growth", title: "Развитие"),
        GoalSphere(id: "rest", title: "Отдых")
    ]
}

/// Этап цели с необязательной датой.
public struct GoalMilestone: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var dueDay: String?
    public var done: Bool
    public init(id: String = UUID().uuidString, title: String, dueDay: String? = nil, done: Bool = false) {
        self.id = id; self.title = title; self.dueDay = dueDay; self.done = done
    }
}

/// Тип прогресса — один на цель.
public enum GoalProgressKind: Codable, Equatable, Hashable, Sendable {
    /// Накопление: `target` в целых тенге; `savingsGoalId` — цель накопления в «Деньгах», откуда берётся сумма.
    case money(target: Int, savingsGoalId: String?)
    /// Число завершённых тренировок с `createdDay` до `dueDay`/сегодня.
    case trainingCount(target: Int)
    /// Рабочий вес в упражнении, кг.
    case trainingWeight(exercise: String, target: Double)
    /// Процент выполнения привычки за последние `days` дней.
    case habit(habitId: String, targetPercent: Int, days: Int)
    /// Этапы отмечаются вручную.
    case milestones([GoalMilestone])

    // Плоский JSON, одинаковый на iPhone и вебе: {"type":"money","target":300000,"savingsGoalId":"…"}.
    private enum Keys: String, CodingKey { case type, target, savingsGoalId, exercise, habitId, days, milestones }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "money":
            self = .money(target: Int(try c.decode(Double.self, forKey: .target)), savingsGoalId: try c.decodeIfPresent(String.self, forKey: .savingsGoalId))
        case "trainingCount":
            self = .trainingCount(target: Int(try c.decode(Double.self, forKey: .target)))
        case "trainingWeight":
            self = .trainingWeight(exercise: try c.decode(String.self, forKey: .exercise), target: try c.decode(Double.self, forKey: .target))
        case "habit":
            self = .habit(habitId: try c.decode(String.self, forKey: .habitId), targetPercent: Int(try c.decode(Double.self, forKey: .target)),
                          days: Int(try c.decodeIfPresent(Double.self, forKey: .days) ?? 30))
        case "milestones":
            self = .milestones(try c.decodeIfPresent([GoalMilestone].self, forKey: .milestones) ?? [])
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown goal kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .money(let target, let id):
            try c.encode("money", forKey: .type); try c.encode(target, forKey: .target); try c.encodeIfPresent(id, forKey: .savingsGoalId)
        case .trainingCount(let target):
            try c.encode("trainingCount", forKey: .type); try c.encode(target, forKey: .target)
        case .trainingWeight(let exercise, let target):
            try c.encode("trainingWeight", forKey: .type); try c.encode(exercise, forKey: .exercise); try c.encode(target, forKey: .target)
        case .habit(let habitId, let percent, let days):
            try c.encode("habit", forKey: .type); try c.encode(habitId, forKey: .habitId)
            try c.encode(percent, forKey: .target); try c.encode(days, forKey: .days)
        case .milestones(let items):
            try c.encode("milestones", forKey: .type); try c.encode(items, forKey: .milestones)
        }
    }
}

public struct Goal: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var sphereId: String?
    public var dueDay: String?
    public var createdDay: String
    public var kind: GoalProgressKind
    public var archived: Bool

    public init(
        id: String = UUID().uuidString,
        title: String,
        sphereId: String? = nil,
        dueDay: String? = nil,
        createdDay: String,
        kind: GoalProgressKind,
        archived: Bool = false
    ) {
        self.id = id; self.title = title; self.sphereId = sphereId; self.dueDay = dueDay
        self.createdDay = createdDay; self.kind = kind; self.archived = archived
    }
}

/// Откуда цели берут данные соседей. nil = данных нет, прогресс не показывается (а не «ноль»).
public struct GoalContext {
    public var savedAmount: (String) -> Int?
    public var trainingCompleted: (_ from: String, _ to: String) -> Int?
    public var bestWeight: (String) -> Double?
    public var habitCompletion: (_ habitId: String, _ from: String, _ to: String) -> (done: Int, total: Int)?
    /// Траты за период (целые тенге) и самая большая категория; nil — данных нет.
    public var spending: (_ from: String, _ to: String) -> (total: Int, topCategory: String?, topAmount: Int)?

    public init(
        savedAmount: @escaping (String) -> Int? = { _ in nil },
        trainingCompleted: @escaping (String, String) -> Int? = { _, _ in nil },
        bestWeight: @escaping (String) -> Double? = { _ in nil },
        habitCompletion: @escaping (String, String, String) -> (done: Int, total: Int)? = { _, _, _ in nil },
        spending: @escaping (String, String) -> (total: Int, topCategory: String?, topAmount: Int)? = { _, _ in nil }
    ) {
        self.savedAmount = savedAmount
        self.trainingCompleted = trainingCompleted
        self.bestWeight = bestWeight
        self.habitCompletion = habitCompletion
        self.spending = spending
    }

    public static let empty = GoalContext()
}

public struct GoalProgress: Equatable {
    /// 0…1; nil — данных нет.
    public var fraction: Double?
    /// Короткая подпись: «120 000 из 300 000 ₸», «3 из 5 этапов».
    public var text: String
    public var achieved: Bool
}

public enum GoalEngine {
    public static func progress(_ goal: Goal, today: String, context: GoalContext) -> GoalProgress {
        switch goal.kind {
        case .money(let target, let savingsGoalId):
            guard let id = savingsGoalId, let saved = context.savedAmount(id), target > 0 else {
                return GoalProgress(fraction: nil, text: "Нет данных из «Денег»", achieved: false)
            }
            return make(Double(saved) / Double(target), "\(grouped(saved)) из \(grouped(target)) ₸")
        case .trainingCount(let target):
            let end = min(today, goal.dueDay ?? today)
            guard target > 0, goal.createdDay <= end, let n = context.trainingCompleted(goal.createdDay, end) else {
                return GoalProgress(fraction: nil, text: "Нет данных о тренировках", achieved: false)
            }
            return make(Double(n) / Double(target), "\(n) из \(target) тренировок")
        case .trainingWeight(let exercise, let target):
            guard target > 0, let best = context.bestWeight(exercise) else {
                return GoalProgress(fraction: nil, text: "Нет данных об упражнении", achieved: false)
            }
            return make(best / target, "\(trimmed(best)) из \(trimmed(target)) кг")
        case .habit(let habitId, let targetPercent, let days):
            let span = max(1, days)
            let from = PlanDomain.addDays(dateStr: today, days: -(span - 1))
            guard targetPercent > 0, let c = context.habitCompletion(habitId, max(from, goal.createdDay), today), c.total > 0 else {
                return GoalProgress(fraction: nil, text: "Пока нет дней для расчёта", achieved: false)
            }
            let percent = Double(c.done) / Double(c.total) * 100
            return make(percent / Double(targetPercent), "\(Int(percent.rounded()))% из \(targetPercent)%")
        case .milestones(let items):
            guard !items.isEmpty else { return GoalProgress(fraction: nil, text: "Этапов нет", achieved: false) }
            let done = items.filter(\.done).count
            return make(Double(done) / Double(items.count), "\(done) из \(items.count) этапов")
        }
    }

    private static func make(_ raw: Double, _ text: String) -> GoalProgress {
        let f = min(max(raw, 0), 1)
        return GoalProgress(fraction: f, text: text, achieved: raw >= 1)
    }

    static func grouped(_ n: Int) -> String {
        let s = String(abs(n))
        var out = ""
        for (i, ch) in s.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append("\u{00A0}") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }

    static func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// Просрочена ли цель: срок прошёл, цель не достигнута.
    public static func isOverdue(_ goal: Goal, today: String, progress: GoalProgress) -> Bool {
        guard let due = goal.dueDay, !goal.archived, !progress.achieved else { return false }
        return due < today
    }

    /// Окно фактов сферы, дней.
    public static let factsWindowDays = 30

    /// Факты сферы из сводок соседей за последние 30 дней. Сейчас: «health» — тренировки, «money» — траты.
    /// Нет данных у соседа — строки нет (а не «0»).
    public static func sphereFacts(sphereId: String, today: String, context: GoalContext) -> [String] {
        let from = PlanDomain.addDays(dateStr: today, days: -(factsWindowDays - 1))
        var lines: [String] = []
        switch sphereId {
        case "health":
            if let n = context.trainingCompleted(from, today) { lines.append("Тренировок за 30 дней: \(n)") }
        case "money":
            if let s = context.spending(from, today) {
                lines.append("Потрачено за 30 дней: \(grouped(s.total)) ₸")
                if let c = s.topCategory, s.topAmount > 0 { lines.append("Больше всего — \(c): \(grouped(s.topAmount)) ₸") }
            }
        default: break
        }
        return lines
    }

    /// Цели сферы (без архивных); `nil` — цели без сферы.
    public static func goals(_ goals: [Goal], sphereId: String?) -> [Goal] {
        goals.filter { !$0.archived && $0.sphereId == sphereId }
    }
}

/// Привычки: процент выполнения за период нужен целям вида «привычка».
extension HabitEngine {
    /// Сколько нужных дней в периоде выполнено. Дни до создания привычки не считаются.
    public static func completion(_ habit: Habit, from: String, to: String, marks: [String: Int],
                                  context: HabitContext) -> (done: Int, total: Int) {
        var done = 0
        var total = 0
        for day in HabitCalendar.days(from: max(from, habit.createdDay), to: to) {
            guard isDue(habit, day: day, marks: marks, context: context) else { continue }
            total += 1
            if isDone(habit, day: day, marks: marks, context: context) { done += 1 }
        }
        return (done, total)
    }
}
