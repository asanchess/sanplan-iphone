import Foundation

public struct WorkoutDomainError: Error, LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public struct WorkoutExercisePlan: Codable, Equatable, Hashable {
    public var name: String
    public var sets: Int
    public var reps: Int
    public var perSide: Bool
    public var restSeconds: Int
    public var restAfterSets: [Int]?
    public var needsClarification: Bool?
    /// Stable identity for the builder; nil only in programs saved before 2.1.
    public var id: String?
    /// Rest after the last set, before the next exercise. Nil uses `restSeconds`.
    public var restAfterExercise: Int?
    /// Working weight in kilograms. Nil: not set yet, or a bodyweight exercise without added load.
    public var weightKg: Double?
    /// True for exercises with the body's own weight (pull-ups, push-ups); `weightKg` is then the added load.
    public var bodyweight: Bool?
    /// How much the progression hint adds once every set reached its reps. Nil uses 2.5 kg.
    public var weightStepKg: Double?

    public init(
        name: String,
        sets: Int = 4,
        reps: Int,
        perSide: Bool = false,
        restSeconds: Int = 120,
        restAfterSets: [Int]? = nil,
        needsClarification: Bool? = nil,
        id: String? = nil,
        restAfterExercise: Int? = nil,
        weightKg: Double? = nil,
        bodyweight: Bool? = nil,
        weightStepKg: Double? = nil
    ) {
        self.weightKg = weightKg
        self.bodyweight = bodyweight
        self.weightStepKg = weightStepKg
        self.id = id
        self.restAfterExercise = restAfterExercise
        self.name = name
        self.sets = sets
        self.reps = reps
        self.perSide = perSide
        self.restSeconds = restSeconds
        self.restAfterSets = restAfterSets
        self.needsClarification = needsClarification
    }
}

public struct WorkoutDayPlan: Codable, Equatable, Hashable {
    public var weekday: Int
    public var exercises: [WorkoutExercisePlan]
    /// Optional name for the day, for example «Ноги».
    public var title: String?

    public init(weekday: Int, exercises: [WorkoutExercisePlan], title: String? = nil) {
        self.weekday = weekday
        self.exercises = exercises
        self.title = title
    }
}

/// One set as it was actually done. Values are filled when the set is marked done and can be changed afterwards.
public struct SetLog: Codable, Equatable, Hashable {
    public var done: Bool
    public var weightKg: Double?
    public var reps: Int?
    /// When the set was marked done.
    public var at: Int64?

    public init(done: Bool = false, weightKg: Double? = nil, reps: Int? = nil, at: Int64? = nil) {
        self.done = done
        self.weightKg = weightKg
        self.reps = reps
        self.at = at
    }
}

public struct SessionExercise: Codable, Equatable, Hashable {
    /// What the screen and the lock screen show, for example «Жим лёжа · 10».
    public var name: String
    /// Rest after each set; its length is the number of sets.
    public var rests: [Int]
    /// The plan exercise this came from, so history and «в прошлый раз» survive a rename. Nil before 2.2.
    public var exerciseId: String?
    /// The exercise name without the reps. Nil before 2.2.
    public var title: String?
    /// Target reps per set.
    public var reps: Int?
    public var perSide: Bool?
    /// Target weight for today, possibly raised by the progression hint.
    public var weightKg: Double?
    /// The weight the plan has, to tell an edit of the plan from today's progression.
    public var planWeightKg: Double?
    public var bodyweight: Bool?
    public var weightStepKg: Double?
    /// One entry per set, parallel to `rests`. Nil or short in sessions saved before 2.2.
    public var log: [SetLog]?
    /// The sets done last time, for «в прошлый раз».
    public var lastTime: [SetLog]?
    /// True when today's weight or reps were raised from last time.
    public var progressed: Bool?

