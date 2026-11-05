import XCTest
@testable import SanPlan

final class PlanDomainTests: XCTestCase {
    private let timeZone = "Asia/Qyzylorda"

    func testZonedEpochAndAddDays() {
        let epoch = PlanDomain.zonedEpoch(dateStr: "2026-11-05", timeStr: "14:30", timeZone: timeZone)
        XCTAssertNotNil(epoch)

        let nextDay = PlanDomain.addDays(dateStr: "2026-11-05", days: 1)
        XCTAssertEqual(nextDay, "2026-11-06")

        let prevDay = PlanDomain.addDays(dateStr: "2026-11-05", days: -5)
        XCTAssertEqual(prevDay, "2026-10-31")
    }

    func testValidationRules() {
        var invalid = PlanItem(id: "1", kind: "invalid_kind", title: "", timeZone: "Invalid/TZ")
        var errors = PlanDomain.validatePlan(invalid)
        XCTAssertTrue(errors.contains("Название не может быть пустым."))
        XCTAssertTrue(errors.contains("Выбери событие или задачу."))
        XCTAssertTrue(errors.contains("Укажи корректный часовой пояс."))

        invalid = PlanItem(id: "2", kind: "event", title: "Встреча", date: "2026-11-05", time: "25:99", durationMinutes: 2000, timeZone: timeZone)
        errors = PlanDomain.validatePlan(invalid)
        XCTAssertTrue(errors.contains("Укажи корректное время."))
        XCTAssertTrue(errors.contains("Длительность должна быть от 1 до 1440 минут."))

        let validEvent = PlanItem(
            id: "3",
            kind: "event",
            title: "Совещание команды",
            date: "2026-11-05",
            time: "10:00",
            durationMinutes: 60,
            reminderMinutes: 1440,
            reminderOffsets: [1440, 60, 0],
            timeZone: timeZone
        )
        XCTAssertTrue(PlanDomain.validatePlan(validEvent).isEmpty)
    }

    func testConflictDetection() {
        let p1 = PlanItem(
            id: "a",
            kind: "event",
            title: "Событие 1",
            date: "2026-11-05",
            time: "10:00",
            durationMinutes: 60,
            timeZone: timeZone
        )
        let p2 = PlanItem(
            id: "b",
            kind: "event",
            title: "Событие 2 (наложение)",
            date: "2026-11-05",
            time: "10:30",
            durationMinutes: 60,
            timeZone: timeZone
        )
        let p3 = PlanItem(
            id: "c",
            kind: "event",
            title: "Событие 3 (нет наложения)",
            date: "2026-11-05",
            time: "12:00",
            durationMinutes: 45,
            timeZone: timeZone
        )

        let conflicts = PlanDomain.getConflicts(plans: [p1, p2, p3])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].ids.sorted(), ["a", "b"])
        XCTAssertEqual(conflicts[0].startMinute, 10 * 60 + 30)
        XCTAssertEqual(conflicts[0].endMinute, 11 * 60)
    }

    func testAgendaMidnightCrossing() {
        let nightEvent = PlanItem(
            id: "night",
            kind: "event",
            title: "Ночное дежурство",
            date: "2026-11-05",
            time: "23:00",
            durationMinutes: 120,
            timeZone: timeZone
        )

        let agendaDay1 = PlanDomain.getAgendaItems(
            plans: [nightEvent],
            targetDate: "2026-11-05",
            targetTimeZone: timeZone
        )
        XCTAssertEqual(agendaDay1.count, 1)
        XCTAssertEqual(agendaDay1[0].displayTime, "23:00–01:00 (+1)")

        let agendaDay2 = PlanDomain.getAgendaItems(
            plans: [nightEvent],
            targetDate: "2026-11-06",
            targetTimeZone: timeZone
        )
        XCTAssertEqual(agendaDay2.count, 1)
        XCTAssertEqual(agendaDay2[0].displayTime, "до 01:00 (с вчера)")
    }

    func testReminderLabels() {
        XCTAssertEqual(PlanDomain.formatReminderOffset(0), "В момент начала")
        XCTAssertEqual(PlanDomain.formatReminderOffset(-1), "Без напоминания")
        XCTAssertEqual(PlanDomain.formatReminderOffset(60), "За 1 ч.")
        XCTAssertEqual(PlanDomain.formatReminderOffset(1440), "За 1 дн.")
        XCTAssertEqual(PlanDomain.formatReminderOffset(1500), "За 1 дн. 1 ч.")
        XCTAssertEqual(PlanDomain.formatReminderOffset(2895), "За 2 дн. 15 мин.")
    }

    func testTolerantAPIDecoding() throws {
        let json = """
        {
            "plans": [
                {
                    "id": "item-123",
                    "kind": "task",
                    "title": "Купить билеты",
                    "date": "2026-11-06",
                    "time": "18:00",
                    "timeZone": "Asia/Qyzylorda"
                }
            ],
            "message": "OK"
        }
        """.data(using: .utf8)!

        let parsed = try JSONDecoder().decode(PlanListResponse.self, from: json)
        XCTAssertEqual(parsed.plans?.count, 1)
        let item = try XCTUnwrap(parsed.plans?.first)
        XCTAssertEqual(item.id, "item-123")
        XCTAssertEqual(item.kind, "task")
        XCTAssertEqual(item.title, "Купить билеты")
        XCTAssertNil(item.completed)
    }
}
