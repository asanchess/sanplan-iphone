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
public struct RegisteredAlarmRecord: Codable, Equatable {
    public let uuidString: String
    public let planId: String
    public let title: String
    public let fireDate: Date
    public let offsetMinutes: Int
    public let createdAt: Date

    public init(uuidString: String, planId: String, title: String, fireDate: Date, offsetMinutes: Int, createdAt: Date) {
        self.uuidString = uuidString
        self.planId = planId
        self.title = title
        self.fireDate = fireDate
        self.offsetMinutes = offsetMinutes
        self.createdAt = createdAt
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

/// Главный координатор системных будильников AlarmKit в SanPlan.
@MainActor
public final class AlarmCoordinator: ObservableObject {
    @Published public private(set) var isAuthorized: Bool = false
    @Published public private(set) var authorizationStatusText: String = "Не запрошено"
    @Published public private(set) var lastSyncDate: Date? = nil
    @Published public private(set) var activeAlarmCount: Int = 0
    @Published public private(set) var syncErrors: [String] = []
    @Published public private(set) var syncWarnings: [String] = []
    @Published public private(set) var statusMessage: String = "Готов к работе"
    @Published public private(set) var isSyncing: Bool = false

    private let registryKey = "SanPlan_AlarmRegistry_Storage"
    private let optInKey = "SanPlan_UserOptedIn_Flag"
    private let accountOriginValue = "SanPlan-Origin-iOS26"

    public var hasUserOptedIn: Bool {
        get { UserDefaults.standard.bool(forKey: optInKey) }
        set { UserDefaults.standard.set(newValue, forKey: optInKey) }
    }

    public init() {
        checkAuthorization()
        loadActiveCount()
    }

    public func checkAuthorization() {
        let state = AlarmManager.shared.authorizationState
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

    /// Запрос системного разрешения на работу с будильниками только по прямому действию пользователя.
    public func requestAuthorization() async {
        do {
            _ = try await AlarmManager.shared.requestAuthorization()
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

    /// Синхронизирует системные будильники на основе загруженных планов.
    /// Сохраняет существующие будильники в случае сетевого сбоя или ошибки парсинга.
    public func syncAlarms(plans: [NativePlan]) async {
        guard !isSyncing else { return }
        checkAuthorization()
        guard isAuthorized else {
            statusMessage = "Требуется разрешение на будильники. Нажмите «Разрешить будильники»."
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        let planResult = NativePlanPlanner.planAlarms(plans: plans, referenceDate: Date(), maxCap: 50)
        let desiredAlarms = planResult.scheduledAlarms
        let currentWarnings = planResult.warnings
        var currentErrors: [String] = []

        var registry = loadRegistry()
        let currentRecords = registry.records
        let desiredMap = Dictionary(uniqueKeysWithValues: desiredAlarms.map { ($0.id, $0) })

        let currentUUIDs = Set(currentRecords.keys)
        let desiredUUIDs = Set(desiredAlarms.map { $0.id.uuidString })

        let newUUIDs = desiredUUIDs.subtracting(currentUUIDs)
        let existingUUIDs = desiredUUIDs.intersection(currentUUIDs)
        let staleUUIDs = currentUUIDs.subtracting(desiredUUIDs)

        // Шаг 1: Добавляем новые будильники первыми
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
                    createdAt: Date()
                )
            } catch {
                currentErrors.append("Ошибка планирования «\(alarm.planTitle)»: \(error.localizedDescription)")
            }
        }

        // Шаг 2: Обновляем изменившиеся заголовки (отмена и пересоздание)
        for uuidString in existingUUIDs {
            guard let alarm = desiredMap[UUID(uuidString: uuidString)!],
                  let existing = currentRecords[uuidString] else { continue }

            if existing.title != alarm.planTitle {
                do {
                    try await AlarmManager.shared.cancel(id: alarm.id)
                    // A successfully cancelled alarm must be retried as new if scheduling fails.
                    registry.records.removeValue(forKey: uuidString)
                    saveRegistry(registry)
                    try await scheduleAlarmKitEntry(alarm: alarm)
                    registry.records[uuidString] = RegisteredAlarmRecord(
                        uuidString: alarm.id.uuidString,
                        planId: alarm.planId,
                        title: alarm.planTitle,
                        fireDate: alarm.alarmDate,
                        offsetMinutes: alarm.offsetMinutes,
                        createdAt: existing.createdAt
                    )
                } catch {
                    currentErrors.append("Ошибка обновления «\(alarm.planTitle)»: \(error.localizedDescription)")
                }
            }
        }

        // Шаг 3: Удаление устаревших/выполненных планов
        for staleString in staleUUIDs {
            guard let staleUUID = UUID(uuidString: staleString) else {
                registry.records.removeValue(forKey: staleString)
                continue
            }
            do {
                try await AlarmManager.shared.cancel(id: staleUUID)
                registry.records.removeValue(forKey: staleString)
            } catch {
                // При ошибке отмены запись сохраняется в реестре для повторной попытки
                currentErrors.append("Не удалось снять устаревший будильник (id: \(staleString)). Будет повторено при следующей синхронизации.")
            }
        }

        saveRegistry(registry)
        activeAlarmCount = registry.records.count
        lastSyncDate = Date()
        syncWarnings = currentWarnings
        syncErrors = currentErrors

        if currentErrors.isEmpty {
            statusMessage = "Синхронизация завершена: активно \(activeAlarmCount) будильников SanPlan."
        } else {
            statusMessage = "Синхронизация завершена с ошибками (\(currentErrors.count)). Проверьте отчет."
        }
    }

    /// Установка реального тестового будильника ровно через 1 минуту для проверки на экране блокировки.
    public func scheduleTestAlarmInOneMinute() async {
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
            title: LocalizedStringResource(stringLiteral: "Тестовый будильник SanPlan"),
            stopButton: AlarmButton(text: "Закрыть", textColor: .white, systemImageName: "stop.circle")
        )
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alertPresentation),
            metadata: metadata,
            tintColor: .purple
        )
        let configuration = AlarmManager.AlarmConfiguration<SanPlanAlarmMetadata>.alarm(schedule: .fixed(fireDate), attributes: attributes, sound: .default)

        do {
            try await AlarmManager.shared.schedule(id: testId, configuration: configuration)
            var registry = loadRegistry()
            registry.records[testId.uuidString] = RegisteredAlarmRecord(
                uuidString: testId.uuidString,
                planId: "sanplan-test-single",
                title: "Тестовый будильник SanPlan",
                fireDate: fireDate,
                offsetMinutes: 0,
                createdAt: Date()
            )
            saveRegistry(registry)
            activeAlarmCount = registry.records.count
            statusMessage = "Тестовый будильник установлен на 1 минуту вперед! Заблокируйте телефон для проверки."
        } catch {
            statusMessage = "Не удалось установить тестовый будильник: \(error.localizedDescription)"
        }
    }

