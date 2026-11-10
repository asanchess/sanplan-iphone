import Foundation

/// One set of a finished workout.
public struct WorkoutRecordSet: Codable, Equatable, Hashable {
    public var done: Bool
    public var weightKg: Double?
    public var reps: Int?

    public init(done: Bool = true, weightKg: Double? = nil, reps: Int? = nil) {
        self.done = done
        self.weightKg = weightKg
        self.reps = reps
    }
}

public struct WorkoutRecordExercise: Codable, Equatable, Hashable, Identifiable {
    public var id: String
    /// The plan exercise, so a rename keeps its history together.
    public var exerciseId: String?
    public var name: String
    public var bodyweight: Bool
    public var targetReps: Int?
    public var perSide: Bool
    public var sets: [WorkoutRecordSet]

    public init(
        id: String = UUID().uuidString,
        exerciseId: String? = nil,
        name: String,
        bodyweight: Bool = false,
        targetReps: Int? = nil,
        perSide: Bool = false,
        sets: [WorkoutRecordSet]
    ) {
        self.id = id
        self.exerciseId = exerciseId
        self.name = name
        self.bodyweight = bodyweight
        self.targetReps = targetReps
        self.perSide = perSide
        self.sets = sets
    }

    public var doneSets: [WorkoutRecordSet] { sets.filter { $0.done } }
}

/// A finished workout in the history. Times are milliseconds since 1970, like the session.
public struct WorkoutRecord: Codable, Equatable, Hashable, Identifiable {
    public var id: String
    public var startedAt: Int64
    public var endedAt: Int64
    /// Plan weekday 1…7 it was started from; nil for a workout added by hand.
    public var weekday: Int?
    public var title: String?
    public var exercises: [WorkoutRecordExercise]
    public var note: String?
    /// Added afterwards by hand rather than recorded live.
    public var manual: Bool
    /// The matching workout written to Apple Health, to replace or delete it there.
    public var healthId: String?

    public init(
        id: String = UUID().uuidString,
        startedAt: Int64,
        endedAt: Int64,
        weekday: Int? = nil,
        title: String? = nil,
        exercises: [WorkoutRecordExercise],
        note: String? = nil,
        manual: Bool = false,
        healthId: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.weekday = weekday
        self.title = title
        self.exercises = exercises
        self.note = note
        self.manual = manual
        self.healthId = healthId
    }

    public var durationSeconds: Int { Int(max(0, endedAt - startedAt) / 1000) }
    public var doneSetCount: Int { exercises.reduce(0) { $0 + $1.doneSets.count } }
    public var plannedSetCount: Int { exercises.reduce(0) { $0 + $1.sets.count } }

    /// Kilograms moved: weight × reps over sets done with a weight.
    public var tonnageKg: Double {
        exercises.reduce(0) { total, exercise in
            total + exercise.doneSets.reduce(0) { $0 + ($1.weightKg ?? 0) * Double($1.reps ?? 0) }
        }
    }
}

/// The history file of one account.
public struct WorkoutHistoryFile: Codable, Equatable {
    public var version: Int
    public var records: [WorkoutRecord]
    /// Workouts a week for the streak. Nil follows the number of training days in the plan.
    public var weeklyGoal: Int?

    public init(version: Int = 1, records: [WorkoutRecord] = [], weeklyGoal: Int? = nil) {
        self.version = version
        self.records = records
        self.weeklyGoal = weeklyGoal
    }
}

public struct WeekStreak: Equatable {
    /// Weeks in a row that reached the goal, counting this week once it has.
    public var weeks: Int
    public var thisWeek: Int
    public var goal: Int
}

public struct PeriodSummary: Equatable {
    public var workouts: Int
    public var totalSeconds: Int
    public var sets: Int
    public var tonnageKg: Double

    public var averageSeconds: Int { workouts == 0 ? 0 : totalSeconds / workouts }

    public static let empty = PeriodSummary(workouts: 0, totalSeconds: 0, sets: 0, tonnageKg: 0)
}

public enum WorkoutHistory {
    public static let maxDurationMs: Int64 = 24 * 3_600_000
    public static let goalRange = 1...14

    // MARK: - Records

