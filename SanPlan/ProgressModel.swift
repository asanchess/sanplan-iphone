import Foundation

// «Прогресс», round 6: everything the sheet shows, computed from the person's own data.
// Owner: every number opens exactly what it is about, the period is spelled out, empty blocks say so honestly.

/// This calendar week (Monday on) or month up to today, and the same stretch of the one before it.
struct ProgressPeriod: Equatable {
    let kind: DeepLink.Period
    let from: String
    let to: String
    let previousFrom: String
    let previousTo: String
    /// First and last day of the whole calendar week or month, for the caption.
    let start: String
    let end: String

    static func make(_ kind: DeepLink.Period, today: String) -> ProgressPeriod {
        switch kind {
        case .week:
            let from = HabitCalendar.weekStart(today)
            return ProgressPeriod(
                kind: .week, from: from, to: today,
                previousFrom: PlanDomain.addDays(dateStr: from, days: -7),
                previousTo: PlanDomain.addDays(dateStr: today, days: -7),
                start: from, end: PlanDomain.addDays(dateStr: from, days: 6)
            )
        case .month:
            let month = String(today.prefix(7))
            let previous = FinanceInsights.previousMonth(month)
            let day = Int(today.suffix(2)) ?? 1
            return ProgressPeriod(
                kind: .month, from: month + "-01", to: today,
                previousFrom: previous + "-01",
                previousTo: previous + String(format: "-%02d", min(day, ProgressText.daysIn(previous))),
                start: month + "-01", end: month + String(format: "-%02d", ProgressText.daysIn(month))
            )
        }
    }

    func contains(_ day: String) -> Bool { day >= from && day <= to }

    /// «за неделю» / «за ноябрь».
    var label: String {
        kind == .week ? "за неделю" : "за \(ProgressText.monthName(from, .nominative))"
    }

    /// «ЗА НЕДЕЛЮ · 16–22 НОЯБРЯ» (shown upper-cased).
    var caption: String { "\(label) · \(ProgressText.range(start, end))" }

    /// «прошлой недели» / «октября».
    var previousGenitive: String {
        kind == .week ? "прошлой недели" : ProgressText.monthName(previousFrom, .genitive)
    }

    /// «на прошлой неделе» / «в октябре».
    var previousIn: String {
        kind == .week ? "на прошлой неделе" : "в \(ProgressText.monthName(previousFrom, .prepositional))"
    }
}

struct ProgressTrend: Identifiable, Equatable {
    enum Kind: String { case money, workouts, plans, gym }
    let kind: Kind
    let value: String
    let note: String
    /// Where a tap goes (owner, round 6).
    let link: DeepLink
    var id: String { kind.rawValue }

    var name: String {
        switch kind {
        case .money: return "ТРАТЫ"
        case .workouts: return "ТРЕНИРОВКИ"
        case .plans: return "ПЛАНЫ"
        case .gym: return "ВРЕМЯ В ЗАЛЕ"
        }
    }

    var accessibilityHint: String {
        switch link {
        case .moneyOverview: return "Откроет «Деньги», обзор за этот период"
        case .workoutHistory: return "Откроет историю тренировок за этот период"
        case .plansAll: return "Откроет все планы"
        case .workoutSession: return "Откроет последнюю тренировку периода"
        default: return "Откроет раздел"
        }
    }
}

/// «Заметки» block: notes written or changed in the period.
struct ProgressNotesLine: Equatable {
    /// Notes written or changed in the period; 0 → the honest empty line.
    let count: Int
    let headline: String
    let detail: String?
}

/// One item of «Может, забыли?».
struct ProgressForgotten: Identifiable, Equatable {
    enum Kind: Equatable { case plan, goal, note }
    let id: String
    let kind: Kind
    let name: String
    let note: String
    /// The main button: «Выполнен» marks a plan done; «Открыть» opens the place.
    let yes: String
    let link: DeepLink
}

struct ProgressSnapshot {
    var period: ProgressPeriod
    var trends: [ProgressTrend]
    var goals: GoalsSummaryBlock?
    var notes: ProgressNotesLine
    var arc: ProgressArcPosition
    var forgotten: [ProgressForgotten]
    var isDemo = false
}

