import Foundation

// Итоги дня и недели: чистая логика без интерфейса и файлов. Раздел «Сегодня и Итоги».
// Сводки соседних разделов (DOMAINS.md §2) вызываются через `ReviewSummaries`;
// там, где у соседа ещё нет своей сводки, стоит временная заглушка с пометкой TEMP.

// MARK: - Dates

public enum ReviewCalendar {
    private static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func isDay(_ value: String) -> Bool {
        guard value.count == 10, let date = parser.date(from: value) else { return false }
        return parser.string(from: date) == value
    }

    public static func addDays(_ day: String, _ days: Int) -> String {
        guard let date = parser.date(from: day), let moved = calendar.date(byAdding: .day, value: days, to: date) else { return day }
        return parser.string(from: moved)
    }

    /// Monday of the week the day belongs to.
    public static func weekStart(_ day: String) -> String {
        guard let date = parser.date(from: day) else { return day }
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        return addDays(day, -((weekday + 5) % 7))
    }

    public static func weekDays(startingAt monday: String) -> [String] {
        (0..<7).map { addDays(monday, $0) }
    }

    public static func monthStart(_ day: String) -> String { String(day.prefix(7)) + "-01" }

    public static func monthEnd(_ day: String) -> String {
        let next = addDays(monthStart(day), 32)
        return addDays(monthStart(next), -1)
    }

    /// Every day from `from` to `to` inclusive; empty when the range is reversed.
    public static func days(from: String, to: String) -> [String] {
        guard isDay(from), isDay(to), from <= to else { return [] }
        var result: [String] = []
        var current = from
        while current <= to && result.count < 400 {
            result.append(current)
            current = addDays(current, 1)
        }
        return result
    }

    /// The day an epoch-millisecond moment falls on in the owner's time zone.
    public static func day(ofMilliseconds ms: Int64, timeZone: String = PlanDomain.defaultTimeZone) -> String {
        PlanDomain.today(now: Date(timeIntervalSince1970: Double(ms) / 1000), timeZone: timeZone)
    }
}

// MARK: - Summaries of other sections

public struct OpenPlan: Equatable, Hashable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct PlansSummary: Equatable {
    public var done: Int
    public var total: Int
    public var open: [OpenPlan]
    public init(done: Int = 0, total: Int = 0, open: [OpenPlan] = []) { self.done = done; self.total = total; self.open = open }
}

public struct MoneySummary: Equatable {
    public var spentMinor: Int64
    public var count: Int
    public var byCategory: [FinanceCategoryBreakdown]
    public init(spentMinor: Int64 = 0, count: Int = 0, byCategory: [FinanceCategoryBreakdown] = []) {
        self.spentMinor = spentMinor; self.count = count; self.byCategory = byCategory
    }
}

public struct TrainingSummary: Equatable {
    public var completed: Int
    public var titles: [String]
    public init(completed: Int = 0, titles: [String] = []) { self.completed = completed; self.titles = titles }
}

public struct HabitsSummary: Equatable {
    public var done: Int
    public var total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}

/// What a day or a week looked like, gathered from the sections' own summaries.
public struct PeriodDigest: Equatable {
    public var plans: PlansSummary
    public var money: MoneySummary
    public var training: TrainingSummary
    /// nil while Plans has not shipped habits.
    public var habits: HabitsSummary?
    public var notes: Int

    public init(plans: PlansSummary = PlansSummary(), money: MoneySummary = MoneySummary(), training: TrainingSummary = TrainingSummary(), habits: HabitsSummary? = nil, notes: Int = 0) {
        self.plans = plans; self.money = money; self.training = training; self.habits = habits; self.notes = notes
    }

    public var isEmpty: Bool {
        plans.total == 0 && money.count == 0 && training.completed == 0 && (habits?.total ?? 0) == 0 && notes == 0
    }
}

/// Everything the digest reads, as plain values: stores hand over snapshots, tests build them directly.
public struct ReviewSources {
    public var plans: [PlanItem]
    public var finance: FinanceState
    public var workouts: [WorkoutRecord]
    public var noteMoments: [Int64]
    public var timeZone: String
    /// Plans' HabitStore.daySummary; nil hides the line.
    public var habitsDay: ((String) -> HabitsSummary?)?

