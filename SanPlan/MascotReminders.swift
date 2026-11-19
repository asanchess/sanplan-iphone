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

/// One short line after something the person just did. Each returns nil when the change is not that event
/// (a reload, a sync, a new day), so the mascot reacts only once and only to a real action.
enum MascotReactions {
    static func plan(old: PlanDaySummary, new: PlanDaySummary) -> String? {
        guard new.total == old.total, new.done == old.done + 1 else { return nil }
        let left = new.total - new.done
        let tail = left == 0 ? "На сегодня всё." : "Осталось \(MascotReminders.plansLeft(left))."
        if let closed = old.open.first(where: { item in !new.open.contains { $0.id == item.id } }) {
            return "Готово: «\(MascotReminders.short(closed.title))». \(tail)"
        }
        return "План выполнен. \(tail)"
    }

    static func workout(old: WorkoutPhase?, new: WorkoutPhase?) -> String? {
        guard new == .complete, let old, old != .complete else { return nil }
        return "Тренировка завершена и записана в историю."
    }

    static func expense(old: [FinanceRecord], new: [FinanceRecord]) -> String? {
        guard new.count == old.count + 1 else { return nil }
        let known = Set(old.map(\.id))
        guard let added = new.first(where: { !known.contains($0.id) }),
              added.kind == "expense", added.importId == nil else { return nil }
        let amount = added.amountMinor.map { ", \(FinanceText.money($0))" } ?? ""
        return "Трата записана: «\(MascotReminders.short(added.title))»\(amount)."
    }
}

/// Watches the stores for the three events the mascot reacts to. Invisible; lives behind the tabs.
struct MascotEventWatcher: View {
    @ObservedObject var plans: PlanStore
    @ObservedObject var finance: FinanceStore
    @ObservedObject var workouts: WorkoutStore

    var body: some View {
        let day = PlanDomain.today(timeZone: plans.timeZone)
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: plans.daySummary(for: day)) { old, new in
                if let line = MascotReactions.plan(old: old, new: new) { MascotCenter.shared.react(line, cheerful: true) }
            }
            .onChange(of: workouts.activeSession?.phase) { old, new in
                if let line = MascotReactions.workout(old: old, new: new) { MascotCenter.shared.react(line, cheerful: true) }
            }
            .onChange(of: finance.state.records) { old, new in
                if let line = MascotReactions.expense(old: old, new: new) { MascotCenter.shared.react(line, cheerful: false) }
            }
    }
}
