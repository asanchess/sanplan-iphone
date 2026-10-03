import Foundation
import CryptoKit

/// Структура расписания, синхронизированная со связанными задачами Google Schedule.
public struct NativeSchedule: Codable, Equatable, Hashable {
    public let date: String?
    public let time: String?
    public let dateTime: String?
    public let timeZone: String?
    public let reminderMinutes: Int?
    public let reminderOffsets: [Int]?

    public init(
        date: String? = nil,
        time: String? = nil,
        dateTime: String? = nil,
        timeZone: String? = nil,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil
    ) {
        self.date = date
        self.time = time
        self.dateTime = dateTime
        self.timeZone = timeZone
        self.reminderMinutes = reminderMinutes
        self.reminderOffsets = reminderOffsets
    }
}

/// Модель плана для нативного iOS-компаньона SanPlan.
public struct NativePlan: Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let kind: String?
    public let title: String
    public let date: String?
    public let time: String?
    public let duration: Int?
    public let reminderMinutes: Int?
    public let reminderOffsets: [Int]?
    public let timeZone: String?
    public let completed: Bool?
    public let googleSchedule: NativeSchedule?
    public let alarmSchedule: NativeSchedule?
    public let alarmDeleted: Bool?

    public init(
        id: String,
        kind: String? = nil,
        title: String,
        date: String? = nil,
        time: String? = nil,
        duration: Int? = nil,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        timeZone: String? = nil,
        completed: Bool? = nil,
        googleSchedule: NativeSchedule? = nil,
        alarmSchedule: NativeSchedule? = nil,
        alarmDeleted: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.date = date
        self.time = time
        self.duration = duration
        self.reminderMinutes = reminderMinutes
        self.reminderOffsets = reminderOffsets
        self.timeZone = timeZone
        self.completed = completed
        self.googleSchedule = googleSchedule
        self.alarmSchedule = alarmSchedule
        self.alarmDeleted = alarmDeleted
    }

    public var effectiveAlarmSchedule: NativeSchedule? { alarmSchedule ?? googleSchedule }

    /// Вычисляет актуальные смещения напоминаний (в минутах до события).
    /// Правила:
    /// - Новый массив `reminderOffsets` имеет приоритет над скалярным `reminderMinutes`.
    /// - Если `reminderOffsets` явно пуст `[]` — напоминания отключены.
    /// - Допустимый диапазон минут: от 0 до 40320 (максимум 28 дней).
    /// - Ограничение: максимум 5 валидных смещений.
    /// - Если `reminderOffsets == nil` — выполняется fallback на скалярное значение `reminderMinutes`.
    public func resolvedReminderOffsets() -> [Int] {
        if alarmDeleted == true { return [] }
        let schedule = effectiveAlarmSchedule
        // An explicit alarm override owns its reminders; never inherit the original plan's signals.
        let offsets = alarmSchedule != nil ? schedule?.reminderOffsets : schedule?.reminderOffsets ?? reminderOffsets
        if let explicitOffsets = offsets {
            if explicitOffsets.isEmpty {
                return []
            }
            var uniqueValidOffsets: [Int] = []
            for offset in explicitOffsets {
                if offset >= 0 && offset <= 40320 {
                    if !uniqueValidOffsets.contains(offset) {
                        uniqueValidOffsets.append(offset)
                    }
                }
            }
            return Array(uniqueValidOffsets.prefix(5))
        }

        let scalar = alarmSchedule != nil ? schedule?.reminderMinutes : schedule?.reminderMinutes ?? reminderMinutes
        if let scalar {
            if scalar >= 0 && scalar <= 40320 {
                return [scalar]
            }
            return []
        }

        return []
    }

    /// Строго парсит дату и время события с учетом приоритета `googleSchedule` и валидации таймзоны.
    public func resolveEventDate() -> Date? {
        let schedule = effectiveAlarmSchedule
        // Приоритет: googleSchedule.dateTime (ISO8601)
        if let schedule, let dtString = schedule.dateTime, !dtString.isEmpty {
            if let date = Self.parseISO8601(dtString) {
                return date
            }
        }

        // Вторичный приоритет: комбинация date + time
        let datePart = schedule?.date ?? date
        guard let validDatePart = datePart, !validDatePart.isEmpty else {
            return nil
        }

        guard let timePart = schedule?.time ?? time, !timePart.isEmpty else { return nil }
        let tzIdentifier = schedule?.timeZone ?? timeZone

        guard let tzIdentifier, !tzIdentifier.isEmpty else { return nil }
        var timeZoneToUse: TimeZone = .current
        let tzId = tzIdentifier
        if !tzId.isEmpty {
            guard let resolvedTz = TimeZone(identifier: tzId) else {
                // Невалидный идентификатор таймзоны приводит к отклонению для строгой валидации
                return nil
            }
            timeZoneToUse = resolvedTz
        }

        return Self.parseDateAndTime(dateString: validDatePart, timeString: timePart, timeZone: timeZoneToUse)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let formatterWithMillis = ISO8601DateFormatter()
        formatterWithMillis.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithMillis.date(from: string) {
            return date
        }

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        return standardFormatter.date(from: string)
    }

    private static func parseDateAndTime(dateString: String, timeString: String, timeZone: TimeZone) -> Date? {
        let cleanTime: String
        if timeString.count == 5 {
            cleanTime = timeString + ":00"
        } else {
            cleanTime = timeString
        }

        let combined = "\(dateString) \(cleanTime)"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.isLenient = false
        guard let parsed = formatter.date(from: combined), formatter.string(from: parsed) == combined else { return nil }
        return parsed
    }
}