    /// Удаляет ИСКЛЮЧИТЕЛЬНО зарегистрированные будильники SanPlan, не затрагивая личные будильники пользователя.
    public func deleteAllOwnAlarms() async {
        var registry = loadRegistry()
        var failedList: [String] = []

        for (uuidStr, _) in registry.records {
            guard let uuid = UUID(uuidString: uuidStr) else {
                registry.records.removeValue(forKey: uuidStr)
                continue
            }
            do {
                try await AlarmManager.shared.cancel(id: uuid)
                registry.records.removeValue(forKey: uuidStr)
            } catch {
                failedList.append(uuidStr)
            }
        }

        saveRegistry(registry)
        activeAlarmCount = registry.records.count

        if failedList.isEmpty {
            statusMessage = "Все будильники SanPlan успешно удалены."
            syncErrors.removeAll()
        } else {
            statusMessage = "Не удалось удалить \(failedList.count) будильников. Они будут повторены при следующей очистке."
        }
    }

    public func reportFetchError(_ description: String) {
        statusMessage = "Сбой загрузки планов: \(description). Существующие будильники сохранены."
        syncErrors = ["Ошибка связи с веб-шлюзом: \(description)"]
    }

    private func scheduleAlarmKitEntry(alarm: PlannedAlarm) async throws {
        let alertPresentation = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: alarm.planTitle),
            stopButton: AlarmButton(text: "Закрыть", textColor: .white, systemImageName: "stop.circle")
        )
        let metadata = SanPlanAlarmMetadata(
            planId: alarm.planId,
            title: alarm.planTitle,
            targetDate: alarm.alarmDate,
            offsetMinutes: alarm.offsetMinutes
        )
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alertPresentation),
            metadata: metadata,
            tintColor: .purple
        )
        let configuration = AlarmManager.AlarmConfiguration<SanPlanAlarmMetadata>.alarm(schedule: .fixed(alarm.alarmDate), attributes: attributes, sound: .default)
        try await AlarmManager.shared.schedule(id: alarm.id, configuration: configuration)
    }

    private func loadRegistry() -> AlarmRegistryData {
        guard let data = UserDefaults.standard.data(forKey: registryKey) else {
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
            UserDefaults.standard.set(data, forKey: registryKey)
        } catch {
            print("Failed to save alarm registry: \(error)")
        }
    }

    private func loadActiveCount() {
        let registry = loadRegistry()
        activeAlarmCount = registry.records.count
    }
}
