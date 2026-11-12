import Foundation

/// What a new exercise starts with. Changing these never touches exercises that already exist.
public struct WorkoutDefaults: Codable, Equatable, Hashable {
    public var sets: Int
    public var restBetweenSets: Int
    public var restBetweenExercises: Int

    public init(sets: Int, restBetweenSets: Int, restBetweenExercises: Int) {
        self.sets = sets
        self.restBetweenSets = restBetweenSets
        self.restBetweenExercises = restBetweenExercises
    }

    public static let standard = WorkoutDefaults(sets: 3, restBetweenSets: 90, restBetweenExercises: 120)
}

/// Editing the weekly program built in the workout builder. Pure: every operation returns a new plan.
public enum WorkoutProgram {
    /// Programs from 2.1 on. Version 1 programs came from the old text format and are not carried over.
    public static let currentVersion = 2

    public static let setsRange = 1...20
    public static let repsRange = 1...100
    public static let restRange = 15...600
    public static let restStep = 15
    public static let defaultReps = 10

    /// Drops a pre-2.1 text program but keeps a workout in progress.
    public static func migrated(_ plan: WorkoutTrainingPlan) -> WorkoutTrainingPlan {
        guard plan.version < currentVersion else { return plan }
        return WorkoutTrainingPlan(version: currentVersion, days: [], session: plan.session, defaults: plan.defaults)
    }

    public static func empty() -> WorkoutTrainingPlan {
        WorkoutTrainingPlan(version: currentVersion, days: [])
    }

    public static func defaults(of plan: WorkoutTrainingPlan) -> WorkoutDefaults {
        plan.defaults ?? .standard
    }

    public static func day(_ plan: WorkoutTrainingPlan, weekday: Int) -> WorkoutDayPlan? {
        plan.days.first { $0.weekday == weekday }
    }

    public static func setDefaults(_ plan: WorkoutTrainingPlan, _ defaults: WorkoutDefaults) throws -> WorkoutTrainingPlan {
        guard setsRange.contains(defaults.sets),
              restRange.contains(defaults.restBetweenSets),
              restRange.contains(defaults.restBetweenExercises) else {
            throw WorkoutDomainError("Значения по умолчанию вне допустимых границ")
        }
        var next = plan
        next.defaults = defaults
        return next
    }

