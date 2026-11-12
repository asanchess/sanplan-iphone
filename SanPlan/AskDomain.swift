import Foundation

// Вопросы в «+»: детерминированный разбор частых формулировок. Ответ считается кодом
// из сводок разделов, модель не участвует и ничего не уходит наружу.

public enum AskPeriod: Equatable {
    case today, yesterday, tomorrow, thisWeek, lastWeek, thisMonth, lastMonth

    /// Inclusive day range for the period, given today.
    public func range(today: String) -> (from: String, to: String) {
        switch self {
        case .today: return (today, today)
        case .yesterday: let d = ReviewCalendar.addDays(today, -1); return (d, d)
        case .tomorrow: let d = ReviewCalendar.addDays(today, 1); return (d, d)
        case .thisWeek: let s = ReviewCalendar.weekStart(today); return (s, ReviewCalendar.addDays(s, 6))
        case .lastWeek: let s = ReviewCalendar.addDays(ReviewCalendar.weekStart(today), -7); return (s, ReviewCalendar.addDays(s, 6))
        case .thisMonth: return (ReviewCalendar.monthStart(today), ReviewCalendar.monthEnd(today))
        case .lastMonth:
            let last = ReviewCalendar.addDays(ReviewCalendar.monthStart(today), -1)
            return (ReviewCalendar.monthStart(last), last)
        }
    }

    /// «в этом месяце», «на этой неделе»…
    public var phrase: String {
        switch self {
        case .today: return "сегодня"
        case .yesterday: return "вчера"
        case .tomorrow: return "завтра"
        case .thisWeek: return "на этой неделе"
        case .lastWeek: return "на прошлой неделе"
        case .thisMonth: return "в этом месяце"
        case .lastMonth: return "в прошлом месяце"
        }
    }
}

/// A spending subject the person named: its label for the answer and the finance categories it covers.
public struct AskCategory: Equatable {
    public var label: String
    public var names: Set<String>
}

public enum AskQuery: Equatable {
    case spent(AskPeriod, AskCategory?)
    case trainings(AskPeriod)
    case agenda(AskPeriod)
    case canSpendToday
}

public enum AskParser {
    /// Examples shown when a question is not understood.
    public static let examples = [
        "Сколько я потратил на еду в этом месяце?",
        "Сколько тренировок на этой неделе?",
        "Что у меня завтра?",
        "Сколько можно потратить сегодня?"
    ]

    static let categoryGroups: [(words: [String], category: AskCategory)] = [
        (["еду", "еда", "еды", "питание", "питани", "продукт"], AskCategory(label: "еду", names: ["Продукты", "Кафе и рестораны", "Доставка еды", "Еда"])),
        (["кафе", "ресторан"], AskCategory(label: "кафе и рестораны", names: ["Кафе и рестораны"])),
        (["доставк"], AskCategory(label: "доставку еды", names: ["Доставка еды"])),
        (["транспорт", "такси", "проезд", "бензин"], AskCategory(label: "транспорт", names: ["Транспорт"])),
        (["связь", "связи", "интернет", "телефон"], AskCategory(label: "связь и интернет", names: ["Связь и интернет", "Связь"])),
        (["здоровь", "лекарств", "аптек"], AskCategory(label: "здоровье", names: ["Здоровье"])),
        (["покупк", "одежд"], AskCategory(label: "покупки", names: ["Покупки"]))
    ]

    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let cleaned = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// Cheap check used by «+» to decide whether to offer an answer at all.
    public static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 140, !trimmed.contains("\n") else { return false }
        return parse(trimmed) != nil
    }

    public static func period(in words: String) -> AskPeriod? {
        // Longest, most specific phrases first.
        let table: [(String, AskPeriod)] = [
            ("прошлом месяце", .lastMonth), ("прошлый месяц", .lastMonth), ("за прошлый месяц", .lastMonth),
            ("прошлой неделе", .lastWeek), ("прошлую неделю", .lastWeek),
            ("этом месяце", .thisMonth), ("этот месяц", .thisMonth), ("за месяц", .thisMonth), ("месяц", .thisMonth),
            ("этой неделе", .thisWeek), ("эту неделю", .thisWeek), ("за неделю", .thisWeek), ("неделе", .thisWeek), ("неделю", .thisWeek),
            ("послезавтра", .tomorrow), ("завтра", .tomorrow),
            ("вчера", .yesterday), ("сегодня", .today)
        ]
        for (phrase, period) in table where words.contains(phrase) {
            if phrase == "послезавтра" { return nil } // not supported: say so rather than answer for tomorrow
            return period
        }
        return nil
    }

    public static func parse(_ text: String) -> AskQuery? {
        let words = normalize(text)
        guard !words.isEmpty else { return nil }
        if words.contains("послезавтра") { return nil }
        let asked = period(in: words)

        // «Сколько можно потратить сегодня», «сколько могу потратить».
        if words.contains("сколько"), words.contains("можно") || words.contains("могу"), words.contains("потрат") {
            return .canSpendToday
        }
        // «Сколько тренировок на этой неделе».
        if words.contains("сколько"), words.contains("трениров") || words.contains("занятий") || words.contains("занимался") {
            return .trainings(asked ?? .thisWeek)
        }
        // «Сколько я потратил на еду в этом месяце».
        if words.contains("потратил") || words.contains("потрачено") || words.contains("трат") || words.contains("расход") {
            let subject = categoryGroups.first { group in group.words.contains { words.contains($0) } }?.category
            return .spent(asked ?? .thisMonth, subject)
        }
        // «Что у меня завтра», «планы на сегодня».
        if words.hasPrefix("что") || words.contains("планы") || words.contains("план на") || words.contains("дела") {
            if let asked, asked == .today || asked == .tomorrow || asked == .yesterday { return .agenda(asked) }
        }
        return nil
    }
}

