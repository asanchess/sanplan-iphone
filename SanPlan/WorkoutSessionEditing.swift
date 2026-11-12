import Foundation

/// Changes to a running workout: logged sets, its exercises and where the user is. Pure, so each step can be undone
/// by keeping the state before it. Every edit keeps the session valid and never touches the rest countdown.
public enum WorkoutSessionEdit {
    public static let weightRange: ClosedRange<Double> = 0...1000
    public static let repsRange: ClosedRange<Int> = 0...1000
    public static let defaultStepKg = 2.5

    /// Sets the weight and reps logged for one set. Nil leaves that value as it is.
    public static func setValues(
        _ state: WorkoutSessionState,
        exercise: Int,
        set: Int,
        weightKg: Double? = nil,
        reps: Int? = nil
    ) throws -> WorkoutSessionState {
        var next = try editable(state)
        try check(next, exercise: exercise, set: set)
        var entries = next.exercises[exercise].sets
        if entries[set].weightKg == nil || entries[set].reps == nil {
            let suggested = next.exercises[exercise].suggestedValues(for: set)
            if entries[set].weightKg == nil { entries[set].weightKg = suggested.weightKg }
            if entries[set].reps == nil { entries[set].reps = suggested.reps }
        }
        if let weightKg {
            entries[set].weightKg = weightRange.contains(weightKg) ? roundWeight(weightKg) : nil
        }
        if let reps {
            guard repsRange.contains(reps) else { throw WorkoutDomainError("Повторы — от 0 до 1000") }
            entries[set].reps = reps
        }
        next.exercises[exercise].log = entries
        return finish(next, from: state)
    }

    /// Marks a set done or not done, for a set ticked by mistake or one done without pressing the button.
    public static func setDone(_ state: WorkoutSessionState, exercise: Int, set: Int, done: Bool, now: Int64) throws -> WorkoutSessionState {
        var next = try editable(state)
        try check(next, exercise: exercise, set: set)
        if done {
            next.exercises[exercise].markDone(set, at: now)
        } else {
            var entries = next.exercises[exercise].sets
            entries[set].done = false
            entries[set].at = nil
            next.exercises[exercise].log = entries
        }
        return finish(next, from: state)
    }

    /// Adds a set at the end of an exercise with the same rest as its last set.
    public static func addSet(_ state: WorkoutSessionState, exercise: Int) throws -> WorkoutSessionState {
        var next = try editable(state)
        guard next.exercises.indices.contains(exercise) else { throw WorkoutDomainError("Упражнение не найдено") }
        guard next.exercises[exercise].rests.count < 100 else { throw WorkoutDomainError("Не больше 100 подходов") }
        var entries = next.exercises[exercise].sets
        var rests = next.exercises[exercise].rests
        // The new set takes the rest between sets; the last rest (before the next exercise) stays last.
        let between = rests.count > 1 ? rests[rests.count - 2] : rests[rests.count - 1]
        rests.insert(between, at: rests.count - 1)
        entries.append(SetLog())
        next.exercises[exercise].rests = rests
        next.exercises[exercise].log = entries
        return finish(next, from: state)
    }

    /// Removes one set. The last set of an exercise is removed by removing the exercise.
    public static func removeSet(_ state: WorkoutSessionState, exercise: Int, set: Int) throws -> WorkoutSessionState {
        var next = try editable(state)
        try check(next, exercise: exercise, set: set)
        guard next.exercises[exercise].rests.count > 1 else { throw WorkoutDomainError("Это единственный подход: удалите упражнение") }
        var entries = next.exercises[exercise].sets
        var rests = next.exercises[exercise].rests
        let lastRest = rests[rests.count - 1]
        entries.remove(at: set)
        rests.remove(at: set)
        rests[rests.count - 1] = lastRest
        next.exercises[exercise].rests = rests
        next.exercises[exercise].log = entries
        if next.exerciseIndex == exercise {
            if set < next.setIndex {
                next.setIndex -= 1
            }
            next.setIndex = min(next.setIndex, rests.count - 1)
        }
        return finish(next, from: state)
    }

