import XCTest
@testable import SanPlan

final class NativePlanTests: XCTestCase {

    // MARK: - 1. Legacy Scalar Fallback

    func testLegacyScalarFallbackWhenOffsetsNil() {
        let plan = NativePlan(
            id: "plan-1",
            title: "Встреча",
            reminderMinutes: 15,
            reminderOffsets: nil
        )
        let offsets = plan.resolvedReminderOffsets()
        XCTAssertEqual(offsets, [15])
    }

    func testLegacyScalarOmittedYieldsEmptyOffsets() {
        let plan = NativePlan(
            id: "plan-2",
            title: "Без напоминания",
            reminderMinutes: nil,
            reminderOffsets: nil
        )
        let offsets = plan.resolvedReminderOffsets()
        XCTAssertEqual(offsets, [])
    }

    func testLegacyScalarZeroIsValid() {
        let plan = NativePlan(
            id: "plan-3",
            title: "Во время события",
            reminderMinutes: 0,
            reminderOffsets: nil
        )
        let offsets = plan.resolvedReminderOffsets()
        XCTAssertEqual(offsets, [0])
    }

    func testLegacyScalarNegativeIsIgnored() {
        let plan = NativePlan(
            id: "plan-4",
            title: "Ошибочное значение",
            reminderMinutes: -10,
            reminderOffsets: nil
        )
        let offsets = plan.resolvedReminderOffsets()
        XCTAssertEqual(offsets, [])
    }

    func testLegacyScalarExceedingMaxIsIgnored() {
        let plan = NativePlan(
            id: "plan-5",
            title: "Слишком далеко",
            reminderMinutes: 50000,
            reminderOffsets: nil
        )
        let offsets = plan.resolvedReminderOffsets()
        XCTAssertEqual(offsets, [])
    }

    // MARK: - 2. New Array Overrides Legacy Scalar

    func testNewArrayOverridesLegacyScalar() {
        let plan = NativePlan(
            id: "plan-6",
            title: "Переопределение скаляра",
            reminderMinutes: 30,
            reminderOffsets: [10, 20]
        )
        let offsets = plan.resolvedReminderOffsets()
        XCTAssertEqual(offsets, [10, 20])
    }

    func testExplicitEmptyArrayDisablesReminders() {
        let plan = NativePlan(
            id: "plan-7",
            title: "Отключено массивом",
            reminderMinutes: 15,
            reminderOffsets: []
        )
        let offsets = plan.resolvedReminderOffsets()
        XCTAssertEqual(offsets, [], "Пустой массив должен полностью отключать напоминания независимо от скаляра")
    }

    // MARK: - 3. Offsets Filtering, Deduplication & Max 5 Cap

    func testOffsetFilteringAndMaxFiveCap() {
        let plan = NativePlan(
            id: "plan-8",
            title: "Много смещений",
            reminderOffsets: [0, 5, 10, -1, 50000, 10, 15, 20, 25, 30]
        )
        let offsets = plan.resolvedReminderOffsets()
        // Валидные и уникальные: [0, 5, 10, 15, 20, 25, 30]
        // Ограничение max 5: первые 5
        XCTAssertEqual(offsets, [0, 5, 10, 15, 20])
        XCTAssertEqual(offsets.count, 5)
    }

    // MARK: - 4. Completed Plans Omission