    /// The history entry for a finished session; nil when no set was done, so an empty workout is not kept.
    public static func record(from session: WorkoutSessionState, id: String = UUID().uuidString, now: Int64) -> WorkoutRecord? {
        let exercises = session.exercises.map { exercise in
            WorkoutRecordExercise(
                exerciseId: exercise.exerciseId,
                name: exercise.baseName,
                bodyweight: exercise.bodyweight ?? false,
                targetReps: exercise.reps,
                perSide: exercise.perSide ?? false,
                sets: exercise.sets.map { WorkoutRecordSet(done: $0.done, weightKg: $0.weightKg, reps: $0.reps) }
            )
        }
        guard exercises.contains(where: { !$0.doneSets.isEmpty }) else { return nil }
        let ended = session.endedAt ?? now
        let started = min(session.startedAt ?? firstSetTime(session) ?? ended, ended)
        return WorkoutRecord(
            id: session.recordId ?? id,
            startedAt: started,
            endedAt: ended,
            weekday: session.planDay?.weekday,
            title: session.planDay.flatMap { $0.title },
            exercises: exercises
        )
    }

    /// Checks and tidies a record before it is saved: times in order and under a day, names present, numbers in range.
    public static func validated(_ record: WorkoutRecord) throws -> WorkoutRecord {
        var clean = record
        guard clean.startedAt >= 0, clean.endedAt >= clean.startedAt else {
            throw WorkoutDomainError("Конец тренировки раньше начала")
        }
        guard clean.endedAt - clean.startedAt <= maxDurationMs else {
            throw WorkoutDomainError("Тренировка не может идти дольше суток")
        }
        clean.title = clean.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.title?.isEmpty == true { clean.title = nil }
        clean.note = clean.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.note?.isEmpty == true { clean.note = nil }
        for i in clean.exercises.indices {
            clean.exercises[i].name = clean.exercises[i].name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.exercises[i].name.isEmpty else { throw WorkoutDomainError("Введите название упражнения") }
            for s in clean.exercises[i].sets.indices {
                if let weight = clean.exercises[i].sets[s].weightKg {
                    guard WorkoutSessionEdit.weightRange.contains(weight) else { throw WorkoutDomainError("Вес — от 0 до 1000 кг") }
                    clean.exercises[i].sets[s].weightKg = WorkoutSessionEdit.roundWeight(weight)
                }
                if let reps = clean.exercises[i].sets[s].reps {
                    guard WorkoutSessionEdit.repsRange.contains(reps) else { throw WorkoutDomainError("Повторы — от 0 до 1000") }
                }
            }
        }
        return clean
    }

    /// Adds or replaces a record by id; newest first.
    public static func upsert(_ records: [WorkoutRecord], _ record: WorkoutRecord) throws -> [WorkoutRecord] {
        let clean = try validated(record)
        var next = records.filter { $0.id != clean.id }
        next.append(clean)
        return sorted(next)
    }

    public static func removing(_ records: [WorkoutRecord], id: String) -> [WorkoutRecord] {
        records.filter { $0.id != id }
    }

    public static func sorted(_ records: [WorkoutRecord]) -> [WorkoutRecord] {
        records.sorted { $0.startedAt == $1.startedAt ? $0.id > $1.id : $0.startedAt > $1.startedAt }
    }

    /// A blank workout for adding one afterwards: an hour ending now.
    public static func manualRecord(endingAt now: Int64) -> WorkoutRecord {
        WorkoutRecord(startedAt: max(0, now - 3_600_000), endedAt: now, exercises: [], manual: true)
    }

    // MARK: - Last time and progression

    /// The latest performance of an exercise with at least one set done, matched by plan id, else by name.
    public static func lastPerformance(
        _ records: [WorkoutRecord],
        exerciseId: String?,
        name: String,
        before: Int64? = nil
    ) -> WorkoutRecordExercise? {
        let key = normalized(name)
        for record in sorted(records) {
            if let before, record.startedAt >= before { continue }
            let match = record.exercises.last { exercise in
                guard !exercise.doneSets.isEmpty else { return false }
                if let exerciseId, let other = exercise.exerciseId { return exerciseId == other }
                return normalized(exercise.name) == key
            }
            if let match { return match }
        }
        return nil
    }

