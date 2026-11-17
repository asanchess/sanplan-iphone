import Foundation

/// Сводка «Сегодня»: какие строки показывать в блоках привычек, целей, закреплённых заметок и тренировки.
/// Чистые функции: данные приходят готовыми, ничего не читается и не пишется. Пустой блок — nil (его не рисуют).
/// Порядок блоков на экране (круг 6, холст `Main.html`): главное сейчас · три круга · дальше сегодня · привычки ·
/// цели · закреплённые заметки · прогресс недели · итоги дня. `order` ниже — порядок веба, его не трогаем.
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

    /// «5 упражнений · около 50 минут»: подходы × (≈45 с работы + отдых), округлено до 5 минут. Пустой день — "".
    public static func estimate(_ day: WorkoutDayPlan) -> String {
        guard !day.exercises.isEmpty else { return "" }
        let seconds = day.exercises.reduce(0) { $0 + max(1, $1.sets) * (45 + max(0, $1.restSeconds)) }
        let minutes = max(5, Int((Double(seconds) / 60 / 5).rounded()) * 5)
        return ReviewFormat.plural(day.exercises.count, "упражнение", "упражнения", "упражнений")
            + " · около " + ReviewFormat.plural(minutes, "минута", "минуты", "минут")
    }
}

// MARK: Главное сейчас (карточка-герой холста)

/// Что крупно стоит вверху «Сегодня». Порядок: идущая тренировка · тренировка дня (ещё не сделана) ·
/// ближайший незакрытый план дня · следующая тренировка · пусто. Верхний регистр ставит вид.
public struct TodayHero: Equatable {
    public enum Kind: Equatable { case activeWorkout, workout, plan, nextWorkout, empty }
    public var kind: Kind
    public var kicker: String
    public var title: String
    public var detail: String
    public var action: String
}

public enum TodayHeroSummary {
    public static func make(
        workout: WorkoutSummaryLine?, workoutDetail: String, workoutDoneToday: Bool,
        nextPlan: (title: String, time: String)?, openPlans: Int
    ) -> TodayHero {
        if let workout, workout.kind == .active {
            return TodayHero(kind: .activeWorkout, kicker: "Идёт тренировка", title: workout.title, detail: workoutDetail, action: "Вернуться")
        }
        if let workout, workout.kind == .today, !workoutDoneToday {
            return TodayHero(kind: .workout, kicker: "Главное сейчас", title: workout.title, detail: workoutDetail, action: "Начать")
        }
        if let nextPlan {
            let title = nextPlan.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = max(0, openPlans - 1)
            return TodayHero(
                kind: .plan,
                kicker: nextPlan.time.isEmpty ? "Главное сейчас" : "Главное сейчас · \(nextPlan.time)",
                title: title.isEmpty ? "План" : title,
                detail: rest > 0 ? "Ещё \(ReviewFormat.plural(rest, "план", "плана", "планов")) на сегодня" : "Последний план на сегодня",
                action: "Открыть"
            )
        }
        if let workout, workout.kind == .next {
            return TodayHero(kind: .nextWorkout, kicker: "Следующая тренировка · \(workout.when)", title: workout.title, detail: workoutDetail, action: "Открыть")
        }
        return TodayHero(kind: .empty, kicker: "Главное сейчас", title: "Планов на сегодня нет", detail: "", action: "Запланировать")
    }
}

// MARK: Прогресс недели (одна строка)

public enum TodayWeekBrief {
    /// «Трат на 12% меньше, тренировок больше на одну.» Неделя до сегодняшнего дня против того же отрезка прошлой.
    /// Деньги — в тийынах.
    public static func sentence(spentNow: Int64, spentBefore: Int64, workoutsNow: Int, workoutsBefore: Int) -> String {
        var parts: [String] = []
        if spentBefore > 0 {
            let pct = Int(((Double(spentNow) - Double(spentBefore)) / Double(spentBefore) * 100).rounded())
            parts.append(pct < 0 ? "трат на \(-pct)% меньше" : pct > 0 ? "трат на \(pct)% больше" : "траты как на прошлой неделе")
        } else if spentNow > 0 {
            parts.append("потрачено \(ReviewFormat.tenge(spentNow))")
        }
        if workoutsNow > 0 || workoutsBefore > 0 {
            let d = workoutsNow - workoutsBefore
            parts.append(d > 0 ? "тренировок больше на \(count(d))" : d < 0 ? "тренировок меньше на \(count(-d))" : "тренировок столько же")
        }
        guard let first = parts.first else { return "Сравнивать с прошлой неделей пока не с чем." }
        parts[0] = first.prefix(1).uppercased() + first.dropFirst()
        return parts.joined(separator: ", ") + "."
    }

