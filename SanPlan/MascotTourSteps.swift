import Foundation

/// What the mascot shows in each section. `target` is the id passed to `.tourTarget(_:)` on that screen;
/// `header.*` targets sit in the shared `ScreenHeader`, `shell.capture` is the round «+» of RootView.
/// A step whose target is not on screen (no habits yet, no money records, no program) is passed over,
/// except in the short tour, which keeps its one step per section and only talks.
public enum TourPlan {
    public static let all: [TourStep] = today + plans + notes + money + workout + general

    // Section by section: the first step names the section, then two or three steps on what is used every day.
    // One idea per step, one short sentence where possible.

    static let today: [TourStep] = [
        TourStep("today.intro", .today, target: "header.title",
                 "«Сегодня» — ваш день из всех разделов на одном экране."),
        TourStep("today.hero", .today, target: "today.hero", key: true,
                 "Главное сейчас. Нажмите — откроется нужное место."),
        TourStep("today.rings", .today, target: "today.rings",
                 "Круги дня. Нажмите круг — откроется раздел."),
        TourStep("today.review", .today, target: "today.review",
                 "Вечером — «Итоги дня»: что сделано и что перенести.")
    ]

    static let plans: [TourStep] = [
        TourStep("plans.intro", .plans, target: "header.title",
                 "«Планы» — дела, привычки и цели."),
        TourStep("plans.days", .plans, target: "plans.days",
                 "Нажмите день — покажу его планы."),
        TourStep("plans.composer", .plans, target: "plans.composer", key: true,
                 "Пишите словами: «завтра в 9 стоматолог». Дату и время разберу сам."),
        TourStep("plans.alarms", .plans, target: "plans.alarms",
                 "Все будильники — здесь.")
    ]

    static let notes: [TourStep] = [
        TourStep("notes.intro", .notes, target: "header.title",
                 "«Заметки» зашифрованы — читаете их только вы."),
        TourStep("notes.grid", .notes, target: "notes.grid",
                 "Нажмите заметку — откроется. Долгое нажатие — закрепить или удалить."),
        TourStep("notes.capture", .notes, target: "notes.capture", key: true,
                 "«+» — новая заметка текстом или голосом.")
    ]

    static let money: [TourStep] = [
        TourStep("money.intro", .money, target: "header.title",
                 "«Деньги» — траты, доходы и бюджет месяца."),
        TourStep("money.canSpend", .money, target: "money.canSpend",
                 "Столько можно потратить сегодня, чтобы уложиться в месяц."),
        TourStep("money.composer", .money, target: "money.composer", key: true,
                 "Пишите «кофе 1200» — категорию подберу сам."),
        TourStep("money.statements", .money, target: "money.statements",
                 "Выписка банка в PDF — операции добавятся сами.")
    ]

    static let workout: [TourStep] = [
        TourStep("workout.intro", .workout, target: "header.title",
                 "«Тренировка» — программа по дням и история."),
        TourStep("workout.hero", .workout, target: "workout.hero", key: true,
                 "«Начать тренировку» — поведу по подходам и посчитаю отдых."),
        TourStep("workout.plan", .workout, target: "workout.plan",
                 "«Изменить» — упражнения, подходы и вес.")
    ]

    static let general: [TourStep] = [
        TourStep("general.capture", .general, target: "shell.capture", key: true,
                 "«+» — быстрая запись из любого раздела."),
        TourStep("general.help", .general, target: "header.help",
                 "«?» — тур по разделу, где вы сейчас."),
        TourStep("general.profile", .general, target: "header.profile",
                 "Профиль: разделы, звуки, маскот и этот тур заново.")
    ]

    public static func steps(for section: TourSection) -> [TourStep] {
        all.filter { $0.section == section }
    }

    public static func steps(_ kind: TourKind) -> [TourStep] {
        switch kind {
        case .full:
            return all
        case .short:
            return TourSection.allCases.compactMap { section in steps(for: section).first(where: \.isKey) }
        case .section(let section):
            return steps(for: section)
        }
    }
}