    /// Adds an exercise after the others, or at `index`.
    public static func addExercise(_ state: WorkoutSessionState, _ exercise: SessionExercise, at index: Int? = nil) throws -> WorkoutSessionState {
        var next = try editable(state)
        try validate(exercise)
        let position = min(max(index ?? next.exercises.count, 0), next.exercises.count)
        next.exercises.insert(exercise, at: position)
        if position <= next.exerciseIndex && index != nil {
            next.exerciseIndex += 1
        }
        return finish(next, from: state)
    }

    /// Removes an exercise. The one in progress hands over to the next one, or the previous at the end.
    public static func removeExercise(_ state: WorkoutSessionState, index: Int, now: Int64) throws -> WorkoutSessionState {
        var next = try editable(state)
        guard next.exercises.indices.contains(index) else { throw WorkoutDomainError("Упражнение не найдено") }
        guard next.exercises.count > 1 else { throw WorkoutDomainError("В тренировке должно остаться хотя бы одно упражнение") }
        next.exercises.remove(at: index)
        if index < next.exerciseIndex {
            next.exerciseIndex -= 1
        } else if index == next.exerciseIndex {
            next.exerciseIndex = min(index, next.exercises.count - 1)
            next.setIndex = firstOpenSet(next.exercises[next.exerciseIndex])
            if next.phase == .working || next.phase == .alerting {
                next.phase = .working
                next.workStartedAt = now
            }
        }
        return finish(next, from: state)
    }

    /// Moves an exercise to another place; the one in progress stays current.
    public static func moveExercise(_ state: WorkoutSessionState, from: Int, to: Int) throws -> WorkoutSessionState {
        var next = try editable(state)
        guard next.exercises.indices.contains(from), next.exercises.indices.contains(to) else {
            throw WorkoutDomainError("Упражнение не найдено")
        }
        guard from != to else { return state }
        let current = next.exerciseIndex
        let moved = next.exercises.remove(at: from)
        next.exercises.insert(moved, at: to)
        if current == from {
            next.exerciseIndex = to
        } else if from < current && to >= current {
            next.exerciseIndex -= 1
        } else if from > current && to <= current {
            next.exerciseIndex += 1
        }
        return finish(next, from: state)
    }

    /// Swaps an exercise for another one with the same number of sets and rests. Logged sets start over.
    public static func replaceExercise(_ state: WorkoutSessionState, index: Int, with replacement: SessionExercise) throws -> WorkoutSessionState {
        var next = try editable(state)
        guard next.exercises.indices.contains(index) else { throw WorkoutDomainError("Упражнение не найдено") }
        var swapped = replacement
        swapped.rests = next.exercises[index].rests
        swapped.reps = replacement.reps ?? next.exercises[index].reps
        swapped.perSide = replacement.perSide ?? next.exercises[index].perSide
        swapped.log = nil
        swapped.refreshName()
        try validate(swapped)
        next.exercises[index] = swapped
        return finish(next, from: state)
    }

    /// Today's targets of one exercise. Logged sets keep their values; sets not done yet follow the new targets.
    public static func updateExercise(
        _ state: WorkoutSessionState,
        index: Int,
        reps: Int? = nil,
        weightKg: Double?? = nil,
        restSeconds: Int? = nil,
        bodyweight: Bool? = nil,
        weightStepKg: Double? = nil
    ) throws -> WorkoutSessionState {
        var next = try editable(state)
        guard next.exercises.indices.contains(index) else { throw WorkoutDomainError("Упражнение не найдено") }
        var exercise = next.exercises[index]
        if let reps {
            guard WorkoutProgram.repsRange.contains(reps) else { throw WorkoutDomainError("Повторы — от 1 до 100") }
            exercise.reps = reps
        }
        if let weightKg {
            let value = weightKg.map { roundWeight(min(max($0, weightRange.lowerBound), weightRange.upperBound)) }
            exercise.weightKg = value
            exercise.planWeightKg = value
            exercise.progressed = false
        }
        if let restSeconds {
            guard (1...WorkoutDomain.maxRestSeconds).contains(restSeconds) else { throw WorkoutDomainError("Отдых вне допустимых границ") }
            for i in exercise.rests.indices.dropLast() { exercise.rests[i] = restSeconds }
            if exercise.rests.count == 1 { exercise.rests[0] = restSeconds }
        }
        if let bodyweight { exercise.bodyweight = bodyweight }
        if let weightStepKg {
            guard weightStepKg > 0, weightStepKg <= 50 else { throw WorkoutDomainError("Шаг веса — до 50 кг") }
            exercise.weightStepKg = weightStepKg
        }
        exercise.refreshName()
        next.exercises[index] = exercise
        return finish(next, from: state)
    }

