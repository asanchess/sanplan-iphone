import XCTest
import CryptoKit
@testable import SanPlan

/// Updating over the phone build of 10–12 November: that build kept money in `ARNA/finance_state.json` (the same
/// `FinanceState` shape as today). After the update the file moves to the account folder, then into the `finance`
/// collection; the phone keeps a copy, and nothing is removed while the server has not confirmed the records.
@MainActor
final class FinanceMigrationTests: XCTestCase {
    private var base: URL!
    private let email = "owner@example.test"

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("finance-migration-\(UUID().uuidString)")
        let arna = base.appendingPathComponent("ARNA", isDirectory: true)
        try FileManager.default.createDirectory(at: arna, withIntermediateDirectories: true)
        // Synthetic data, written the way the old build wrote it.
        let old = FinanceState(version: 1,
                               records: [FinanceRecord(id: "old-rec-0001", kind: "expense", title: "Кофе", amountMinor: 1_500_00, date: "2026-11-10", category: "Кафе"),
                                         FinanceRecord(id: "old-rec-0002", kind: "income", title: "Зарплата", amountMinor: 300_000_00, date: "2026-11-01", category: "Зарплата")],
                               committedBatches: ["batch-old-1"])
        try JSONEncoder().encode(old).write(to: arna.appendingPathComponent("finance_state.json"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private var accountFolder: URL {
        base.appendingPathComponent("ARNA/accounts", isDirectory: true).appendingPathComponent(FinanceStore.accountFolderName(email), isDirectory: true)
    }

    private func collection(_ server: MemoryVaultTransport, _ key: SymmetricKey) -> VaultCollection<FinancePayload> {
        let c = VaultCollection<FinancePayload>(collection: "finance", policy: .newest, idPrefix: "f", baseDirectory: base.appendingPathComponent("vault"))
        c.syncDelay = .seconds(3600)
        c.attach(account: email, key: key, transport: server)
        return c
    }

    func testOldPhoneFileMovesIntoTheAccountAndACopyStays() async throws {
        let store = FinanceStore(owner: .account(email), baseDirectory: base)
        XCTAssertEqual(store.state.records.map(\.id), ["old-rec-0001", "old-rec-0002"], "the old file is found after the update")
        let server = MemoryVaultTransport(), key = SymmetricKey(size: .bits256)
        let c = collection(server, key)
        await c.sync()
        store.attach(collection: c)
        await store.moveToCollectionIfNeeded()
        for _ in 0..<50 where store.storage != .cloud { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(store.storage, .cloud)
        XCTAssertEqual(Set(store.state.records.map(\.id)), ["old-rec-0001", "old-rec-0002"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountFolder.appendingPathComponent("finance_state.json").path))
        let backup = try JSONDecoder().decode(FinanceState.self, from: Data(contentsOf: accountFolder.appendingPathComponent("finance_state.pre-sync-backup.json")))
        XCTAssertEqual(backup.records.map(\.id), ["old-rec-0001", "old-rec-0002"], "the phone keeps the file it moved")
        XCTAssertFalse(server.records.values.contains { $0.c.contains("Кофе") }, "the server holds ciphertext only")

        // A second device of the account gets the money from the server.
        let other = VaultCollection<FinancePayload>(collection: "finance", policy: .newest, idPrefix: "f", baseDirectory: base.appendingPathComponent("vault-b"))
        other.attach(account: email, key: key, transport: server)
        await other.sync()
        XCTAssertEqual(Set(FinanceCloud.state(from: other.items).records.map(\.id)), ["old-rec-0001", "old-rec-0002"])
    }

    /// The owner's phone, 17 November: the server failed during the move, the move waited forever and every change of
    /// money answered «Идёт перенос финансов в облако». Now a failed upload hands the money back to the phone's file,
    /// changes keep working, and the next return to the app finishes the move with them.
    func testNoConnectionKeepsMoneyEditableOnThePhoneAndRetriesLater() async throws {
        let store = FinanceStore(owner: .account(email), baseDirectory: base)
        let server = MemoryVaultTransport(), key = SymmetricKey(size: .bits256)
        let c = collection(server, key)
        await c.sync()
        server.failNext = true
        store.attach(collection: c)
        for _ in 0..<100 where store.storage != .local || store.notice == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.storage, .local, "a failed upload must not leave the move waiting")
        XCTAssertNotNil(store.notice)
        let file = accountFolder.appendingPathComponent("finance_state.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "nothing is removed before the server confirms")

        var next = store.state
        next.records.append(FinanceRecord(id: "new-rec-0003", kind: "expense", title: "Обед", amountMinor: 2_500_00, date: "2026-11-12", category: "Кафе"))
        XCTAssertNoThrow(try store.replaceState(with: next, today: "2026-11-12"), "money stays editable without the cloud")
        let saved = try JSONDecoder().decode(FinanceState.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.records.count, 3)

        store.retryMoveIfNeeded()
        for _ in 0..<100 where store.storage != .cloud { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.storage, .cloud)
        XCTAssertEqual(Set(store.state.records.map(\.id)), ["old-rec-0001", "old-rec-0002", "new-rec-0003"], "the change made offline reached the cloud")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSigningOutDuringTheMoveKeepsTheFile() async throws {
        let store = FinanceStore(owner: .account(email), baseDirectory: base)
        let server = MemoryVaultTransport(), key = SymmetricKey(size: .bits256)
        let c = collection(server, key)
        await c.sync()
        store.attach(collection: c)
        c.detach()
        for _ in 0..<50 where store.storage != .local { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.storage, .local)
        XCTAssertTrue(FileManager.default.fileExists(atPath: accountFolder.appendingPathComponent("finance_state.json").path))
        XCTAssertEqual(store.state.records.count, 2)
    }
}