    public init(plans: [PlanItem] = [], finance: FinanceState = FinanceState(), workouts: [WorkoutRecord] = [], noteMoments: [Int64] = [], timeZone: String = PlanDomain.defaultTimeZone, habitsDay: ((String) -> HabitsSummary?)? = nil) {
        self.plans = plans; self.finance = finance; self.workouts = workouts; self.noteMoments = noteMoments; self.timeZone = timeZone; self.habitsDay = habitsDay
    }
}

public enum ReviewSummaries {
    // Owners' summaries (DOMAINS.md §2): PlanSummary, FinanceSummaries, WorkoutSummary. Money there is WHOLE tenge;
    // MoneySummary keeps minor units, so the conversion lives here and nowhere else.

    /// Tasks of the period: Plans' day summary summed over the days.
    public static func plansPeriod(_ plans: [PlanItem], from: String, to: String) -> PlansSummary {
        var done = 0, total = 0
        var open: [OpenPlan] = []
        for day in ReviewCalendar.days(from: from, to: to) {
            let s = PlanSummary.day(plans: plans, day: day)
            done += s.done; total += s.total
            open += s.open.map { OpenPlan(id: $0.id, title: $0.title) }
        }
        return PlansSummary(done: done, total: total, open: open)
    }

    public static func plansDay(_ plans: [PlanItem], day: String) -> PlansSummary {
        plansPeriod(plans, from: day, to: day)
    }

    /// Spending of the period from the Money state; `categories` limits it to those category names.
    public static func financePeriod(_ state: FinanceState, from: String, to: String, categories: Set<String>? = nil) -> MoneySummary {
        var spent: Int64 = 0
        var count = 0
        var by: [String: Int64] = [:]
        if let categories {
            for name in categories {
                let p = FinanceSummaries.period(state, from: from, to: to, category: name)
                spent += p.spent; count += p.count
                if p.count > 0 { by[name] = p.spent }
            }
        } else {
            let p = FinanceSummaries.period(state, from: from, to: to)
            spent = p.spent; count = p.count; by = p.byCategory
        }
        let breakdown = by.map { FinanceCategoryBreakdown(name: $0.key, amountMinor: $0.value * 100) }
            .sorted { $0.amountMinor != $1.amountMinor ? $0.amountMinor > $1.amountMinor : $0.name < $1.name }
        return MoneySummary(spentMinor: spent * 100, count: count, byCategory: breakdown)
    }

    public static func financeDay(_ state: FinanceState, day: String) -> MoneySummary {
        financePeriod(state, from: day, to: day)
    }

    /// Finished workouts of the period. Day boundaries are Training's own (Asia/Qyzylorda).
    public static func trainingPeriod(_ records: [WorkoutRecord], from: String, to: String) -> TrainingSummary {
        var titles: [String] = []
        for day in ReviewCalendar.days(from: from, to: to) {
            titles += WorkoutSummary.day(records, day).sessions.map { $0.title ?? "Тренировка" }
        }
        return TrainingSummary(completed: WorkoutSummary.period(records, from: from, to: to).completed, titles: titles)
    }

    public static func trainingDay(_ records: [WorkoutRecord], day: String) -> TrainingSummary {
        trainingPeriod(records, from: day, to: day)
    }

    public static func notesCount(_ moments: [Int64], from: String, to: String, timeZone: String = PlanDomain.defaultTimeZone) -> Int {
        moments.filter {
            let day = ReviewCalendar.day(ofMilliseconds: $0, timeZone: timeZone)
            return day >= from && day <= to
        }.count
    }

    public static func digest(_ sources: ReviewSources, from: String, to: String) -> PeriodDigest {
        var habits: HabitsSummary?
        if let habitsDay = sources.habitsDay {
            let all = ReviewCalendar.days(from: from, to: to).compactMap { habitsDay($0) }
            if !all.isEmpty { habits = HabitsSummary(done: all.reduce(0) { $0 + $1.done }, total: all.reduce(0) { $0 + $1.total }) }
        }
        return PeriodDigest(
            plans: plansPeriod(sources.plans, from: from, to: to),
            money: financePeriod(sources.finance, from: from, to: to),
            training: trainingPeriod(sources.workouts, from: from, to: to),
            habits: habits,
            notes: notesCount(sources.noteMoments, from: from, to: to, timeZone: sources.timeZone)
        )
    }

    public static func digest(_ sources: ReviewSources, day: String) -> PeriodDigest {
        digest(sources, from: day, to: day)
    }
}

// MARK: - Entries

public enum ReviewLimits {
    public static let moodRange = 1...5
    public static let ratingRange = 1...10
    public static let maxTextLength = 500
}