    /// Today's target from last time: every set done at its reps raises the weight by the step
    /// (or a bodyweight exercise without load by one rep); otherwise last time's weight is repeated.
    /// The plan's own weight wins when it is higher, since the user set it on purpose.
    public static func target(
        planReps: Int,
        planSets: Int,
        planWeightKg: Double?,
        bodyweight: Bool,
        stepKg: Double?,
        last: WorkoutRecordExercise?
    ) -> (weightKg: Double?, reps: Int, progressed: Bool) {
        guard let last else { return (planWeightKg, planReps, false) }
        let done = last.doneSets
        let goalReps = last.targetReps ?? planReps
        let allDone = done.count >= max(planSets, last.sets.count) && done.allSatisfy { ($0.reps ?? 0) >= goalReps }
        let lastWeight = done.compactMap { $0.weightKg }.max()
        let step = stepKg ?? WorkoutSessionEdit.defaultStepKg

        if bodyweight && (lastWeight ?? 0) == 0 {
            guard allDone else { return (planWeightKg, planReps, false) }
            let best = done.compactMap { $0.reps }.min() ?? planReps
            let reps = min(max(planReps, best + 1), WorkoutProgram.repsRange.upperBound)
            return (planWeightKg, reps, reps > planReps)
        }
        guard let lastWeight else { return (planWeightKg, planReps, false) }
        let suggested = WorkoutSessionEdit.roundWeight(allDone ? lastWeight + step : lastWeight)
        if let planWeightKg, planWeightKg > suggested {
            return (planWeightKg, planReps, false)
        }
        return (suggested, planReps, allDone)
    }

    /// Fills «в прошлый раз» and today's targets for a workout about to start.
    public static func prepared(_ exercises: [SessionExercise], history records: [WorkoutRecord]) -> [SessionExercise] {
        exercises.map { exercise in
            var next = exercise
            let last = lastPerformance(records, exerciseId: exercise.exerciseId, name: exercise.baseName)
            next.lastTime = last.map { $0.sets.map { SetLog(done: $0.done, weightKg: $0.weightKg, reps: $0.reps) } }
            guard let reps = exercise.reps else { return next }
            let goal = target(
                planReps: reps,
                planSets: exercise.rests.count,
                planWeightKg: exercise.planWeightKg ?? exercise.weightKg,
                bodyweight: exercise.bodyweight ?? false,
                stepKg: exercise.weightStepKg,
                last: last
            )
            next.weightKg = goal.weightKg
            next.reps = goal.reps
            next.progressed = goal.progressed
            next.refreshName()
            return next
        }
    }

    // MARK: - Saving changes back to the plan

