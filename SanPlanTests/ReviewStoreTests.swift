import XCTest
import CryptoKit
@testable import SanPlan

@MainActor
final class ReviewStoreTests: XCTestCase {
    private var directory: URL!
    private var clock: Int64 = 1_000

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> ReviewStore {
        ReviewStore(directory: directory, now: { [unowned self] in self.clock })
    }

    func testNothingIsSavedWhileSignedOut() {
        let store = makeStore()
        XCTAssertFalse(store.saveDay("2026-11-12", mood: 3, text: "x"))
        XCTAssertNil(store.day("2026-11-12"))
    }

    func testSavedDayIsReadBackAfterRestart() {
        let store = makeStore()
        store.switchOwner(to: .account("a@example.com"))
        XCTAssertTrue(store.saveDay("2026-11-12", mood: 4, text: "Хороший день"))
        let reopened = makeStore()
        reopened.switchOwner(to: .account("A@example.com "))
        XCTAssertEqual(reopened.day("2026-11-12"), ReviewEntry(day: "2026-11-12", mood: 4, text: "Хороший день", updatedAt: 1_000))
    }

    func testAccountsDoNotSeeEachOther() {
        let store = makeStore()
        store.switchOwner(to: .account("a@example.com"))
        store.saveDay("2026-11-12", mood: 5, text: "")
        store.switchOwner(to: .account("b@example.com"))
        XCTAssertNil(store.day("2026-11-12"))
        store.switchOwner(to: .none)
        XCTAssertNil(store.day("2026-11-12"))
        store.switchOwner(to: .account("a@example.com"))
        XCTAssertEqual(store.day("2026-11-12")?.mood, 5)
    }

    func testEditReplacesTheSameDayAndDeleteRemovesIt() {
        let store = makeStore()
        store.switchOwner(to: .device)
        store.saveDay("2026-11-12", mood: 2, text: "Тяжело")
        clock = 2_000
        store.saveDay("2026-11-12", mood: 3, text: "Лучше")
        XCTAssertEqual(store.reviewedDays, ["2026-11-12"])
        XCTAssertEqual(store.day("2026-11-12")?.updatedAt, 2_000)
        XCTAssertTrue(store.deleteDay("2026-11-12"))
        XCTAssertNil(store.day("2026-11-12"))
        XCTAssertFalse(store.deleteDay("2026-11-12"))
    }

    func testEmptyReviewIsRefused() {
        let store = makeStore()
        store.switchOwner(to: .device)
        XCTAssertFalse(store.saveDay("2026-11-12", mood: nil, text: "   "))
        XCTAssertTrue(store.reviewedDays.isEmpty)
    }

    func testWeekRatingsAndPreviousWeekLookup() {
        let store = makeStore()
        store.switchOwner(to: .device)
        XCTAssertTrue(store.saveWeek(containing: "2026-11-05", ratings: ["health": 6]))
        XCTAssertTrue(store.saveWeek(containing: "2026-11-12", ratings: ["health": 8]))
        XCTAssertEqual(store.week(containing: "2026-11-15")?.ratings["health"], 8)
        XCTAssertEqual(store.previousWeek(before: "2026-11-12")?.ratings["health"], 6)
        XCTAssertFalse(store.saveWeek(containing: "2026-11-12", ratings: ["health": 99]))
    }

    func testActivityDaysAreTheReviewedDaysInRange() {
        let store = makeStore()
        store.switchOwner(to: .device)
        for day in ["2026-11-01", "2026-11-10", "2026-11-12"] { store.saveDay(day, mood: 3, text: "") }
        XCTAssertEqual(store.activityDays(from: "2026-11-09", to: "2026-11-15"), ["2026-11-10", "2026-11-12"])
    }

    func testReminderSettingsPersist() {
        let store = makeStore()
        store.switchOwner(to: .device)
        XCTAssertEqual(store.reminder, .standard)
        store.setReminder(ReviewReminderSettings(enabled: true, hour: 22, minute: 30))
        let reopened = makeStore()
        reopened.switchOwner(to: .device)
        XCTAssertEqual(reopened.reminder.timeText, "22:30")
    }

    func testUnreadableFileIsKeptAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("не json".utf8).write(to: directory.appendingPathComponent("device.json"))
        let store = makeStore()
        store.switchOwner(to: .device)
        XCTAssertNotNil(store.errorMessage)
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("unreadable") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(store.saveDay("2026-11-12", mood: 3, text: ""))
    }

    // MARK: Notes activity (DOMAINS.md §2)

    func testNotesActivityDaysCountWrittenNotesNotDeletedOnes() {
        var notesClock: Int64 = {
            let date = ISO8601DateFormatter().date(from: "2026-11-10T07:00:00Z")!
            return Int64(date.timeIntervalSince1970 * 1000)
        }()
        let notes = NotesStore(baseDirectory: directory.appendingPathComponent("notes"), now: { notesClock })
        notes.attach(account: "a@example.com", key: SymmetricKey(size: .bits256), transport: nil)
        notes.create(text: "Первая")
        notesClock += 86_400_000 * 2
        notes.create(text: "Вторая")
        notesClock += 86_400_000
        notes.create(text: "Удалим")
        XCTAssertEqual(notes.activityDays(from: "2026-11-01", to: "2026-11-30"), ["2026-11-10", "2026-11-12", "2026-11-13"])
        XCTAssertEqual(notes.activityDays(from: "2026-11-11", to: "2026-11-12"), ["2026-11-12"])
        if let id = notes.notes.first(where: { $0.text == "Удалим" })?.id { notes.delete(id) }
        XCTAssertEqual(notes.activityDays(from: "2026-11-01", to: "2026-11-30"), ["2026-11-10", "2026-11-12"])
    }
}
