import Foundation

/// The «Неделя» view: Monday to Sunday around a date, with the workout program's training days shown beside the plans.
/// Training rows are display-only. They are never plans, so they create no alarms and are never saved.
public enum PlanWeek {
    public struct TrainingRow: Equatable, Hashable {
        public let date: String
        public let title: String
        public let exerciseCount: Int
    }

    /// The seven `yyyy-MM-dd` dates, Monday first, of the week that contains `date` in `timeZone`.
    public static func days(containing date: String, timeZone: String) -> [String] {
        guard let calendar = calendar(timeZone),
              let day = formatter(timeZone).date(from: date),
              let week = calendar.dateInterval(of: .weekOfYear, for: day) else { return [date] }
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: week.start).map { formatter(timeZone).string(from: $0) }
        }
    }

    /// The training day for each date whose weekday has exercises in the program.
    public static func trainingRows(program: WorkoutTrainingPlan, days: [String], timeZone: String) -> [TrainingRow] {
        guard let zone = TimeZone(identifier: timeZone) else { return [] }
        return days.compactMap { date in
            guard let day = formatter(timeZone).date(from: date) else { return nil }
            let weekday = WorkoutProgram.weekday(of: day, timeZone: zone)
            guard let plan = WorkoutProgram.day(program, weekday: weekday), !plan.exercises.isEmpty else { return nil }
            return TrainingRow(date: date, title: plan.title ?? "Тренировка", exerciseCount: plan.exercises.count)
        }
    }

    /// «9–15 ноября» or «30 ноября – 6 декабря».
    public static func title(of days: [String], timeZone: String) -> String {
        guard let first = days.first, let last = days.last,
              let start = formatter(timeZone).date(from: first),
              let end = formatter(timeZone).date(from: last) else { return "" }
        let dayOnly = PlanDateTime.formatter("d", timeZone: timeZone, locale: "ru_RU")
        let dayMonth = PlanDateTime.formatter("d MMMM", timeZone: timeZone, locale: "ru_RU")
        if first.prefix(7) == last.prefix(7) {
            return "\(dayOnly.string(from: start))–\(dayMonth.string(from: end))"
        }
        return "\(dayMonth.string(from: start)) – \(dayMonth.string(from: end))"
    }

    public static func exercisesLabel(_ count: Int) -> String {
        let mod10 = count % 10, mod100 = count % 100
        let word: String
        if mod10 == 1 && mod100 != 11 { word = "упражнение" }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "упражнения" }
        else { word = "упражнений" }
        return "\(count) \(word)"
    }

    private static func formatter(_ timeZone: String) -> DateFormatter {
        PlanDateTime.formatter("yyyy-MM-dd", timeZone: timeZone)
    }

    private static func calendar(_ timeZone: String) -> Calendar? {
        guard let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        return calendar
    }
}