    /// The plan day as the workout ended up, or nil when nothing that belongs in the plan changed.
    /// Logged weights and today's progression are not plan changes; edited targets, sets, order and exercises are.
    public static func planChanges(_ session: WorkoutSessionState) -> WorkoutDayPlan? {
        guard let day = session.planDay, session.exercises.allSatisfy({ $0.reps != nil }) else { return nil }
        let byId = Dictionary(day.exercises.compactMap { e in e.id.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        let exercises = session.exercises.map { exercise -> WorkoutExercisePlan in
            let original = exercise.exerciseId.flatMap { byId[$0] }
            let rests = exercise.rests
            let between = rests.count > 1 ? rests[0] : (original?.restSeconds ?? rests[0])
            let planReps = (exercise.progressed == true && exercise.bodyweight == true && (exercise.planWeightKg ?? 0) == 0)
                ? (original?.reps ?? exercise.reps ?? 1)
                : (exercise.reps ?? 1)
            return WorkoutExercisePlan(
                name: exercise.baseName,
                sets: rests.count,
                reps: planReps,
                perSide: exercise.perSide ?? false,
                restSeconds: between,
                id: exercise.exerciseId ?? UUID().uuidString,
                restAfterExercise: rests[rests.count - 1],
                weightKg: exercise.planWeightKg,
                bodyweight: exercise.bodyweight,
                weightStepKg: exercise.weightStepKg
            )
        }
        let changed = exercises.count != day.exercises.count
            || zip(exercises, day.exercises).contains { !samePlan($0, $1) }
        guard changed else { return nil }
        return WorkoutDayPlan(weekday: day.weekday, exercises: exercises, title: day.title)
    }

    private static func samePlan(_ a: WorkoutExercisePlan, _ b: WorkoutExercisePlan) -> Bool {
        let afterA = a.restAfterExercise ?? a.restSeconds
        let afterB = b.restAfterExercise ?? b.restSeconds
        return a.id == b.id
            && a.name == b.name.trimmingCharacters(in: .whitespacesAndNewlines)
            && a.sets == b.sets
            && a.reps == b.reps
            && a.perSide == b.perSide
            && (a.sets == 1 || a.restSeconds == b.restSeconds)
            && afterA == afterB
            && a.weightKg == b.weightKg
            && (a.bodyweight ?? false) == (b.bodyweight ?? false)
            && (a.weightStepKg ?? WorkoutSessionEdit.defaultStepKg) == (b.weightStepKg ?? WorkoutSessionEdit.defaultStepKg)
    }

    // MARK: - Statistics

    /// Gregorian weeks starting on Monday in the phone's time zone.
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    public static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    public static func weekStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// The goal in force: the one set by the user, else one workout per training day of the plan.
    public static func effectiveGoal(_ weeklyGoal: Int?, planDays: Int) -> Int {
        let goal = weeklyGoal ?? planDays
        return min(max(goal, goalRange.lowerBound), goalRange.upperBound)
    }

    /// Weeks in a row with at least `goal` workouts. This week joins the streak once reached
    /// and does not break it while still under way.
    public static func streak(_ records: [WorkoutRecord], goal: Int, now: Date, calendar: Calendar) -> WeekStreak {
        var perWeek: [Date: Int] = [:]
        for record in records where record.doneSetCount > 0 {
            perWeek[weekStart(date(record.startedAt), calendar: calendar), default: 0] += 1
        }
        let current = weekStart(now, calendar: calendar)
        let thisWeek = perWeek[current] ?? 0
        var weeks = 0
        var cursor = current
        if thisWeek >= goal { weeks = 1 }
        while let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor),
              (perWeek[previous] ?? 0) >= goal {
            weeks += 1
            cursor = previous
        }
        return WeekStreak(weeks: weeks, thisWeek: thisWeek, goal: goal)
    }

    /// Totals of workouts started in [from, to).
    public static func summary(_ records: [WorkoutRecord], from: Date, to: Date) -> PeriodSummary {
        let start = Int64(from.timeIntervalSince1970 * 1000)
        let end = Int64(to.timeIntervalSince1970 * 1000)
        let inside = records.filter { $0.startedAt >= start && $0.startedAt < end && $0.doneSetCount > 0 }
        return PeriodSummary(
            workouts: inside.count,
            totalSeconds: inside.reduce(0) { $0 + $1.durationSeconds },
            sets: inside.reduce(0) { $0 + $1.doneSetCount },
            tonnageKg: inside.reduce(0) { $0 + $1.tonnageKg }
        )
    }

    /// This week or month and the one before it, for «итоги» with a comparison.
    public static func periods(
        _ records: [WorkoutRecord],
        component: Calendar.Component,
        now: Date,
        calendar: Calendar
    ) -> (current: PeriodSummary, previous: PeriodSummary) {
        guard let interval = calendar.dateInterval(of: component, for: now),
              let previousStart = calendar.date(byAdding: component, value: -1, to: interval.start) else {
            return (.empty, .empty)
        }
        return (
            summary(records, from: interval.start, to: interval.end),
            summary(records, from: previousStart, to: interval.start)
        )
    }

    /// Workouts per day for the calendar heat map, keyed by the start of the day.
    public static func activeDays(_ records: [WorkoutRecord], calendar: Calendar) -> [Date: Int] {
        var days: [Date: Int] = [:]
        for record in records where record.doneSetCount > 0 {
            days[calendar.startOfDay(for: date(record.startedAt)), default: 0] += 1
        }
        return days
    }

    // MARK: - Helpers

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func firstSetTime(_ session: WorkoutSessionState) -> Int64? {
        session.exercises.flatMap { $0.sets.compactMap { $0.at } }.min()
    }
}
