import SwiftUI

/// What the walking mascot says on a tap: one short reminder from the person's own data, no advice and no cheering.
struct MascotReminderInput: Equatable {
    var plansTotal = 0
    var plansDone = 0
    var nextPlanTitle: String? = nil
    var workoutPlanned = false
    var workoutDone = false
    var workoutActive = false
    /// Already formatted, e.g. «4 500 ₸»; nil without a budget.
    var canSpend: String? = nil
    var pinnedNote: String? = nil
    /// «14:30» of the nearest open plan, when it has a time.
    var nextPlanTime: String? = nil
    /// Today's share of the limits, formatted; nil without day limits.
    var dayLimit: String? = nil
    /// «Жим лёжа, подход 3» during a workout.
    var nextSet: String? = nil
    /// «завтра: Ноги» from the program.
    var nextWorkout: String? = nil
    var pinnedCount = 0

    init() {}
}

enum MascotReminders {
    /// Titles are cut so the bubble stays two lines.
    static func short(_ title: String, limit: Int = 32) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        return String(clean.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func plansLeft(_ n: Int) -> String {
        ReviewFormat.plural(n, "план", "плана", "планов")
    }

    /// Every line that holds now, the current section's first; a tap shows the next one.
    /// A section that is off (`hidden`) has no line.
    static func lines(_ input: MascotReminderInput, focus: MainTab, hidden: Set<MainTab> = []) -> [String] {
        var plans: [String] = []
        let open = max(input.plansTotal - input.plansDone, 0)
        if input.plansTotal == 0 {
            plans.append("На сегодня планов нет.")
        } else if open == 0 {
            plans.append("Все планы на сегодня выполнены.")
        } else {
            var line = "На сегодня осталось \(plansLeft(open))."
            if let next = input.nextPlanTitle, !next.isEmpty { line += " Ближайший: «\(short(next))»." }
            plans.append(line)
        }

        let workout: String
        if input.workoutActive {
            workout = "Идёт тренировка: таймер на вкладке «Тренировка»."
        } else if input.workoutDone {
            workout = "Тренировка сегодня уже есть."
        } else if input.workoutPlanned {
            workout = "Сегодня тренировка по программе, ещё не начата."
        } else {
            workout = "Сегодня ещё без тренировки."
        }

        let money = input.canSpend.map { "Сегодня можно потратить \($0)." }
        let notes = input.pinnedNote.map { "Заметка закреплена: «\(short($0))»." }

        var order: [MainTab] = [.today, .plans, .workout, .money, .notes]
        if let index = order.firstIndex(of: focus) { order.insert(order.remove(at: index), at: 0) }
        return order.filter { !hidden.contains($0) }.flatMap { tab -> [String] in
            switch tab {
            case .today: return []
            case .plans: return plans
            case .workout: return [workout]
            case .money: return money.map { [$0] } ?? []
            case .notes: return notes.map { [$0] } ?? []
            }
        }
    }

    /// The first tap line: a short summary of the section on screen.
    static func summary(_ input: MascotReminderInput, tab: MainTab) -> String? {
        let next = input.nextPlanTitle.map { "Дальше «\(short($0, limit: 24))»" + (input.nextPlanTime.map { " в \($0)" } ?? "") }
        switch tab {
        case .today:
            let parts = [next, input.canSpend.map { "можно потратить \($0)" }].compactMap { $0 }
            guard !parts.isEmpty else { return nil }
            let text = parts.joined(separator: ", ")
            return text.prefix(1).uppercased() + String(text.dropFirst()) + "."
        case .plans:
            return next.map { $0 + "." } ?? "Открытых планов на сегодня нет."
        case .money:
            guard let can = input.canSpend else { return nil }
            return "Сегодня можно \(can)" + (input.dayLimit.map { " из \($0)" } ?? "") + "."
        case .workout:
            if let set = input.nextSet { return "Следующий: \(set)." }
            return input.nextWorkout.map { "Следующая тренировка \($0)." }
        case .notes:
            return input.pinnedCount == 0 ? "Закреплённых заметок нет."
                : "Закреплено: \(ReviewFormat.plural(input.pinnedCount, "заметка", "заметки", "заметок"))."
        }
    }

    /// Reads the stores at the moment of the tap.
    @MainActor
    static func input(plans: PlanStore, finance: FinanceStore, workouts: WorkoutStore, notes: NotesStore) -> MascotReminderInput {
        var input = MascotReminderInput()
        let day = PlanDomain.today(timeZone: plans.timeZone)
        let planDay = plans.daySummary(for: day)
        input.plansTotal = planDay.total
        input.plansDone = planDay.done
        input.nextPlanTitle = planDay.open.first?.title
        if let id = planDay.open.first?.id, let time = plans.plans.first(where: { $0.id == id })?.time {
            input.nextPlanTime = String(time.prefix(5))
        }

        let zone = TimeZone(identifier: plans.timeZone) ?? .current
        let weekday = WorkoutProgram.weekday(of: Date(), timeZone: zone)
        input.workoutPlanned = WorkoutProgram.day(workouts.program, weekday: weekday).map { !$0.exercises.isEmpty } ?? false
        input.workoutDone = workouts.daySummary(for: day).completed
        input.workoutActive = workouts.activeSession.map { $0.phase != .complete } ?? false
        if input.workoutActive, let session = workouts.activeSession,
           let exercise = session.exercises.first(where: { $0.doneCount < $0.sets.count }) {
            input.nextSet = "\(short(exercise.name, limit: 22)), подход \(exercise.doneCount + 1)"
        }
        for offset in (input.workoutDone ? 1 : 0)..<8 {
            let date = Date().addingTimeInterval(Double(offset) * 86_400)
            guard let plan = WorkoutProgram.day(workouts.program, weekday: WorkoutProgram.weekday(of: date, timeZone: zone)),
                  !plan.exercises.isEmpty else { continue }
            let when = offset == 0 ? "сегодня" : offset == 1 ? "завтра" : "через \(offset) дн."
            input.nextWorkout = when + (plan.title.map { ": \(short($0, limit: 20))" } ?? "")
            break
        }

        if !finance.state.records.isEmpty, let can = finance.canSpendToday(on: FinanceText.today()) {
            input.canSpend = FinanceText.money(can.amount * 100)
            input.dayLimit = can.dayLimit.map { FinanceText.money($0 * 100) }
        }
        input.pinnedCount = notes.notes.filter { $0.pinned && !$0.deleted }.count
        input.pinnedNote = PinnedNotesSummary.make(notes: notes.notes)?.rows.first?.title
        return input
    }
}


/// The events the mascot answers with a short line (owner 20.11, K-2 and plan §1).
enum MascotEvent: CaseIterable {
    case planDone, setDone, workoutDone, limitKept
    case planAdded, expense, bigExpense, noteSaved, habitChecked, envelopeEnough, envelopeBought

