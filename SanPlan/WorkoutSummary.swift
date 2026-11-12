import Foundation

/// Сводки тренировок для других разделов (Итоги, «+», привычка «тренировка», цели).
/// Договорённость: docs/contracts/DOMAINS.md §2. Дни — «YYYY-MM-DD» в Asia/Qyzylorda, ничего не уходит наружу.
/// Тренировка засчитывается, если в ней отмечен хотя бы один подход; день тренировки — день её начала.
public struct WorkoutSessionBrief: Equatable {
    public var id: String
    public var title: String?
    /// Миллисекунды с 1970.
    public var finishedAt: Int64
}

public struct WorkoutDaySummary: Equatable {
    public var completed: Bool
    public var sessions: [WorkoutSessionBrief]
}

public struct WorkoutExerciseTotals: Equatable {
    public var sets: Int
    public var reps: Int
    public var tonnageKg: Double
    public var bestWeightKg: Double?
}

public struct WorkoutPeriodSummary: Equatable {
    public var completed: Int
    /// Ключ — название упражнения в нижнем регистре, «ё» как «е».
    public var byExercise: [String: WorkoutExerciseTotals]
}

public enum WorkoutSummary {
    public static let zone = TimeZone(identifier: "Asia/Qyzylorda") ?? TimeZone(secondsFromGMT: 5 * 3600)!

    public static func exerciseKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    public static func dayKey(_ ms: Int64, timeZone: TimeZone = zone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    static func counted(_ records: [WorkoutRecord]) -> [WorkoutRecord] {
        records.filter { $0.doneSetCount > 0 }
    }

    public static func day(_ records: [WorkoutRecord], _ day: String, timeZone: TimeZone = zone) -> WorkoutDaySummary {
        let sessions = counted(records)
            .filter { dayKey($0.startedAt, timeZone: timeZone) == day }
            .sorted { $0.endedAt < $1.endedAt }
            .map { WorkoutSessionBrief(id: $0.id, title: $0.title, finishedAt: $0.endedAt) }
        return WorkoutDaySummary(completed: !sessions.isEmpty, sessions: sessions)
    }

    /// Дни включительно: from ≤ день ≤ to (строки «YYYY-MM-DD» сравниваются как текст).
    public static func period(_ records: [WorkoutRecord], from: String, to: String, timeZone: TimeZone = zone) -> WorkoutPeriodSummary {
        var completed = 0
        var by: [String: WorkoutExerciseTotals] = [:]
        for record in counted(records) {
            let key = dayKey(record.startedAt, timeZone: timeZone)
            guard key >= from, key <= to else { continue }
            completed += 1
            for exercise in record.exercises {
                let done = exercise.doneSets
                guard !done.isEmpty else { continue }
                let name = exerciseKey(exercise.name)
                var totals = by[name] ?? WorkoutExerciseTotals(sets: 0, reps: 0, tonnageKg: 0, bestWeightKg: nil)
                for set in done {
                    totals.sets += 1
                    totals.reps += set.reps ?? 0
                    totals.tonnageKg += (set.weightKg ?? 0) * Double(set.reps ?? 0)
                    if let w = set.weightKg, w > (totals.bestWeightKg ?? -1) { totals.bestWeightKg = w }
                }
                by[name] = totals
            }
        }
        return WorkoutPeriodSummary(completed: completed, byExercise: by)
    }

    /// Наибольший вес в отмеченных подходах упражнения за всё время; nil — веса нет.
    public static func bestWeight(_ records: [WorkoutRecord], exercise: String) -> Double? {
        let key = exerciseKey(exercise)
        var best: Double?
        for record in counted(records) {
            for e in record.exercises where exerciseKey(e.name) == key {
                for set in e.doneSets {
                    if let w = set.weightKg, w > 0, w > (best ?? 0) { best = w }
                }
            }
        }
        return best
    }

    public static func activityDays(_ records: [WorkoutRecord], from: String, to: String, timeZone: TimeZone = zone) -> [String] {
        let days = Set(counted(records).map { dayKey($0.startedAt, timeZone: timeZone) })
        return days.filter { $0 >= from && $0 <= to }.sorted()
    }
}

extension WorkoutStore {
    public func daySummary(for day: String) -> WorkoutDaySummary { WorkoutSummary.day(history.records, day) }
    public func periodSummary(from: String, to: String) -> WorkoutPeriodSummary { WorkoutSummary.period(history.records, from: from, to: to) }
    public func bestWeight(exercise: String) -> Double? { WorkoutSummary.bestWeight(history.records, exercise: exercise) }
    public func activityDays(from: String, to: String) -> [String] { WorkoutSummary.activityDays(history.records, from: from, to: to) }
}