/// Raw data the snapshot is made from; the screen fills it from the stores.
struct ProgressInputs {
    var today: String
    var plans: [PlanItem]
    /// Money data; spending is read with `FinanceSummaries.period` (whole tenge, days inclusive).
    var finance: FinanceState
    var workouts: [WorkoutRecord]
    var weeklyGoal: Int
    var goals: GoalsSummaryBlock?
    /// Goals past their due day and not reached: (goal, due day).
    var overdueGoals: [(id: String, title: String, due: String)]
    var notes: [Note]
}

enum ProgressBuilder {
    static func make(_ input: ProgressInputs, kind: DeepLink.Period) -> ProgressSnapshot {
        let period = ProgressPeriod.make(kind, today: input.today)
        let tasks = PlanDomain.visibleItems(input.plans).filter { $0.kind == "task" && $0.alarmDeleted != true }
        let counted = input.workouts.filter { $0.doneSetCount > 0 }
        return ProgressSnapshot(
            period: period,
            trends: trends(input, period: period, tasks: tasks, workouts: counted),
            goals: input.goals,
            notes: notesLine(input.notes, period: period, today: input.today),
            arc: ProgressArcs.position(counted: ProgressArcs.countedWeeks(
                closedTaskDays: tasks.filter { $0.completed == true }.compactMap(\.date).filter { $0 <= input.today },
                workoutDays: counted.map { WorkoutSummary.dayKey($0.startedAt) }
            )),
            forgotten: forgotten(input, tasks: tasks)
        )
    }

    // MARK: Numbers

    static func trends(_ input: ProgressInputs, period: ProgressPeriod, tasks: [PlanItem], workouts: [WorkoutRecord]) -> [ProgressTrend] {
        let spent = FinanceSummaries.period(input.finance, from: period.from, to: period.to).spent
        let spentBefore = FinanceSummaries.period(input.finance, from: period.previousFrom, to: period.previousTo).spent

        let inPeriod = workouts.filter { period.contains(WorkoutSummary.dayKey($0.startedAt)) }
        let before = workouts.filter {
            let day = WorkoutSummary.dayKey($0.startedAt)
            return day >= period.previousFrom && day <= period.previousTo
        }.count
        let workoutsValue = period.kind == .week && input.weeklyGoal > 0
            ? "\(inPeriod.count) из \(input.weeklyGoal)" : "\(inPeriod.count)"
        let workoutsNote = period.kind == .week ? "было \(before) на прошлой неделе" : "\(period.previousIn) было \(before)"

        let dated = tasks.filter { ($0.date).map(period.contains) ?? false }
        let closed = dated.filter { $0.completed == true }.count

        let seconds = inPeriod.reduce(0) { $0 + $1.durationSeconds }
        let latest = inPeriod.max { $0.startedAt < $1.startedAt }

        return [
            ProgressTrend(kind: .money, value: ReviewFormat.tenge(spent * 100),
                          note: compare(spent, spentBefore, period: period),
                          link: .moneyOverview(period.kind)),
            ProgressTrend(kind: .workouts, value: workoutsValue, note: workoutsNote,
                          link: .workoutHistory(period.kind)),
            ProgressTrend(kind: .plans,
                          value: dated.isEmpty ? "—" : "\(closed * 100 / dated.count)%",
                          note: dated.isEmpty ? "задач с датой не было" : "Закрыто \(closed) из \(dated.count)",
                          link: .plansAll),
            ProgressTrend(kind: .gym,
                          value: inPeriod.isEmpty ? "—" : ProgressText.duration(minutes: seconds / 60),
                          note: inPeriod.isEmpty ? "тренировок не было"
                              : "в среднем \(ProgressText.durationLong(minutes: seconds / 60 / inPeriod.count))",
                          link: latest.map { .workoutSession($0.id) } ?? .workoutHistory(period.kind))
        ]
    }

    static func compare(_ now: Int64, _ before: Int64, period: ProgressPeriod) -> String {
        guard before > 0 else { return now == 0 ? "трат не было" : "\(period.previousIn) трат не было" }
        let pct = Int((Double(now - before) / Double(before) * 100).rounded())
        if pct == 0 { return "как и \(period.previousIn)" }
        return "на \(abs(pct))% \(pct > 0 ? "больше" : "меньше") \(period.previousGenitive)"
    }

    // MARK: Notes

