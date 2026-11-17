import Combine
import Foundation

/// Состояние привычек. Без ключа данных хранится локально (UserDefaults); после `attach(collection:)` один раз
/// переезжает в зашифрованную коллекцию `habits` (HabitCloud), дальше источник — коллекция.
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
        /// Когда снимок записан (мс): с этим временем он идёт в коллекцию, чтобы более свежие правки сервера не затирались.
        var savedAtMs: Int64?
    }

    private var collection: VaultCollection<HabitPayload>?
    private var collectionObserver: AnyCancellable?
    /// true — источник данных коллекция, локальный снимок уже удалён.
    public private(set) var usesCloud = false
    private var knownRecordIDs: Set<String> = []

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
        collectionObserver = nil
        collection = nil
        usesCloud = false
        knownRecordIDs = []
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

    /// Общая серия приложения из источников всех разделов; ручные отметки привычек добавляются сами.
    public func appStreak(today: String, sources: [StreakEngine.ActivitySource]) -> StreakState {
        StreakEngine.current(today: today, sources: sources + [{ [self] from, to in self.activityDays(from: from, to: to) }],
                             settings: streakSettings)
    }

    /// Общая серия приложения по дням действия всех разделов (`*ActivityDays`).
    public func appStreak(today: String, activitySources: [[String]]) -> StreakState {
        StreakEngine.current(today: today, activeDays: StreakEngine.activeDays(activitySources), settings: streakSettings)
    }

    // MARK: Хранение

    private func save() {
        guard !isLoading else { return }
        if usesCloud { persistToCollection(); return }
        guard let key else { return }
        let snapshot = Snapshot(habits: habits, marks: marks, streak: streakSettings,
                                savedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
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

    // MARK: Зашифрованная коллекция

    private func localSnapshot() -> Snapshot? {
        guard let key, let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Вызывает координатор после `collection.attach`. Привычки с телефона переезжают в коллекцию один раз.
    public func attach(collection: VaultCollection<HabitPayload>) {
        detach()
        self.collection = collection
        collectionObserver = collection.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.collectionChanged() }
        }
        Task { await self.moveToCollectionIfNeeded() }
    }

    /// Выход или блокировка ключа: назад к локальному состоянию, расшифрованное в памяти не остаётся.
    public func detach() {
        collectionObserver = nil
        collection = nil
        knownRecordIDs = []
        if usesCloud {
            usesCloud = false
            load()
        }
    }

    private func collectionChanged() {
        guard usesCloud, let collection, collection.isAvailable else { return }
        applyCollection(collection)
    }

    private func applyCollection(_ collection: VaultCollection<HabitPayload>) {
        let rebuilt = HabitCloud.state(from: collection.items)
        knownRecordIDs = Set(collection.items.map(\.id))
        guard rebuilt.habits != habits || rebuilt.marks != marks || rebuilt.streak != streakSettings else { return }
        isLoading = true
        habits = rebuilt.habits
        marks = rebuilt.marks
        streakSettings = rebuilt.streak
        isLoading = false
    }

    /// Шаги переезда: загрузка (повтор безопасен: id выведены из локальных), ожидание сервера, сверка, и только потом
    /// удаление локального снимка.
    func moveToCollectionIfNeeded() async {
        guard let collection, collection.isAvailable, owner != .none, !usesCloud else { return }
        if let local = localSnapshot(), !(local.habits.isEmpty && local.marks.isEmpty) {
            let stamp = local.savedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000)
            let entries = HabitCloud.records(habits: local.habits, marks: local.marks, streak: local.streak)
                .map { (id: $0.id, data: $0.payload, updatedAt: stamp) }
            _ = collection.importMany(entries)
            let synced = await collection.whenSynced()
            guard synced, self.collection === collection, collection.isAvailable else { return }
            let rebuilt = HabitCloud.state(from: collection.items)
            let present = Set(rebuilt.habits.map(\.id))
            let migratable = Set(local.habits.map(\.id).filter { HabitCloud.isValidID(HabitCloud.habitRecordID($0)) })
            guard migratable.isSubset(of: present) else { return }
            // Привычки с id короче допустимого остаются на телефоне: локальный снимок тогда не удаляется.
            if migratable.count == local.habits.count, let key { defaults.removeObject(forKey: key) }
        }
        usesCloud = true
        applyCollection(collection)
    }

    private func persistToCollection() {
        guard let collection, collection.isAvailable else { return }
        let desired = HabitCloud.records(habits: habits, marks: marks, streak: streakSettings)
        let desiredIDs = Set(desired.map(\.id))
        for entry in desired where collection.item(entry.id)?.data != entry.payload {
            _ = collection.put(entry.id, entry.payload)
        }
        for id in knownRecordIDs.subtracting(desiredIDs) { _ = collection.remove(id) }
        knownRecordIDs = desiredIDs
    }
}

