import Foundation

/// Состояние привычек. Пока хранится локально (UserDefaults); перенос в зашифрованную коллекцию `habits`
/// начнётся, когда координатор выдаст общий магазин коллекции.
@MainActor
public final class HabitStore: ObservableObject {
    @Published public private(set) var habits: [Habit] = []
    /// habitId → день → количество.
    @Published public private(set) var marks: [String: [String: Int]] = [:]
    @Published public var streakSettings: StreakSettings = .standard {
        didSet { save() }
    }
    /// Сводки соседей; их подставляет корневой экран / координатор.
    public var context: HabitContext = .empty

    /// Общий экземпляр: им пользуются экран «Планы» и корневая модель (сброс при выходе, сводки для «Сегодня»).
    public static let shared = HabitStore()

    private let defaults: UserDefaults
    private let keyPrefix: String
    public private(set) var owner: FinanceStore.Owner

    private struct Snapshot: Codable {
        var habits: [Habit]
        var marks: [String: [String: Int]]
        var streak: StreakSettings
    }

    /// Без владельца (`.none`) привычек нет: состояние пустое, ничего не читается и не пишется.
    public init(defaults: UserDefaults = .standard, keyPrefix: String = "arna.habits.v1", owner: FinanceStore.Owner = .none) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        self.owner = owner
        load()
    }

    /// Ключ хранения владельца; адрес почты на диск не пишется, только хеш.
    private var key: String? {
        switch owner {
        case .none: return nil
        case .device: return keyPrefix
        case .account(let email): return "\(keyPrefix).\(FinanceStore.accountFolderName(email))"
        }
    }

    /// Выход и вход: текущего владельца сохраняем, следующего загружаем. Тот же владелец — ничего не меняется.
    public func switchOwner(to next: FinanceStore.Owner) {
        guard next != owner else { return }
        owner = next
        load() // load() сначала очищает память под isLoading, поэтому пустой снимок не пишется
    }

    private func clearMemory() {
        habits = []
        marks = [:]
        streakSettings = .standard
    }

    // MARK: Привычки

    public var activeHabits: [Habit] { habits.filter { !$0.archived } }

    public func add(_ habit: Habit) {
        guard owner != .none, !habit.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        habits.append(habit)
        save()
    }

    public func update(_ habit: Habit) {
        guard let i = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        habits[i] = habit
        save()
    }

    public func archive(id: String, _ archived: Bool = true) {
        guard let i = habits.firstIndex(where: { $0.id == id }) else { return }
        habits[i].archived = archived
        save()
    }

    public func delete(id: String) {
        habits.removeAll { $0.id == id }
        marks[id] = nil
        save()
    }

    // MARK: Отметки

    public func amount(_ habit: Habit, on day: String) -> Int { marks[habit.id]?[day] ?? 0 }

    public func isDone(_ habit: Habit, on day: String) -> Bool {
        HabitEngine.isDone(habit, day: day, marks: marks[habit.id] ?? [:], context: context)
    }

    /// Выполнена ли привычка правилом, а не рукой (для подписи «авто» на экране).
    public func isAutoDone(_ habit: Habit, on day: String) -> Bool {
        guard let rule = habit.rule else { return false }
        return HabitEngine.ruleSatisfied(rule, day: day, context: context)
    }

    /// Одна отметка тапом: для привычки «раз» — переключатель, для количества — +1 до нормы, затем сброс.
    @discardableResult
    public func tap(_ habit: Habit, on day: String) -> Int {
        let current = amount(habit, on: day)
        let next: Int
        if habit.target.isCountable {
            next = current >= habit.target.amount ? 0 : current + 1
        } else {
            next = current >= 1 ? 0 : 1
        }
        setAmount(habit, on: day, amount: next)
        return next
    }

    /// Свайп «готово»: сразу выставляет норму.
    public func complete(_ habit: Habit, on day: String) {
        setAmount(habit, on: day, amount: habit.target.amount)
    }

    public func setAmount(_ habit: Habit, on day: String, amount: Int) {
        var perHabit = marks[habit.id] ?? [:]
        if amount <= 0 { perHabit[day] = nil } else { perHabit[day] = amount }
        marks[habit.id] = perHabit.isEmpty ? nil : perHabit
        save()
    }

    // MARK: Сводки

    public func daySummary(for day: String) -> HabitDaySummary {
        HabitEngine.daySummary(habits: habits, day: day, marks: marks, context: context)
    }

    /// Привычки, которые нужно отметить в этот день.
    public func dueHabits(on day: String) -> [Habit] {
        habits.filter { HabitEngine.isDue($0, day: day, marks: marks[$0.id] ?? [:], context: context) }
    }

    public func streak(for habit: Habit, today: String) -> HabitStreak {
        HabitEngine.streak(habit, today: today, marks: marks[habit.id] ?? [:], context: context)
    }

    /// Дни с ручной отметкой — вклад привычек в общую серию.
    public func activityDays(from: String, to: String) -> [String] {
        var days = Set<String>()
        for habit in habits {
            for (day, amount) in marks[habit.id] ?? [:] where amount > 0 && day >= from && day <= to { days.insert(day) }
        }
        return days.sorted()
    }

    /// Общая серия приложения по дням действия всех разделов (`*ActivityDays`).
    public func appStreak(today: String, activitySources: [[String]]) -> StreakState {
        StreakEngine.current(today: today, activeDays: StreakEngine.activeDays(activitySources), settings: streakSettings)
    }

    // MARK: Хранение

    private func save() {
        guard !isLoading, let key else { return }
        let snapshot = Snapshot(habits: habits, marks: marks, streak: streakSettings)
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key) }
    }

    private var isLoading = false

    private func load() {
        isLoading = true
        defer { isLoading = false }
        clearMemory()
        guard let key, let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        habits = s.habits
        marks = s.marks
        streakSettings = s.streak
    }
}