    public static func addExercise(
        _ plan: WorkoutTrainingPlan,
        weekday: Int,
        name: String,
        id: String = UUID().uuidString
    ) throws -> WorkoutTrainingPlan {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...7).contains(weekday) else { throw WorkoutDomainError("Неверный день недели") }
        guard !trimmed.isEmpty else { throw WorkoutDomainError("Введите название упражнения") }
        let defaults = defaults(of: plan)
        let exercise = WorkoutExercisePlan(
            name: trimmed,
            sets: defaults.sets,
            reps: defaultReps,
            restSeconds: defaults.restBetweenSets,
            id: id,
            restAfterExercise: defaults.restBetweenExercises
        )
        var next = withIdentities(plan)
        if let index = next.days.firstIndex(where: { $0.weekday == weekday }) {
            next.days[index].exercises.append(exercise)
        } else {
            next.days.append(WorkoutDayPlan(weekday: weekday, exercises: [exercise]))
            next.days.sort { $0.weekday < $1.weekday }
        }
        next.version = currentVersion
        return next
    }

    /// Applies an edit to one exercise and clamps every number to its range.
    public static func updateExercise(
        _ plan: WorkoutTrainingPlan,
        weekday: Int,
        id: String,
        _ edit: (inout WorkoutExercisePlan) -> Void
    ) throws -> WorkoutTrainingPlan {
        var next = plan
        let (dayIndex, exerciseIndex) = try locate(next, weekday: weekday, id: id)
        var exercise = next.days[dayIndex].exercises[exerciseIndex]
        edit(&exercise)
        exercise.name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exercise.name.isEmpty else { throw WorkoutDomainError("Введите название упражнения") }
        exercise.sets = clamp(exercise.sets, setsRange)
        exercise.reps = clamp(exercise.reps, repsRange)
        exercise.restSeconds = clamp(exercise.restSeconds, restRange)
        exercise.restAfterExercise = exercise.restAfterExercise.map { clamp($0, restRange) }
        exercise.restAfterSets = nil
        next.days[dayIndex].exercises[exerciseIndex] = exercise
        return next
    }

    public static func duplicateExercise(
        _ plan: WorkoutTrainingPlan,
        weekday: Int,
        id: String,
        newId: String = UUID().uuidString
    ) throws -> WorkoutTrainingPlan {
        var next = plan
        let (dayIndex, exerciseIndex) = try locate(next, weekday: weekday, id: id)
        var copy = next.days[dayIndex].exercises[exerciseIndex]
        copy.id = newId
        next.days[dayIndex].exercises.insert(copy, at: exerciseIndex + 1)
        return next
    }

    /// Moves an exercise up (negative) or down (positive) within its day.
    public static func moveExercise(_ plan: WorkoutTrainingPlan, weekday: Int, id: String, by offset: Int) throws -> WorkoutTrainingPlan {
        var next = plan
        let (dayIndex, exerciseIndex) = try locate(next, weekday: weekday, id: id)
        let target = exerciseIndex + offset
        guard next.days[dayIndex].exercises.indices.contains(target) else { return plan }
        let exercise = next.days[dayIndex].exercises.remove(at: exerciseIndex)
        next.days[dayIndex].exercises.insert(exercise, at: target)
        return next
    }

    /// Removing the last exercise of a day makes it a rest day again.
    public static func deleteExercise(_ plan: WorkoutTrainingPlan, weekday: Int, id: String) throws -> WorkoutTrainingPlan {
        var next = plan
        let (dayIndex, exerciseIndex) = try locate(next, weekday: weekday, id: id)
        next.days[dayIndex].exercises.remove(at: exerciseIndex)
        if next.days[dayIndex].exercises.isEmpty {
            next.days.remove(at: dayIndex)
        }
        return next
    }

    public static func setDayTitle(_ plan: WorkoutTrainingPlan, weekday: Int, title: String) -> WorkoutTrainingPlan {
        var next = plan
        guard let index = next.days.firstIndex(where: { $0.weekday == weekday }) else { return plan }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        next.days[index].title = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        return next
    }

    /// Weekday 1…7 (Monday first) of a date in the given time zone.
    public static func weekday(of date: Date, timeZone: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sundayFirst = calendar.component(.weekday, from: date)
        return (sundayFirst + 5) % 7 + 1
    }

    /// Puts a whole day back, as a workout ended up after «Сохранить изменения в план». Numbers are clamped to the
    /// builder's ranges; weights are kept to 0.25 kg.
    public static func replaceDay(_ plan: WorkoutTrainingPlan, with day: WorkoutDayPlan) throws -> WorkoutTrainingPlan {
        guard (1...7).contains(day.weekday) else { throw WorkoutDomainError("Неверный день недели") }
        guard !day.exercises.isEmpty else { throw WorkoutDomainError("В дне должно быть хотя бы одно упражнение") }
        var clean = day
        for i in clean.exercises.indices {
            var exercise = clean.exercises[i]
            exercise.name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !exercise.name.isEmpty else { throw WorkoutDomainError("Введите название упражнения") }
            exercise.sets = clamp(exercise.sets, setsRange)
            exercise.reps = clamp(exercise.reps, repsRange)
            exercise.restSeconds = clamp(exercise.restSeconds, restRange)
            exercise.restAfterExercise = exercise.restAfterExercise.map { clamp($0, restRange) }
            exercise.restAfterSets = nil
            exercise.weightKg = exercise.weightKg.map { WorkoutSessionEdit.roundWeight(min(max($0, 0), 1000)) }
            if exercise.id == nil { exercise.id = UUID().uuidString }
            clean.exercises[i] = exercise
        }
        var next = plan
        if let index = next.days.firstIndex(where: { $0.weekday == day.weekday }) {
            next.days[index] = clean
        } else {
            next.days.append(clean)
            next.days.sort { $0.weekday < $1.weekday }
        }
        next.version = currentVersion
        return next
    }

    // MARK: - Helpers

    /// Exercises saved without an id get one, so the builder can address them.
    private static func withIdentities(_ plan: WorkoutTrainingPlan) -> WorkoutTrainingPlan {
        var next = plan
        for d in next.days.indices {
            for e in next.days[d].exercises.indices where next.days[d].exercises[e].id == nil {
                next.days[d].exercises[e].id = UUID().uuidString
            }
        }
        return next
    }

    private static func locate(_ plan: WorkoutTrainingPlan, weekday: Int, id: String) throws -> (Int, Int) {
        guard let dayIndex = plan.days.firstIndex(where: { $0.weekday == weekday }),
              let exerciseIndex = plan.days[dayIndex].exercises.firstIndex(where: { $0.id == id }) else {
            throw WorkoutDomainError("Упражнение не найдено")
        }
        return (dayIndex, exerciseIndex)
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
