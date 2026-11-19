import Foundation

/// What the mascot shows in each section. `target` is the id passed to `.tourTarget(_:)` on that screen;
/// `header.*` targets sit in the shared `ScreenHeader`, `shell.capture` is the round «+» of RootView.
/// A step whose target is not on screen (no habits yet, no money records, no program) is passed over,
/// except in the short tour, which keeps its one step per section and only talks.
public enum TourPlan {
    public static let all: [TourStep] = today + plans + notes + money + workout + general

    static let today: [TourStep] = [
        TourStep("today.intro", .today, target: "header.title",
                 "«Сегодня» собирает день из всех разделов: планы, привычки, деньги и тренировку."),
        TourStep("today.hero", .today, target: "today.hero", key: true,
                 "Главное на сейчас: ближайший план или тренировка дня. Нажмите — откроется нужное место."),
        TourStep("today.rings", .today, target: "today.rings",
                 "Три круга: планы, привычки и сколько можно потратить. Нажмите круг — откроется раздел."),
        TourStep("today.next", .today, target: "today.next",
                 "Дальше сегодня — планы по времени. «Все планы» открывает весь список."),
        TourStep("today.habits", .today, target: "today.habits",
                 "Привычки на сегодня. Нажмите строку — привычка отмечена, «Отменить» внизу вернёт как было."),
        TourStep("today.progress", .today, target: "today.progress",
                 "Неделя коротко. Нажмите — откроется весь прогресс."),
        TourStep("today.review", .today, target: "today.review",
                 "Вечером откройте «Итоги дня»: что сделано и что перенести на завтра.")
    ]

    static let plans: [TourStep] = [
        TourStep("plans.intro", .plans, target: "header.title",
                 "«Планы» — дела, привычки и цели в одном разделе."),
        TourStep("plans.sections", .plans, target: "plans.sections",
                 "Здесь переключаются планы, привычки и цели."),
        TourStep("plans.modes", .plans, target: "plans.modes",
                 "Планы можно смотреть на сегодня, на неделю, все ближайшие или уже готовые."),
        TourStep("plans.days", .plans, target: "plans.days",
                 "Дни недели. Нажмите число — покажу планы этого дня."),
        TourStep("plans.composer", .plans, target: "plans.composer", key: true,
                 "Пишите словами: «завтра в 9 стоматолог». Дату и время разберу сам, сохраните после проверки."),
        TourStep("plans.alarms", .plans, target: "plans.alarms",
                 "Все будильники — за этой кнопкой.")
    ]

    static let notes: [TourStep] = [
        TourStep("notes.intro", .notes, target: "header.title",
                 "Заметки хранятся зашифрованными ключом вашего аккаунта."),
        TourStep("notes.search", .notes, target: "notes.search",
                 "Поиск идёт по всем заметкам сразу."),
        TourStep("notes.pinned", .notes, target: "notes.pinned",
                 "Закреплённая заметка всегда сверху и видна на «Сегодня»."),
        TourStep("notes.grid", .notes, target: "notes.grid",
                 "Нажмите заметку, чтобы открыть. Долгое нажатие — закрепить, поделиться или удалить."),
        TourStep("notes.capture", .notes, target: "notes.capture", key: true,
                 "«+» — новая запись текстом или голосом. Из неё можно сделать план или трату.")
    ]

    static let money: [TourStep] = [
        TourStep("money.intro", .money, target: "header.title",
                 "«Деньги» — траты, доходы и бюджет месяца."),
        TourStep("money.canSpend", .money, target: "money.canSpend",
                 "Столько можно потратить сегодня, чтобы уложиться в месяц."),
        TourStep("money.sections", .money, target: "money.sections",
                 "Обзор, план бюджета и все операции — переключатель здесь."),
        TourStep("money.composer", .money, target: "money.composer", key: true,
                 "Пишите как удобно: «кофе 1200». Категорию подберу сам, можно голосом."),
        TourStep("money.statements", .money, target: "money.statements",
                 "Выписку банка в PDF можно загрузить — операции добавятся сами.")
    ]

    static let workout: [TourStep] = [
        TourStep("workout.intro", .workout, target: "header.title",
                 "«Тренировка» — программа по дням, подходы с отдыхом и история."),
        TourStep("workout.sections", .workout, target: "workout.sections",
                 "Здесь переключаются тренировка и история."),
        TourStep("workout.rhythm", .workout, target: "workout.rhythm",
                 "Ритм недели: дни с тренировкой отмечены."),
        TourStep("workout.hero", .workout, target: "workout.hero", key: true,
                 "Тренировка дня. «Начать тренировку» ведёт по подходам и считает отдых."),
        TourStep("workout.plan", .workout, target: "workout.plan",
                 "План дня. «Изменить» — упражнения, подходы и вес.")
    ]

    static let general: [TourStep] = [
        TourStep("general.capture", .general, target: "shell.capture", key: true,
                 "«+» — быстрая запись: заметка, план или трата, текстом или голосом."),
        TourStep("general.progress", .general, target: "header.progress",
                 "Прогресс за неделю и месяц — по этой кнопке."),
        TourStep("general.profile", .general, target: "header.profile",
                 "Профиль: настройки разделов, звуки, вид маскота и «Краткий тур»."),
        TourStep("general.help", .general, target: "header.help",
                 "«?» в шапке раздела покажет, как им пользоваться."),
        TourStep("general.mascot", .general, target: nil,
                 "Нажмите на меня — напомню, что осталось на сегодня. Спрятать меня можно в профиле.")
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
