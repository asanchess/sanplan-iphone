import Foundation

/// Сводка «Сегодня»: какие строки показывать в блоках привычек, целей, закреплённых заметок и тренировки.
/// Чистые функции: данные приходят готовыми, ничего не читается и не пишется. Пустой блок — nil (его не рисуют).
/// Порядок блоков на экране: итоги дня · планы · привычки · цели · закреплённые заметки · деньги · тренировка.
/// Зеркало `src/today-summary.mjs`; числа и правила совпадают. Без мотивационных текстов.
public enum TodaySummary {
    public static let habitsLimit = 4
    public static let goalsLimit = 3
    public static let notesLimit = 3
    public static let order = ["review", "plans", "habits", "goals", "notes", "money", "workout"]

    /// «ещё 2» под блоком, когда строк больше, чем показано.
    public static func moreText(_ count: Int) -> String { count > 0 ? "ещё \(count)" : "" }
}

// MARK: Привычки

public struct SummaryHabitRow: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var done: Bool
    /// Отмечена правилом, а не рукой: вручную не снимается.
    public var auto: Bool
    /// «3 из 8 стак.» для привычек с количеством, иначе пусто.
    public var detail: String
}

public struct HabitsSummaryBlock: Equatable {
    public var rows: [SummaryHabitRow]
    public var more: Int
    public var done: Int
    public var total: Int
}

public enum TodayHabitsSummary {
    /// Привычки на сегодня: те, что нужно отметить в этот день. Невыполненные первыми, порядок внутри групп прежний.
    public static func make(
        habits: [Habit], marks: [String: [String: Int]], day: String, context: HabitContext,
        limit: Int = TodaySummary.habitsLimit
    ) -> HabitsSummaryBlock? {
        var rows: [SummaryHabitRow] = []
        for habit in habits where !habit.archived {
            let own = marks[habit.id] ?? [:]
            guard HabitEngine.isDue(habit, day: day, marks: own, context: context) else { continue }
            let unit = habit.target.unit.isEmpty ? "" : " \(habit.target.unit)"
            rows.append(SummaryHabitRow(
                id: habit.id,
                title: habit.title,
                done: HabitEngine.isDone(habit, day: day, marks: own, context: context),
                auto: habit.rule.map { HabitEngine.ruleSatisfied($0, day: day, context: context) } ?? false,
                detail: habit.target.isCountable ? "\(own[day] ?? 0) из \(habit.target.amount)\(unit)" : ""
            ))
        }
        guard !rows.isEmpty else { return nil }
        let done = rows.filter(\.done).count
        let ordered = rows.filter { !$0.done } + rows.filter(\.done)
        return HabitsSummaryBlock(rows: Array(ordered.prefix(limit)), more: max(0, rows.count - limit), done: done, total: rows.count)
    }
}

// MARK: Цели

public struct SummaryGoalRow: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var text: String
    /// 0…1; nil — данных нет (это не ноль).
    public var fraction: Double?
    public var isWeek: Bool
}

public struct GoalsSummaryBlock: Equatable {
    public var rows: [SummaryGoalRow]
    public var more: Int
}

public enum GoalsSummary {
    /// До трёх активных целей (не в архиве, ещё не достигнутых), цель недели первой.
    public static func make(
        goals: [Goal], weekGoalId: String?, progressOf: (Goal) -> GoalProgress,
        limit: Int = TodaySummary.goalsLimit
    ) -> GoalsSummaryBlock? {
        var rows: [SummaryGoalRow] = []
        for goal in goals where !goal.archived {
            let progress = progressOf(goal)
            if progress.achieved { continue }
            let fraction = progress.fraction.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
            rows.append(SummaryGoalRow(
                id: goal.id, title: goal.title,
                text: progress.text.trimmingCharacters(in: .whitespacesAndNewlines),
                fraction: fraction, isWeek: goal.id == weekGoalId
            ))
        }
        guard !rows.isEmpty else { return nil }
        let ordered = rows.filter(\.isWeek) + rows.filter { !$0.isWeek }
        return GoalsSummaryBlock(rows: Array(ordered.prefix(limit)), more: max(0, rows.count - limit))
    }
}

// MARK: Закреплённые заметки

public struct SummaryNoteRow: Equatable, Identifiable {
    public var id: String
    public var title: String
}

public struct PinnedNotesBlock: Equatable {
    public var rows: [SummaryNoteRow]
    public var more: Int
}

public enum PinnedNotesSummary {
    /// Закрепление = избранное: не удалённые, самые свежие первыми, до трёх.
    public static func make(notes: [Note], limit: Int = TodaySummary.notesLimit) -> PinnedNotesBlock? {
        let pinned = notes
            .filter { $0.pinned && !$0.deleted && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
        guard !pinned.isEmpty else { return nil }
        return PinnedNotesBlock(
            rows: pinned.prefix(limit).map { SummaryNoteRow(id: $0.id, title: $0.title) },
            more: max(0, pinned.count - limit)
        )
    }
}

// MARK: Тренировка

public struct WorkoutSummaryLine: Equatable {
    public enum Kind: String { case active, today, next }
    public var kind: Kind
    public var title: String
    public var when: String
}

public enum TodayWorkoutSummary {
    private static let weekdayShort = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    /// Идущая тренировка, иначе сегодняшний день программы, иначе ближайший следующий (по кругу недели).
    /// `weekday` — сегодня, 1…7 (Пн = 1). Нет ни сессии, ни программы — nil.
    public static func make(active: Bool, currentName: String, days: [WorkoutDayPlan], weekday: Int) -> WorkoutSummaryLine? {
        if active {
            let name = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
            return WorkoutSummaryLine(kind: .active, title: name.isEmpty ? "Тренировка" : name, when: "Идёт сейчас")
        }
        let valid = days.filter { (1...7).contains($0.weekday) }
        guard !valid.isEmpty, (1...7).contains(weekday) else { return nil }
        func title(_ day: WorkoutDayPlan) -> String {
            let text = (day.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Тренировка" : text
        }
        if let today = valid.first(where: { $0.weekday == weekday }) {
            return WorkoutSummaryLine(kind: .today, title: title(today), when: "Сегодня")
        }
        var best = valid[0]
        var bestGap = 8
        for day in valid {
            let gap = (day.weekday - weekday + 7) % 7
            if gap < bestGap { best = day; bestGap = gap }
        }
        return WorkoutSummaryLine(kind: .next, title: title(best), when: bestGap == 1 ? "Завтра" : weekdayShort[best.weekday - 1])
    }
}
