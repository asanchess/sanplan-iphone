import XCTest
@testable import SanPlan

/// Points Application Support at a throwaway folder, so the store never touches the app's real finance file.
private final class SandboxFileManager: FileManager {
    let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root]
    }
}

@MainActor
final class FinanceStoreTests: XCTestCase {
    private let today = "2026-05-10"

    /// A fresh folder per test, removed when the test ends.
    private struct Sandbox {
        let fileManager: SandboxFileManager
        let storageURL: URL
        let corruptFolderURL: URL
    }

    private var sandbox: Sandbox!

    private var storageURL: URL { sandbox.storageURL }
    private var corruptFolderURL: URL { sandbox.corruptFolderURL }

    private func prepareSandbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinanceStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        sandbox = Sandbox(
            fileManager: SandboxFileManager(root: root),
            storageURL: root.appendingPathComponent("ARNA/finance_state.json"),
            corruptFolderURL: root.appendingPathComponent("ARNA/corrupt", isDirectory: true)
        )
    }

    private func makeStore() -> FinanceStore {
        FinanceStore(fileManager: sandbox.fileManager)
    }

    private func sampleState() -> FinanceState {
        FinanceState(records: [
            FinanceRecord(id: "b1", kind: "balance", title: "Остаток", amountMinor: 1_000_000, date: "2026-05-01"),
            FinanceRecord(id: "e1", kind: "expense", title: "Обед", amountMinor: 250_000, date: "2026-05-02", category: "   "),
        ])
    }

    func testFreshFolderStartsEmptyWithoutWritingAFile() throws {
        try prepareSandbox()
        let store = makeStore()
        XCTAssertEqual(store.state, emptyFinance())
        XCTAssertNil(store.summary)
        XCTAssertNil(store.notice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
    }

    func testReplaceStateCleansSavesAndRefreshesSummary() throws {
        try prepareSandbox()
        let store = makeStore()
        try store.replaceState(with: sampleState(), today: today)

        XCTAssertEqual(store.state.records.count, 2)
        XCTAssertEqual(store.state.records[1].category, "Без категории", "A blank category is normalised before saving")
        XCTAssertEqual(store.summary?.balanceMinor, 750_000)
        XCTAssertEqual(store.summary?.expenseMinor, 250_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))
    }

    func testPersistenceRoundTripAcrossStoreInstances() throws {
        try prepareSandbox()
        let first = makeStore()
        try first.replaceState(with: sampleState(), today: today)

        let reopened = makeStore()
        XCTAssertEqual(reopened.state, first.state)
        XCTAssertNil(reopened.notice)
        XCTAssertNil(reopened.summary, "The summary is computed on request, not on load")

        reopened.refreshSummary(today: today)
        XCTAssertEqual(reopened.summary, first.summary)
    }

    func testInvalidStateIsRejectedAndNothingChanges() throws {
        try prepareSandbox()
        let store = makeStore()
        try store.replaceState(with: sampleState(), today: today)
        let saved = store.state
        let savedData = try Data(contentsOf: storageURL)

        var badVersion = sampleState()
        badVersion.version = 2
        XCTAssertThrowsError(try store.replaceState(with: badVersion, today: today))

        var duplicate = sampleState()
        duplicate.records.append(FinanceRecord(id: "e1", kind: "income", title: "Аванс", amountMinor: 1, date: "2026-05-03"))
        XCTAssertThrowsError(try store.replaceState(with: duplicate, today: today))

        XCTAssertEqual(store.state, saved)
        XCTAssertEqual(try Data(contentsOf: storageURL), savedData, "A refused state never reaches the disk")
    }

    func testRemovePersistsAndUnknownIdIsANoOp() throws {
        try prepareSandbox()
        let store = makeStore()
        try store.replaceState(with: sampleState(), today: today)

        try store.remove(recordId: "missing", today: today)
        XCTAssertEqual(store.state.records.map(\.id), ["b1", "e1"])

        try store.remove(recordId: "e1", today: today)
        XCTAssertEqual(store.state.records.map(\.id), ["b1"])
        XCTAssertEqual(store.summary?.balanceMinor, 1_000_000)
        XCTAssertEqual(makeStore().state.records.map(\.id), ["b1"])
    }

    func testCommitIsIdempotentPerBatchAndPersists() throws {
        try prepareSandbox()
        let store = makeStore()
        let drafts = [FinanceDraft(kind: "income", title: "Подработка", amountMinor: 500_000, date: "2026-05-03", category: "Работа")]
        try store.commit(drafts: drafts, today: today, batchId: "batch-1")
        try store.commit(drafts: drafts, today: today, batchId: "batch-1")

        XCTAssertEqual(store.state.records.map(\.id), ["batch-1:0"])
        XCTAssertEqual(store.state.committedBatches, ["batch-1"])
        XCTAssertEqual(store.summary?.incomeMinor, 500_000)
        XCTAssertEqual(makeStore().state, store.state)
    }

    func testRefreshSummaryClearsOnInvalidInput() throws {
        try prepareSandbox()
        let store = makeStore()
        try store.replaceState(with: sampleState(), today: today)
        XCTAssertNotNil(store.summary)

        store.refreshSummary(today: "2026-13-40")
        XCTAssertNil(store.summary)

        store.refreshSummary(today: today, horizonDays: 0)
        XCTAssertNil(store.summary, "Horizon must be 1…366 days")

        store.refreshSummary(today: today, horizonDays: 366)
        XCTAssertNotNil(store.summary)
    }

    func testUnreadableFileIsMovedAsideAndAFreshProfileStarts() throws {
        try prepareSandbox()
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: storageURL)

        let store = makeStore()
        XCTAssertEqual(store.state, emptyFinance())
        XCTAssertNotNil(store.notice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
        let preserved = try FileManager.default.contentsOfDirectory(atPath: corruptFolderURL.path)
        XCTAssertEqual(preserved.count, 1)
        XCTAssertTrue(preserved[0].hasPrefix("finance_state_corrupt_"))

        // The next save works and the store is usable again.
        try store.replaceState(with: sampleState(), today: today)
        XCTAssertNil(store.notice)
        XCTAssertEqual(makeStore().state.records.count, 2)
    }

    func testDecodableButInvalidStateIsTreatedAsCorrupt() throws {
        try prepareSandbox()
        var invalid = sampleState()
        invalid.records.append(FinanceRecord(id: "b1", kind: "income", title: "Дубль", amountMinor: 100, date: "2026-05-04"))
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(invalid).write(to: storageURL)

        let store = makeStore()
        XCTAssertEqual(store.state, emptyFinance())
        XCTAssertNotNil(store.notice)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: corruptFolderURL.path).count, 1)
    }

    // MARK: One account, one set of money

    func testEachAccountKeepsItsOwnMoney() throws {
        try prepareSandbox()
        let store = FinanceStore(fileManager: sandbox.fileManager, owner: .account("a@example.com"))
        try store.replaceState(with: sampleState(), today: today)

        store.switchOwner(to: .account("b@example.com"))
        XCTAssertEqual(store.state, emptyFinance(), "another account starts with nothing")
        try store.commit(drafts: [FinanceDraft(kind: "income", title: "Аванс", amountMinor: 100_000, date: "2026-05-03", category: "Работа")],
                         today: today, batchId: "b-1")

        store.switchOwner(to: .account(" A@Example.com "))
        XCTAssertEqual(store.state.records.map(\.id), ["b1", "e1"], "the first account's money comes back, address case aside")
        XCTAssertEqual(FinanceStore(fileManager: sandbox.fileManager, owner: .account("b@example.com")).state.records.map(\.id), ["b-1:0"])
    }

    func testTheFirstAccountTakesOverTheEarlierSharedFile() throws {
        try prepareSandbox()
        try makeStore().replaceState(with: sampleState(), today: today)

        let first = FinanceStore(fileManager: sandbox.fileManager, owner: .account("a@example.com"))
        XCTAssertEqual(first.state.records.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path), "moved, not copied")
        XCTAssertEqual(FinanceStore(fileManager: sandbox.fileManager, owner: .account("b@example.com")).state, emptyFinance())
        XCTAssertEqual(FinanceStore(fileManager: sandbox.fileManager, owner: .account("a@example.com")).state.records.count, 2)
    }

    func testSignedOutShowsNothingSavesNothingAndKeepsTheFiles() throws {
        try prepareSandbox()
        let store = FinanceStore(fileManager: sandbox.fileManager, owner: .account("a@example.com"))
        try store.replaceState(with: sampleState(), today: today)

        store.switchOwner(to: .none)
        XCTAssertEqual(store.state, emptyFinance())
        XCTAssertNil(store.summary)
        XCTAssertThrowsError(try store.replaceState(with: sampleState(), today: today))
        store.reset()

        store.switchOwner(to: .account("a@example.com"))
        XCTAssertEqual(store.state.records.count, 2, "sign-out never deletes an account's money")
    }

    func testResetDeletesTheFileAndClearsEverything() throws {
        try prepareSandbox()
        let store = makeStore()
        try store.replaceState(with: sampleState(), today: today)
        store.notice = "Сообщение"

        store.reset()
        XCTAssertEqual(store.state, emptyFinance())
        XCTAssertNil(store.summary)
        XCTAssertNil(store.notice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
        XCTAssertEqual(makeStore().state, emptyFinance())
    }
}