    public init(
        name: String,
        rests: [Int],
        exerciseId: String? = nil,
        title: String? = nil,
        reps: Int? = nil,
        perSide: Bool? = nil,
        weightKg: Double? = nil,
        planWeightKg: Double? = nil,
        bodyweight: Bool? = nil,
        weightStepKg: Double? = nil,
        log: [SetLog]? = nil,
        lastTime: [SetLog]? = nil,
        progressed: Bool? = nil
    ) {
        self.name = name
        self.rests = rests
        self.exerciseId = exerciseId
        self.title = title
        self.reps = reps
        self.perSide = perSide
        self.weightKg = weightKg
        self.planWeightKg = planWeightKg
        self.bodyweight = bodyweight
        self.weightStepKg = weightStepKg
        self.log = log
        self.lastTime = lastTime
        self.progressed = progressed
    }

    /// The log padded or cut to the number of sets.
    public var sets: [SetLog] {
        var result = Array((log ?? []).prefix(rests.count))
        if result.count < rests.count {
            result.append(contentsOf: Array(repeating: SetLog(), count: rests.count - result.count))
        }
        return result
    }

    public var doneCount: Int { sets.filter { $0.done }.count }

    /// The name without the reps: the title, or the shown name cut at « · ».
    public var baseName: String {
        if let title, !title.isEmpty { return title }
        return name.components(separatedBy: " · ").first ?? name
    }

    /// Rebuilds the shown name after the reps or title changed.
    public mutating func refreshName() {
        guard let reps else { return }
        name = "\(baseName) · \(reps)\(perSide == true ? " на каждую сторону" : "")"
    }

    /// Marks a set done with the values the screen suggests, keeping values already entered for it.
    public mutating func markDone(_ index: Int, at now: Int64) {
        guard rests.indices.contains(index) else { return }
        var entries = sets
        let suggested = suggestedValues(for: index)
        entries[index].done = true
        entries[index].at = now
        if entries[index].weightKg == nil { entries[index].weightKg = suggested.weightKg }
        if entries[index].reps == nil { entries[index].reps = suggested.reps }
        log = entries
    }

    /// What a set starts with: the weight of the last earlier set done today, else today's target; the target reps.
    public func suggestedValues(for index: Int) -> (weightKg: Double?, reps: Int?) {
        let entries = sets
        let earlier = entries.prefix(max(0, min(index, entries.count))).last(where: { $0.done })
        return (earlier?.weightKg ?? weightKg, reps)
    }
}

public enum WorkoutPhase: String, Codable, Equatable {
    case preparing
    case working
    case resting
    case paused
    case alerting
    case complete
}

public struct WorkoutCommandRecord: Codable, Equatable, Hashable {
    public var id: String
    public var payload: String

    public init(id: String, payload: String) {
        self.id = id
        self.payload = payload
    }
}

public struct WorkoutCommand: Equatable {
    public var type: String
    public var id: String?
    public var seconds: Int?
    public var count: Int?

    public init(type: String, id: String? = nil, seconds: Int? = nil, count: Int? = nil) {
        self.type = type
        self.id = id
        self.seconds = seconds
        self.count = count
    }

    /// Ends the warm-up early and starts the first set.
    public static func startNow(id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "startNow", id: id)
    }

    /// Changes how many sets the current exercise has; never below the set in progress.
    public static func setSets(_ count: Int, id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "setSets", id: id, count: count)
    }

    public static func recoverClock(id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "recoverClock", id: id)
    }

    public static func tick(id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "tick", id: id)
    }

    public static func startRest(id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "startRest", id: id)
    }

    public static func pause(id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "pause", id: id)
    }

    public static func resume(id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "resume", id: id)
    }

    public static func adjust(seconds: Int, id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "adjust", id: id, seconds: seconds)
    }

    public static func repeatRest(id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "repeatRest", id: id)
    }

    public static func finish(id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "finish", id: id)
    }

    /// Ends the workout after its last set: the set in progress counts as done.
    public static func finishSet(id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "finishSet", id: id)
    }

    public static func skipRest(id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "skipRest", id: id)
    }

    public static func acknowledge(id: String? = nil) -> WorkoutCommand {
        WorkoutCommand(type: "acknowledge", id: id)
    }
}

