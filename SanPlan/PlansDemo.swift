import Foundation

/// Made-up content for the cloud screenshots of «Планы» (`--screenshot-demo-data`).
/// Lives only in memory: plans are put into `PlanStore.plans` directly (no disk, no server, no system alarms),
/// habits and goals are display models that never reach their stores. Nothing here is anyone's real data.
@MainActor
enum PlansDemo {
    static func plans(today: String, timeZone: String) -> [PlanItem] {
        let tomorrow = PlanDomain.addDays(dateStr: today, days: 1)
        let inTwo = PlanDomain.addDays(dateStr: today, days: 2)
        let inThree = PlanDomain.addDays(dateStr: today, days: 3)
        let saved = "2026-01-01T00:00:00.000Z"
        func plan(_ id: String, _ kind: String, _ title: String, _ date: String, _ time: String?,
                  minutes: Int? = 60, done: Bool? = nil, note: String? = nil) -> PlanItem {
            PlanItem(id: "demo-\(id)", kind: kind, title: title, date: date, time: time, durationMinutes: minutes,
                     reminderMinutes: nil, reminderOffsets: [], timeZone: timeZone, completed: done,
                     savedAt: saved, description: note)
        }
        func alarm(_ id: String, _ title: String, _ date: String, _ time: String) -> PlanItem {
            let schedule = NativeSchedule(date: date, time: time, timeZone: timeZone, reminderOffsets: [0])
            return PlanItem(id: "demo-\(id)", kind: "event", title: title, date: date, time: time, durationMinutes: nil,
                            reminderMinutes: 0, reminderOffsets: [0], timeZone: timeZone, alarmSchedule: schedule,
                            alarmOnly: true, savedAt: saved)
        }
        return [
            plan("run", "task", "Пробежка 5 км", today, "07:30", minutes: nil, done: true),
            plan("standup", "event", "Созвон по проекту", today, "10:00", minutes: 30, note: "Ссылка в календаре"),
            plan("report", "task", "Отправить отчёт", today, "12:00", minutes: nil, done: true),
            plan("parcel", "task", "Забрать посылку", today, "17:30", minutes: nil),
            plan("groceries", "task", "Купить продукты на неделю", today, "19:00", minutes: nil),
            plan("dentist", "event", "Стоматолог", tomorrow, "09:00", minutes: 60),
            plan("gym", "event", "Тренировка в зале", inTwo, "18:30", minutes: 90),
            plan("internet", "task", "Оплатить интернет", inThree, "11:00", minutes: nil),
            alarm("wake", "Подъём", tomorrow, "07:00"),
            alarm("vitamins", "Витамины", tomorrow, "21:00"),
        ]
    }

    static let habits: [PlansHabitTileModel] = [
        PlansHabitTileModel(id: "demo-water", title: "Вода", count: 5, goal: 8, note: "Ещё 3 стакана", streak: HabitStreak(count: 9, unit: .days), isAuto: false),
        PlansHabitTileModel(id: "demo-read", title: "Чтение", count: 20, goal: 20, note: "страниц", streak: HabitStreak(count: 14, unit: .days), isAuto: false),
        PlansHabitTileModel(id: "demo-steps", title: "Без сладкого", count: 0, goal: 1, note: "Не отмечено", streak: HabitStreak(count: 3, unit: .days), isAuto: false),
    ]

    static let goals: [PlansGoalCardModel] = [
        PlansGoalCardModel(id: "demo-trip", sphere: "Деньги", title: "Накопить на отпуск", figure: "182 400 ₸",
                           fraction: 0.61, note: "из 300 000 ₸ · до 1 июня", isOverdue: false, isWeekGoal: true),
        PlansGoalCardModel(id: "demo-runs", sphere: "Здоровье", title: "30 тренировок до лета", figure: "12 из 30",
                           fraction: 0.4, note: "до 1 июня", isOverdue: false, isWeekGoal: false),
    ]
}
