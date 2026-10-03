import XCTest
import AlarmKit
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

// MARK: - Тестовый двойник сервиса AlarmKit для XCTest

final class FakeAlarmService: AlarmServiceProtocol, @unchecked Sendable {
    var authState: AlarmManager.AuthorizationState = .authorized
    var systemIDs: Set<UUID> = []
    var scheduledConfigurations: [UUID: AlarmManager.AlarmConfiguration<SanPlanAlarmMetadata>] = [:]

    var shouldFailEnumeration: Bool = false
    var shouldFailSchedulingForID: UUID? = nil
    var cancelErrorForID: [UUID: Error] = [:]
    var cancelCallCount: [UUID: Int] = [:]
    var scheduleCallCount: [UUID: Int] = [:]
    var removeOnCancelError: Set<UUID> = []

    var authorizationState: AlarmManager.AuthorizationState {
        authState
    }

    func requestAuthorization() async throws {
        authState = .authorized
    }

    func fetchSystemAlarmIDs() async throws -> Set<UUID> {
        if shouldFailEnumeration {
            throw NSError(domain: "SanPlanTest", code: 500, userInfo: [NSLocalizedDescriptionKey: "System enumeration snapshot failed"])
        }
        return systemIDs
    }

    func schedule(id: UUID, configuration: AlarmManager.AlarmConfiguration<SanPlanAlarmMetadata>) async throws {
        scheduleCallCount[id, default: 0] += 1
        if let failID = shouldFailSchedulingForID, failID == id {
            throw NSError(domain: "SanPlanTest", code: 501, userInfo: [NSLocalizedDescriptionKey: "Scheduling failed for \(id)"])
        }
        scheduledConfigurations[id] = configuration
        systemIDs.insert(id)
    }

    func cancel(id: UUID) async throws {
        cancelCallCount[id, default: 0] += 1
        if let error = cancelErrorForID[id] {
            if removeOnCancelError.contains(id) { systemIDs.remove(id) }
            throw error
        }
        systemIDs.remove(id)
    }
}

// MARK: - Тесты сверки и надежности координатора AlarmCoordinator

@MainActor
final class AlarmCoordinatorReconciliationTests: XCTestCase {

    private func createTestDefaults() -> (UserDefaults, String) {
        let suiteName = "SanPlanTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    private func makeFuturePlan(id: String, title: String, secondsFromNow: TimeInterval, offset: Int = 0) -> NativePlan {
        let target = Date().addingTimeInterval(secondsFromNow)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let dateStr = formatter.string(from: target)
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: target)

