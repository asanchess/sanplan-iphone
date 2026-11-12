import XCTest
import CryptoKit
@testable import SanPlan

/// История тренировок в коллекции `training`: id, слияние, сверка и повторный перенос.
@MainActor
final class WorkoutVaultTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let email = "owner@example.test"

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("workout-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suiteName = "workout-vault-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func record(_ id: String, start: Int64, weight: Double = 60, reps: Int = 8, healthId: String? = nil) -> WorkoutRecord {
        WorkoutRecord(
            id: id, startedAt: start, endedAt: start + 3_600_000,
            exercises: [WorkoutRecordExercise(name: "Жим", sets: [
                WorkoutRecordSet(done: true, weightKg: weight, reps: reps),
                WorkoutRecordSet(done: false, weightKg: nil, reps: nil),
            ])],
            healthId: healthId
        )
    }

    private func store() -> WorkoutStore {
        WorkoutStore(
            restAlarm: RestAlarmCoordinator(service: FakeRestAlarmService()),
            baseDirectory: base, owner: .account(email), defaults: defaults
        )
    }

    private func collection(folder: String) -> VaultCollection<WorkoutRecord> {
        let c = VaultCollection<WorkoutRecord>(collection: "training", policy: .newest, idPrefix: "t",
                                               baseDirectory: base.appendingPathComponent(folder))
        c.syncDelay = .seconds(3600)
        return c
    }

    func testVaultIDIsDeterministicAndValid() {
        let uuid = "9F1C2B3A-1111-4222-8333-444455556666"
        let id = WorkoutVaultMigration.vaultID(for: uuid)
        XCTAssertEqual(id, "t-" + uuid)
        XCTAssertEqual(id, WorkoutVaultMigration.vaultID(for: uuid))
        XCTAssertTrue(VaultCollection<WorkoutRecord>.isValidID(id))
        XCTAssertTrue(VaultCollection<WorkoutRecord>.isValidID(WorkoutVaultMigration.vaultID(for: "a")))
        XCTAssertTrue(VaultCollection<WorkoutRecord>.isValidID(WorkoutVaultMigration.vaultID(for: "тренировка №1")))
        XCTAssertTrue(VaultCollection<WorkoutRecord>.isValidID(WorkoutVaultMigration.vaultID(for: String(repeating: "x", count: 100))))
    }

    func testReportCountsWorkoutsSetsAndTonnage() {
        let report = WorkoutVaultMigration.report([record("a", start: 1_000), record("b", start: 2_000, weight: 62.5, reps: 8)])
        XCTAssertEqual(report.workouts, 2)
        XCTAssertEqual(report.doneSets, 2)
        XCTAssertEqual(report.plannedSets, 4)
        XCTAssertEqual(report.exercises, 2)
        XCTAssertEqual(report.tonnageTenths, 9800)
    }

    func testPayloadDropsHealthLink() {
        XCTAssertNil(WorkoutVaultMigration.payload(record("a", start: 1, healthId: "hk-1")).healthId)
    }

    func testMergeBringsRemoteEditsAndTombstonesAndKeepsHealthLink() {
        let mine = record("a", start: 1_000, healthId: "hk-1")
        let gone = record("b", start: 2_000)
        let remoteEdit = record("a", start: 1_000, weight: 70)
        let vault: [String: VaultItem<WorkoutRecord>] = [
            "t-a": VaultItem(id: "t-a", updatedAt: 5, data: remoteEdit),
            "t-b": VaultItem(id: "t-b", updatedAt: 6, deleted: true, data: gone),
            "t-c": VaultItem(id: "t-c", updatedAt: 7, data: record("c", start: 3_000)),
        ]
        let merged = WorkoutVaultMigration.merged(local: [mine, gone], vault: vault)
        XCTAssertEqual(merged.map(\.id), ["c", "a"])
        XCTAssertEqual(merged.first { $0.id == "a" }?.exercises.first?.sets.first?.weightKg, 70)
        XCTAssertEqual(merged.first { $0.id == "a" }?.healthId, "hk-1")
        // Слияние идемпотентно: второй проход ничего не меняет.
        XCTAssertEqual(WorkoutVaultMigration.merged(local: merged, vault: vault), merged)
    }

    func testMigrationUploadsConfirmsAndIsIdempotent() async throws {
        let key = SymmetricKey(size: .bits256)
        let server = MemoryVaultTransport()
        let s = store()
        s.saveRecord(record("rec-0001", start: 1_700_000_000_000))
        s.saveRecord(record("rec-0002", start: 1_700_100_000_000, weight: 65))
        XCTAssertEqual(s.records.count, 2)

        let a = collection(folder: "a")
        a.attach(account: email, key: key, transport: server)
        s.attachVault(a, account: email, autoMigrate: false)
        let status = await s.migrateHistory()
        XCTAssertEqual(status, .confirmed)
        XCTAssertEqual(server.records.count, 2)
        XCTAssertNotNil(s.loadJournal().confirmedAt)
        XCTAssertEqual(s.loadJournal().before, s.loadJournal().after)
        XCTAssertEqual(s.records.count, 2, "локальная история не удаляется")

        // Повторный запуск на другом экземпляре коллекции того же аккаунта ничего не дублирует.
        let again = store()
        let b = collection(folder: "b")
        b.attach(account: email, key: key, transport: server)
        again.attachVault(b, account: email, autoMigrate: false)
        _ = await again.migrateHistory()
        _ = await b.whenSynced()
        XCTAssertEqual(server.records.count, 2)
    }

    func testVaultOfAnotherAccountIsNotAttached() {
        let s = store()
        let c = collection(folder: "x")
        s.attachVault(c, account: "someone@else.test", autoMigrate: false)
        XCTAssertNil(s.vault)
    }

    func testEditsAndDeletesGoToTheCollection() async throws {
        let key = SymmetricKey(size: .bits256)
        let s = store()
        let c = collection(folder: "c")
        c.attach(account: email, key: key, transport: nil)
        s.attachVault(c, account: email, autoMigrate: false)
        s.saveRecord(record("rec-0003", start: 1_700_000_000_000))
        let vid = WorkoutVaultMigration.vaultID(for: "rec-0003")
        XCTAssertEqual(c.item(vid)?.data?.id, "rec-0003")
        s.deleteRecord(id: "rec-0003")
        XCTAssertNil(c.item(vid))
        XCTAssertEqual(c.all[vid]?.deleted, true)
    }
}
