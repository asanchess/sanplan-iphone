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

    /// Reads the stores at the moment of the tap.
    @MainActor
    static func input(plans: PlanStore, finance: FinanceStore, workouts: WorkoutStore, notes: NotesStore) -> MascotReminderInput {
        var input = MascotReminderInput()
        let day = PlanDomain.today(timeZone: plans.timeZone)
        let planDay = plans.daySummary(for: day)
        input.plansTotal = planDay.total
        input.plansDone = planDay.done
        input.nextPlanTitle = planDay.open.first?.title

        let zone = TimeZone(identifier: plans.timeZone) ?? .current
        let weekday = WorkoutProgram.weekday(of: Date(), timeZone: zone)
        input.workoutPlanned = WorkoutProgram.day(workouts.program, weekday: weekday).map { !$0.exercises.isEmpty } ?? false
        input.workoutDone = workouts.daySummary(for: day).completed
        input.workoutActive = workouts.activeSession.map { $0.phase != .complete } ?? false

        if !finance.state.records.isEmpty, let can = finance.canSpendToday(on: FinanceText.today()) {
            input.canSpend = FinanceText.money(can.amount * 100)
        }
        input.pinnedNote = PinnedNotesSummary.make(notes: notes.notes)?.rows.first?.title
        return input
    }
}

/// The events the mascot answers with a short line (owner 20.11, K-2). Nothing else makes it talk on its own.
enum MascotEvent: CaseIterable {
    case planDone, setDone, workoutDone, limitKept

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
        }
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

/// Watches the stores for the events the mascot reacts to. Invisible; lives behind the tabs.
struct MascotEventWatcher: View {
    @ObservedObject var plans: PlanStore
    @ObservedObject var finance: FinanceStore
    @ObservedObject var workouts: WorkoutStore
    @State private var lastLine: String?
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
            .onChange(of: workouts.activeSession?.phase) { old, new in
                say(MascotReactions.workout(old: old, new: new))
            }
            .onChange(of: workouts.activeSession?.exercises.reduce(0) { $0 + $1.doneCount }) { old, new in
                say(MascotReactions.sets(old: old, new: new))
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
        guard let event, let line = MascotReactions.line(for: event, after: lastLine) else { return }
        lastLine = line
        MascotCenter.shared.react(line, cheerful: true)
    }
}