    /// Said every time; the rest at most once per `MascotThrottle.gap`.
    var important: Bool { self == .planDone || self == .workoutDone || self == .limitKept }

    var lines: [String] {
        switch self {
        case .planDone: return ["Квест выполнен!", "Галочка стоит. Красота", "Минус один пункт. Сугой!",
                                "План пал. Следующий!", "Ачивка получена", "Вот это скорость, нян"]
        case .setDone: return ["Подход засчитан!", "Ещё один, сэмпай", "Железо трепещет",
                               "Сила +1", "Подход в копилку", "Мышцы это запомнят"]
        case .workoutDone: return ["Тренировка закрыта. GG", "Финал арки! Можно выдохнуть", "Режим героя выключен. Отдых",
                                   "Записано в историю. Мощь", "Босс тренировки повержен"]
        case .limitKept: return ["Вчера лимит устоял. Сугой!", "Вчера без перерасхода. GG", "Кошелёк цел: вчера в лимите",
                                 "Вчерашний лимит выдержан", "Вчера деньги под контролем"]
        case .planAdded: return ["Новый квест в списке", "Записал. Не забудем", "План принят, капитан",
                                 "Ещё одна миссия, хе", "Добавлено в сюжет"]
        case .expense: return ["Трата записана", "Деньги ушли. Учтено", "Чек в копилку истории",
                               "Записал, без осуждения", "Минус монетка. Ок"]
        case .bigExpense: return ["Ого! Крупная трата", "Это был чек босс-уровня", "Нани?! Вот это сумма",
                                  "Кошелёк ойкнул", "Серьёзная покупка, однако"]
        case .noteSaved: return ["Заметка сохранена", "Записано в свиток", "Мысль поймана",
                                 "Память +1", "Сохранил. Не потеряем"]
        case .habitChecked: return ["Привычка отмечена!", "Серия растёт, сугой", "Стабильность — сила",
                                    "Ещё день в копилку", "Так держать, сэмпай"]
        case .envelopeEnough: return ["Конверт: уже хватает!", "Накопил на цель. GG", "Цель закрыта деньгами",
                                      "Хватает! Вот это да", "Копилка справилась"]
        case .envelopeBought: return ["Куплено! Поздравляю", "Цель достигнута, ура", "Покупка из конверта. Мощь",
                                      "Мечта сбылась, нян", "Отмечено: куплено"]
        }
    }
}

/// Minor events are said at most once per two minutes; important ones always.
enum MascotThrottle {
    static let gap: TimeInterval = 120

