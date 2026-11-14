import XCTest
import CryptoKit
@testable import SanPlan

private struct Item: Codable, Equatable, Sendable {
    var title: String
}

@MainActor
private final class FakeCollection: VaultSyncable {
    let syncName: String
    var syncCursor: Int
    private(set) var nudges = 0
    init(_ name: String, cursor: Int = 0) { syncName = name; syncCursor = cursor }
    func syncNow() { nudges += 1 }
    func advanceCursor(to stamp: Int) { syncCursor = max(syncCursor, stamp) }
}

/// The live-sync contract (docs/ONE-APP-PLAN.md): counters, `?since=<highest seq>`, the 10 second fallback, plans.
@MainActor
final class VaultLiveSyncTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-live-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func driver(plansMoved: @escaping @MainActor () -> Void = {}) -> VaultLiveSync {
        VaultLiveSync(stamps: { [:] }, canPoll: { true }, onPlansMoved: plansMoved, now: { [unowned self] in self.clock })
    }

    private func collection(_ folder: String) -> VaultCollection<Item> {
        let c = VaultCollection<Item>(collection: "habits", policy: .newest, idPrefix: "h", baseDirectory: directory.appendingPathComponent(folder))
        c.syncDelay = .seconds(3600)
        return c
    }

    func testACounterAheadOfTheCursorSyncsThatCollectionOnly() {
        let live = driver()
        let notes = FakeCollection("notes", cursor: 5), goals = FakeCollection("goals", cursor: 3)
        live.register(notes)
        live.register(goals)
        live.evaluate(["notes": 6, "goals": 3])
        XCTAssertEqual(notes.nudges, 1)
        XCTAssertEqual(goals.nudges, 0)
    }

    func testCounterBehindOrEqualDoesNothing() {
        let live = driver()
        let notes = FakeCollection("notes", cursor: 9)
        live.register(notes)
        live.evaluate(["notes": 9])
        live.evaluate(["notes": 4])
        live.evaluate([:])
        XCTAssertEqual(notes.nudges, 0)
    }

    /// A put that lost its conflict raised the counter but wrote no record: after ~10 s stop asking for it.
    func testCounterStuckAheadForTenSecondsMovesTheCursorToTheStamp() {
        let live = driver()
        let notes = FakeCollection("notes", cursor: 5)
        live.register(notes)
        live.evaluate(["notes": 8])
        clock = clock.addingTimeInterval(6)
        live.evaluate(["notes": 8])
        XCTAssertEqual(notes.syncCursor, 5)
        XCTAssertEqual(notes.nudges, 2)
        clock = clock.addingTimeInterval(5)
        live.evaluate(["notes": 8])
        XCTAssertEqual(notes.syncCursor, 8)
        live.evaluate(["notes": 8])
        XCTAssertEqual(notes.nudges, 2, "Nothing more to fetch once the cursor caught up")
    }

    func testPlansRefetchOnlyWhenTheCounterMovesAfterTheFirstLook() {
        var moved = 0
        let live = driver(plansMoved: { moved += 1 })
        live.evaluate(["plans": 4])
        XCTAssertEqual(moved, 0, "The first answer is only the baseline")
        live.evaluate(["plans": 4])
        XCTAssertEqual(moved, 0)
        live.evaluate(["plans": 5])
        XCTAssertEqual(moved, 1)
        live.reset()
        live.evaluate(["plans": 9])
        XCTAssertEqual(moved, 1, "After sign-out the next account starts from a fresh baseline")
    }

    func testPollOnceReadsTheStampsAndSkipsWhenNotAllowed() async {
        var allowed = false
        var asked = 0
        let live = VaultLiveSync(stamps: { asked += 1; return ["notes": 2] }, canPoll: { allowed }, onPlansMoved: {})
        let notes = FakeCollection("notes")
        live.register(notes)
        await live.pollOnce()
        XCTAssertEqual(asked, 0)
        allowed = true
        await live.pollOnce()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(notes.nudges, 1)
    }

    /// Two devices on one account: B asks only for what came after the last `seq` it has seen.
    func testSinceFetchBringsOnlyNewRecords() async throws {
        let key = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let a = collection("a"), b = collection("b")
        a.attach(account: "acc1", key: key, transport: server)
        b.attach(account: "acc1", key: key, transport: server)
        let first = try XCTUnwrap(a.put("habit-0001", Item(title: "Вода")))
        await a.sync()
        await b.sync()
        XCTAssertEqual(b.item(first)?.data?.title, "Вода")
        XCTAssertEqual(b.syncCursor, 1)
        XCTAssertTrue(server.listedSince.contains { $0 == nil }, "The first load takes everything")

        let second = try XCTUnwrap(a.put("habit-0002", Item(title: "Зарядка")))
        await a.sync()
        let stamps = try await server.stamps()
        XCTAssertGreaterThan(stamps["habits"] ?? 0, b.syncCursor)
        await b.sync()
        XCTAssertTrue(server.listedSince.contains { $0 == 1 }, "Then only what came after seq 1")
        XCTAssertEqual(b.item(second)?.data?.title, "Зарядка")
        XCTAssertEqual(b.syncCursor, 2)
        XCTAssertEqual(b.items.count, 2)
    }

    /// The whole loop: a counter moves on the server, the driver nudges, the collection takes the change.
    func testDriverMakesAnotherDevicesEditArrive() async throws {
        let key = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let a = collection("a"), b = collection("b")
        a.attach(account: "acc1", key: key, transport: server)
        b.attach(account: "acc1", key: key, transport: server)
        await b.sync()
        let live = VaultLiveSync(stamps: { try await server.stamps() }, canPoll: { true }, onPlansMoved: {})
        live.register(b)
        let id = try XCTUnwrap(a.put("habit-0003", Item(title: "Чтение")))
        await a.sync()
        await live.pollOnce()
        for _ in 0..<50 where b.item(id) == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(b.item(id)?.data?.title, "Чтение")
    }

    func testCursorForgottenOnSignOutSoTheNextAccountLoadsEverything() async throws {
        let key = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let a = collection("a")
        a.attach(account: "acc1", key: key, transport: server)
        a.put("habit-0004", Item(title: "Сон"))
        await a.sync()
        XCTAssertGreaterThan(a.syncCursor, 0)
        a.detach()
        XCTAssertEqual(a.syncCursor, 0)
        XCTAssertFalse(a.hasSynced)
    }

    /// Records sealed under another key (the server's key replaced the cached one) are dropped and fetched again.
    func testKeySwitchRefetchesWhatTheOldKeyCouldNotOpen() async throws {
        let oldKey = SymmetricKey(size: .bits256), newKey = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let writer = collection("w")
        writer.attach(account: "acc1", key: newKey, transport: server)
        let id = try XCTUnwrap(writer.put("habit-0005", Item(title: "Прогулка")))
        await writer.sync()

        let phone = collection("p")
        phone.attach(account: "acc1", key: oldKey, transport: server)
        await phone.sync()
        XCTAssertNil(phone.item(id), "Not readable under the old key")
        phone.attach(account: "acc1", key: newKey, transport: server)
        await phone.sync()
        XCTAssertEqual(phone.item(id)?.data?.title, "Прогулка")
    }
}
