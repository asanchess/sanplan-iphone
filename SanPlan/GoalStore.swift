import Combine
import Foundation

/// Цель недели: выбранная цель действует до конца недели, которая начинается в `weekStart`.
public struct GoalWeekPick: Codable, Equatable, Sendable {
    public var goalId: String
    public var weekStart: String
    public init(goalId: String, weekStart: String) { self.goalId = goalId; self.weekStart = weekStart }
}

/// Запись коллекции `goals`: одна цель — `g-<id>`; список сфер и цель недели — `g-meta-state`.
public struct GoalPayload: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case goal, meta }
    public var kind: Kind
    public var goal: Goal?
    public var spheres: [GoalSphere]?
    public var weekGoal: GoalWeekPick?
}

public enum GoalCloud {
    public static let metaRecordID = "g-meta-state"
    public static func goalRecordID(_ id: String) -> String { "g-\(id)" }

    /// Правило сервера (8–64 знака A-Z a-z 0-9 _ -).
    public static func isValidID(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    public static func records(goals: [Goal], spheres: [GoalSphere], weekGoal: GoalWeekPick?) -> [(id: String, payload: GoalPayload)] {
        var out: [(id: String, payload: GoalPayload)] = []
        for goal in goals where isValidID(goalRecordID(goal.id)) {
            out.append((goalRecordID(goal.id), GoalPayload(kind: .goal, goal: goal)))
        }
        out.append((metaRecordID, GoalPayload(kind: .meta, spheres: spheres, weekGoal: weekGoal)))
        return out
    }

    public static func state(from items: [VaultItem<GoalPayload>]) -> (goals: [Goal], spheres: [GoalSphere], weekGoal: GoalWeekPick?) {
        var goals: [Goal] = []
        var spheres = GoalSphere.defaults
        var week: GoalWeekPick?
        for item in items {
            guard let p = item.data else { continue }
            switch p.kind {
            case .goal: if let g = p.goal { goals.append(g) }
            case .meta:
                if let s = p.spheres, !s.isEmpty { spheres = s }
                week = p.weekGoal
            }
        }
        goals.sort { ($0.createdDay, $0.id) < ($1.createdDay, $1.id) }
        return (goals, spheres, week)
    }
}

/// Цели и сферы. Те же правила, что у HabitStore: по владельцу, без данных при `.none`, после `attach` — коллекция `goals`.
@MainActor
public final class GoalStore: ObservableObject {
    @Published public private(set) var goals: [Goal] = []
    @Published public private(set) var spheres: [GoalSphere] = GoalSphere.defaults
    @Published public private(set) var weekPick: GoalWeekPick?
    /// Сводки соседей; подставляет корневая модель.
    public var context: GoalContext = .empty

    public static let shared = GoalStore()

    private let defaults: UserDefaults
    private let keyPrefix: String
    public private(set) var owner: FinanceStore.Owner

    private struct Snapshot: Codable {
        var goals: [Goal]
        var spheres: [GoalSphere]
        var weekPick: GoalWeekPick?
        var savedAtMs: Int64?
    }