        return NativePlan(
            id: id,
            title: title,
            date: dateStr,
            time: timeStr,
            reminderOffsets: [offset],
            timeZone: "UTC"
        )
    }

    // 1. Очистка сработавших / удаленных демоном будильников без генерации ошибок
    func testStoppedMissingStaleCleanup() async {
        let (defaults, suite) = createTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let fakeService = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: fakeService, userDefaults: defaults)

        // Планируем будущий будильник
        let plan = makeFuturePlan(id: "plan-stale", title: "Зарядка", secondsFromNow: 7200, offset: 0)
        await coordinator.syncAlarms(plans: [plan])
        XCTAssertEqual(coordinator.activeAlarmCount, 1)

        let alarmID = fakeService.systemIDs.first!

        // Имитируем, что демон системы удалил будильник после звонка
        fakeService.removeOnCancelError.insert(alarmID)

        // Запуск сверки с системой должен очистить реестр без ошибок
        await coordinator.reconcileWithSystem()
        XCTAssertEqual(coordinator.activeAlarmCount, 0)
        XCTAssertTrue(coordinator.syncErrors.isEmpty)
    }

    // 2. Ошибка отмены будильника, если он всё ещё существует в системе: запись сохраняется и выводится понятная ошибка
    func testCancellationStillPresentFailurePreservesAndReports() async {
        let (defaults, suite) = createTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let fakeService = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: fakeService, userDefaults: defaults)

        let plan = makeFuturePlan(id: "plan-cancel-fail", title: "Совещание", secondsFromNow: 3600, offset: 10)
        await coordinator.syncAlarms(plans: [plan])
        XCTAssertEqual(coordinator.activeAlarmCount, 1)

        let alarmID = fakeService.systemIDs.first!
        fakeService.cancelErrorForID[alarmID] = NSError(domain: "AlarmKit", code: 403, userInfo: [NSLocalizedDescriptionKey: "Daemon denied cancel"])

        // Синхронизируем с пустым списком планов (будильник стал устаревшим)
        await coordinator.syncAlarms(plans: [])

        // Будильник не удалось отменить, и он по-прежнему в системе: запись сохранена в реестре для повтора
        XCTAssertEqual(coordinator.activeAlarmCount, 1)
        XCTAssertFalse(coordinator.syncErrors.isEmpty)
        XCTAssertTrue(coordinator.syncErrors.first!.contains("Совещание"))
        XCTAssertFalse(coordinator.syncErrors.first!.contains(alarmID.uuidString), "В сообщении пользователю не должно быть сырых UUID")
    }

    // 3. Гонка отмены: cancel выбросил ошибку, но свежий снимок подтвердил отсутствие будильника -> запись удаляется
    func testCancellationRaceAbsentConfirmedRemoves() async {
        let (defaults, suite) = createTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let fakeService = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: fakeService, userDefaults: defaults)

        let plan = makeFuturePlan(id: "plan-race", title: "Поезд", secondsFromNow: 5000, offset: 15)
        await coordinator.syncAlarms(plans: [plan])
        XCTAssertEqual(coordinator.activeAlarmCount, 1)

        let alarmID = fakeService.systemIDs.first!
        // Имитируем ошибку "будильник не найден" от демона, и в системе его уже нет
        fakeService.cancelErrorForID[alarmID] = NSError(domain: "AlarmKit", code: 404, userInfo: [NSLocalizedDescriptionKey: "Alarm not found"])
        fakeService.systemIDs.remove(alarmID)

        await coordinator.syncAlarms(plans: [])

        // Свежий снимок подтвердил отсутствие: запись удалена из реестра, ошибки нет
        XCTAssertEqual(coordinator.activeAlarmCount, 0)
        XCTAssertTrue(coordinator.syncErrors.isEmpty)
    }

    // 4. Восстановление отсутствующих будущих будильников без дублирования
    func testMissingDesiredFutureRestoredWithoutDuplicates() async {
        let (defaults, suite) = createTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let fakeService = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: fakeService, userDefaults: defaults)

        let plan = makeFuturePlan(id: "plan-restore", title: "Вебинар", secondsFromNow: 10000, offset: 5)
        await coordinator.syncAlarms(plans: [plan])
        XCTAssertEqual(coordinator.activeAlarmCount, 1)

        // Внезапная очистка системных будильников (например, сброс настроек ОС)
        fakeService.systemIDs.removeAll()

        // Повторная синхронизация должна восстановить будущий сигнал
        await coordinator.syncAlarms(plans: [plan])
        XCTAssertEqual(coordinator.activeAlarmCount, 1)
        XCTAssertEqual(fakeService.systemIDs.count, 1)
        XCTAssertTrue(coordinator.syncErrors.isEmpty)
        await coordinator.syncAlarms(plans: [plan])
        XCTAssertEqual(fakeService.scheduleCallCount.values.reduce(0, +), 2, "Initial install plus one restoration, with no redundant scheduling")
    }

    // 5. Переименование задачи приводит к пересозданию будильника с новым названием
    func testPlanRenameReschedulesAlarm() async {
        let (defaults, suite) = createTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let fakeService = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: fakeService, userDefaults: defaults)

        let planOriginal = makeFuturePlan(id: "plan-rename", title: "Старое название", secondsFromNow: 4000, offset: 0)
        await coordinator.syncAlarms(plans: [planOriginal])
        XCTAssertEqual(coordinator.activeRecords.first?.title, "Старое название")

        let planRenamed = makeFuturePlan(id: "plan-rename", title: "Новое название", secondsFromNow: 4000, offset: 0)
        await coordinator.syncAlarms(plans: [planRenamed])

        XCTAssertEqual(coordinator.activeAlarmCount, 1)
        XCTAssertEqual(coordinator.activeRecords.first?.title, "Новое название")
    }

    // 6. Завершение задачи корректно снимает системный будильник
    func testRescheduleOrCompletedCleanup() async {
        let (defaults, suite) = createTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let fakeService = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: fakeService, userDefaults: defaults)

        let target = Date().addingTimeInterval(3000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let dateStr = formatter.string(from: target)
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: target)

        let activePlan = NativePlan(id: "task-done", title: "Сдать отчет", date: dateStr, time: timeStr, reminderOffsets: [0], timeZone: "UTC", completed: false)
        await coordinator.syncAlarms(plans: [activePlan])
        XCTAssertEqual(coordinator.activeAlarmCount, 1)

        let completedPlan = NativePlan(id: "task-done", title: "Сдать отчет", date: dateStr, time: timeStr, reminderOffsets: [0], timeZone: "UTC", completed: true)
        await coordinator.syncAlarms(plans: [completedPlan])

        XCTAssertEqual(coordinator.activeAlarmCount, 0)
        XCTAssertEqual(fakeService.systemIDs.count, 0)
    }

    // 7. Ошибка перечисления системы не очищает локальный реестр
    func testSystemEnumerationFailureRetainsRegistry() async {
        let (defaults, suite) = createTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let fakeService = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: fakeService, userDefaults: defaults)

        let plan = makeFuturePlan(id: "plan-retain", title: "Встреча", secondsFromNow: 6000, offset: 0)
        await coordinator.syncAlarms(plans: [plan])
        XCTAssertEqual(coordinator.activeAlarmCount, 1)

        fakeService.shouldFailEnumeration = true
        await coordinator.reconcileWithSystem()

        // Реестр должен быть полностью сохранен
        XCTAssertEqual(coordinator.activeAlarmCount, 1)
    }

    // 8. Проверка форматирования системного названия с названием, датой и смещением
    func testFormatSystemAlarmTitle() {
        let eventDate = Date(timeIntervalSince1970: 1792065600) // 2026-10-15 12:00:00 UTC
        let alarmDate = eventDate.addingTimeInterval(-900)
        let planned = PlannedAlarm(
            id: UUID(),
            planId: "p1",
            planTitle: "Командный синк",
            eventDate: eventDate,
            alarmDate: alarmDate,
            offsetMinutes: 15,
            timeZone: "UTC"
        )

        let formattedTitle = AlarmCoordinator.formatSystemAlarmTitle(alarm: planned)
        XCTAssertTrue(formattedTitle.contains("Командный синк"))
        XCTAssertTrue(formattedTitle.contains("15"))
        XCTAssertTrue(formattedTitle.contains("15 мин"))
    }

    func testDayHourAndEventOffsetsScheduleThreeExactSignalsAndCompleteTogether() async {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: service, userDefaults: defaults)
        let base = makeFuturePlan(id: "multiple", title: "Встреча", secondsFromNow: 172800)
        let plan = NativePlan(id: base.id, title: base.title, date: base.date, time: base.time,
                              reminderOffsets: [1440, 60, 0], timeZone: "UTC", completed: false)
        await coordinator.syncAlarms(plans: [plan])
        XCTAssertEqual(service.systemIDs.count, 3)
        for record in coordinator.activeRecords {
            XCTAssertEqual(record.resolvedEventDate.timeIntervalSince(record.fireDate), Double(record.offsetMinutes * 60), accuracy: 0.01)
        }
        await coordinator.syncAlarms(plans: [plan])
        XCTAssertEqual(service.scheduleCallCount.values.reduce(0, +), 3)
        let done = NativePlan(id: base.id, title: base.title, date: base.date, time: base.time,
                              reminderOffsets: [1440, 60, 0], timeZone: "UTC", completed: true)
        await coordinator.syncAlarms(plans: [done])
        XCTAssertTrue(service.systemIDs.isEmpty)
        XCTAssertTrue(coordinator.activeRecords.isEmpty)
    }

    func testTimeChangeRemovesOldAlarmAndSchedulesNewDate() async {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: service, userDefaults: defaults)
        let first = makeFuturePlan(id: "move", title: "Поезд", secondsFromNow: 3600)
        await coordinator.syncAlarms(plans: [first])
        let oldIDs = service.systemIDs
        let moved = makeFuturePlan(id: "move", title: "Поезд", secondsFromNow: 7200)
        await coordinator.syncAlarms(plans: [moved])
        XCTAssertEqual(service.systemIDs.count, 1)
        XCTAssertTrue(oldIDs.isDisjoint(with: service.systemIDs))
        XCTAssertEqual(coordinator.activeRecords.first?.resolvedEventDate, moved.resolveEventDate())
    }

    func testPendingMinuteCheckSurvivesPlanRefresh() async {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: service, userDefaults: defaults)
        await coordinator.scheduleTestAlarmInOneMinute()
        let IDs = service.systemIDs
        await coordinator.syncAlarms(plans: [])
        XCTAssertEqual(service.systemIDs, IDs)
        XCTAssertEqual(coordinator.activeAlarmCount, 1)
    }

    func testFetchFailurePreservesScheduledAlarms() async {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: service, userDefaults: defaults)
        await coordinator.syncAlarms(plans: [makeFuturePlan(id: "offline", title: "Отчёт", secondsFromNow: 3600)])
        let IDs = service.systemIDs
        coordinator.reportFetchError("Нет подключения")
        XCTAssertEqual(service.systemIDs, IDs)
        XCTAssertEqual(coordinator.activeAlarmCount, 1)
        XCTAssertFalse(coordinator.syncErrors.isEmpty)
    }
}
