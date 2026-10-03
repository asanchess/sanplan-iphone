import Foundation
import Combine
import SwiftUI
import AlarmKit

/// Метаданные будильника SanPlan, сохраняемые системой AlarmKit.
public struct SanPlanAlarmMetadata: AlarmMetadata, Hashable {
    public let planId: String
    public let title: String
    public let targetDate: Date
    public let offsetMinutes: Int

    public init(planId: String, title: String, targetDate: Date, offsetMinutes: Int) {
        self.planId = planId
        self.title = title
        self.targetDate = targetDate
        self.offsetMinutes = offsetMinutes
    }
}

/// Запись локального реестра установленных приложением будильников.
public struct RegisteredAlarmRecord: Codable, Equatable, Identifiable {
    public var id: String { uuidString }
    public let uuidString: String
    public let planId: String
    public let title: String
    public let fireDate: Date
    public let offsetMinutes: Int
    public let createdAt: Date
    public let eventDate: Date?
    public let timeZone: String?

    public init(
        uuidString: String,
        planId: String,
        title: String,
        fireDate: Date,
        offsetMinutes: Int,
        createdAt: Date,
        eventDate: Date? = nil,
        timeZone: String? = nil
    ) {
        self.uuidString = uuidString
        self.planId = planId
        self.title = title
        self.fireDate = fireDate
        self.offsetMinutes = offsetMinutes
        self.createdAt = createdAt
        self.eventDate = eventDate
        self.timeZone = timeZone
    }

    public init(uuidString: String, planId: String, title: String, fireDate: Date, offsetMinutes: Int, createdAt: Date) {
        self.init(
            uuidString: uuidString,
            planId: planId,
            title: title,
            fireDate: fireDate,
            offsetMinutes: offsetMinutes,
            createdAt: createdAt,
            eventDate: nil,
            timeZone: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case uuidString, planId, title, fireDate, offsetMinutes, createdAt, eventDate, timeZone
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuidString = try container.decode(String.self, forKey: .uuidString)
        planId = try container.decode(String.self, forKey: .planId)
        title = try container.decode(String.self, forKey: .title)
        fireDate = try container.decode(Date.self, forKey: .fireDate)
        offsetMinutes = try container.decode(Int.self, forKey: .offsetMinutes)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        eventDate = try container.decodeIfPresent(Date.self, forKey: .eventDate)
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuidString, forKey: .uuidString)
        try container.encode(planId, forKey: .planId)
        try container.encode(title, forKey: .title)
        try container.encode(fireDate, forKey: .fireDate)
        try container.encode(offsetMinutes, forKey: .offsetMinutes)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(eventDate, forKey: .eventDate)
        try container.encodeIfPresent(timeZone, forKey: .timeZone)
    }

    /// Дата исходного события: из сохраненного поля либо расчет fireDate + offsetMinutes.
    public var resolvedEventDate: Date {
        if let eventDate = eventDate {
            return eventDate
        }
        return fireDate.addingTimeInterval(Double(offsetMinutes * 60))
    }
}

/// Структура постоянного реестра происхождения аккаунта в UserDefaults.
public struct AlarmRegistryData: Codable {
    public var accountOrigin: String
    public var records: [String: RegisteredAlarmRecord]

    public init(accountOrigin: String, records: [String: RegisteredAlarmRecord] = [:]) {
        self.accountOrigin = accountOrigin
        self.records = records
    }
}

/// Протокол системных операций AlarmKit для надежного тестирования через инъекцию.
public protocol AlarmServiceProtocol: AnyObject, Sendable {
    var authorizationState: AlarmManager.AuthorizationState { get }
    func requestAuthorization() async throws
    func fetchSystemAlarmIDs() async throws -> Set<UUID>
    func schedule(id: UUID, configuration: AlarmManager.AlarmConfiguration<SanPlanAlarmMetadata>) async throws
    func cancel(id: UUID) async throws
}

/// Реализация системных операций AlarmKit для реального устройства iOS 26+.
public final class LiveAlarmService: AlarmServiceProtocol, @unchecked Sendable {
    public init() {}

    public var authorizationState: AlarmManager.AuthorizationState {
        AlarmManager.shared.authorizationState
    }

    public func requestAuthorization() async throws {
        _ = try await AlarmManager.shared.requestAuthorization()
    }

