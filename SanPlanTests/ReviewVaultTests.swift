import XCTest
import CryptoKit
@testable import SanPlan

/// Day reviews in the encrypted `reviews` collection: record ids, merging of conflict copies, local → vault migration.
@MainActor
final class ReviewVaultTests: XCTestCase {
    private var directory: URL!
    private var clock: Int64 = 1_000
    private let day = "2026-11-12"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("review-vault-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func collection() -> VaultCollection<ReviewDayRecord> {
        let c = VaultCollection<ReviewDayRecord>(collection: "reviews", policy: .copy, idPrefix: "r",
                                                 baseDirectory: directory.appendingPathComponent("vault"), now: { [unowned self] in self.clock })
        c.syncDelay = .seconds(3600)
        c.attach(account: "a@example.com", key: SymmetricKey(data: Data(repeating: 7, count: 32)), transport: nil)
        return c
    }

    private func store(_ vault: VaultCollection<ReviewDayRecord>?) -> ReviewStore {
        let s = ReviewStore(directory: directory.appendingPathComponent("files"), now: { [unowned self] in self.clock })
        s.switchOwner(to: .account("a@example.com"))
        s.setCollection(vault)
        return s
    }

    func testRecordIDComesFromTheDay() {
        XCTAssertEqual(ReviewVault.recordID(for: day), "r-2026-11-12")
        XCTAssertTrue(VaultCollection<ReviewDayRecord>.isValidID(ReviewVault.recordID(for: day)))
    }

    func testMergeKeepsNewestMoodAndEveryLine() {
        let merged = ReviewVault.merge([
            VaultItem(id: "r-2026-11-12", updatedAt: 10, data: ReviewDayRecord(day: day, mood: 3, text: "Утро")),
            VaultItem(id: "rcopy00000001", updatedAt: 20, data: ReviewDayRecord(day: day, mood: nil, text: "Вечер")),
            VaultItem(id: "rcopy00000002", updatedAt: 5, data: ReviewDayRecord(day: day, mood: 2, text: "Утро"))
        ])[day]
        XCTAssertEqual(merged?.entry.mood, 3)
        XCTAssertEqual(merged?.entry.text, "Утро · Вечер")
        XCTAssertEqual(merged?.ids.count, 3)
    }

    func testSavedDayLandsInTheCollection() {
        let vault = collection()
        let s = store(vault)
        XCTAssertTrue(s.saveDay(day, mood: 4, text: "Хороший день"))
        XCTAssertEqual(vault.item("r-2026-11-12")?.data, ReviewDayRecord(day: day, mood: 4, text: "Хороший день"))
        XCTAssertEqual(s.day(day)?.text, "Хороший день")
        XCTAssertTrue(s.deleteDay(day))
        XCTAssertNil(s.day(day))
        XCTAssertNil(vault.item("r-2026-11-12"))
    }

    func testLocalDaysMoveIntoTheCollectionWhenItOpens() {
        let s = store(nil)
        XCTAssertTrue(s.saveDay(day, mood: 5, text: "Локально"))
        let vault = collection()
        s.setCollection(vault)
        XCTAssertEqual(vault.item("r-2026-11-12")?.data?.text, "Локально")
        XCTAssertEqual(s.day(day)?.mood, 5)
        s.setCollection(vault)
        XCTAssertEqual(vault.items.count, 1)
    }

    func testConflictCopiesAreMergedBackIntoOneRecord() {
        let vault = collection()
        let s = store(vault)
        vault.put("r-2026-11-12", ReviewDayRecord(day: day, mood: 3, text: "Первое"), updatedAt: 100)
        vault.put("rcopy0000000000001", ReviewDayRecord(day: day, mood: nil, text: "Со второго устройства"), updatedAt: 200)
        s.setCollection(vault)
        XCTAssertEqual(vault.items.count, 1)
        XCTAssertEqual(vault.item("r-2026-11-12")?.data, ReviewDayRecord(day: day, mood: 3, text: "Первое · Со второго устройства"))
    }
}