    private var collection: VaultCollection<GoalPayload>?
    private var collectionObserver: AnyCancellable?
    public private(set) var usesCloud = false
    private var knownRecordIDs: Set<String> = []
    private var isLoading = false

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "arna.goals.v1", owner: FinanceStore.Owner = .none) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        self.owner = owner
        load()
    }

    private var key: String? {
        switch owner {
        case .none: return nil
        case .device: return keyPrefix
        case .account(let email): return "\(keyPrefix).\(FinanceStore.accountFolderName(email))"
        }
    }

    public func switchOwner(to next: FinanceStore.Owner) {
        guard next != owner else { return }
        owner = next
        collectionObserver = nil
        collection = nil
        usesCloud = false
        knownRecordIDs = []
        load()
    }

    // MARK: Цели

    public var activeGoals: [Goal] { goals.filter { !$0.archived } }

    public func add(_ goal: Goal) {
        guard owner != .none, !goal.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        goals.append(goal)
        save()
    }

    public func update(_ goal: Goal) {
        guard let i = goals.firstIndex(where: { $0.id == goal.id }) else { return }
        goals[i] = goal
        save()
    }

    public func archive(id: String, _ archived: Bool = true) {
        guard let i = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[i].archived = archived
        save()
    }

    public func delete(id: String) {
        goals.removeAll { $0.id == id }
        if weekPick?.goalId == id { weekPick = nil }
        save()
    }

    /// Отмечает этап цели «этапы».
    public func setMilestone(goalId: String, milestoneId: String, done: Bool) {
        guard let i = goals.firstIndex(where: { $0.id == goalId }), case .milestones(var items) = goals[i].kind,
              let j = items.firstIndex(where: { $0.id == milestoneId }) else { return }
        items[j].done = done
        goals[i].kind = .milestones(items)
        save()
    }

    public func progress(for goal: Goal, today: String) -> GoalProgress {
        GoalEngine.progress(goal, today: today, context: context)
    }

    // MARK: Цель недели

    /// Цель недели для `GoalStore.weekGoal` (DOMAINS.md §2): выбранная на этой неделе и ещё не архивная.
    public func weekGoal(today: String) -> (goal: Goal, progress: GoalProgress)? {
        guard let pick = weekPick, pick.weekStart == HabitCalendar.weekStart(today),
              let goal = goals.first(where: { $0.id == pick.goalId && !$0.archived }) else { return nil }
        return (goal, progress(for: goal, today: today))
    }

    public func setWeekGoal(_ id: String?, today: String) {
        if let id, goals.contains(where: { $0.id == id && !$0.archived }) {
            weekPick = GoalWeekPick(goalId: id, weekStart: HabitCalendar.weekStart(today))
        } else {
            weekPick = nil
        }
        save()
    }

    // MARK: Сферы

    public func setSpheres(_ next: [GoalSphere]) {
        let clean = next.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        spheres = clean.isEmpty ? GoalSphere.defaults : clean
        save()
    }

    public func sphereTitle(_ id: String?) -> String? { spheres.first { $0.id == id }?.title }

    // MARK: Хранение

    private func clearMemory() {
        goals = []
        spheres = GoalSphere.defaults
        weekPick = nil
    }

    private func save() {
        guard !isLoading else { return }
        if usesCloud { persistToCollection(); return }
        guard let key else { return }
        let snapshot = Snapshot(goals: goals, spheres: spheres, weekPick: weekPick, savedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key) }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        clearMemory()
        guard let s = localSnapshot() else { return }
        goals = s.goals
        spheres = s.spheres.isEmpty ? GoalSphere.defaults : s.spheres
        weekPick = s.weekPick
    }

    private func localSnapshot() -> Snapshot? {
        guard let key, let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    // MARK: Зашифрованная коллекция

    public func attach(collection: VaultCollection<GoalPayload>) {
        detach()
        self.collection = collection
        collectionObserver = collection.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.collectionChanged() }
        }
        Task { await self.moveToCollectionIfNeeded() }
    }

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

    private func applyCollection(_ collection: VaultCollection<GoalPayload>) {
        let rebuilt = GoalCloud.state(from: collection.items)
        knownRecordIDs = Set(collection.items.map(\.id))
        guard rebuilt.goals != goals || rebuilt.spheres != spheres || rebuilt.weekGoal != weekPick else { return }
        isLoading = true
        goals = rebuilt.goals
        spheres = rebuilt.spheres
        weekPick = rebuilt.weekGoal
        isLoading = false
    }

    /// Загрузка (повтор безопасен) → ожидание сервера → сверка → только потом удаление локального снимка.
    func moveToCollectionIfNeeded() async {
        guard let collection, collection.isAvailable, owner != .none, !usesCloud else { return }
        if let local = localSnapshot(), !local.goals.isEmpty || local.spheres != GoalSphere.defaults {
            let stamp = local.savedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000)
            let entries = GoalCloud.records(goals: local.goals, spheres: local.spheres, weekGoal: local.weekPick)
                .map { (id: $0.id, data: $0.payload, updatedAt: stamp) }
            _ = collection.importMany(entries)
            let synced = await collection.whenSynced()
            guard synced, self.collection === collection, collection.isAvailable else { return }
            let present = Set(GoalCloud.state(from: collection.items).goals.map(\.id))
            let migratable = Set(local.goals.map(\.id).filter { GoalCloud.isValidID(GoalCloud.goalRecordID($0)) })
            guard migratable.isSubset(of: present) else { return }
            if migratable.count == local.goals.count, let key { defaults.removeObject(forKey: key) }
        }
        usesCloud = true
        applyCollection(collection)
    }

    private func persistToCollection() {
        guard let collection, collection.isAvailable else { return }
        let desired = GoalCloud.records(goals: goals, spheres: spheres, weekGoal: weekPick)
        let desiredIDs = Set(desired.map(\.id))
        for entry in desired where collection.item(entry.id)?.data != entry.payload {
            _ = collection.put(entry.id, entry.payload)
        }
        for id in knownRecordIDs.subtracting(desiredIDs) { _ = collection.remove(id) }
        knownRecordIDs = desiredIDs
    }
}