    public func fetchSystemAlarmIDs() async throws -> Set<UUID> {
        let alarms = try AlarmManager.shared.alarms
        return Set(alarms.map { $0.id })
    }

    public func schedule(id: UUID, configuration: AlarmManager.AlarmConfiguration<SanPlanAlarmMetadata>) async throws {
        try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }

    public func cancel(id: UUID) async throws {
        try await AlarmManager.shared.cancel(id: id)
    }
}

/// Главный координатор системных будильников AlarmKit в SanPlan с надежной сверкой снимков.
@MainActor
public final class AlarmCoordinator: ObservableObject {
    @Published public private(set) var isAuthorized: Bool = false
    @Published public private(set) var authorizationStatusText: String = "Не запрошено"
    @Published public private(set) var lastSyncDate: Date? = nil
    @Published public private(set) var activeAlarmCount: Int = 0
    @Published public private(set) var activeRecords: [RegisteredAlarmRecord] = []
    @Published public private(set) var syncErrors: [String] = []
    @Published public private(set) var syncWarnings: [String] = []
    @Published public private(set) var statusMessage: String = "Готов к работе"
    @Published public private(set) var isSyncing: Bool = false
    @Published public private(set) var systemStateConfirmed: Bool = false

    private let registryKey = "SanPlan_AlarmRegistry_Storage"
    private let optInKey = "SanPlan_UserOptedIn_Flag"
    private let accountOriginValue = "SanPlan-Origin-iOS26"

    private let service: AlarmServiceProtocol
    private let userDefaults: UserDefaults

    private var needsResync: Bool = false
    private var queuedPlans: [NativePlan]? = nil
    private var observationTask: Task<Void, Never>?

    public var hasUserOptedIn: Bool {
        get { userDefaults.bool(forKey: optInKey) }
        set { userDefaults.set(newValue, forKey: optInKey) }
    }

    public init(service: AlarmServiceProtocol = LiveAlarmService(), userDefaults: UserDefaults = .standard) {
        self.service = service
        self.userDefaults = userDefaults
        checkAuthorization()
        loadActiveCount()
        if service is LiveAlarmService {
            observationTask = Task { [weak self] in
                for await _ in AlarmManager.shared.alarmUpdates {
                    guard !Task.isCancelled, let self else { break }
                    await self.reconcileWithSystem()
                }
            }
        }
    }

    deinit { observationTask?.cancel() }

    public func checkAuthorization() {
        let state = service.authorizationState
        if state == .authorized {
            isAuthorized = true
            authorizationStatusText = "Разрешено"
        } else if state == .denied {
            isAuthorized = false
            authorizationStatusText = "Отклонено"
        } else {
            isAuthorized = false
            authorizationStatusText = "Не определено"
        }
    }

    /// Запрос системного разрешения на работу с будильниками по прямому действию пользователя.
    public func requestAuthorization() async {
        do {
            try await service.requestAuthorization()
            hasUserOptedIn = true
            checkAuthorization()
            if isAuthorized {
                statusMessage = "Доступ к AlarmKit успешно предоставлен"
            } else {
                statusMessage = "В доступе к AlarmKit отказано пользователем"
            }
        } catch {
            statusMessage = "Ошибка авторизации AlarmKit: \(error.localizedDescription)"
        }
    }

    /// Сверка локального реестра с живым системным состоянием AlarmManager.shared.
    /// Официальный контракт Apple: сработавшие/отключенные однократные будильники удаляются системным демоном.
    /// Отсутствие известного будильника в системе не является ошибкой — запись удаляется из реестра.
    public func reconcileWithSystem() async {
        guard !isSyncing else { return }
        checkAuthorization()
        guard isAuthorized else { return }
        isSyncing = true
        defer { finishOperation() }

        do {
            let systemIDs = try await service.fetchSystemAlarmIDs()
            systemStateConfirmed = true
            var registry = loadRegistry()
            var changed = false

            for (uuidStr, _) in registry.records {
                if let uuid = UUID(uuidString: uuidStr), !systemIDs.contains(uuid) {
                    registry.records.removeValue(forKey: uuidStr)
                    changed = true
                }
            }

            if changed {
                saveRegistry(registry)
                updatePublishedState(from: registry)
            }
        } catch {
            systemStateConfirmed = false
            // Ошибка перечисления системных будильников ни при каких обстоятельствах не очищает реестр
        }
    }

