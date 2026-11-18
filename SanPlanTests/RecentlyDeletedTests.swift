import XCTest
import CryptoKit
@testable import SanPlan

/// A store that keeps deleted things in memory, to check the registry's routing.
@MainActor
private final class FakeDeletedSource: RecentlyDeletedSource {
    var kept: [DeletedItem]
    private(set) var purged: [String] = []

    init(_ items: [DeletedItem]) { kept = items }

    var deletedItems: [DeletedItem] { kept }
    func restoreDeleted(id: String) { kept.removeAll { $0.id == id } }
    func purgeDeleted(id: String) {
        purged.append(id)
        kept.removeAll { $0.id == id }
    }
}

@MainActor
final class RecentlyDeletedTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    private func item(_ id: String, section: MainTab = .plans, daysAgo: Double = 1) -> DeletedItem {
        DeletedItem(id: id, title: id, section: section, deletedAt: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        dirs.append(dir)
        return dir
    }

    func testPurgeGoesOnlyToTheOwningStore() {
        let registry = RecentlyDeleted()
        let a = FakeDeletedSource([item("a:1"), item("a:2")])
        let b = FakeDeletedSource([item("b:1")])
        registry.register(a)
        registry.register(b)
        XCTAssertEqual(registry.items.count, 3)

        registry.purge(item("a:2"))
        XCTAssertEqual(a.purged, ["a:2"])
        XCTAssertTrue(b.purged.isEmpty)
        XCTAssertEqual(Set(registry.items.map(\.id)), ["a:1", "b:1"])
    }

    func testPurgeAllEmptiesEveryStoreIncludingExpiredLeftovers() {
        let registry = RecentlyDeleted()
        let a = FakeDeletedSource([item("a:1"), item("a:old", daysAgo: 40)])
        let b = FakeDeletedSource([item("b:1", section: .notes)])
        registry.register(a)
        registry.register(b)
        XCTAssertEqual(registry.items.count, 2, "Older than 30 days is not listed")

        registry.purgeAll()
        XCTAssertTrue(registry.items.isEmpty)
        XCTAssertTrue(a.kept.isEmpty)
        XCTAssertTrue(b.kept.isEmpty)
        XCTAssertEqual(Set(a.purged), ["a:1", "a:old"])
    }

    func testGoalAndHabitPurgeCannotBeRestored() throws {
        let goals = GoalStore(defaults: UserDefaults(suiteName: "purge-goals-\(UUID().uuidString)")!)
        goals.switchOwner(to: .device)
        goals.add(Goal(id: "goal-0001", title: "Цель", sphereId: "health", createdDay: "2026-11-01",
                       kind: .milestones([GoalMilestone(id: "m1", title: "Один")])))
        goals.add(Goal(id: "goal-0002", title: "Вторая", sphereId: "health", createdDay: "2026-11-01",
                       kind: .milestones([GoalMilestone(id: "m1", title: "Один")])))
        let habits = HabitStore(defaults: UserDefaults(suiteName: "purge-habits-\(UUID().uuidString)")!)
        habits.switchOwner(to: .device)
        habits.add(Habit(id: "habit-0001", title: "Вода", createdDay: "2026-11-01"))

        goals.deleteKeepingTrash(id: "goal-0001")
        goals.deleteKeepingTrash(id: "goal-0002")
        habits.deleteKeepingTrash(id: "habit-0001")
        let registry = RecentlyDeleted()
        registry.register(goals)
        registry.register(habits)
        XCTAssertEqual(registry.items.count, 3)

        let goalItem = try XCTUnwrap(registry.items.first { $0.id == "goal:goal-0001" })
        registry.purge(goalItem)
        XCTAssertEqual(goals.deletedItems.map(\.id), ["goal:goal-0002"])
        goals.restoreDeleted(id: "goal:goal-0001")
        XCTAssertFalse(goals.goals.contains { $0.id == "goal-0001" }, "A purged goal does not come back")

        registry.purgeAll()
        XCTAssertTrue(registry.items.isEmpty)
        habits.restoreDeleted(id: "habit:habit-0001")
        XCTAssertTrue(habits.habits.isEmpty, "A purged habit does not come back")
    }

    func testPurgedNoteLeavesAnEmptyTombstoneThatSyncs() async throws {
        let key = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let phone = NotesStore(baseDirectory: tempDir(), now: { 1_000 })
        let pc = NotesStore(baseDirectory: tempDir(), now: { 1_000 })
        phone.syncDelay = .seconds(3600)
        pc.syncDelay = .seconds(3600)
        phone.attach(account: "a@example.com", key: key, transport: server)
        let id = try XCTUnwrap(phone.create(text: "Секрет"))
        await phone.sync()
        pc.attach(account: "a@example.com", key: key, transport: server)
        await pc.sync()

        phone.delete(id)
        XCTAssertEqual(phone.deletedItems.map(\.id), ["note:" + id])
        phone.purgeDeleted(id: "note:" + id)
        XCTAssertTrue(phone.deletedItems.isEmpty)
        XCTAssertEqual(phone.all[id]?.deleted, true)
        XCTAssertEqual(phone.all[id]?.text, "")
        phone.restoreDeleted(id: "note:" + id)
        XCTAssertTrue(phone.notes.isEmpty, "A purged note does not come back")

        await phone.sync()
        await pc.sync()
        XCTAssertTrue(pc.notes.isEmpty)
        XCTAssertTrue(pc.deletedItems.isEmpty, "The other device drops the text too")
        XCTAssertEqual(pc.all[id]?.text, "")
    }
}

@MainActor
final class ProfileNicknameTests: XCTestCase {
    func testNormalizedTrimsAndCuts() {
        XCTAssertEqual(ProfileNickname.normalized("  Саня  "), "Саня")
        XCTAssertEqual(ProfileNickname.normalized("   "), "")
        XCTAssertEqual(ProfileNickname.normalized(String(repeating: "я", count: 30)).count, ProfileNickname.maxLength)
    }

    func testEmptyNicknameFallsBackToEmail() {
        XCTAssertEqual(ProfileNickname.display(nickname: "", email: "alex.m@example.com"), "Alex.m")
        XCTAssertEqual(ProfileNickname.display(nickname: " Саня ", email: "alex@example.com"), "Саня")
        XCTAssertEqual(ProfileNickname.fallback(email: "Неизвестно"), "Неизвестно")
    }

    func testNicknameIsKeptInTheAccountSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = VaultCollection<SettingsPayload>(collection: "settings", policy: .newest, idPrefix: "s", baseDirectory: dir)
        let store = ProfileNameStore()
        XCTAssertFalse(store.setNickname("Саня"), "Nothing is saved while the account's settings are closed")

        settings.attach(account: "a@example.com", key: SymmetricKey(size: .bits256), transport: nil)
        store.attach(collection: settings)
        XCTAssertTrue(store.canEdit)
        XCTAssertTrue(store.setNickname("  Саня  "))
        XCTAssertEqual(store.nickname, "Саня")
        let record = try XCTUnwrap(settings.item(ProfileNameStore.recordID)?.data)
        XCTAssertEqual(record.kind, "profile")
        XCTAssertEqual(record.nickname, "Саня")

        let other = ProfileNameStore()
        other.attach(collection: settings)
        XCTAssertEqual(other.nickname, "Саня")

        XCTAssertTrue(store.setNickname("   "))
        XCTAssertEqual(store.nickname, "")
        XCTAssertNil(settings.item(ProfileNameStore.recordID)?.data?.nickname)

        store.detach()
        XCTAssertEqual(store.nickname, "")
        XCTAssertFalse(store.canEdit)
    }
}