    func testCompletedPlansProduceNoAlarms() {
        let futureDate = Date().addingTimeInterval(3600)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: futureDate)
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: futureDate)

        let completedPlan = NativePlan(
            id: "plan-completed",
            title: "Завершенная задача",
            date: dateStr,
            time: timeStr,
            reminderOffsets: [10],
            completed: true
        )

        let result = NativePlanPlanner.planAlarms(plans: [completedPlan], referenceDate: Date())
        XCTAssertEqual(result.scheduledAlarms.count, 0)
    }

    // MARK: - 5. Deterministic UUID Stability

    func testDeterministicUUIDIsStable() {
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let uuid1 = DeterministicAlarmID.generate(planId: "task-100", eventDate: fixedDate, offsetMinutes: 15)
        let uuid2 = DeterministicAlarmID.generate(planId: "task-100", eventDate: fixedDate, offsetMinutes: 15)
        XCTAssertEqual(uuid1, uuid2, "Одинаковые входные данные должны давать идентичный UUID")

        let uuidDifferentOffset = DeterministicAlarmID.generate(planId: "task-100", eventDate: fixedDate, offsetMinutes: 30)
        XCTAssertNotEqual(uuid1, uuidDifferentOffset, "Разные смещения должны давать разные UUID")

        let uuidDifferentId = DeterministicAlarmID.generate(planId: "task-101", eventDate: fixedDate, offsetMinutes: 15)
        XCTAssertNotEqual(uuid1, uuidDifferentId, "Разные ID планов должны давать разные UUID")
    }

    // MARK: - 6. TimeZone Validation

    func testValidAndInvalidTimeZone() {
        let planWithValidTz = NativePlan(
            id: "tz-valid",
            title: "Валидный часовой пояс",
            date: "2026-10-15",
            time: "10:00:00",
            timeZone: "Europe/Moscow"
        )
        XCTAssertNotNil(planWithValidTz.resolveEventDate())

        let planWithInvalidTz = NativePlan(
            id: "tz-invalid",
            title: "Невалидный часовой пояс",
            date: "2026-10-15",
            time: "10:00:00",
            timeZone: "Mars/Olympus_Mons"
        )
        XCTAssertNil(planWithInvalidTz.resolveEventDate(), "Несуществующий часовой пояс должен отклоняться")
    }

    // MARK: - 7. Google Schedule Priority

    func testGoogleSchedulePriority() {
        let schedule = NativeSchedule(
            date: nil,
            time: nil,
            dateTime: "2026-11-01T15:30:00Z",
            timeZone: nil
        )
        let plan = NativePlan(
            id: "plan-google",
            title: "Синхронизировано из Google",
            date: "2026-10-01",
            time: "08:00:00",
            googleSchedule: schedule
        )
        let resolvedDate = plan.resolveEventDate()
        XCTAssertNotNil(resolvedDate)

        let isoFormatter = ISO8601DateFormatter()
        let expectedDate = isoFormatter.date(from: "2026-11-01T15:30:00Z")
        XCTAssertEqual(resolvedDate, expectedDate)
    }

    // MARK: - 8. Max 50 Native Alarms Cap Policy

    func testMax50AlarmCapAndChronologicalSelection() {
        let baseDate = Date().addingTimeInterval(3600)
        var plans: [NativePlan] = []

        // Создаем 60 планов в будущем с шагом в 1 час
        for i in 1...60 {
            let eventTime = baseDate.addingTimeInterval(Double(i * 3600))
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let dStr = formatter.string(from: eventTime)
            formatter.dateFormat = "HH:mm:ss"
            let tStr = formatter.string(from: eventTime)

            plans.append(NativePlan(
                id: "plan-cap-\(i)",
                title: "План \(i)",
                date: dStr,
                time: tStr,
                reminderOffsets: [0],
                timeZone: "UTC"
            ))
        }

        let result = NativePlanPlanner.planAlarms(plans: plans, referenceDate: Date(), maxCap: 50)
        XCTAssertEqual(result.scheduledAlarms.count, 50, "Должно быть отобрано ровно 50 ближайших будильников")
        XCTAssertEqual(result.droppedAlarms.count, 10, "10 последующих будильников должны быть отложены")
        XCTAssertTrue(result.warnings.contains { $0.contains("50") }, "Должно присутствовать предупреждение о лимите")

        // Проверяем строгий хронологический порядок
        for i in 0..<result.scheduledAlarms.count - 1 {
            XCTAssertLessThanOrEqual(result.scheduledAlarms[i].alarmDate, result.scheduledAlarms[i + 1].alarmDate)
        }
    }

    // MARK: - 9. JSON Codable Decoding

    func testNativePlanJSONDecoding() throws {
        let json = """
        [
            {
                "id": "item-1",
                "kind": "task",
                "title": "Купить молоко",
                "date": "2026-10-20",
                "time": "18:00:00",
                "duration": 30,
                "reminderMinutes": 10,
                "reminderOffsets": [10, 30],
                "timeZone": "Europe/Moscow",
                "completed": false,
                "googleSchedule": {
                    "dateTime": "2026-10-20T15:00:00Z"
                }
            }
        ]
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([NativePlan].self, from: json)
        XCTAssertEqual(decoded.count, 1)
        let first = decoded[0]
        XCTAssertEqual(first.id, "item-1")
        XCTAssertEqual(first.title, "Купить молоко")
        XCTAssertEqual(first.resolvedReminderOffsets(), [10, 30])
        XCTAssertEqual(first.completed, false)
    }
}

extension NativePlanTests {
    func testMissingTimeDoesNotInventMorningAlarm() {
        let plan = NativePlan(id: "no-time", title: "Без времени", date: "2026-12-20", reminderMinutes: 0, timeZone: "Asia/Qyzylorda")
        XCTAssertNil(plan.resolveEventDate())
    }
    func testLinkedGoogleScheduleUsesItsOwnReminderOffsets() {
        let schedule = NativeSchedule(date: "2026-12-20", time: "12:00", timeZone: "Asia/Qyzylorda", reminderMinutes: 1440, reminderOffsets: [1440, 60, 10, 0])
        let plan = NativePlan(id: "linked", title: "Связанная задача", reminderMinutes: -1, googleSchedule: schedule)
        XCTAssertEqual(plan.resolvedReminderOffsets(), [1440, 60, 10, 0])
        XCTAssertNotNil(plan.resolveEventDate())
    }
}