    static func notesLine(_ notes: [Note], period: ProgressPeriod, today: String) -> ProgressNotesLine {
        let live = notes
            .filter { !$0.deleted && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard let last = live.first else {
            return ProgressNotesLine(count: 0, headline: "Заметок нет.", detail: nil)
        }
        let lastDay = WorkoutSummary.dayKey(last.updatedAt)
        let written = live.filter { period.contains(WorkoutSummary.dayKey($0.updatedAt)) }
        guard !written.isEmpty else {
            return ProgressNotesLine(count: 0, headline: "Заметок давно не было.",
                                     detail: "Последняя — \(ProgressText.dayLabel(lastDay, today: today))")
        }
        return ProgressNotesLine(
            count: written.count,
            headline: "\(ReviewFormat.plural(written.count, "заметка", "заметки", "заметок")) \(period.label)",
            detail: "Последняя — «\(last.title)», \(ProgressText.dayLabel(lastDay, today: today))"
        )
    }

    // MARK: May have forgotten

    static func forgotten(_ input: ProgressInputs, tasks: [PlanItem]) -> [ProgressForgotten] {
        let weekAgo = PlanDomain.addDays(dateStr: input.today, days: -7)
        let plans = tasks
            .filter { $0.completed != true && ($0.date ?? "9999") <= weekAgo }
            .sorted { ($0.date ?? "") > ($1.date ?? "") }
            .prefix(3)
            .map { plan -> ProgressForgotten in
                let days = ProgressText.daysBetween(plan.date ?? input.today, input.today)
                return ProgressForgotten(
                    id: "plan-\(plan.id)", kind: .plan, name: "План «\(plan.title)»",
                    note: "Срок прошёл \(ReviewFormat.plural(days, "день", "дня", "дней")) назад, не отмечен",
                    yes: "Выполнен", link: .plansAll
                )
            }
        let goals = input.overdueGoals.prefix(2).map { goal -> ProgressForgotten in
            let days = ProgressText.daysBetween(goal.due, input.today)
            return ProgressForgotten(
                id: "goal-\(goal.id)", kind: .goal, name: "Цель «\(goal.title)»",
                note: "Срок прошёл \(ReviewFormat.plural(days, "день", "дня", "дней")) назад",
                yes: "Открыть", link: .goals
            )
        }
        let monthAgo = PlanDomain.addDays(dateStr: input.today, days: -30)
        let notes = input.notes
            .filter { $0.pinned && !$0.deleted && WorkoutSummary.dayKey($0.updatedAt) <= monthAgo }
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(1)
            .map { note -> ProgressForgotten in
                let days = ProgressText.daysBetween(WorkoutSummary.dayKey(note.updatedAt), input.today)
                return ProgressForgotten(
                    id: "note-\(note.id)", kind: .note, name: "Заметка «\(note.title)»",
                    note: "Закреплена, не меняли \(ReviewFormat.plural(days, "день", "дня", "дней"))",
                    yes: "Открыть", link: .notes
                )
            }
        return Array(plans) + Array(goals) + Array(notes)
    }
}

// MARK: - Demo (screenshots only, never saved)

extension ProgressSnapshot {
    /// Made-up numbers from the canvas for `--screenshot-demo-data`. Lives only in memory.
    static func demo(_ kind: DeepLink.Period, today: String) -> ProgressSnapshot {
        let period = ProgressPeriod.make(kind, today: today)
        let week = kind == .week
        let goals = GoalsSummaryBlock(rows: [
            SummaryGoalRow(id: "demo-g1", title: "Отложить на отпуск", text: "120 000 из 300 000 ₸", fraction: 0.4, isWeek: true),
            SummaryGoalRow(id: "demo-g2", title: "Читать 20 минут", text: "9 из 14 дней", fraction: 0.64, isWeek: false)
        ], more: 0)
        return ProgressSnapshot(
            period: period,
            trends: [
                ProgressTrend(kind: .money, value: week ? "41 200 ₸" : "148 000 ₸",
                              note: week ? "на 12% меньше прошлой недели" : "на 6% больше \(period.previousGenitive)",
                              link: .moneyOverview(kind)),
                ProgressTrend(kind: .workouts, value: week ? "2 из 3" : "11",
                              note: week ? "было 1 на прошлой неделе" : "\(period.previousIn) было 8",
                              link: .workoutHistory(kind)),
                ProgressTrend(kind: .plans, value: week ? "71%" : "64%",
                              note: week ? "Закрыто 10 из 14" : "Закрыто 45 из 70", link: .plansAll),
                ProgressTrend(kind: .gym, value: week ? "1 ч 47 м" : "9 ч 20 м",
                              note: week ? "в среднем 53 минуты" : "в среднем 51 минута",
                              link: .workoutHistory(kind))
            ],
            goals: goals,
            notes: ProgressNotesLine(count: 3, headline: "3 заметки \(period.label)",
                                     detail: "Последняя — «Идеи для отпуска», вчера"),
            arc: ProgressArcs.position(counted: 3),
            forgotten: [
                ProgressForgotten(id: "demo-a", kind: .plan, name: "План «Записаться к врачу»",
                                  note: "Срок прошёл 9 дней назад, не отмечен", yes: "Выполнен", link: .plansAll),
                ProgressForgotten(id: "demo-b", kind: .note, name: "Заметка «Идеи для отпуска»",
                                  note: "Закреплена, не меняли 34 дня", yes: "Открыть", link: .notes),
                ProgressForgotten(id: "demo-c", kind: .goal, name: "Цель «Читать 20 минут»",
                                  note: "Срок прошёл 14 дней назад", yes: "Открыть", link: .goals)
            ],
            isDemo: true
        )
    }
}

// MARK: - Russian dates and durations

enum ProgressText {
    enum Case { case nominative, genitive, prepositional }

