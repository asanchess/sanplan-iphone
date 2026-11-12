import Foundation

// История тренировок в зашифрованной коллекции `training` (docs/contracts/TRAINING-MIGRATION.md).
// Одна запись на завершённую тренировку, id «t-<id тренировки>», политика конфликтов `.newest`.
// Идущая тренировка (session) и план в коллекцию не уходят.

extension WorkoutRecordSet: @unchecked Sendable {}
extension WorkoutRecordExercise: @unchecked Sendable {}
extension WorkoutRecord: @unchecked Sendable {}

/// Показатели, которые до и после переноса обязаны совпасть.
public struct WorkoutMigrationReport: Codable, Equatable {
    public var workouts: Int
    public var doneSets: Int
    public var plannedSets: Int
    public var exercises: Int
    /// Тоннаж в десятых долях килограмма, чтобы сравнение не зависело от плавающей запятой.
    public var tonnageTenths: Int
}

/// Итог переноса: журнал лежит рядом с файлами тренировок аккаунта.
public struct WorkoutMigrationJournal: Codable, Equatable {
    public var confirmedAt: Int64?
    public var before: WorkoutMigrationReport?
    public var after: WorkoutMigrationReport?
}

public enum WorkoutMigrationStatus: Equatable {
    case idle
    case running
    case confirmed
    /// Перенос не подтверждён; локальные данные не тронуты. Текст — причина для пользователя.
    case failed(String)
}

public enum WorkoutVaultMigration {
    /// Сколько дней хранится копия локальной истории после подтверждённого переноса.
    public static let backupDays: Int64 = 30

    public static func report(_ records: [WorkoutRecord]) -> WorkoutMigrationReport {
        var tonnage = 0.0
        var done = 0, planned = 0, exercises = 0
        for record in records {
            done += record.doneSetCount
            planned += record.plannedSetCount
            exercises += record.exercises.count
            tonnage += record.tonnageKg
        }
        return WorkoutMigrationReport(
            workouts: records.count,
            doneSets: done,
            plannedSets: planned,
            exercises: exercises,
            tonnageTenths: Int((tonnage * 10).rounded())
        )
    }

    /// «t-<id>»: детерминированно из локального id, поэтому повторный перенос не создаёт дублей.
    /// Символы вне A-Z a-z 0-9 _ - заменяются, длина укладывается в 8–64.
    public static func vaultID(for recordID: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        var body = String(recordID.map { allowed.contains($0) ? $0 : "_" })
        body = String(body.prefix(62))
        var id = "t-" + body
        while id.count < 8 { id += "_" }
        return id
    }

    /// Запись для сервера: связь с Apple Health принадлежит устройству и не уходит в облако.
    public static func payload(_ record: WorkoutRecord) -> WorkoutRecord {
        var copy = record
        copy.healthId = nil
        return copy
    }

    /// Локальная история и коллекция вместе. Коллекция главнее при расхождении (правка с другого устройства);
    /// надгробие удаляет тренировку; своя связь с Apple Health сохраняется.
    public static func merged(local: [WorkoutRecord], vault: [String: VaultItem<WorkoutRecord>]) -> [WorkoutRecord] {
        var byID: [String: WorkoutRecord] = [:]
        for record in local { byID[record.id] = record }
        for (vid, item) in vault {
            if item.deleted {
                if let id = item.data?.id { byID[id] = nil }
                else if vid.hasPrefix("t-") {
                    let tail = String(vid.dropFirst(2))
                    for key in byID.keys where vaultID(for: key) == vid || key == tail { byID[key] = nil }
                }
                continue
            }
            guard var remote = item.data else { continue }
            if let mine = byID[remote.id] { remote.healthId = mine.healthId }
            byID[remote.id] = remote
        }
        return WorkoutHistory.sorted(Array(byID.values))
    }
}