// MARK: - Отмена и «Недавно удалённые»

private struct HabitTrashEntry: Codable {
    var habit: Habit
    var marks: [String: Int]
    var deletedAt: Date
}

extension HabitStore: RecentlyDeletedSource {
    /// Отметка тапом с общей плашкой «Отменить»: случайное нажатие возвращается одним касанием.
    func tapUndoable(_ habit: Habit, on day: String) {
        let before = amount(habit, on: day)
        let after = tap(habit, on: day)
        let message: String
        if after == 0 {
            message = "Отметка снята: \(habit.title)"
        } else if habit.target.isCountable {
            message = "\(habit.title): \(after) из \(habit.target.amount)"
        } else {
            message = "Отмечено: \(habit.title)"
        }
        UndoCenter.shared.show(message) { [weak self] in
            guard let self, let current = self.habits.first(where: { $0.id == habit.id }) else { return }
            self.setAmount(current, on: day, amount: before)
        }
    }

    private var trashKey: String? { key.map { "\($0).trash" } }

    private var trash: [HabitTrashEntry] {
        get {
            guard let trashKey, let data = defaults.data(forKey: trashKey) else { return [] }
            return (try? JSONDecoder().decode([HabitTrashEntry].self, from: data)) ?? []
        }
        set {
            guard let trashKey else { return }
            let limit = Date().addingTimeInterval(-Double(RecentlyDeleted.keepDays) * 86_400)
            let kept = newValue.filter { $0.deletedAt >= limit }
            if kept.isEmpty { defaults.removeObject(forKey: trashKey) } else { defaults.set(try? JSONEncoder().encode(kept), forKey: trashKey) }
        }
    }

    /// Удаление, которое можно вернуть: 5 секунд «Отменить», потом 30 дней в «Недавно удалённых» (только на этом телефоне).
    func deleteKeepingTrash(id: String) {
        guard let habit = habits.first(where: { $0.id == id }) else { return }
        trash = [HabitTrashEntry(habit: habit, marks: marks[id] ?? [:], deletedAt: Date())] + trash.filter { $0.habit.id != id }
        delete(id: id)
        RecentlyDeleted.shared.register(self)
        UndoCenter.shared.show("Привычка удалена: \(habit.title)") { [weak self] in
            self?.restoreDeleted(id: "habit:" + id)
        }
    }

    var deletedItems: [DeletedItem] {
        trash.map { DeletedItem(id: "habit:" + $0.habit.id, title: "Привычка «\($0.habit.title)»", section: .plans, deletedAt: $0.deletedAt) }
    }

    func restoreDeleted(id: String) {
        let raw = id.hasPrefix("habit:") ? String(id.dropFirst(6)) : id
        guard let entry = trash.first(where: { $0.habit.id == raw }) else { return }
        trash = trash.filter { $0.habit.id != raw }
        guard !habits.contains(where: { $0.id == raw }) else { return }
        habits.append(entry.habit)
        if !entry.marks.isEmpty { marks[raw] = entry.marks }
        save()
    }

    func purgeDeleted(id: String) {
        let raw = id.hasPrefix("habit:") ? String(id.dropFirst(6)) : id
        trash = trash.filter { $0.habit.id != raw }
    }
}