    /// Синхронизирует системные будильники на основе загруженных планов с коалесценцией наложений.
    public func syncAlarms(plans: [NativePlan]) async {
        if isSyncing {
            needsResync = true
            queuedPlans = plans
            return
        }

        checkAuthorization()
        guard isAuthorized else {
            statusMessage = "Требуется разрешение на будильники. Нажмите «Разрешить доступ»."
            return
        }

        isSyncing = true
        defer { finishOperation() }

        let planResult = NativePlanPlanner.planAlarms(plans: plans, referenceDate: Date(), maxCap: 50)
        let desiredAlarms = planResult.scheduledAlarms
        var currentWarnings = planResult.warnings
        var currentErrors: [String] = []

        var registry = loadRegistry()

        // 1. Получаем снимок системных будильников для сверки
        let systemSnapshot: Set<UUID>?
        do {
            systemSnapshot = try await service.fetchSystemAlarmIDs()
            systemStateConfirmed = true
        } catch {
            systemSnapshot = nil
            systemStateConfirmed = false
            // Сбой перечисления НЕ должен очищать локальный реестр
            currentWarnings.append("Не удалось получить снимок системы AlarmKit: \(error.localizedDescription). Существующий реестр сохранен.")
        }

        // 2. Если снимок получен, очищаем записи, которые уже отработали или были удалены из системы
        if let systemIDs = systemSnapshot {
            for (uuidStr, _) in registry.records {
                guard let uuid = UUID(uuidString: uuidStr) else {
                    registry.records.removeValue(forKey: uuidStr)
                    continue
                }
                if !systemIDs.contains(uuid) {
                    // Будильник уже отсутствует в системе (штатное завершение). Удаляем запись без ошибки.
                    registry.records.removeValue(forKey: uuidStr)
                }
            }
        }

        let currentRecords = registry.records
        let desiredMap = Dictionary(uniqueKeysWithValues: desiredAlarms.map { ($0.id, $0) })
        let currentUUIDs = Set(currentRecords.keys)
        let desiredUUIDs = Set(desiredAlarms.map { $0.id.uuidString })

        let newUUIDs = desiredUUIDs.subtracting(currentUUIDs)
        let existingUUIDs = desiredUUIDs.intersection(currentUUIDs)
        let pendingTestUUIDs = Set(currentRecords.values.filter {
            $0.planId == "sanplan-test-single" && $0.fireDate > Date()
        }.map { $0.uuidString })
        let staleUUIDs = currentUUIDs.subtracting(desiredUUIDs).subtracting(pendingTestUUIDs)

        // 3. Планирование новых или восстановление отсутствующих будущих будильников
        for uuidString in newUUIDs {
            guard let alarm = desiredMap[UUID(uuidString: uuidString)!] else { continue }
            do {
                try await scheduleAlarmKitEntry(alarm: alarm)
                registry.records[uuidString] = RegisteredAlarmRecord(
                    uuidString: alarm.id.uuidString,
                    planId: alarm.planId,
                    title: alarm.planTitle,
                    fireDate: alarm.alarmDate,
                    offsetMinutes: alarm.offsetMinutes,
                    createdAt: Date(),
                    eventDate: alarm.eventDate,
                    timeZone: alarm.timeZone
                )
            } catch {
                currentErrors.append("Ошибка планирования «\(alarm.planTitle)»: \(error.localizedDescription)")
            }
        }

        // 4. Обновление изменившихся будильников (переименование)
        for uuidString in existingUUIDs {
            guard let alarm = desiredMap[UUID(uuidString: uuidString)!],
                  let existing = currentRecords[uuidString] else { continue }

            if existing.title != alarm.planTitle || existing.eventDate == nil || existing.timeZone != alarm.timeZone {
                guard let alarmUUID = UUID(uuidString: uuidString) else { continue }
                do {
                    try await service.cancel(id: alarmUUID)
                    registry.records.removeValue(forKey: uuidString)
                    try await scheduleAlarmKitEntry(alarm: alarm)
                    registry.records[uuidString] = RegisteredAlarmRecord(
                        uuidString: alarm.id.uuidString,
                        planId: alarm.planId,
                        title: alarm.planTitle,
                        fireDate: alarm.alarmDate,
                        offsetMinutes: alarm.offsetMinutes,
                        createdAt: existing.createdAt,
                        eventDate: alarm.eventDate,
                        timeZone: alarm.timeZone
                    )
                } catch {
                    currentErrors.append("Ошибка обновления «\(alarm.planTitle)»: \(error.localizedDescription)")
                }
            }
        }

        // 5. Удаление устаревших / выполненных будильников
        for staleString in staleUUIDs {
            guard let staleUUID = UUID(uuidString: staleString) else {
                registry.records.removeValue(forKey: staleString)
                continue
            }
            let staleTitle = currentRecords[staleString]?.title ?? "Будильник"
            do {
                try await service.cancel(id: staleUUID)
                registry.records.removeValue(forKey: staleString)
            } catch {
                // Если отмена выбросила ошибку, проверяем свежим системным снимком:
                // Если подтверждено отсутствие -> удаляем запись из реестра (штатный случай, ошибки нет).
                // Если всё ещё существует или снимок не удался -> сохраняем запись и сообщаем понятную ошибку.
                do {
                    let freshSnapshot = try await service.fetchSystemAlarmIDs()
                    if !freshSnapshot.contains(staleUUID) {
                        registry.records.removeValue(forKey: staleString)
                    } else {
                        currentErrors.append("Не удалось отменить «\(staleTitle)»: \(error.localizedDescription)")
                    }
                } catch {
                    currentErrors.append("Не удалось отменить «\(staleTitle)» (проверка системы не удалась): \(error.localizedDescription)")
                }
            }
        }

        saveRegistry(registry)
        updatePublishedState(from: registry)
        lastSyncDate = Date()
        syncWarnings = currentWarnings
        syncErrors = currentErrors

        if currentErrors.isEmpty {
            statusMessage = "Синхронизация завершена: активно \(activeAlarmCount) будильников SanPlan."
        } else {
            statusMessage = "Синхронизация завершена с замечаниями (\(currentErrors.count)). Проверьте отчет."
        }
    }