public struct WorkoutSessionState: Codable, Equatable {
    public var version: Int
    public var revision: Int
    public var phase: WorkoutPhase
    public var exercises: [SessionExercise]
    public var exerciseIndex: Int
    public var setIndex: Int
    public var deadline: Int64?
    public var pausedRemainingMs: Int64?
    public var lastNow: Int64
    public var commandHistory: [WorkoutCommandRecord]
    /// When the current set began (working) or the rest ran out (alerting). Absent in sessions saved before 2.1.
    public var workStartedAt: Int64?
    /// When the workout began, for its total duration. Absent in sessions saved before 2.2.
    public var startedAt: Int64?
    /// When the workout ended.
    public var endedAt: Int64?
    /// The plan day it was started from, to offer saving changes made during the workout.
    public var planDay: WorkoutDayPlan?
    /// The history entry written when it ended, so it is written once.
    public var recordId: String?

    public init(
        version: Int = 1,
        revision: Int = 0,
        phase: WorkoutPhase = .preparing,
        exercises: [SessionExercise],
        exerciseIndex: Int = 0,
        setIndex: Int = 0,
        deadline: Int64? = nil,
        pausedRemainingMs: Int64? = nil,
        lastNow: Int64,
        commandHistory: [WorkoutCommandRecord] = [],
        workStartedAt: Int64? = nil,
        startedAt: Int64? = nil,
        endedAt: Int64? = nil,
        planDay: WorkoutDayPlan? = nil,
        recordId: String? = nil
    ) {
        self.workStartedAt = workStartedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.planDay = planDay
        self.recordId = recordId
        self.version = version
        self.revision = revision
        self.phase = phase
        self.exercises = exercises
        self.exerciseIndex = exerciseIndex
        self.setIndex = setIndex
        self.deadline = deadline
        self.pausedRemainingMs = pausedRemainingMs
        self.lastNow = lastNow
        self.commandHistory = commandHistory
    }
}

public struct WorkoutTrainingPlan: Codable, Equatable {
    public var version: Int
    public var days: [WorkoutDayPlan]
    public var session: WorkoutSessionState?
    /// Values new exercises start with. Nil means `WorkoutDefaults.standard`.
    public var defaults: WorkoutDefaults?

    public init(version: Int = 1, days: [WorkoutDayPlan], session: WorkoutSessionState? = nil, defaults: WorkoutDefaults? = nil) {
        self.version = version
        self.days = days
        self.session = session
        self.defaults = defaults
    }
}

public enum WorkoutDomain {
    public static let maxRestSeconds = 3600
    public static let maxSafeTimerTime: Int64 = 9_007_199_254_740_991 - (3600000 * 2)

    public static func assertValidNow(_ now: Int64, minNow: Int64 = 0) throws {
        if now < 0 || now < minNow || now > maxSafeTimerTime {
            throw WorkoutDomainError("Invalid timestamp")
        }
    }