    static func allows(_ event: MascotEvent, now: Date, lastMinor: Date?) -> Bool {
        guard !event.important, let lastMinor else { return true }
        return now.timeIntervalSince(lastMinor) >= gap
    }
}

/// Spots the events in store changes. Each returns nil when the change is not that event
/// (a reload, a sync, a restored session), so the mascot reacts only once and only to a real action.
enum MascotReactions {
    static func plan(old: PlanDaySummary, new: PlanDaySummary) -> MascotEvent? {
        new.total == old.total && new.done == old.done + 1 ? .planDone : nil
    }

    static func workout(old: WorkoutPhase?, new: WorkoutPhase?) -> MascotEvent? {
        guard new == .complete, let old, old != .complete else { return nil }
        return .workoutDone
    }

    /// Done sets of the running workout: exactly one more within the same session.
    static func sets(old: Int?, new: Int?) -> MascotEvent? {
        guard let old, let new, new == old + 1 else { return nil }
        return .setDone
    }

    /// A counter that went up by exactly one (a load or a sync usually moves it by more).
    static func step(old: Int, new: Int, _ event: MascotEvent) -> MascotEvent? {
        new == old + 1 ? event : nil
    }

    /// More than three times the average expense, or more than 20 000 ₸ without history.
    static func isBigExpense(_ amountMinor: Int64, history: [Int64]) -> Bool {
        guard !history.isEmpty else { return amountMinor > 2_000_000 }
        let average = history.reduce(0, +) / Int64(history.count)
        return amountMinor > average * 3
    }

    /// Exactly one new expense record.
    static func expense(old: [FinanceRecord], new: [FinanceRecord]) -> MascotEvent? {
        guard new.count == old.count + 1 else { return nil }
        let known = Set(old.map(\.id))
        guard let added = new.first(where: { !known.contains($0.id) }), added.kind == "expense" else { return nil }
        let history = old.filter { $0.kind == "expense" }.compactMap(\.amountMinor).filter { $0 > 0 }
        return isBigExpense(added.amountMinor ?? 0, history: history) ? .bigExpense : .expense
    }

    /// Envelope items: [covered («Хватает»), bought].
    static func envelopeCounts(_ records: [FinanceRecord]) -> [Int] {
        var enough = 0
        var bought = 0
        for record in records where record.items != nil {
            bought += (record.items ?? []).filter { $0.bought == true }.count
            enough += FinanceBudgeting.itemFills(record).filter(\.isEnough).count
        }
        return [enough, bought]
    }

    /// Yesterday's spending stayed within its day limit. nil without limits or after an overspend.
    static func limitKept(_ state: FinanceState, yesterday: String) -> MascotEvent? {
        guard let day = FinanceSummaries.canSpendToday(state, on: yesterday),
              let limit = day.dayLimit, limit > 0, day.spentToday <= limit else { return nil }
        return .limitKept
    }

    /// A line for the event, never the same as the last one; nil when the lines are switched off.
    static func line(for event: MascotEvent, after last: String?, enabled: Bool = SectionPrefs.mascotLines()) -> String? {
        guard enabled else { return nil }
        let pool = event.lines.filter { $0 != last }
        return pool.randomElement()
    }
}

/// What the mascot may say on its own, rarely (plan §1): a start soon, the day limit, a habit streak at risk.
struct MascotSelfTalkInput {
    var now = Date()
    var hour = 12
    /// The nearest plan start after `now`.
    var nextStart: (title: String, at: Date)? = nil
    /// Tenge; nil without day limits.
    var dayLimit: Int64? = nil
    var spentToday: Int64 = 0
    /// Titles of habits with a streak of 3+ that are due and not done today.
    var habitsAtRisk: [String] = []
}

enum MascotSelfTalk {
    static let gap: TimeInterval = 600

