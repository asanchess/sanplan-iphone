import SwiftUI

/// «Дальше сегодня» as a vertical time list (owner 20.11): «09:00  Тренировка», sorted by time, a «сейчас» line between past and ahead.
struct DayTimelineMark: Identifiable, Equatable {
    enum Kind: Equatable { case plan, workout }
    let id: String
    let minute: Int
    let kind: Kind
    let done: Bool
    let title: String
}

enum DayTimeline {
    static let startHour = 6
    static let endHour = 24

    /// Plans of the day with a time, and workouts started that day.
    static func marks(agenda: [AgendaItem], day: String, workouts: [WorkoutRecord], timeZone: TimeZone) -> [DayTimelineMark] {
        var marks: [DayTimelineMark] = agenda.compactMap { entry in
            guard entry.displayDate == day, let start = entry.startMin, entry.item.allDay != true else { return nil }
            return DayTimelineMark(id: "plan-\(entry.id)", minute: start, kind: .plan,
                                   done: entry.item.completed == true, title: entry.item.title)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        for record in workouts {
            let date = Date(timeIntervalSince1970: Double(record.startedAt) / 1000)
            guard PlanDomain.today(now: date, timeZone: timeZone.identifier) == day else { continue }
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            marks.append(DayTimelineMark(id: "workout-\(record.id)", minute: minute, kind: .workout,
                                         done: true, title: record.title ?? "Тренировка"))
        }
        return marks.sorted { $0.minute < $1.minute }
    }

    /// «2 плана, 1 тренировка» for VoiceOver.
    static func spoken(_ marks: [DayTimelineMark]) -> String {
        let plans = marks.filter { $0.kind == .plan }.count
        let workouts = marks.filter { $0.kind == .workout }.count
        var parts: [String] = []
        if plans > 0 { parts.append(ReviewFormat.plural(plans, "план", "плана", "планов")) }
        if workouts > 0 { parts.append(ReviewFormat.plural(workouts, "тренировка", "тренировки", "тренировок")) }
        return parts.isEmpty ? "На сегодня по времени ничего нет" : "Лента дня: " + parts.joined(separator: ", ")
    }
}

/// One line of the time list: a plan (keeps its agenda entry for checking) or a workout.
struct DayTimelineRow: Identifiable {
    let id: String
    let minute: Int?
    let title: String
    let done: Bool
    let agenda: AgendaItem?
}