    private static let nominative = ["январь", "февраль", "март", "апрель", "май", "июнь",
                                     "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь"]
    private static let genitive = ["января", "февраля", "марта", "апреля", "мая", "июня",
                                   "июля", "августа", "сентября", "октября", "ноября", "декабря"]
    private static let prepositional = ["январе", "феврале", "марте", "апреле", "мае", "июне",
                                        "июле", "августе", "сентябре", "октябре", "ноябре", "декабре"]

    /// Month of a «YYYY-MM» or «YYYY-MM-DD» string.
    static func monthName(_ day: String, _ form: Case) -> String {
        let parts = day.split(separator: "-")
        guard parts.count >= 2, let m = Int(parts[1]), (1...12).contains(m) else { return "" }
        switch form {
        case .nominative: return nominative[m - 1]
        case .genitive: return genitive[m - 1]
        case .prepositional: return prepositional[m - 1]
        }
    }

    static func dayNumber(_ day: String) -> Int { Int(day.suffix(2)) ?? 0 }

    /// «16–22 ноября», «30 ноября – 6 декабря».
    static func range(_ from: String, _ to: String) -> String {
        if from.prefix(7) == to.prefix(7) {
            return "\(dayNumber(from))–\(dayNumber(to)) \(monthName(to, .genitive))"
        }
        return "\(dayNumber(from)) \(monthName(from, .genitive)) – \(dayNumber(to)) \(monthName(to, .genitive))"
    }

    /// «сегодня», «вчера», «12 октября».
    static func dayLabel(_ day: String, today: String) -> String {
        if day == today { return "сегодня" }
        if day == PlanDomain.addDays(dateStr: today, days: -1) { return "вчера" }
        return "\(dayNumber(day)) \(monthName(day, .genitive))"
    }

    static func daysIn(_ month: String) -> Int {
        guard let year = Int(month.prefix(4)), let m = Int(month.dropFirst(5).prefix(2)) else { return 30 }
        return getDaysInMonth(year: year, month: m)
    }

    /// Whole days from `from` to `to` (date strings); 0 when unreadable.
    static func daysBetween(_ from: String, _ to: String) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        func date(_ s: String) -> Date? {
            let p = s.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        }
        guard let a = date(from), let b = date(to) else { return 0 }
        return max(0, calendar.dateComponents([.day], from: a, to: b).day ?? 0)
    }

    /// «1 ч 47 м», «47 мин».
    static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) м" : "\(minutes) мин"
    }

    /// «53 минуты», «1 ч 5 м».
    static func durationLong(minutes: Int) -> String {
        minutes >= 60 ? duration(minutes: minutes) : ReviewFormat.plural(minutes, "минута", "минуты", "минут")
    }
}