    /// Установка тестового будильника через 1 минуту (доступна только в свернутой диагностике).
    public func scheduleTestAlarmInOneMinute() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { finishOperation() }
        checkAuthorization()
        guard isAuthorized else {
            statusMessage = "Для тестового будильника требуется разрешение."
            return
        }

        let fireDate = Date().addingTimeInterval(60)
        let testId = UUID()
        let metadata = SanPlanAlarmMetadata(
            planId: "sanplan-test-single",
            title: "Тестовый будильник SanPlan",
            targetDate: fireDate,
            offsetMinutes: 0
        )

        let alertPresentation = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: "Тестовый будильник SanPlan — проверка экрана блокировки"),
            stopButton: AlarmButton(text: "Закрыть", textColor: .white, systemImageName: "stop.circle")
        )
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alertPresentation),
            metadata: metadata,
            tintColor: Color(red: 0.10, green: 0.28, blue: 0.60)
        )
        let configuration = AlarmManager.AlarmConfiguration<SanPlanAlarmMetadata>.alarm(
            schedule: .fixed(fireDate),
            attributes: attributes,
            sound: .default
        )

        do {
            try await service.schedule(id: testId, configuration: configuration)
            var registry = loadRegistry()
            registry.records[testId.uuidString] = RegisteredAlarmRecord(
                uuidString: testId.uuidString,
                planId: "sanplan-test-single",
                title: "Тестовый будильник SanPlan",
                fireDate: fireDate,
                offsetMinutes: 0,
                createdAt: Date(),
                eventDate: fireDate,
                timeZone: TimeZone.current.identifier
            )
            saveRegistry(registry)
            updatePublishedState(from: registry)
            statusMessage = "Тестовый будильник установлен на 1 минуту вперед. Заблокируйте телефон для проверки."
        } catch {
            statusMessage = "Не удалось установить тестовый будильник: \(error.localizedDescription)"
        }
    }

    /// Удаляет ИСКЛЮЧИТЕЛЬНО зарегистрированные будильники SanPlan, не затрагивая личные будильники пользователя.
    public func deleteAllOwnAlarms() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { finishOperation() }
        var registry = loadRegistry()
        var failedList: [String] = []

        for (uuidStr, record) in registry.records {
            guard let uuid = UUID(uuidString: uuidStr) else {
                registry.records.removeValue(forKey: uuidStr)
                continue
            }
            do {
                try await service.cancel(id: uuid)
                registry.records.removeValue(forKey: uuidStr)
            } catch {
                do {
                    let freshSnapshot = try await service.fetchSystemAlarmIDs()
                    if !freshSnapshot.contains(uuid) {
                        registry.records.removeValue(forKey: uuidStr)
                    } else {
                        failedList.append(record.title)
                    }
                } catch {
                    failedList.append(record.title)
                }
            }
        }

        saveRegistry(registry)
        updatePublishedState(from: registry)

        if failedList.isEmpty {
            statusMessage = "Все будильники SanPlan успешно удалены."
            syncErrors.removeAll()
        } else {
            statusMessage = "Не удалось отменить: \(failedList.joined(separator: ", ")). Они будут повторены при следующей очистке."
            syncErrors = ["Не удалось отменить будильники: \(failedList.joined(separator: ", "))"]
        }
    }

    public func reportFetchError(_ description: String) {
        statusMessage = "Сбой загрузки планов: \(description). Существующие будильники сохранены."
        syncErrors = ["Ошибка связи с веб-шлюзом: \(description)"]
    }

    private func finishOperation() {
        isSyncing = false
        if needsResync, let nextPlans = queuedPlans {
            needsResync = false
            queuedPlans = nil
            Task { [weak self] in await self?.syncAlarms(plans: nextPlans) }
        }
    }

    /// Форматирует системное название будильника, включая название плана, дату/время события и смещение.
    public static func formatSystemAlarmTitle(alarm: PlannedAlarm) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        if let tzId = alarm.timeZone, let tz = TimeZone(identifier: tzId) {
            formatter.timeZone = tz
        } else {
            formatter.timeZone = .current
        }
        formatter.dateFormat = "d MMM, HH:mm"
        let dateStr = formatter.string(from: alarm.eventDate)

        let offsetStr: String
        if alarm.offsetMinutes == 0 {
            offsetStr = "в момент события"
        } else if alarm.offsetMinutes == 60 {
            offsetStr = "за 1 час"
        } else if alarm.offsetMinutes == 1440 {
            offsetStr = "за 1 день"
        } else if alarm.offsetMinutes % 1440 == 0 {
            offsetStr = "за \(alarm.offsetMinutes / 1440) дн."
        } else if alarm.offsetMinutes % 60 == 0 {
            offsetStr = "за \(alarm.offsetMinutes / 60) ч."
        } else {
            offsetStr = "за \(alarm.offsetMinutes) мин."
        }

        return "\(alarm.planTitle) — \(dateStr) (\(offsetStr))"
    }

    private func scheduleAlarmKitEntry(alarm: PlannedAlarm) async throws {
        let systemTitle = Self.formatSystemAlarmTitle(alarm: alarm)

        let alertPresentation = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: systemTitle),
            stopButton: AlarmButton(text: "Закрыть", textColor: .white, systemImageName: "stop.circle")
        )
        let metadata = SanPlanAlarmMetadata(
            planId: alarm.planId,
            title: alarm.planTitle,
            targetDate: alarm.eventDate, // targetDate хранит точную дату события, а не время срабатывания
            offsetMinutes: alarm.offsetMinutes
        )
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alertPresentation),
            metadata: metadata,
            tintColor: Color(red: 0.10, green: 0.28, blue: 0.60)
        )
        let configuration = AlarmManager.AlarmConfiguration<SanPlanAlarmMetadata>.alarm(
            schedule: .fixed(alarm.alarmDate),
            attributes: attributes,
            sound: .default
        )
        try await service.schedule(id: alarm.id, configuration: configuration)
    }

    private func loadRegistry() -> AlarmRegistryData {
        guard let data = userDefaults.data(forKey: registryKey) else {
            return AlarmRegistryData(accountOrigin: accountOriginValue)
        }
        do {
            return try JSONDecoder().decode(AlarmRegistryData.self, from: data)
        } catch {
            return AlarmRegistryData(accountOrigin: accountOriginValue)
        }
    }

    private func saveRegistry(_ registry: AlarmRegistryData) {
        do {
            let data = try JSONEncoder().encode(registry)
            userDefaults.set(data, forKey: registryKey)
        } catch {
            print("Failed to save alarm registry: \(error)")
        }
    }

    private func loadActiveCount() {
        let registry = loadRegistry()
        updatePublishedState(from: registry)
    }

    private func updatePublishedState(from registry: AlarmRegistryData) {
        let sorted = Array(registry.records.values).sorted { $0.fireDate < $1.fireDate }
        activeRecords = sorted
        activeAlarmCount = sorted.count
    }
}