// MARK: - Answers

/// Plain values the answers are computed from. Stores fill it; tests build it directly.
public struct AskData {
    public var today: String
    public var plans: [PlanItem]
    public var finance: [FinanceRecord]
    public var workouts: [WorkoutRecord]
    public var dailyMinor: Int64?
    public var timeZone: String

    public init(today: String, plans: [PlanItem] = [], finance: [FinanceRecord] = [], workouts: [WorkoutRecord] = [], dailyMinor: Int64? = nil, timeZone: String = PlanDomain.defaultTimeZone) {
        self.today = today; self.plans = plans; self.finance = finance; self.workouts = workouts; self.dailyMinor = dailyMinor; self.timeZone = timeZone
    }
}

public struct AskAnswer: Equatable {
    public var text: String
    public var lines: [String]
    public var isUnderstood: Bool
}

public enum AskEngine {
    public static func answer(_ text: String, data: AskData) -> AskAnswer {
        guard let query = AskParser.parse(text) else {
            return AskAnswer(text: "Такой вопрос пока не разобрать. Можно спросить так:", lines: AskParser.examples, isUnderstood: false)
        }
        return answer(query, data: data)
    }

    public static func answer(_ query: AskQuery, data: AskData) -> AskAnswer {
        switch query {
        case .spent(let period, let category):
            let range = period.range(today: data.today)
            let money = ReviewSummaries.financePeriod(data.finance, from: range.from, to: range.to, categories: category?.names)
            let subject = category.map { " на \($0.label)" } ?? ""
            guard money.count > 0 else {
                return AskAnswer(text: "Трат\(subject) \(period.phrase) нет.", lines: [], isUnderstood: true)
            }
            let lines = category == nil ? money.byCategory.prefix(3).map { "\($0.name): \(ReviewFormat.tenge($0.amountMinor))" } : []
            return AskAnswer(
                text: "Потрачено\(subject) \(period.phrase): \(ReviewFormat.tenge(money.spentMinor)) (\(ReviewFormat.plural(money.count, "трата", "траты", "трат"))).",
                lines: Array(lines), isUnderstood: true)
        case .trainings(let period):
            let range = period.range(today: data.today)
            let training = ReviewSummaries.trainingPeriod(data.workouts, from: range.from, to: range.to, timeZone: data.timeZone)
            guard training.completed > 0 else {
                return AskAnswer(text: "Тренировок \(period.phrase) нет.", lines: [], isUnderstood: true)
            }
            return AskAnswer(text: "Тренировок \(period.phrase): \(training.completed).", lines: training.titles, isUnderstood: true)
        case .agenda(let period):
            let day = period.range(today: data.today).from
            let items = PlanDomain.getAgendaItems(plans: data.plans.filter { !($0.date ?? "").isEmpty }, targetDate: day, targetTimeZone: data.timeZone)
            guard !items.isEmpty else {
                return AskAnswer(text: "На \(period == .tomorrow ? "завтра" : period == .yesterday ? "вчера" : "сегодня") планов нет.", lines: [], isUnderstood: true)
            }
            let lines = items.prefix(6).map { $0.displayTime.isEmpty ? $0.item.title : "\($0.displayTime) — \($0.item.title)" }
            let more = items.count > 6 ? ["…и ещё \(items.count - 6)"] : []
            return AskAnswer(text: "\(period == .tomorrow ? "Завтра" : period == .yesterday ? "Вчера" : "Сегодня"): \(ReviewFormat.plural(items.count, "дело", "дела", "дел")).", lines: Array(lines) + more, isUnderstood: true)
        case .canSpendToday:
            guard let daily = data.dailyMinor else {
                return AskAnswer(text: "Не хватает данных: в «Деньги» нужны баланс и обязательные платежи.", lines: [], isUnderstood: true)
            }
            return AskAnswer(text: "Сегодня можно потратить \(ReviewFormat.tenge(max(0, daily))).", lines: [], isUnderstood: true)
        }
    }
}

extension AskData {
    @MainActor
    static func current(plans: PlanStore, finance: FinanceStore, workouts: WorkoutStore) -> AskData {
        AskData(
            today: PlanDomain.today(timeZone: plans.timeZone),
            plans: plans.plans + plans.upcomingEvents,
            finance: finance.state.records,
            workouts: workouts.history.records,
            dailyMinor: finance.summary?.dailyMinor,
            timeZone: plans.timeZone
        )
    }
}