    static func line(_ input: MascotSelfTalkInput) -> String? {
        if let next = input.nextStart {
            let seconds = next.at.timeIntervalSince(input.now)
            if seconds > 0, seconds <= 15 * 60 {
                return "Через \(Int((seconds / 60).rounded(.up))) мин: \(MascotReminders.short(next.title, limit: 22))"
            }
        }
        if let limit = input.dayLimit, limit > 0, Double(limit - input.spentToday) < Double(limit) * 0.15 {
            return "Лимит на сегодня почти кончился"
        }
        if input.hour >= 20, let habit = input.habitsAtRisk.first {
            return "Серия «\(MascotReminders.short(habit, limit: 18))» под угрозой"
        }
        return nil
    }

    static func start(_ plan: PlanItem) -> Date? {
        guard let day = plan.date, let time = plan.time else { return nil }
        let f = FormatterCache.date("yyyy-MM-dd HH:mm", locale: "en_US_POSIX", timeZone: TimeZone(identifier: plan.timeZone) ?? .current)
        return f.date(from: "\(day) \(time.prefix(5))")
    }

    @MainActor
    static func input(plans: PlanStore, finance: FinanceStore, habits: HabitStore, now: Date = Date()) -> MascotSelfTalkInput {
        var input = MascotSelfTalkInput()
        input.now = now
        input.hour = Calendar.current.component(.hour, from: now)
        input.nextStart = plans.plans
            .filter { $0.completed != true }
            .compactMap { plan in start(plan).map { (title: plan.title, at: $0) } }
            .filter { $0.at > now }
            .min { $0.at < $1.at }
        if let can = finance.canSpendToday(on: FinanceText.today()) {
            input.dayLimit = can.dayLimit
            input.spentToday = can.spentToday
        }
        let day = PlanDomain.today(timeZone: plans.timeZone)
        input.habitsAtRisk = habits.dueHabits(on: day)
            .filter { !habits.isDone($0, on: day) && habits.streak(for: $0, today: day).count >= 3 }
            .map(\.title)
        return input
    }
}

/// Watches the stores for the events the mascot reacts to. Invisible; lives behind the tabs.
struct MascotEventWatcher: View {
    @ObservedObject var plans: PlanStore
    @ObservedObject var finance: FinanceStore
    @ObservedObject var workouts: WorkoutStore
    @ObservedObject var notes: NotesStore
    @ObservedObject var habits: HabitStore = .shared
    @State private var lastLine: String?
    @State private var lastMinor: Date?
    /// The day whose «yesterday kept the limit» line was already decided, so it is said once a day.
    @AppStorage("mascot.limitKeptDay") private var limitCheckedDay = ""

    var body: some View {
        let day = PlanDomain.today(timeZone: plans.timeZone)
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: plans.daySummary(for: day)) { old, new in
                say(MascotReactions.plan(old: old, new: new))
            }
            .onChange(of: plans.plans.count) { old, new in
                say(MascotReactions.step(old: old, new: new, .planAdded))
            }
            .onChange(of: workouts.activeSession?.phase) { old, new in
                say(MascotReactions.workout(old: old, new: new))
            }
            .onChange(of: workouts.activeSession?.exercises.reduce(0) { $0 + $1.doneCount }) { old, new in
                say(MascotReactions.sets(old: old, new: new))
            }
            .onChange(of: finance.state.records) { old, new in
                say(MascotReactions.expense(old: old, new: new))
                let before = MascotReactions.envelopeCounts(old)
                let after = MascotReactions.envelopeCounts(new)
                say(MascotReactions.step(old: before[1], new: after[1], .envelopeBought)
                    ?? MascotReactions.step(old: before[0], new: after[0], .envelopeEnough))
            }
            .onChange(of: notes.notes.map(\.updatedAt).max() ?? 0) { old, new in
                if old > 0, new > old { say(.noteSaved) }
            }
            .onChange(of: habits.daySummary(for: day).done) { old, new in
                say(MascotReactions.step(old: old, new: new, .habitChecked))
            }
            .task(id: "\(day)|\(finance.state.records.count)") {
                guard limitCheckedDay != day else { return }
                let yesterday = PlanDomain.addDays(dateStr: day, days: -1)
                // Without limits there is nothing to decide yet; the data may still be loading.
                guard FinanceSummaries.canSpendToday(finance.state, on: yesterday) != nil else { return }
                limitCheckedDay = day
                say(MascotReactions.limitKept(finance.state, yesterday: yesterday))
            }
    }

    private func say(_ event: MascotEvent?) {
        guard let event, MascotThrottle.allows(event, now: Date(), lastMinor: lastMinor),
              let line = MascotReactions.line(for: event, after: lastLine) else { return }
        if !event.important { lastMinor = Date() }
        lastLine = line
        MascotCenter.shared.react(line, event: event)
    }
}
