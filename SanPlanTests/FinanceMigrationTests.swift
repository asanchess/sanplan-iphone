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

    func testNoConnectionLeavesTheFileInPlace() async throws {
        let store = FinanceStore(owner: .account(email), baseDirectory: base)
        let server = MemoryVaultTransport(), key = SymmetricKey(size: .bits256)
        let c = collection(server, key)
        await c.sync()
        server.failNext = true
        store.attach(collection: c)
        // Offline the move waits for the server (live sync retries); the file stays meanwhile.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.storage, .migrating)
        XCTAssertTrue(FileManager.default.fileExists(atPath: accountFolder.appendingPathComponent("finance_state.json").path), "nothing is removed before the server confirms")
        // Signing out while waiting gives up the move; the file is still there.
        c.detach()
        for _ in 0..<50 where store.storage != .local { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.storage, .local)
        XCTAssertTrue(FileManager.default.fileExists(atPath: accountFolder.appendingPathComponent("finance_state.json").path))
        XCTAssertEqual(store.state.records.count, 2)
    }
}