/// Генератор детерминированных UUID для будильников SanPlan.
/// Гарантирует стабильный UUID на основе SHA256 (первые 16 байт) от `id + event datetime + offset`.
public enum DeterministicAlarmID {
    public static func generate(planId: String, eventDate: Date, offsetMinutes: Int) -> UUID {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let utcDateString = formatter.string(from: eventDate)

        let compositeKey = "\(planId)|\(utcDateString)|\(offsetMinutes)"
        let digest = SHA256.hash(data: Data(compositeKey.utf8))
        let bytes = Array(digest.prefix(16))

        let uuidTuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuidTuple)
    }
}

/// Запланированный кандидат будильника.
public struct PlannedAlarm: Identifiable, Equatable {
    public let id: UUID
    public let planId: String
    public let planTitle: String
    public let eventDate: Date
    public let alarmDate: Date
    public let offsetMinutes: Int
    public let timeZone: String?

    public init(
        id: UUID,
        planId: String,
        planTitle: String,
        eventDate: Date,
        alarmDate: Date,
        offsetMinutes: Int,
        timeZone: String? = nil
    ) {
        self.id = id
        self.planId = planId
        self.planTitle = planTitle
        self.eventDate = eventDate
        self.alarmDate = alarmDate
        self.offsetMinutes = offsetMinutes
        self.timeZone = timeZone
    }
}

/// Результат планирования будильников с отчетом об отсечении по лимиту приложения.
public struct AlarmPlanResult {
    public let scheduledAlarms: [PlannedAlarm]
    public let droppedAlarms: [PlannedAlarm]
    public let warnings: [String]

    public init(scheduledAlarms: [PlannedAlarm], droppedAlarms: [PlannedAlarm], warnings: [String]) {
        self.scheduledAlarms = scheduledAlarms
        self.droppedAlarms = droppedAlarms
        self.warnings = warnings
    }
}

/// Чистая логика вычисления будильников без обращения к системе.
public enum NativePlanPlanner {
    public static func planAlarms(
        plans: [NativePlan],
        referenceDate: Date = Date(),
        maxCap: Int = 50
    ) -> AlarmPlanResult {
        var candidates: [PlannedAlarm] = []
        var warnings: [String] = []

        for plan in plans {
            // Завершенные задачи исключаются из расписания
            if plan.completed == true || plan.alarmDeleted == true {
                continue
            }

            guard let eventDate = plan.resolveEventDate() else {
                warnings.append("План «\(plan.title)» (id: \(plan.id)) имеет некорректную дату/время или таймзону и пропущен.")
                continue
            }

            let planTz = plan.effectiveAlarmSchedule?.timeZone ?? plan.timeZone
            let offsets = plan.resolvedReminderOffsets()
            for offset in offsets {
                let alarmTimestamp = eventDate.addingTimeInterval(-Double(offset * 60))
                if alarmTimestamp > referenceDate {
                    let alarmUUID = DeterministicAlarmID.generate(
                        planId: plan.id,
                        eventDate: eventDate,
                        offsetMinutes: offset
                    )
                    candidates.append(PlannedAlarm(
                        id: alarmUUID,
                        planId: plan.id,
                        planTitle: plan.title,
                        eventDate: eventDate,
                        alarmDate: alarmTimestamp,
                        offsetMinutes: offset,
                        timeZone: planTz
                    ))
                }
            }
        }

        // Дедупликация по UUID
        var uniqueCandidates: [PlannedAlarm] = []
        var seenIDs: Set<UUID> = []
        for candidate in candidates {
            if !seenIDs.contains(candidate.id) {
                seenIDs.insert(candidate.id)
                uniqueCandidates.append(candidate)
            }
        }

        // Хронологическая сортировка: ближайшие срабатывания первыми
        uniqueCandidates.sort { $0.alarmDate < $1.alarmDate }

        if uniqueCandidates.count > maxCap {
            let scheduled = Array(uniqueCandidates.prefix(maxCap))
            let dropped = Array(uniqueCandidates.suffix(uniqueCandidates.count - maxCap))
            warnings.append("Политикой приложения установлен лимит в 50 активных будильников. Запланировано ближайших: 50. Отложено будущих: \(dropped.count).")
            return AlarmPlanResult(scheduledAlarms: scheduled, droppedAlarms: dropped, warnings: warnings)
        }

        return AlarmPlanResult(scheduledAlarms: uniqueCandidates, droppedAlarms: [], warnings: warnings)
    }
}