    public static func getPayloadString(_ cmd: WorkoutCommand) -> String {
        var dict: [String: Any] = ["type": cmd.type]
        if let seconds = cmd.seconds {
            dict["seconds"] = seconds
        }
        if let count = cmd.count {
            dict["count"] = count
        }
        let sortedKeys = dict.keys.sorted()
        var parts: [String] = []
        for key in sortedKeys {
            if let val = dict[key] as? String {
                parts.append("\"\(key)\":\"\(val)\"")
            } else if let val = dict[key] as? Int {
                parts.append("\"\(key)\":\(val)")
            }
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    public static func validateState(_ state: WorkoutSessionState) throws {
        if state.version != 1 {
            throw WorkoutDomainError("Invalid state version")
        }
        if state.revision < 0 {
            throw WorkoutDomainError("Invalid state revision")
        }
        if state.exercises.isEmpty {
            throw WorkoutDomainError("Invalid state exercises")
        }
        if state.exerciseIndex < 0 || state.exerciseIndex >= state.exercises.count {
            throw WorkoutDomainError("Invalid state exerciseIndex")
        }
        for ex in state.exercises {
            let name = ex.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || ex.rests.isEmpty || ex.rests.contains(where: { $0 <= 0 || $0 > maxRestSeconds }) {
                throw WorkoutDomainError("Invalid saved exercises")
            }
        }
        if state.phase == .preparing || state.phase == .resting {
            guard let deadline = state.deadline, deadline >= 0, state.pausedRemainingMs == nil else {
                throw WorkoutDomainError("Invalid saved timer")
            }
        } else if state.deadline != nil {
            throw WorkoutDomainError("Unexpected deadline")
        }

        if state.phase == .paused {
            guard let remaining = state.pausedRemainingMs, remaining > 0, remaining <= 3600000 else {
                throw WorkoutDomainError("Invalid paused timer")
            }
        } else if state.pausedRemainingMs != nil {
            throw WorkoutDomainError("Unexpected paused timer")
        }

        if let started = state.workStartedAt {
            if (state.phase != .working && state.phase != .alerting) || started < 0 {
                throw WorkoutDomainError("Unexpected set start")
            }
        }

        if state.commandHistory.count > 64 {
            throw WorkoutDomainError("Invalid command history")
        }
        for item in state.commandHistory {
            if item.payload.isEmpty || item.id.isEmpty {
                throw WorkoutDomainError("Invalid command history")
            }
        }

        let currentEx = state.exercises[state.exerciseIndex]
        if state.setIndex < 0 || state.setIndex >= currentEx.rests.count {
            throw WorkoutDomainError("Invalid state setIndex")
        }
        if state.lastNow < 0 {
            throw WorkoutDomainError("Invalid state lastNow")
        }
    }

    public static func sessionExercises(from day: WorkoutDayPlan) throws -> [SessionExercise] {
        if day.weekday < 1 || day.weekday > 7 || day.exercises.isEmpty {
            throw WorkoutDomainError("Invalid workout day")
        }
        var result: [SessionExercise] = []
        for exercise in day.exercises {
            let name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let sets = exercise.sets
            let reps = exercise.reps
            let perSide = exercise.perSide
            let restSeconds = exercise.restSeconds
            let restAfterSets = exercise.restAfterSets

            if name.isEmpty || sets < 1 || sets > 100 || reps < 1 {
                throw WorkoutDomainError("Invalid exercise")
            }

            let rests: [Int]
            if let customRests = restAfterSets {
                rests = customRests
            } else if let afterExercise = exercise.restAfterExercise {
                rests = Array(repeating: restSeconds, count: sets - 1) + [afterExercise]
            } else {
                rests = Array(repeating: restSeconds, count: sets)
            }

            if rests.count != sets || rests.contains(where: { $0 < 1 || $0 > maxRestSeconds }) {
                throw WorkoutDomainError("Invalid rest schedule")
            }

            let formattedName = "\(name) · \(reps)\(perSide ? " на каждую сторону" : "")"
            result.append(SessionExercise(
                name: formattedName,
                rests: rests,
                exerciseId: exercise.id,
                title: name,
                reps: reps,
                perSide: perSide,
                weightKg: exercise.weightKg,
                planWeightKg: exercise.weightKg,
                bodyweight: exercise.bodyweight,
                weightStepKg: exercise.weightStepKg
            ))
        }
        return result
    }

    public static func createWorkout(exercises: [SessionExercise], now: Int64) throws -> WorkoutSessionState {
        try assertValidNow(now, minNow: 0)

        if exercises.isEmpty {
            throw WorkoutDomainError("Exercises must be a non-empty array")
        }

        var copiedExercises: [SessionExercise] = []
        for (i, ex) in exercises.enumerated() {
            let name = ex.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                throw WorkoutDomainError("Exercise at index \(i) name cannot be empty")
            }
            if ex.rests.isEmpty {
                throw WorkoutDomainError("Exercise at index \(i) rests must be a non-empty array")
            }
            for (r, rest) in ex.rests.enumerated() {
                if rest <= 0 || rest > maxRestSeconds {
                    throw WorkoutDomainError("Exercise at index \(i) rest at index \(r) must be a positive integer <= 3600")
                }
            }
            var copy = ex
            copy.name = name
            copiedExercises.append(copy)
        }

        return WorkoutSessionState(
            version: 1,
            revision: 0,
            phase: .preparing,
            exercises: copiedExercises,
            exerciseIndex: 0,
            setIndex: 0,
            deadline: now + 30000,
            pausedRemainingMs: nil,
            lastNow: now,
            commandHistory: [],
            startedAt: now
        )
    }

    public static func workoutCommand(state: WorkoutSessionState, command: WorkoutCommand, now: Int64) throws -> WorkoutSessionState {
        try validateState(state)
        let minNow = command.type == "recoverClock" ? 0 : state.lastNow
        try assertValidNow(now, minNow: minNow)

        if let commandId = command.id {
            if commandId.isEmpty {
                throw WorkoutDomainError("Command id cannot be empty")
            }
            if let existing = state.commandHistory.first(where: { $0.id == commandId }) {
                let payload = getPayloadString(command)
                if existing.payload != payload {
                    throw WorkoutDomainError("Same command id with different payload")
                }
                return state
            }
        }

        var newPhase = state.phase
        var newExerciseIndex = state.exerciseIndex
        var newSetIndex = state.setIndex
        var newDeadline = state.deadline
        var newPausedRemainingMs = state.pausedRemainingMs
        var newExercises = state.exercises
        // Only phases that keep a set clock carry it forward; every branch below sets it explicitly when it changes.
        var newWorkStartedAt: Int64? = state.workStartedAt

        switch command.type {
        case "recoverClock":
            if now >= state.lastNow {
                return state
            }
            if state.phase == .preparing || state.phase == .resting {
                let previousDeadline = state.deadline ?? state.lastNow
                let remainder = max(0, previousDeadline - state.lastNow)
                newDeadline = now + remainder
            }
            if let started = state.workStartedAt {
                newWorkStartedAt = max(0, now - max(0, min(state.lastNow - started, 6 * 3_600_000)))
            }

        case "tick":
            if state.phase == .preparing {
                if let deadline = state.deadline, now >= deadline {
                    newPhase = .working
                    newDeadline = nil
                    newPausedRemainingMs = nil
                    newWorkStartedAt = deadline
                } else {
                    return state
                }
            } else if state.phase == .resting {
                if let deadline = state.deadline, now >= deadline {
                    newPhase = .alerting
                    newDeadline = nil
                    newPausedRemainingMs = nil
                    newWorkStartedAt = deadline
                } else {
                    return state
                }
            } else {
                return state
            }

        case "startNow":
            if state.phase != .preparing {
                throw WorkoutDomainError("startNow command is only valid in preparing phase")
            }
            newPhase = .working
            newDeadline = nil
            newPausedRemainingMs = nil
            newWorkStartedAt = now

        case "startRest":
            // The set can end early at any point outside a rest, including during the warm-up.
            // From alerting the user has already done the next set, so move to it first.
            var restExerciseIndex = state.exerciseIndex
            var restSetIndex = state.setIndex
            switch state.phase {
            case .preparing, .working:
                break
            case .alerting:
                guard let next = nextSet(state) else {
                    newPhase = .complete
                    newDeadline = nil
                    newPausedRemainingMs = nil
                    newWorkStartedAt = nil
                    break
                }
                restExerciseIndex = next.exercise
                restSetIndex = next.set
            default:
                throw WorkoutDomainError("startRest command is not valid during a rest")
            }
            if newPhase == .complete { break }
            newExercises[restExerciseIndex].markDone(restSetIndex, at: now)
            let restSeconds = state.exercises[restExerciseIndex].rests[restSetIndex]
            newExerciseIndex = restExerciseIndex
            newSetIndex = restSetIndex
            newPhase = .resting
            newDeadline = now + Int64(restSeconds) * 1000
            newPausedRemainingMs = nil
            newWorkStartedAt = nil

        case "setSets":
            if state.phase == .complete {
                throw WorkoutDomainError("setSets is not valid after the workout")
            }
            guard let count = command.count, count >= state.setIndex + 1, count <= 100 else {
                throw WorkoutDomainError("setSets count must keep the current set and be at most 100")
            }
            var rests = state.exercises[state.exerciseIndex].rests
            if count > rests.count {
                let fill = rests.last ?? 120
                rests.append(contentsOf: Array(repeating: fill, count: count - rests.count))
            } else {
                rests.removeLast(rests.count - count)
            }
            newExercises[state.exerciseIndex].log = Array(newExercises[state.exerciseIndex].sets.prefix(rests.count))
            newExercises[state.exerciseIndex].rests = rests

        case "pause":
            if state.phase != .resting {
                throw WorkoutDomainError("pause command is only valid in resting or paused phase")
            }
            if state.phase == .paused {
                return state
            }
            guard let deadline = state.deadline else {
                throw WorkoutDomainError("Missing deadline in resting phase")
            }
            if now >= deadline {
                newPhase = .alerting
                newDeadline = nil
                newPausedRemainingMs = nil
                newWorkStartedAt = deadline
            } else {
                newPhase = .paused
                newPausedRemainingMs = deadline - now
                newDeadline = nil
                newWorkStartedAt = nil
            }

        case "resume":
            if state.phase != .paused {
                throw WorkoutDomainError("resume command is only valid in resting or paused phase")
            }
            if state.phase == .resting {
                return state
            }
            guard let pausedMs = state.pausedRemainingMs else {
                throw WorkoutDomainError("Missing pausedRemainingMs in paused phase")
            }
            newPhase = .resting
            newDeadline = now + pausedMs
            newPausedRemainingMs = nil

        case "adjust":
            if state.phase != .resting && state.phase != .paused {
                throw WorkoutDomainError("adjust command is only valid in resting or paused phase")
            }
            guard let seconds = command.seconds, seconds != 0, seconds >= -3600, seconds <= 3600 else {
                throw WorkoutDomainError("adjust command requires nonzero integer seconds between -3600 and 3600")
            }

            if state.phase == .resting {
                guard let deadline = state.deadline else {
                    throw WorkoutDomainError("Missing deadline in resting phase")
                }
                let remainingMs = deadline - now + Int64(seconds) * 1000
                if remainingMs <= 0 {
                    newPhase = .alerting
                    newDeadline = nil
                    newPausedRemainingMs = nil
                    newWorkStartedAt = now
                } else {
                    let cappedMs = min(3600000, remainingMs)
                    newPhase = .resting
                    newDeadline = now + cappedMs
                    newPausedRemainingMs = nil
                }
            } else {
                guard let pausedMs = state.pausedRemainingMs else {
                    throw WorkoutDomainError("Missing pausedRemainingMs in paused phase")
                }
                let remainingMs = pausedMs + Int64(seconds) * 1000
                if remainingMs <= 0 {
                    newPhase = .alerting
                    newDeadline = nil
                    newPausedRemainingMs = nil
                    newWorkStartedAt = now
                } else {
                    let cappedMs = min(3600000, remainingMs)
                    newPhase = .paused
                    newDeadline = nil
                    newPausedRemainingMs = cappedMs
                }
            }

        case "repeatRest":
            if state.phase != .resting && state.phase != .paused && state.phase != .alerting {
                throw WorkoutDomainError("repeatRest requires a rest")
            }
            let restSec = state.exercises[state.exerciseIndex].rests[state.setIndex]
            newPhase = .resting
            newDeadline = now + Int64(restSec) * 1000
            newPausedRemainingMs = nil
            newWorkStartedAt = nil

        case "finish":
            if state.phase == .complete {
                return state
            }
            newPhase = .complete
            newDeadline = nil
            newPausedRemainingMs = nil
            newWorkStartedAt = nil

        case "finishSet":
            if state.phase == .complete {
                return state
            }
            if state.phase == .preparing || state.phase == .working {
                newExercises[state.exerciseIndex].markDone(state.setIndex, at: now)
            } else if state.phase == .alerting, let next = nextSet(state) {
                newExercises[next.exercise].markDone(next.set, at: now)
                newExerciseIndex = next.exercise
                newSetIndex = next.set
            }
            newPhase = .complete
            newDeadline = nil
            newPausedRemainingMs = nil
            newWorkStartedAt = nil

        case "skipRest":
            if state.phase != .resting && state.phase != .paused {
                throw WorkoutDomainError("skipRest command is only valid in resting or paused phase")
            }
            if let next = nextSet(state) {
                newExerciseIndex = next.exercise
                newSetIndex = next.set
                newPhase = .working
                newWorkStartedAt = now
            } else {
                newPhase = .complete
                newWorkStartedAt = nil
            }
            newDeadline = nil
            newPausedRemainingMs = nil

        case "acknowledge":
            if state.phase != .alerting {
                throw WorkoutDomainError("acknowledge command is only valid in alerting phase")
            }
            if let next = nextSet(state) {
                newExerciseIndex = next.exercise
                newSetIndex = next.set
                newPhase = .working
                // The next set began when the rest ran out, not when the alert was dismissed.
                newWorkStartedAt = state.workStartedAt ?? now
            } else {
                newPhase = .complete
                newWorkStartedAt = nil
            }
            newDeadline = nil
            newPausedRemainingMs = nil

        default:
            throw WorkoutDomainError("Unknown command type: \(command.type)")
        }

        var nextHistory = state.commandHistory
        if let cmdId = command.id {
            nextHistory.append(WorkoutCommandRecord(id: cmdId, payload: getPayloadString(command)))
            if nextHistory.count > 64 {
                nextHistory.removeFirst(nextHistory.count - 64)
            }
        }

        return WorkoutSessionState(
            version: 1,
            revision: state.revision + 1,
            phase: newPhase,
            exercises: newExercises,
            exerciseIndex: newExerciseIndex,
            setIndex: newSetIndex,
            deadline: newDeadline,
            pausedRemainingMs: newPausedRemainingMs,
            lastNow: now,
            commandHistory: nextHistory,
            workStartedAt: (newPhase == .working || newPhase == .alerting) ? newWorkStartedAt : nil,
            startedAt: state.startedAt,
            endedAt: newPhase == .complete ? (state.endedAt ?? now) : nil,
            planDay: state.planDay,
            recordId: state.recordId
        )
    }

    /// Whole seconds since the workout began; nil for sessions saved before 2.2. Stops at the end.
    public static func totalElapsedSeconds(state: WorkoutSessionState, now: Int64) -> Int? {
        guard let started = state.startedAt else { return nil }
        let end = state.endedAt ?? now
        return Int(max(0, end - started) / 1000)
    }

    /// The set after the current one, or nil when the current set is the last of the workout.
    /// True when no set follows the current one, so the screen offers to finish instead of a rest or a set that will not happen.
    public static func isLastSet(_ state: WorkoutSessionState) -> Bool {
        nextSet(state) == nil
    }

    static func nextSet(_ state: WorkoutSessionState) -> (exercise: Int, set: Int)? {
        if state.setIndex + 1 < state.exercises[state.exerciseIndex].rests.count {
            return (state.exerciseIndex, state.setIndex + 1)
        }
        if state.exerciseIndex + 1 < state.exercises.count {
            return (state.exerciseIndex + 1, 0)
        }
        return nil
    }

    /// Seconds since the current set began, for the set stopwatch. Nil outside a set or for sessions saved before 2.1.
    /// A tap carries the time of the frame it was drawn in, which can trail the last command
    /// (for example a tick sent on returning to the app) by a fraction of a second.
    public static func userCommandTime(_ now: Int64, state: WorkoutSessionState) -> Int64 {
        if now < state.lastNow && state.lastNow - now <= 5_000 {
            return state.lastNow
        }
        return now
    }

    public static func elapsedWorkSeconds(state: WorkoutSessionState, now: Int64) -> Int? {
        guard state.phase == .working || state.phase == .alerting, let started = state.workStartedAt else { return nil }
        return Int(max(0, now - started) / 1000)
    }

    public static func remainingSeconds(state: WorkoutSessionState, now: Int64) throws -> Int {
        try validateState(state)
        try assertValidNow(now, minNow: state.lastNow)

        if state.phase == .paused {
            let ms = state.pausedRemainingMs ?? 0
            let nonNegative = max(0, ms)
            return Int(ceil(Double(nonNegative) / 1000.0))
        }

        if state.phase == .preparing || state.phase == .resting {
            guard let deadline = state.deadline else {
                return 0
            }
            let diff = max(0, deadline - now)
            return Int(ceil(Double(diff) / 1000.0))
        }

        return 0
    }

    public static func parseWorkoutText(
        _ text: String,
        defaultSets: Int = 4,
        defaultRestSeconds: Int = 120
    ) throws -> WorkoutTrainingPlan {
        if text.count > 100000 || defaultSets < 1 || defaultSets > 100 || defaultRestSeconds < 1 || defaultRestSeconds > 3600 {
            throw WorkoutDomainError("Проверь текст, подходы и время отдыха.")
        }

        var sets = defaultSets
        let globalPattern = try NSRegularExpression(pattern: "везде\\s+по\\s+(\\d+)\\s+подход[а-я]*", options: .caseInsensitive)
        let textRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = globalPattern.firstMatch(in: text, options: [], range: textRange),
           let subRange = Range(match.range(at: 1), in: text),
           let parsedSets = Int(text[subRange]) {
            sets = parsedSets
        }

        if sets < 1 || sets > 100 {
            throw WorkoutDomainError("Количество подходов — от 1 до 100.")
        }

        let weekdayMap: [String: Int] = [
            "пн": 1, "вт": 2, "ср": 3, "чт": 4, "пт": 5, "сб": 6, "вс": 7
        ]

        var days: [WorkoutDayPlan] = []
        let lines = text.components(separatedBy: .newlines)
        let punctuationRegex = try NSRegularExpression(pattern: "^[.,…\\s]+$", options: [])
        let globalLineRegex = try NSRegularExpression(pattern: "^везде\\s+по\\s+\\d+\\s+подход[а-я]*[.!]?$", options: .caseInsensitive)
        let exerciseRegex = try NSRegularExpression(
            pattern: "^(.+?)[,\\s]+(\\d+)\\s*раз(?:а|ов)?(?:\\s+(на каждую (?:ногу|сторону)))?[.!]?$",
            options: .caseInsensitive
        )
        let timeRegex = try NSRegularExpression(pattern: "\\d+\\s*(?:секунд|сек\\b|минут|мин\\b)", options: .caseInsensitive)

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if punctuationRegex.firstMatch(in: line, options: [], range: lineRange) != nil {
                continue
            }
            if globalLineRegex.firstMatch(in: line, options: [], range: lineRange) != nil {
                continue
            }

            var heading = line.lowercased()
            if heading.hasSuffix(".") || heading.hasSuffix(":") {
                heading.removeLast()
            }

            if let wday = weekdayMap[heading] {
                if days.contains(where: { $0.weekday == wday }) {
                    throw WorkoutDomainError("День «\(heading)» указан дважды.")
                }
                days.append(WorkoutDayPlan(weekday: wday, exercises: []))
                continue
            }

            if days.isEmpty {
                throw WorkoutDomainError("Строка \(index + 1): сначала укажи день, например вт.")
            }

            if timeRegex.firstMatch(in: line, options: [], range: lineRange) != nil {
                throw WorkoutDomainError("Строка \(index + 1): упражнения на время пока не поддерживаются. Укажи повторения: «Упражнение, 12 раз».")
            }

            guard let match = exerciseRegex.firstMatch(in: line, options: [], range: lineRange) else {
                throw WorkoutDomainError("Строка \(index + 1): не удалось прочитать упражнение. Формат: «Упражнение, 12 раз».")
            }

            guard let nameRange = Range(match.range(at: 1), in: line),
                  let repsRange = Range(match.range(at: 2), in: line) else {
                throw WorkoutDomainError("Строка \(index + 1): не удалось прочитать упражнение. Формат: «Упражнение, 12 раз».")
            }

            var exName = String(line[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            while exName.hasSuffix(",") || exName.hasSuffix(" ") {
                exName.removeLast()
            }
            exName = exName.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let reps = Int(line[repsRange]), reps >= 1, reps <= 10000, !exName.isEmpty else {
                throw WorkoutDomainError("Строка \(index + 1): не удалось прочитать упражнение. Формат: «Упражнение, 12 раз».")
            }

            var perSide = false
            if match.range(at: 3).location != NSNotFound {
                perSide = true
            }

            let lastIndex = days.count - 1
            days[lastIndex].exercises.append(
                WorkoutExercisePlan(
                    name: exName,
                    sets: sets,
                    reps: reps,
                    perSide: perSide,
                    restSeconds: defaultRestSeconds
                )
            )
        }

        if days.isEmpty || days.contains(where: { $0.exercises.isEmpty }) {
            throw WorkoutDomainError("Добавь хотя бы одно упражнение в каждый день.")
        }

        return WorkoutTrainingPlan(version: 1, days: days, session: nil)
    }
}
