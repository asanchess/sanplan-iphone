import Foundation

/// The bottom field «Что запланировать?» in «Привычки» and «Цели»: a plain-words reading done on the phone.
/// Nothing is saved here; the screen shows the result («Понял так») and saves only after a tap.
/// Plans themselves go to the server's AI parse (`PlanStore.parseText`).
enum PlansQuickParse {
    // MARK: Habit

    /// «вода 8 стаканов каждый день», «чтение 20 минут по будням», «зарядка 3 раза в неделю», «бег пн ср пт».
    static func habit(from text: String, today: String) -> Habit? {
        var rest = " " + text.trimmingCharacters(in: .whitespacesAndNewlines) + " "
        var schedule = HabitSchedule.everyDay

        if let match = first(#"(\d{1,2})\s*раз[а]?\s+в\s+недел[юи]"#, in: rest), let n = Int(match.groups[0]) {
            schedule = .timesPerWeek(min(max(n, 1), 7))
            rest = removing(match.range, from: rest)
        } else if let match = first(#"(?:по\s+)?будн(?:ям|и|ие\s+дни)"#, in: rest) {
            schedule = .onWeekdays([1, 2, 3, 4, 5])
            rest = removing(match.range, from: rest)
        } else if let match = first(#"(?:по\s+)?выходн(?:ым|ые)"#, in: rest) {
            schedule = .onWeekdays([6, 7])
            rest = removing(match.range, from: rest)
        } else {
            var days = Set<Int>()
            while let match = first(weekdayPattern, in: rest) {
                if let day = weekday(match.groups[0]) { days.insert(day) }
                rest = removing(match.range, from: rest)
            }
            if !days.isEmpty { schedule = days.count == 7 ? .everyDay : .onWeekdays(days) }
        }
        if let match = first(#"кажд(?:ый|ое)\s+(?:день|утро|вечер)|ежедневно"#, in: rest) {
            rest = removing(match.range, from: rest)
        }

        var target = HabitTarget.once
        if let match = first(#"(\d{1,2})\s*раз[а]?\s+в\s+день"#, in: rest), let n = Int(match.groups[0]), n > 1 {
            target = HabitTarget(amount: min(n, 99), unit: "")
            rest = removing(match.range, from: rest)
        } else if let match = first(#"(\d{1,2})\s+(стакан\w*|страниц\w*|глав\w*|отжиман\w*|приседан\w*|подход\w*|упражнен\w*|раз\w*|км)"#, in: rest),
                  let n = Int(match.groups[0]), n > 1 {
            target = HabitTarget(amount: min(n, 99), unit: match.groups[1])
            rest = removing(match.range, from: rest)
        }

        let title = tidyTitle(rest)
        guard !title.isEmpty else { return nil }
        return Habit(title: title, schedule: schedule, target: target, createdDay: today)
    }

    // MARK: Goal

    struct GoalReading: Equatable {
        var goal: Goal
        /// What the measure means in words: «Деньги, 300 000 ₸».
        var measure: String
    }

    /// «отложить 300 000 ₸ к январю», «12 тренировок до 31 декабря», «выучить испанский до лета».
    static func goal(from text: String, today: String, sphereIds: Set<String>) -> GoalReading? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        var rest = " " + clean + " "

        var due: String?
        if let match = first(#"(?:к|до)\s+(\d{1,2})\s+(январ[яь]|феврал[яь]|марта?|апрел[яь]|ма[яй]|июн[яь]|июл[яь]|августа?|сентябр[яь]|октябр[яь]|ноябр[яь]|декабр[яь])"#, in: rest),
           let day = Int(match.groups[0]), let month = month(match.groups[1]) {
            due = nextDate(day: day, month: month, after: today)
            rest = removing(match.range, from: rest)
        } else if let match = first(#"(?:к|до)\s+(январю|февралю|марту|апрелю|маю|июню|июлю|августу|сентябрю|октябрю|ноябрю|декабрю)"#, in: rest),
                  let month = month(match.groups[0]) {
            due = nextDate(day: 1, month: month, after: today)
            rest = removing(match.range, from: rest)
        } else if let match = first(#"(?:к|до)\s+конц[ау]\s+года"#, in: rest) {
            due = "\(today.prefix(4))-12-31"
            rest = removing(match.range, from: rest)
        } else if let match = first(#"(?:к|до)\s+лет[ау]"#, in: rest) {
            due = nextDate(day: 1, month: 6, after: today)
            rest = removing(match.range, from: rest)
        }

        let title = capitalized(clean)
        let kind: GoalProgressKind
        let measure: String
        var sphere: String?
        if let match = first(#"(\d{1,3})\s+тренировк\w*"#, in: rest), let n = Int(match.groups[0]), n > 0 {
            kind = .trainingCount(target: n)
            measure = "Тренировки, \(n)"
            sphere = "health"
        } else if let amount = moneyAmount(in: rest) {
            kind = .money(target: amount, savingsGoalId: nil)
            measure = "Деньги, \(GoalEngine.grouped(amount)) ₸"
            sphere = "money"
        } else {
            kind = .milestones([GoalMilestone(title: title)])
            measure = "Этапы: отметить, когда готово"
        }
        if let id = sphere, !sphereIds.contains(id) { sphere = nil }
        let goal = Goal(title: title, sphereId: sphere, dueDay: due, createdDay: today, kind: kind)
        return GoalReading(goal: goal, measure: measure)
    }

    /// A sum of money: «300 000», «300000 ₸», «300 тыс», «1,5 млн». Needs a money word or a sign next to it.
    static func moneyAmount(in text: String) -> Int? {
        let lower = text.lowercased()
        let hasMoneyWord = ["₸", "тенге", " тг", "отлож", "накоп", "собрать", "скопить", "сэконом", "заработ"].contains { lower.contains($0) }
        guard let match = first(#"(\d+(?:[  ]\d{3})*(?:[.,]\d+)?)\s*(млн|тыс\.?|к\b)?"#, in: text) else { return nil }
        let digits = match.groups[0].replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: ",", with: ".")
        guard var value = Double(digits) else { return nil }
        let scale = match.groups[1].lowercased()
        if scale.hasPrefix("млн") { value *= 1_000_000 } else if scale.hasPrefix("тыс") || scale == "к" { value *= 1_000 }
        guard hasMoneyWord || !scale.isEmpty, value >= 1 else { return nil }
        return Int(value.rounded())
    }

    // MARK: Words

    private static let weekdayPattern = #"(?:по\s+|и\s+|,\s*)?\b(пн|вт|ср|чт|пт|сб|вс|понедельник\w*|вторник\w*|сред[аыу]|четверг\w*|пятниц\w*|суббот\w*|воскресень\w*)\b"#

    private static func weekday(_ word: String) -> Int? {
        let w = word.lowercased()
        let table: [(String, Int)] = [("пн", 1), ("пон", 1), ("вт", 2), ("ср", 3), ("чт", 4), ("чет", 4), ("пт", 5), ("пят", 5), ("сб", 6), ("суб", 6), ("вс", 7), ("вос", 7)]
        return table.first { w.hasPrefix($0.0) }?.1
    }

    private static func month(_ word: String) -> Int? {
        let w = word.lowercased()
        let stems = ["янв", "фев", "мар", "апр", "ма", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]
        // «ма» must not catch «мар»: check the longer stems first.
        if w.hasPrefix("мар") { return 3 }
        return stems.firstIndex { w.hasPrefix($0) }.map { $0 + 1 }
    }

    /// The first `yyyy-MM-dd` with this day and month on or after `today`.
    static func nextDate(day: Int, month: Int, after today: String) -> String? {
        let parts = today.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(month), (1...31).contains(day) else { return nil }
        var year = parts[0]
        if month < parts[1] || (month == parts[1] && day < parts[2]) { year += 1 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard calendar.date(from: DateComponents(year: year, month: month, day: day)) != nil,
              let range = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month)) ?? Date()),
              range.contains(day) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func tidyTitle(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;—-"))
        for tail in [" и", " по", " в", ","] where t.hasSuffix(tail) {
            t = String(t.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
        }
        return capitalized(t)
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: Regex

    private struct Match {
        let range: NSRange
        let groups: [String]
    }

    private static func first(_ pattern: String, in text: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let result = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let groups = (1..<max(result.numberOfRanges, 1)).map { index -> String in
            let r = result.range(at: index)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        return Match(range: result.range, groups: groups)
    }

    private static func removing(_ range: NSRange, from text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: " ")
    }
}