/// One evening review: mood 1–5 and one line of text. Either may be empty, not both.
public struct ReviewEntry: Codable, Equatable, Identifiable {
    public var day: String
    public var mood: Int?
    public var text: String
    public var updatedAt: Int64
    public var id: String { day }

    public init(day: String, mood: Int? = nil, text: String = "", updatedAt: Int64) {
        self.day = day; self.mood = mood; self.text = text; self.updatedAt = updatedAt
    }

    /// nil when the entry would be empty or invalid; otherwise the cleaned entry.
    public static func make(day: String, mood: Int?, text: String, now: Int64) -> ReviewEntry? {
        guard ReviewCalendar.isDay(day) else { return nil }
        if let mood, !ReviewLimits.moodRange.contains(mood) { return nil }
        let line = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ReviewLimits.maxTextLength))
        guard mood != nil || !line.isEmpty else { return nil }
        return ReviewEntry(day: day, mood: mood, text: line, updatedAt: now)
    }
}

/// The payload of a day's record in the encrypted `reviews` collection (id `r-YYYY-MM-DD`).
public struct ReviewDayRecord: Codable, Equatable, Sendable {
    public var day: String
    public var mood: Int?
    public var text: String
    public init(day: String, mood: Int?, text: String) { self.day = day; self.mood = mood; self.text = text }
}

/// One day gathered from the primary record and any copies the `.copy` conflict policy made.
public struct MergedReviewDay: Equatable {
    public var entry: ReviewEntry
    public var ids: [String]
}

public enum ReviewVault {
    public static func recordID(for day: String) -> String { "r-\(day)" }

    /// Newest mood wins; the lines of all copies are kept (oldest first, joined once). Mirrors mergeDayRecords in review-domain.mjs.
    public static func merge(_ items: [VaultItem<ReviewDayRecord>]) -> [String: MergedReviewDay] {
        var groups: [String: [VaultItem<ReviewDayRecord>]] = [:]
        for item in items where !item.deleted {
            guard let data = item.data, ReviewCalendar.isDay(data.day) else { continue }
            groups[data.day, default: []].append(item)
        }
        var out: [String: MergedReviewDay] = [:]
        for (day, list) in groups {
            let newestFirst = list.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
            let mood = newestFirst.compactMap { $0.data?.mood }.first { ReviewLimits.moodRange.contains($0) }
            var lines: [String] = []
            for item in newestFirst.reversed() {
                let t = (item.data?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !lines.contains(t) { lines.append(t) }
            }
            let text = String(lines.joined(separator: " · ").prefix(ReviewLimits.maxTextLength))
            guard mood != nil || !text.isEmpty else { continue }
            out[day] = MergedReviewDay(entry: ReviewEntry(day: day, mood: mood, text: text, updatedAt: newestFirst[0].updatedAt), ids: list.map(\.id))
        }
        return out
    }
}

/// What the Money card says about «Можно потратить сегодня»: the sum, what is missing for it, or nothing.
public enum CanSpendLine: Equatable {
    case amount(Int64, basis: String)
    case gap(String)

    public static func make(spend: CanSpendToday?, gap: String?, hasData: Bool) -> CanSpendLine? {
        if let spend { return .amount(spend.amount, basis: spend.basis) }
        if hasData, let gap { return .gap(gap) }
        return nil
    }
}

public enum ReviewMood {
    public static let labels: [Int: String] = [1: "Тяжело", 2: "Так себе", 3: "Нормально", 4: "Хорошо", 5: "Отлично"]
    public static func label(_ mood: Int) -> String { labels[mood] ?? "" }
}

/// A sphere of life to rate once a week. TEMP: the real list belongs to Plans (spheres).
public struct ReviewSphere: Codable, Equatable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }

    public static let defaults: [ReviewSphere] = [
        ReviewSphere(id: "health", title: "Здоровье"),
        ReviewSphere(id: "money", title: "Деньги"),
        ReviewSphere(id: "work", title: "Дела и работа"),
        ReviewSphere(id: "people", title: "Близкие"),
        ReviewSphere(id: "rest", title: "Отдых"),
        ReviewSphere(id: "growth", title: "Развитие")
    ]
}

public struct WeekReview: Codable, Equatable, Identifiable {
    public var weekStart: String
    public var ratings: [String: Int]
    public var updatedAt: Int64
    public var id: String { weekStart }

    public init(weekStart: String, ratings: [String: Int], updatedAt: Int64) {
        self.weekStart = weekStart; self.ratings = ratings; self.updatedAt = updatedAt
    }