    static func count(_ n: Int) -> String { n == 1 ? "одну" : n == 2 ? "две" : "\(n)" }
}

// MARK: Итоги: «Собрано само»

/// Одна строка блока «Собрано само» на экране «Итоги»: что, пояснение, число и место, куда она ведёт.
public struct SummaryFactRow: Equatable, Identifiable {
    public enum Kind: String { case plans, workout, money, habits, notes }
    public var kind: Kind
    public var name: String
    public var note: String
    public var value: String
    public var link: DeepLink
    public var id: String { kind.rawValue }
}

public enum SummaryFacts {
    /// День. `dayLimit` — доля лимитов на день в целых тенге (Деньги), `habitsOpen` — неотмеченные привычки дня.
    public static func day(_ digest: PeriodDigest, day: String, workouts: [WorkoutRecord], dayLimit: Int64?, habitsOpen: [String]) -> [SummaryFactRow] {
        var rows: [SummaryFactRow] = []
        let p = digest.plans
        let planNote: String
        if let first = p.open.first {
            planNote = "Не закрыто: «\(first.title)»" + (p.open.count > 1 ? " и ещё \(p.open.count - 1)" : "")
        } else {
            planNote = p.total > 0 ? "Всё закрыто" : "Задач на день не было"
        }
        rows.append(SummaryFactRow(kind: .plans, name: "Планы", note: planNote, value: p.total == 0 ? "нет" : "\(p.done) из \(p.total)", link: .plansAll))

        let sessions = sessionsOf(workouts, from: day, to: day)
        let workoutNote: String
        if let first = sessions.first {
            workoutNote = "\(title(first)) · \(clock(first.startedAt))–\(clock(first.endedAt))" + (sessions.count > 1 ? " и ещё \(sessions.count - 1)" : "")
        } else {
            workoutNote = "Тренировки не было"
        }
        rows.append(SummaryFactRow(
            kind: .workout, name: "Тренировка", note: workoutNote,
            value: sessions.isEmpty ? "нет" : duration(sessions.reduce(0) { $0 + $1.durationSeconds }),
            link: sessions.count == 1 ? .workoutSession(sessions[0].id) : .workoutHistory(.week)
        ))

        let m = digest.money
        let moneyNote: String
        if let dayLimit, dayLimit > 0 {
            moneyNote = "Лимит дня \(ReviewFormat.tenge(dayLimit * 100))"
        } else if let top = m.byCategory.first {
            moneyNote = "Больше всего — \(top.name)"
        } else {
            moneyNote = "Трат не было"
        }
        rows.append(SummaryFactRow(kind: .money, name: "Потрачено", note: moneyNote, value: ReviewFormat.tenge(m.spentMinor), link: .moneyOverview(.week)))

        if let h = digest.habits {
            let open = habitsOpen.filter { !$0.isEmpty }
            let note = open.isEmpty ? "Все отмечены"
                : "Не отмечено: " + open.prefix(2).joined(separator: ", ") + (open.count > 2 ? " и ещё \(open.count - 2)" : "")
            rows.append(SummaryFactRow(kind: .habits, name: "Привычки", note: note, value: "\(h.done) из \(h.total)", link: .habits))
        }
        if digest.notes > 0 {
            rows.append(SummaryFactRow(kind: .notes, name: "Заметки", note: "Новые за день", value: "\(digest.notes)", link: .notes))
        }
        return rows
    }

