import Foundation

/// Запись коллекции `habits` (зашифрованный слой, DOMAINS.md §3). Три вида записей:
/// - `habit` — определение привычки, id `h-<id привычки>`;
/// - `marks` — отметки одной привычки за месяц, id `m-<id привычки>-<ГГГГММ>` (две правки с разных устройств
///   в разных месяцах не затирают друг друга);
/// - `streak` — настройки дней отдыха, id `s-streak`.
public struct HabitPayload: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case habit, marks, streak }
    public var kind: Kind
    public var habit: Habit?
    public var habitId: String?
    public var month: String?
    public var amounts: [String: Int]?
    public var streak: StreakSettings?
}

public struct HabitRecordEntry: Equatable {
    public let id: String
    public let payload: HabitPayload
}

public enum HabitCloud {
    /// Правило сервера (8–64 знака A-Z a-z 0-9 _ -), то же, что `VaultCollection.isValidID`.
    public static func isValidID(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    public static let streakRecordID = "s-streak"
    public static func habitRecordID(_ habitId: String) -> String { "h-\(habitId)" }
    public static func marksRecordID(_ habitId: String, month: String) -> String {
        "m-\(habitId)-\(month.replacingOccurrences(of: "-", with: ""))"
    }

    /// Все записи, которые должны лежать в коллекции для этого состояния. Записи с недопустимым id
    /// (короче 8 знаков и т. п.) пропускаются: такая привычка остаётся только на устройстве.
    public static func records(habits: [Habit], marks: [String: [String: Int]], streak: StreakSettings) -> [HabitRecordEntry] {
        var out: [HabitRecordEntry] = []
        for habit in habits where isValidID(habitRecordID(habit.id)) {
            out.append(HabitRecordEntry(id: habitRecordID(habit.id),
                                        payload: HabitPayload(kind: .habit, habit: habit)))
            var byMonth: [String: [String: Int]] = [:]
            for (day, amount) in marks[habit.id] ?? [:] where amount > 0 {
                byMonth[String(day.prefix(7)), default: [:]][day] = amount
            }
            for (month, amounts) in byMonth {
                let id = marksRecordID(habit.id, month: month)
                guard isValidID(id) else { continue }
                out.append(HabitRecordEntry(id: id, payload: HabitPayload(kind: .marks, habitId: habit.id, month: month, amounts: amounts)))
            }
        }
        out.append(HabitRecordEntry(id: streakRecordID, payload: HabitPayload(kind: .streak, streak: streak)))
        return out
    }

    /// Состояние из записей коллекции. Отметки без привычки отбрасываются.
    public static func state(from items: [VaultItem<HabitPayload>]) -> (habits: [Habit], marks: [String: [String: Int]], streak: StreakSettings) {
        var habits: [Habit] = []
        var streak = StreakSettings.standard
        var rawMarks: [String: [String: Int]] = [:]
        for item in items {
            guard let p = item.data else { continue }
            switch p.kind {
            case .habit:
                if let h = p.habit { habits.append(h) }
            case .marks:
                if let id = p.habitId, let amounts = p.amounts {
                    for (day, n) in amounts where n > 0 { rawMarks[id, default: [:]][day] = n }
                }
            case .streak:
                if let s = p.streak { streak = s }
            }
        }
        habits.sort { ($0.createdDay, $0.id) < ($1.createdDay, $1.id) }
        let ids = Set(habits.map(\.id))
        return (habits, rawMarks.filter { ids.contains($0.key) }, streak)
    }
}