    /// nil when `day` is not a day or no rating is in 1…10; invalid ratings are dropped.
    public static func make(containing day: String, ratings: [String: Int], now: Int64) -> WeekReview? {
        guard ReviewCalendar.isDay(day) else { return nil }
        let valid = ratings.filter { ReviewLimits.ratingRange.contains($0.value) }
        guard !valid.isEmpty else { return nil }
        return WeekReview(weekStart: ReviewCalendar.weekStart(day), ratings: valid, updatedAt: now)
    }

    public var average: Double? {
        ratings.isEmpty ? nil : Double(ratings.values.reduce(0, +)) / Double(ratings.count)
    }
}

/// This week against the previous one: per-sphere change and the change of the average.
public struct WeekComparison: Equatable {
    public var deltas: [String: Int]
    public var averageDelta: Double?

    public static func make(current: WeekReview?, previous: WeekReview?) -> WeekComparison {
        guard let current, let previous else { return WeekComparison(deltas: [:], averageDelta: nil) }
        var deltas: [String: Int] = [:]
        for (id, value) in current.ratings { if let before = previous.ratings[id] { deltas[id] = value - before } }
        let both = current.ratings.keys.filter { previous.ratings[$0] != nil }
        guard !both.isEmpty else { return WeekComparison(deltas: [:], averageDelta: nil) }
        let now = Double(both.reduce(0) { $0 + current.ratings[$1]! }) / Double(both.count)
        let before = Double(both.reduce(0) { $0 + previous.ratings[$1]! }) / Double(both.count)
        return WeekComparison(deltas: deltas, averageDelta: now - before)
    }
}

/// One line of the week's numbers compared with the previous week; the sign is the caller's to word.
public struct WeekFigure: Equatable {
    public var title: String
    public var current: Int64
    public var previous: Int64
    public var isMoney: Bool
    public var delta: Int64 { current - previous }
}

public enum ReviewWeekFigures {
    public static func make(current: PeriodDigest, previous: PeriodDigest) -> [WeekFigure] {
        var figures = [
            WeekFigure(title: "Задач выполнено", current: Int64(current.plans.done), previous: Int64(previous.plans.done), isMoney: false),
            WeekFigure(title: "Тренировок", current: Int64(current.training.completed), previous: Int64(previous.training.completed), isMoney: false),
            WeekFigure(title: "Потрачено", current: current.money.spentMinor, previous: previous.money.spentMinor, isMoney: true),
            WeekFigure(title: "Заметок", current: Int64(current.notes), previous: Int64(previous.notes), isMoney: false)
        ]
        if let habits = current.habits {
            figures.insert(WeekFigure(title: "Привычек выполнено", current: Int64(habits.done), previous: Int64(previous.habits?.done ?? 0), isMoney: false), at: 2)
        }
        return figures
    }
}

// MARK: - Reminder settings

public struct ReviewReminderSettings: Codable, Equatable {
    public var enabled: Bool
    public var hour: Int
    public var minute: Int

    public static let standard = ReviewReminderSettings(enabled: true, hour: 21, minute: 0)

    public init(enabled: Bool, hour: Int, minute: Int) {
        self.enabled = enabled
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
    }

    public var timeText: String { String(format: "%02d:%02d", hour, minute) }
}

// MARK: - Formatting shared by review and answers

public enum StreakLine {
    /// «Серия: 5 дней · отдыха осталось 2»; nil, когда показывать нечего.
    public static func text(_ streak: StreakState?) -> String? {
        guard let streak, streak.days > 0 else { return nil }
        let head = "Серия: " + ReviewFormat.plural(streak.days, "день", "дня", "дней")
        return head + " · " + (streak.restDaysLeft > 0 ? "отдыха осталось (streak.restDaysLeft)" : "дней отдыха не осталось")
    }
}

public enum ReviewFormat {
    /// «1 234 ₸» from tiyn.
    public static func tenge(_ minor: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.maximumFractionDigits = 0
        let whole = Int64((Double(minor) / 100).rounded())
        return "\(formatter.string(from: NSNumber(value: whole)) ?? "\(whole)") ₸"
    }

    /// Russian plural: 1 тренировка, 2 тренировки, 5 тренировок.
    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let a = abs(n) % 100, b = a % 10
        let form = (a > 10 && a < 20) ? many : b == 1 ? one : (b >= 2 && b <= 4) ? few : many
        return "\(n) \(form)"
    }
}