    /// Неделя (пн–вс) против прошлой. `days` — дни этой недели до сегодняшнего включительно (для «дней без планов»).
    public static func week(current: PeriodDigest, previous: PeriodDigest, days: [String], plans: [PlanItem], workouts: [WorkoutRecord], from: String, to: String) -> [SummaryFactRow] {
        var rows: [SummaryFactRow] = []
        let p = current.plans
        let empty = days.filter { PlanSummary.day(plans: plans, day: $0).total == 0 }.count
        let planNote = p.total == 0 ? "Задач на неделе не было"
            : empty > 0 ? "\(ReviewFormat.plural(empty, "день", "дня", "дней")) без планов" : "Планы каждый день"
        rows.append(SummaryFactRow(kind: .plans, name: "Планы", note: planNote, value: p.total == 0 ? "нет" : "\(p.done) из \(p.total)", link: .plansAll))

        let sessions = sessionsOf(workouts, from: from, to: to)
        let total = sessions.reduce(0) { $0 + $1.durationSeconds }
        rows.append(SummaryFactRow(
            kind: .workout, name: "Тренировка",
            note: sessions.isEmpty ? "Тренировок не было"
                : "\(ReviewFormat.plural(sessions.count, "тренировка", "тренировки", "тренировок")) · в среднем \(total / sessions.count / 60) мин",
            value: sessions.isEmpty ? "нет" : duration(total), link: .workoutHistory(.week)
        ))

        let now = current.money.spentMinor, before = previous.money.spentMinor
        let moneyNote: String
        if before > 0 {
            let pct = Int(((Double(now) - Double(before)) / Double(before) * 100).rounded())
            moneyNote = pct < 0 ? "На \(-pct)% меньше прошлой недели" : pct > 0 ? "На \(pct)% больше прошлой недели" : "Как на прошлой неделе"
        } else {
            moneyNote = current.money.count == 0 ? "Трат не было" : "Прошлой недели для сравнения нет"
        }
        rows.append(SummaryFactRow(kind: .money, name: "Потрачено", note: moneyNote, value: ReviewFormat.tenge(now), link: .moneyOverview(.week)))

        if let h = current.habits {
            let d = h.done - (previous.habits?.done ?? 0)
            let note = previous.habits == nil ? "Прошлой недели для сравнения нет"
                : d == 0 ? "Как на прошлой неделе" : "К прошлой неделе: \(d > 0 ? "+" : "−")\(abs(d))"
            rows.append(SummaryFactRow(kind: .habits, name: "Привычки", note: note, value: "\(h.done) из \(h.total)", link: .habits))
        }
        if current.notes > 0 {
            rows.append(SummaryFactRow(kind: .notes, name: "Заметки", note: "Новые за неделю", value: "\(current.notes)", link: .notes))
        }
        return rows
    }

    /// Засчитанные тренировки периода (с отмеченным подходом), по времени начала.
    static func sessionsOf(_ records: [WorkoutRecord], from: String, to: String) -> [WorkoutRecord] {
        records.filter { $0.doneSetCount > 0 }
            .filter { let d = WorkoutSummary.dayKey($0.startedAt); return d >= from && d <= to }
            .sorted { $0.startedAt < $1.startedAt }
    }

    static func title(_ record: WorkoutRecord) -> String {
        let t = (record.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Тренировка" : t
    }

    /// «52 мин», «1 ч 47 м», «2 ч».
    public static func duration(_ seconds: Int) -> String {
        let minutes = Int((Double(max(0, seconds)) / 60).rounded())
        if minutes < 60 { return "\(minutes) мин" }
        return minutes % 60 == 0 ? "\(minutes / 60) ч" : "\(minutes / 60) ч \(minutes % 60) м"
    }

    static func clock(_ ms: Int64) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WorkoutSummary.zone
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Подпись под оценкой дня, как на холсте.
    public static func moodText(_ mood: Int?) -> String {
        switch mood {
        case 1: return "Тяжёлый день."
        case 2: return "Так себе."
        case 3: return "Нормально."
        case 4: return "Хороший день."
        case 5: return "Отличный день."
        default: return "Можно пропустить."
        }
    }
}
