import XCTest
import CryptoKit
@testable import SanPlan

private struct Lift: Codable, Equatable, Sendable {
    var title: String
    var weight: Int
    var reps: Int
}

@MainActor
final class VaultCollectionTests: XCTestCase {
    private var directory: URL!
    private var clock: Int64 = 1_000_000

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-collection-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(_ policy: VaultConflictPolicy = .newest, folder: String = "a") -> VaultCollection<Lift> {
        let s = VaultCollection<Lift>(collection: "training", policy: policy, idPrefix: "t",
                                      baseDirectory: directory.appendingPathComponent(folder), now: { [unowned self] in self.clock })
        s.syncDelay = .seconds(3600)
        return s
    }

    /// Records sealed by the web (src/vault-collection.mjs format) open on the phone, tombstones included.
    func testOpensRecordsTheWebSealed() async throws {
        let key = SymmetricKey(data: Data(base64Encoded: "kT+mbrsKvcl4oneEDmvMt1WMrBzwHm69tfRUWhi/Zfk=")!)
        let server = MemoryVaultTransport()
        server.records["fixture-training-01"] = VaultRemoteRecord(id: "fixture-training-01", revision: 1,
            c: "LrlbBOIdM+Qpvr1z5eyXdSuFI0W7ZKK/8xsaUtXa1Ug6vZNJ42mbqRGh/c1AOm5RAvz8UZiYcT6lHPnusxHoeDSIXEf7xKXDqUGgMj56jyTp6orO3jdOSA2OWLpzg4sa70NM6pV8Yf1yTEIuPOmN6Zh5hp1W")
        server.records["fixture-training-02"] = VaultRemoteRecord(id: "fixture-training-02", revision: 1,
            c: "GA3d4qMmh0nMktVc7chdhNdNGKK0K4NzdxX51eROaPCK/wtOmDmZUBEHUGfFuA0NtjiZVPnNDzLEF3/Rbo5IzPx8vcOD70W584fQJAvZXQby+piVHS00OX+XyjanvofMR4Im465auRG2gvm/gOhIq5e7OZPAwP+UjPsxYf5Ci0lnew==")
        let s = store()
        s.attach(account: "fixture@example.test", key: key, transport: server)
        await s.sync()
        XCTAssertEqual(s.item("fixture-training-01")?.data, Lift(title: "Жим лёжа", weight: 80, reps: 5))
        XCTAssertEqual(s.item("fixture-training-01")?.updatedAt, 1762934400000)
        XCTAssertNil(s.item("fixture-training-02"))
        XCTAssertEqual(s.all["fixture-training-02"]?.deleted, true)
        XCTAssertEqual(s.unreadableCount, 0)
    }

    func testSyncsBetweenDevicesAndServerHoldsCiphertextOnly() async throws {
        let key = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let a = store(folder: "a"), b = store(folder: "b")
        a.attach(account: "acc1", key: key, transport: server)
        b.attach(account: "acc1", key: key, transport: server)
        let id = try XCTUnwrap(a.put("lift-0001", Lift(title: "Жим", weight: 80, reps: 5)))
        await a.sync()
        XCTAssertEqual(a.pendingCount, 0)
        XCTAssertFalse(server.records[id]!.c.contains("Жим"))
        await b.sync()
        XCTAssertEqual(b.item(id)?.data?.weight, 80)
        b.remove(id)
        await b.sync()
        await a.sync()
        XCTAssertNil(a.item(id))
    }

    func testNewestEditWinsWithoutDuplicates() async throws {
        let key = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let a = store(folder: "a"), b = store(folder: "b")
        a.attach(account: "acc1", key: key, transport: server)
        b.attach(account: "acc1", key: key, transport: server)
        a.put("lift-0001", Lift(title: "Жим", weight: 80, reps: 5))
        await a.sync(); await b.sync()
        clock += 10; a.put("lift-0001", Lift(title: "Жим", weight: 85, reps: 5))
        clock += 10; b.put("lift-0001", Lift(title: "Жим", weight: 90, reps: 5))
        await a.sync(); await b.sync(); await a.sync()
        XCTAssertEqual(a.item("lift-0001")?.data?.weight, 90)
        XCTAssertEqual(b.item("lift-0001")?.data?.weight, 90)
        XCTAssertEqual(server.records.count, 1)
    }

    func testCopyPolicyKeepsBothVersions() async throws {
        let key = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let a = store(.copy, folder: "a"), b = store(.copy, folder: "b")
        a.attach(account: "acc1", key: key, transport: server)
        b.attach(account: "acc1", key: key, transport: server)
        a.put("lift-0001", Lift(title: "Жим", weight: 80, reps: 5))
        await a.sync(); await b.sync()
        clock += 10; a.put("lift-0001", Lift(title: "Жим", weight: 85, reps: 5))
        clock += 10; b.put("lift-0001", Lift(title: "Жим", weight: 90, reps: 5))
        await b.sync(); await a.sync(); await b.sync()
        XCTAssertEqual(Set(a.items.compactMap { $0.data?.weight }), [85, 90])
        XCTAssertEqual(Set(b.items.compactMap { $0.data?.weight }), [85, 90])
    }

    func testImportIsIdempotentAndWhenSyncedConfirmsUpload() async throws {
        let key = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let a = store()
        a.attach(account: "acc1", key: key, transport: server)
        let local: [(id: String, data: Lift, updatedAt: Int64)] = [
            ("t-local-1", Lift(title: "Жим", weight: 80, reps: 5), 10),
            ("t-local-2", Lift(title: "Присед", weight: 100, reps: 3), 20)
        ]
        XCTAssertEqual(a.importMany(local).written, 2)
        let synced = await a.whenSynced()
        XCTAssertTrue(synced)
        XCTAssertEqual(a.pendingCount, 0)
        XCTAssertEqual(server.records.count, 2)
        XCTAssertEqual(a.importMany(local).skipped, 2, "second run uploads nothing")
        XCTAssertEqual(a.pendingCount, 0)
    }

    func testRejectsIdsTheServerWouldRefuse() {
        XCTAssertFalse(VaultCollection<Lift>.isValidID("t1"))
        XCTAssertFalse(VaultCollection<Lift>.isValidID("тренировка-01"))
        XCTAssertTrue(VaultCollection<Lift>.isValidID("t-local-1"))
        let s = store()
        XCTAssertTrue(VaultCollection<Lift>.isValidID(s.newID()))
    }

    func testAccountsAreIsolatedAndCacheSurvivesRelaunch() async throws {
        let k1 = SymmetricKey(size: .bits256)
        let a = store()
        a.attach(account: "acc1", key: k1, transport: nil)
        a.put("habit-0001", Lift(title: "Вода", weight: 0, reps: 8))
        XCTAssertEqual(a.pendingCount, 1)
        a.attach(account: "acc2", key: SymmetricKey(size: .bits256), transport: nil)
        XCTAssertTrue(a.items.isEmpty)
        a.detach()
        let relaunched = store()
        relaunched.attach(account: "acc1", key: k1, transport: nil)
        XCTAssertEqual(relaunched.item("habit-0001")?.data?.title, "Вода")
        XCTAssertEqual(relaunched.pendingCount, 1, "unsent edit is still queued after relaunch")
    }
}