    /// Goes to any set: it becomes the set in progress and its stopwatch starts now. A rest in progress ends.
    public static func jump(_ state: WorkoutSessionState, exercise: Int, set: Int, now: Int64) throws -> WorkoutSessionState {
        var next = try editable(state)
        try check(next, exercise: exercise, set: set)
        try WorkoutDomain.assertValidNow(now, minNow: 0)
        guard next.phase != .complete else { throw WorkoutDomainError("Тренировка уже завершена") }
        next.exerciseIndex = exercise
        next.setIndex = set
        next.phase = .working
        next.deadline = nil
        next.pausedRemainingMs = nil
        next.workStartedAt = now
        next.lastNow = max(next.lastNow, now)
        return finish(next, from: state)
    }

    /// The first set not done yet, or the last set when all are done.
    public static func firstOpenSet(_ exercise: SessionExercise) -> Int {
        exercise.sets.firstIndex(where: { !$0.done }) ?? max(0, exercise.rests.count - 1)
    }

    /// A new exercise for the running workout, from the library or typed by hand.
    public static func newExercise(
        name: String,
        sets: Int,
        reps: Int,
        restSeconds: Int,
        restAfterExercise: Int,
        weightKg: Double? = nil,
        bodyweight: Bool = false,
        id: String = UUID().uuidString
    ) throws -> SessionExercise {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WorkoutDomainError("Введите название упражнения") }
        let count = min(max(sets, 1), 20)
        var exercise = SessionExercise(
            name: title,
            rests: Array(repeating: restSeconds, count: count - 1) + [restAfterExercise],
            exerciseId: id,
            title: title,
            reps: reps,
            perSide: false,
            weightKg: weightKg,
            planWeightKg: weightKg,
            bodyweight: bodyweight
        )
        exercise.refreshName()
        try validate(exercise)
        return exercise
    }

    /// Weights are kept to 0.25 kg so 2.5 + 0.1 steps do not pile up floating-point noise.
    public static func roundWeight(_ value: Double) -> Double {
        (value * 4).rounded() / 4
    }

    // MARK: - Helpers

    private static func editable(_ state: WorkoutSessionState) throws -> WorkoutSessionState {
        try WorkoutDomain.validateState(state)
        return state
    }

    private static func check(_ state: WorkoutSessionState, exercise: Int, set: Int) throws {
        guard state.exercises.indices.contains(exercise),
              state.exercises[exercise].rests.indices.contains(set) else {
            throw WorkoutDomainError("Подход не найден")
        }
    }

    private static func validate(_ exercise: SessionExercise) throws {
        if exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || exercise.rests.isEmpty
            || exercise.rests.count > 100
            || exercise.rests.contains(where: { $0 <= 0 || $0 > WorkoutDomain.maxRestSeconds }) {
            throw WorkoutDomainError("Проверьте упражнение")
        }
    }

    private static func finish(_ edited: WorkoutSessionState, from original: WorkoutSessionState) -> WorkoutSessionState {
        var next = edited
        next.revision = original.revision + 1
        let exercise = next.exercises[next.exerciseIndex]
        next.setIndex = min(max(next.setIndex, 0), exercise.rests.count - 1)
        return next
    }
}
