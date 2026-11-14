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

    // MARK: Week reviews and the reminder time live in the collection too

    private let monday = "2026-11-09"

    func testWeekAndReminderRecordIDsAreValidAndDoNotLookLikeDays() {
        XCTAssertEqual(ReviewVault.weekRecordID(for: monday), "w-2026-11-09")
        XCTAssertTrue(VaultCollection<ReviewDayRecord>.isValidID(ReviewVault.weekRecordID(for: monday)))
        XCTAssertTrue(VaultCollection<ReviewDayRecord>.isValidID(ReviewVault.reminderRecordID))
        let items = [
            VaultItem(id: "w-2026-11-09", updatedAt: 1, data: ReviewDayRecord(week: WeekReview(weekStart: monday, ratings: ["health": 7], updatedAt: 1))),
            VaultItem(id: ReviewVault.reminderRecordID, updatedAt: 1, data: ReviewDayRecord(reminder: ReviewReminderSettings(enabled: true, hour: 22, minute: 30)))
        ]
        XCTAssertTrue(ReviewVault.merge(items).isEmpty, "Day code skips records of other kinds")
    }

    /// The same JSON the web writes (src/review-domain.mjs): `{kind, weekStart, ratings}` and `{kind, enabled, hour, minute}`.
    func testRecordsRoundTripAsTheWebShapes() throws {
        let week = ReviewDayRecord(week: WeekReview(weekStart: monday, ratings: ["health": 7, "money": 5], updatedAt: 9))
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(week), encoding: .utf8))
        XCTAssertTrue(json.contains("\"kind\":\"week\""))
        XCTAssertFalse(json.contains("\"day\""), "A week record carries no day")
        XCTAssertEqual(try JSONDecoder().decode(ReviewDayRecord.self, from: Data(json.utf8)), week)

        let webReminder = Data(#"{"kind":"reminder","enabled":false,"hour":8,"minute":5}"#.utf8)
        let reminder = try JSONDecoder().decode(ReviewDayRecord.self, from: webReminder)
        XCTAssertEqual(reminder, ReviewDayRecord(reminder: ReviewReminderSettings(enabled: false, hour: 8, minute: 5)))

        let day = try JSONDecoder().decode(ReviewDayRecord.self, from: Data(#"{"day":"2026-11-12","mood":4,"text":"Ок"}"#.utf8))
        XCTAssertEqual(day, ReviewDayRecord(day: "2026-11-12", mood: 4, text: "Ок"))
        let dayJSON = try XCTUnwrap(String(data: JSONEncoder().encode(day), encoding: .utf8))
        XCTAssertFalse(dayJSON.contains("kind"), "Day records keep their old shape")
    }

    func testSavedWeekAndReminderLandInTheCollection() {
        let vault = collection()
        let s = store(vault)
        XCTAssertTrue(s.saveWeek(containing: "2026-11-12", ratings: ["health": 7]))
        XCTAssertEqual(vault.item("w-2026-11-09")?.data?.ratings, ["health": 7])
        XCTAssertEqual(s.week(containing: "2026-11-12")?.ratings, ["health": 7])
        XCTAssertEqual(s.weeks.map(\.weekStart), [monday])
        let custom = ReviewReminderSettings(enabled: true, hour: 22, minute: 30)
        XCTAssertTrue(s.setReminder(custom))
        XCTAssertEqual(s.reminder, custom)
        XCTAssertEqual(vault.item(ReviewVault.reminderRecordID)?.data, ReviewDayRecord(reminder: custom))
    }

    func testLocalWeeksAndReminderMoveIntoTheCollectionAfterABackup() throws {
        let s = store(nil)
        XCTAssertTrue(s.saveWeek(containing: "2026-11-12", ratings: ["health": 6]))
        let custom = ReviewReminderSettings(enabled: true, hour: 20, minute: 15)
        XCTAssertTrue(s.setReminder(custom))
        let vault = collection()
        s.setCollection(vault)
        XCTAssertEqual(vault.item("w-2026-11-09")?.data?.ratings, ["health": 6])
        XCTAssertEqual(vault.item(ReviewVault.reminderRecordID)?.data, ReviewDayRecord(reminder: custom))
        XCTAssertEqual(s.reminder, custom)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("files").path)
        XCTAssertTrue(files.contains { $0.hasSuffix("pre-sync-backup.json") }, "Backup of the local file is taken before moving data")
        s.setCollection(vault)
        XCTAssertEqual(vault.items.filter { $0.data?.kind == "week" }.count, 1, "Moving again changes nothing")
    }

    func testANewerWeekFromAnotherDeviceWinsOverALocalOne() {
        clock = 5_000
        let s = store(nil)
        XCTAssertTrue(s.saveWeek(containing: "2026-11-12", ratings: ["health": 3]))
        let vault = collection()
        vault.put("w-2026-11-09", ReviewDayRecord(week: WeekReview(weekStart: monday, ratings: ["health": 9], updatedAt: 9_000)), updatedAt: 9_000)
        s.setCollection(vault)
        XCTAssertEqual(s.week(containing: monday)?.ratings, ["health": 9])
        XCTAssertEqual(vault.item("w-2026-11-09")?.data?.ratings, ["health": 9])
    }

    func testReminderCopiesFromConflictsCollapseToTheNewest() {
        let vault = collection()
        let s = store(vault)
        vault.put(ReviewVault.reminderRecordID, ReviewDayRecord(reminder: ReviewReminderSettings(enabled: true, hour: 21, minute: 0)), updatedAt: 100)
        vault.put("rcopy0000000000002", ReviewDayRecord(reminder: ReviewReminderSettings(enabled: true, hour: 7, minute: 45)), updatedAt: 300)
        s.setCollection(vault)
        XCTAssertEqual(s.reminder.timeText, "07:45")
        XCTAssertEqual(vault.items.filter { $0.data?.kind == "reminder" }.count, 1)
        XCTAssertEqual(vault.item(ReviewVault.reminderRecordID)?.data, ReviewDayRecord(reminder: ReviewReminderSettings(enabled: true, hour: 7, minute: 45)))
    }

    func testAReminderChangedElsewhereIsReported() {
        let vault = collection()
        let s = store(vault)
        var seen: [ReviewReminderSettings] = []
        s.onReminderChanged = { seen.append($0) }
        s.setCollection(vault)
        vault.put(ReviewVault.reminderRecordID, ReviewDayRecord(reminder: ReviewReminderSettings(enabled: true, hour: 6, minute: 30)), updatedAt: 500)
        s.setCollection(vault)
        XCTAssertEqual(seen.map(\.timeText), ["06:30"])
    }
}
