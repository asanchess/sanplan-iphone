import XCTest
@testable import SanPlan

/// Pure parts of the workout history: editing a running workout, records, «в прошлый раз», progression,
/// saving changes to the plan, streak and totals, and what Apple Health has to change.
final class WorkoutHistoryTests: XCTestCase {
    private let t0: Int64 = 1_700_000_000_000

    private func utc() -> Calendar {
        WorkoutHistory.calendar(timeZone: TimeZone(identifier: "UTC")!)
    }

    private func ms(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10) -> Int64 {
        let date = utc().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func workingSession() throws -> WorkoutSessionState {
        let bench = try WorkoutSessionEdit.newExercise(name: "Жим", sets: 3, reps: 8, restSeconds: 60, restAfterExercise: 90, weightKg: 60, id: "bench")
        let row = try WorkoutSessionEdit.newExercise(name: "Тяга", sets: 2, reps: 10, restSeconds: 60, restAfterExercise: 60, weightKg: 40, id: "row")
        let created = try WorkoutDomain.createWorkout(exercises: [bench, row], now: t0)
        return try WorkoutDomain.workoutCommand(state: created, command: .startNow(), now: t0 + 1_000)
    }

    private func record(
        id: String = UUID().uuidString,
        start: Int64,
        minutes: Int64 = 60,
        exerciseId: String? = nil,
        name: String = "Жим",
        sets: [WorkoutRecordSet] = [WorkoutRecordSet(done: true, weightKg: 60, reps: 8)]
    ) -> WorkoutRecord {
        WorkoutRecord(
            id: id,
            startedAt: start,
            endedAt: start + minutes * 60_000,
            exercises: [WorkoutRecordExercise(exerciseId: exerciseId, name: name, targetReps: 8, sets: sets)]
        )
    }

    // MARK: - Editing a running workout

    func testSetValuesStartFromTheSuggestionAndRoundTheWeight() throws {
        var state = try workingSession()
        state = try WorkoutSessionEdit.setValues(state, exercise: 0, set: 0, weightKg: 62.6)
        XCTAssertEqual(state.exercises[0].sets[0].weightKg, 62.5)
        XCTAssertEqual(state.exercises[0].sets[0].reps, 8)
        XCTAssertFalse(state.exercises[0].sets[0].done)

        state = try WorkoutSessionEdit.setValues(state, exercise: 0, set: 0, reps: 6)
        XCTAssertEqual(state.exercises[0].sets[0].reps, 6)
        XCTAssertEqual(state.exercises[0].sets[0].weightKg, 62.5)
        XCTAssertThrowsError(try WorkoutSessionEdit.setValues(state, exercise: 0, set: 0, reps: 5000))
        XCTAssertThrowsError(try WorkoutSessionEdit.setValues(state, exercise: 0, set: 9, reps: 5))
        XCTAssertThrowsError(try WorkoutSessionEdit.setValues(state, exercise: 7, set: 0, reps: 5))
    }

    func testSetDoneMarksAndUnmarksWithoutTouchingTheTimer() throws {
        let state = try workingSession()
        let marked = try WorkoutSessionEdit.setDone(state, exercise: 1, set: 1, done: true, now: t0 + 5_000)
        XCTAssertTrue(marked.exercises[1].sets[1].done)
        XCTAssertEqual(marked.exercises[1].sets[1].weightKg, 40)
        XCTAssertEqual(marked.exercises[1].sets[1].reps, 10)
        XCTAssertEqual(marked.exercises[1].sets[1].at, t0 + 5_000)
        XCTAssertEqual(marked.phase, state.phase)
        XCTAssertEqual(marked.exerciseIndex, state.exerciseIndex)

        let unmarked = try WorkoutSessionEdit.setDone(marked, exercise: 1, set: 1, done: false, now: t0 + 6_000)
        XCTAssertFalse(unmarked.exercises[1].sets[1].done)
        XCTAssertNil(unmarked.exercises[1].sets[1].at)
        // The values typed for the set stay, so ticking it again keeps them.
        XCTAssertEqual(unmarked.exercises[1].sets[1].weightKg, 40)
    }

    func testAddAndRemoveSetKeepTheRestBeforeTheNextExercise() throws {
        var state = try workingSession()
        state = try WorkoutSessionEdit.addSet(state, exercise: 0)
        XCTAssertEqual(state.exercises[0].rests, [60, 60, 60, 90])
        XCTAssertEqual(state.exercises[0].sets.count, 4)

        state = try WorkoutSessionEdit.removeSet(state, exercise: 0, set: 3)
        XCTAssertEqual(state.exercises[0].rests, [60, 60, 90])

        // Removing a set before the one in progress keeps the same set current.
        state = try WorkoutSessionEdit.jump(state, exercise: 0, set: 2, now: t0 + 10_000)
        state = try WorkoutSessionEdit.removeSet(state, exercise: 0, set: 0)
        XCTAssertEqual(state.setIndex, 1)
        XCTAssertEqual(state.exercises[0].rests, [60, 90])

        state = try WorkoutSessionEdit.removeSet(state, exercise: 0, set: 0)
        XCTAssertEqual(state.exercises[0].rests, [90])
        XCTAssertThrowsError(try WorkoutSessionEdit.removeSet(state, exercise: 0, set: 0))
    }

    func testRemovingTheExerciseInProgressHandsOverToTheNextOne() throws {
        var state = try workingSession()
        XCTAssertThrowsError(try WorkoutSessionEdit.removeExercise(state, index: 5, now: t0))
        state = try WorkoutSessionEdit.removeExercise(state, index: 0, now: t0 + 20_000)
        XCTAssertEqual(state.exercises.map { $0.baseName }, ["Тяга"])
        XCTAssertEqual(state.exerciseIndex, 0)
        XCTAssertEqual(state.setIndex, 0)
        XCTAssertEqual(state.phase, .working)
        XCTAssertEqual(state.workStartedAt, t0 + 20_000)
        XCTAssertThrowsError(try WorkoutSessionEdit.removeExercise(state, index: 0, now: t0 + 21_000))
    }

    func testAddMoveAndReplaceExercisesKeepTheCurrentOne() throws {
        var state = try workingSession()
        let squat = try WorkoutSessionEdit.newExercise(name: "Присед", sets: 2, reps: 5, restSeconds: 120, restAfterExercise: 120, id: "squat")
        state = try WorkoutSessionEdit.addExercise(state, squat, at: 0)
        XCTAssertEqual(state.exercises.map { $0.baseName }, ["Присед", "Жим", "Тяга"])
        XCTAssertEqual(state.exerciseIndex, 1)

        state = try WorkoutSessionEdit.moveExercise(state, from: 1, to: 2)
        XCTAssertEqual(state.exercises.map { $0.baseName }, ["Присед", "Тяга", "Жим"])
        XCTAssertEqual(state.exerciseIndex, 2)
        state = try WorkoutSessionEdit.moveExercise(state, from: 0, to: 2)
        XCTAssertEqual(state.exercises.map { $0.baseName }, ["Тяга", "Жим", "Присед"])
        XCTAssertEqual(state.exerciseIndex, 1)

        state = try WorkoutSessionEdit.setDone(state, exercise: 0, set: 0, done: true, now: t0 + 2_000)
        let dips = SessionExercise(name: "Отжимания на брусьях", rests: [30], exerciseId: "dips", title: "Отжимания на брусьях", bodyweight: true)
        state = try WorkoutSessionEdit.replaceExercise(state, index: 0, with: dips)
        XCTAssertEqual(state.exercises[0].baseName, "Отжимания на брусьях")
        XCTAssertEqual(state.exercises[0].rests, [60, 60], "the replacement keeps the sets of the one it replaces")
        XCTAssertEqual(state.exercises[0].reps, 10)
        XCTAssertEqual(state.exercises[0].doneCount, 0, "logged sets start over")
        XCTAssertEqual(state.exercises[0].name, "Отжимания на брусьях · 10")
    }

    func testUpdateExerciseChangesTodaysTargetsOnly() throws {
        var state = try workingSession()
        state = try WorkoutSessionEdit.setDone(state, exercise: 0, set: 0, done: true, now: t0 + 2_000)
        state = try WorkoutSessionEdit.updateExercise(state, index: 0, reps: 6, weightKg: .some(70), restSeconds: 45, weightStepKg: 5)
        let bench = state.exercises[0]
        XCTAssertEqual(bench.reps, 6)
        XCTAssertEqual(bench.name, "Жим · 6")
        XCTAssertEqual(bench.weightKg, 70)
        XCTAssertEqual(bench.planWeightKg, 70)
        XCTAssertEqual(bench.rests, [45, 45, 90])
        XCTAssertEqual(bench.weightStepKg, 5)
        XCTAssertEqual(bench.sets[0].weightKg, 60, "a set already logged keeps its weight")
        XCTAssertEqual(bench.suggestedValues(for: 1).weightKg, 60, "the next set starts from the last one done today")

        state = try WorkoutSessionEdit.updateExercise(state, index: 0, weightKg: .some(nil))
        XCTAssertNil(state.exercises[0].weightKg)
        XCTAssertThrowsError(try WorkoutSessionEdit.updateExercise(state, index: 0, reps: 0))
        XCTAssertThrowsError(try WorkoutSessionEdit.updateExercise(state, index: 0, restSeconds: 0))
        XCTAssertThrowsError(try WorkoutSessionEdit.updateExercise(state, index: 0, weightStepKg: 0))
    }

    func testJumpGoesToAnySetAndEndsTheRest() throws {
        var state = try workingSession()
        state = try WorkoutDomain.workoutCommand(state: state, command: .startRest(), now: t0 + 30_000)
        XCTAssertEqual(state.phase, .resting)
        state = try WorkoutSessionEdit.jump(state, exercise: 1, set: 1, now: t0 + 31_000)
        XCTAssertEqual(state.phase, .working)
        XCTAssertEqual(state.exerciseIndex, 1)
        XCTAssertEqual(state.setIndex, 1)
        XCTAssertNil(state.deadline)
        XCTAssertEqual(state.workStartedAt, t0 + 31_000)
        XCTAssertTrue(state.exercises[0].sets[0].done)
    }

    func testFinishSetLogsTheLastSetAndStopsTheWorkoutClock() throws {
        var state = try workingSession()
        XCTAssertEqual(WorkoutDomain.totalElapsedSeconds(state: state, now: t0 + 65_000), 65)
        state = try WorkoutDomain.workoutCommand(state: state, command: .finishSet(), now: t0 + 90_000)
        XCTAssertEqual(state.phase, .complete)
        XCTAssertTrue(state.exercises[0].sets[0].done)
        XCTAssertEqual(state.exercises[0].doneCount, 1)
        XCTAssertEqual(state.endedAt, t0 + 90_000)
        XCTAssertEqual(WorkoutDomain.totalElapsedSeconds(state: state, now: t0 + 999_000), 90)
        XCTAssertThrowsError(try WorkoutSessionEdit.jump(state, exercise: 0, set: 1, now: t0 + 91_000))
    }

    func testNewExerciseValidatesItsName() {
        XCTAssertThrowsError(try WorkoutSessionEdit.newExercise(name: "  ", sets: 3, reps: 8, restSeconds: 60, restAfterExercise: 60))
        XCTAssertEqual(WorkoutSessionEdit.roundWeight(2.5 + 0.1), 2.5)
        XCTAssertEqual(WorkoutSessionEdit.roundWeight(61.3), 61.25)
    }

    func testLastTimeLineGroupsAlikeSets() {
        XCTAssertEqual(WorkoutFormat.sets(Array(repeating: (60.0, 8), count: 4), bodyweight: false), "4 × 8 · 60 кг")
        XCTAssertEqual(WorkoutFormat.sets([(60, 8), (60, 6)], bodyweight: false), "60 кг × 8 · 60 кг × 6")
        XCTAssertEqual(WorkoutFormat.sets(Array(repeating: (nil, 10), count: 3), bodyweight: true), "3 × 10 · свой вес")
        XCTAssertEqual(WorkoutFormat.sets([(62.5, 8)], bodyweight: false), "62,5 кг × 8")
    }

    // MARK: - Records

    func testRecordNeedsAtLeastOneSetDone() throws {
        let state = try workingSession()
        let finished = try WorkoutDomain.workoutCommand(state: state, command: .finish(), now: t0 + 60_000)
        XCTAssertNil(WorkoutHistory.record(from: finished, now: t0 + 60_000))
    }

    func testRecordCarriesSetsTimesAndThePlanDay() throws {
        var state = try workingSession()
        state.planDay = WorkoutDayPlan(weekday: 2, exercises: [WorkoutExercisePlan(name: "Жим", reps: 8)], title: "Верх")
        state.recordId = "rec-1"
        state = try WorkoutSessionEdit.setValues(state, exercise: 0, set: 0, weightKg: 62.5, reps: 7)
        state = try WorkoutDomain.workoutCommand(state: state, command: .finishSet(), now: t0 + 1_800_000)
        let record = try XCTUnwrap(WorkoutHistory.record(from: state, now: t0 + 2_000_000))
        XCTAssertEqual(record.id, "rec-1")
        XCTAssertEqual(record.startedAt, t0)
        XCTAssertEqual(record.endedAt, t0 + 1_800_000)
        XCTAssertEqual(record.durationSeconds, 1_800)
        XCTAssertEqual(record.weekday, 2)
        XCTAssertEqual(record.title, "Верх")
        XCTAssertEqual(record.exercises.map { $0.name }, ["Жим", "Тяга"])
        XCTAssertEqual(record.exercises[0].exerciseId, "bench")
        XCTAssertEqual(record.exercises[0].sets[0], WorkoutRecordSet(done: true, weightKg: 62.5, reps: 7))
        XCTAssertEqual(record.doneSetCount, 1)
        XCTAssertEqual(record.plannedSetCount, 5)
        XCTAssertEqual(record.tonnageKg, 437.5, accuracy: 0.001)
    }

    func testValidatedRejectsBadTimesAndTidiesText() throws {
        var bad = record(start: t0)
        bad.endedAt = t0 - 1
        XCTAssertThrowsError(try WorkoutHistory.validated(bad))
        bad.endedAt = t0 + WorkoutHistory.maxDurationMs + 1
        XCTAssertThrowsError(try WorkoutHistory.validated(bad))

        var blankName = record(start: t0)
        blankName.exercises[0].name = "   "
        XCTAssertThrowsError(try WorkoutHistory.validated(blankName))

        var heavy = record(start: t0)
        heavy.exercises[0].sets[0].weightKg = 1500
        XCTAssertThrowsError(try WorkoutHistory.validated(heavy))

        var messy = record(start: t0)
        messy.title = "  "
        messy.note = " тяжело "
        messy.exercises[0].name = " Жим "
        messy.exercises[0].sets[0].weightKg = 60.1
        let clean = try WorkoutHistory.validated(messy)
        XCTAssertNil(clean.title)
        XCTAssertEqual(clean.note, "тяжело")
        XCTAssertEqual(clean.exercises[0].name, "Жим")
        XCTAssertEqual(clean.exercises[0].sets[0].weightKg, 60)
    }

    func testUpsertReplacesByIdAndKeepsNewestFirst() throws {
        var records = try WorkoutHistory.upsert([], record(id: "a", start: t0))
        records = try WorkoutHistory.upsert(records, record(id: "b", start: t0 + 86_400_000))
        XCTAssertEqual(records.map { $0.id }, ["b", "a"])
        records = try WorkoutHistory.upsert(records, record(id: "a", start: t0 + 2 * 86_400_000))
        XCTAssertEqual(records.map { $0.id }, ["a", "b"])
        XCTAssertEqual(WorkoutHistory.removing(records, id: "a").map { $0.id }, ["b"])

        let manual = WorkoutHistory.manualRecord(endingAt: t0)
        XCTAssertTrue(manual.manual)
        XCTAssertEqual(manual.durationSeconds, 3_600)
    }

    // MARK: - Last time and progression

    func testLastPerformanceMatchesByPlanIdBeforeName() {
        let renamed = record(id: "old", start: t0, exerciseId: "bench", name: "Жим штанги")
        let sameName = record(id: "other", start: t0 + 86_400_000, exerciseId: "someone-else", name: "Жим")
        let skipped = record(id: "skipped", start: t0 + 2 * 86_400_000, exerciseId: "bench", name: "Жим",
                             sets: [WorkoutRecordSet(done: false, weightKg: 70, reps: 8)])
        let records = [renamed, sameName, skipped]

        XCTAssertEqual(WorkoutHistory.lastPerformance(records, exerciseId: "bench", name: "Жим")?.name, "Жим штанги",
                       "a rename keeps the history, and a workout with nothing done is skipped")
        XCTAssertEqual(WorkoutHistory.lastPerformance(records, exerciseId: nil, name: " жим ")?.exerciseId, "someone-else")
        XCTAssertNil(WorkoutHistory.lastPerformance(records, exerciseId: "bench", name: "Жим", before: t0))
    }

    func testTargetRaisesTheWeightOnlyWhenEverySetHitItsReps() {
        let full = WorkoutRecordExercise(name: "Жим", targetReps: 8, sets: Array(repeating: WorkoutRecordSet(done: true, weightKg: 60, reps: 8), count: 3))
        let up = WorkoutHistory.target(planReps: 8, planSets: 3, planWeightKg: 55, bodyweight: false, stepKg: nil, last: full)
        XCTAssertEqual(up.weightKg, 62.5)
        XCTAssertTrue(up.progressed)

        let custom = WorkoutHistory.target(planReps: 8, planSets: 3, planWeightKg: nil, bodyweight: false, stepKg: 5, last: full)
        XCTAssertEqual(custom.weightKg, 65)

        var short = full
        short.sets[2].reps = 6
        let same = WorkoutHistory.target(planReps: 8, planSets: 3, planWeightKg: 55, bodyweight: false, stepKg: nil, last: short)
        XCTAssertEqual(same.weightKg, 60)
        XCTAssertFalse(same.progressed)

        var missed = full
        missed.sets[2].done = false
        XCTAssertFalse(WorkoutHistory.target(planReps: 8, planSets: 3, planWeightKg: nil, bodyweight: false, stepKg: nil, last: missed).progressed)

        let planHigher = WorkoutHistory.target(planReps: 8, planSets: 3, planWeightKg: 80, bodyweight: false, stepKg: nil, last: full)
        XCTAssertEqual(planHigher.weightKg, 80)
        XCTAssertFalse(planHigher.progressed)

        let first = WorkoutHistory.target(planReps: 8, planSets: 3, planWeightKg: 50, bodyweight: false, stepKg: nil, last: nil)
        XCTAssertEqual(first.weightKg, 50)
        XCTAssertFalse(first.progressed)
    }

    func testBodyweightProgressionAddsARep() {
        let pullups = WorkoutRecordExercise(name: "Подтягивания", bodyweight: true, targetReps: 8,
                                            sets: Array(repeating: WorkoutRecordSet(done: true, reps: 8), count: 3))
        let next = WorkoutHistory.target(planReps: 8, planSets: 3, planWeightKg: nil, bodyweight: true, stepKg: nil, last: pullups)
        XCTAssertEqual(next.reps, 9)
        XCTAssertNil(next.weightKg)
        XCTAssertTrue(next.progressed)

        var weighted = pullups
        weighted.sets = Array(repeating: WorkoutRecordSet(done: true, weightKg: 10, reps: 8), count: 3)
        let loaded = WorkoutHistory.target(planReps: 8, planSets: 3, planWeightKg: nil, bodyweight: true, stepKg: 2.5, last: weighted)
        XCTAssertEqual(loaded.weightKg, 12.5)
        XCTAssertEqual(loaded.reps, 8)
    }

    func testPreparedFillsLastTimeAndTargetsButNeverThePlan() throws {
        let day = WorkoutDayPlan(weekday: 1, exercises: [WorkoutExercisePlan(name: "Жим", sets: 2, reps: 8, id: "bench", weightKg: 50)])
        let planned = try WorkoutDomain.sessionExercises(from: day)
        let history = [record(start: t0, exerciseId: "bench", sets: [
            WorkoutRecordSet(done: true, weightKg: 60, reps: 8), WorkoutRecordSet(done: true, weightKg: 60, reps: 8)
        ])]
        let prepared = WorkoutHistory.prepared(planned, history: history)
        XCTAssertEqual(prepared[0].lastTime?.count, 2)
        XCTAssertEqual(prepared[0].weightKg, 62.5)
        XCTAssertEqual(prepared[0].planWeightKg, 50, "the hint does not change the plan's weight")
        XCTAssertEqual(prepared[0].progressed, true)
        XCTAssertEqual(prepared[0].name, "Жим · 8")

        let fresh = WorkoutHistory.prepared(planned, history: [])
        XCTAssertNil(fresh[0].lastTime)
        XCTAssertEqual(fresh[0].weightKg, 50)
        XCTAssertEqual(fresh[0].progressed, false)
    }

    // MARK: - Saving changes to the plan

    private func planDay() -> WorkoutDayPlan {
        WorkoutDayPlan(weekday: 3, exercises: [
            WorkoutExercisePlan(name: "Жим", sets: 3, reps: 8, restSeconds: 60, id: "bench", restAfterExercise: 90, weightKg: 60),
            WorkoutExercisePlan(name: "Тяга", sets: 2, reps: 10, restSeconds: 60, id: "row", restAfterExercise: 60)
        ], title: "Верх")
    }

    private func sessionFromPlan() throws -> WorkoutSessionState {
        let day = planDay()
        var state = try WorkoutDomain.createWorkout(exercises: try WorkoutDomain.sessionExercises(from: day), now: t0)
        state.planDay = day
        return state
    }

    func testPlanChangesIgnoreLoggedSetsAndProgression() throws {
        var state = try sessionFromPlan()
        XCTAssertNil(WorkoutHistory.planChanges(state))
        state = try WorkoutSessionEdit.setDone(state, exercise: 0, set: 0, done: true, now: t0 + 1_000)
        state = try WorkoutSessionEdit.setValues(state, exercise: 0, set: 0, weightKg: 65, reps: 6)
        state.exercises[0].weightKg = 62.5
        state.exercises[0].progressed = true
        XCTAssertNil(WorkoutHistory.planChanges(state))
    }

    func testPlanChangesFollowEditedSetsTargetsAndOrder() throws {
        var state = try sessionFromPlan()
        state = try WorkoutSessionEdit.addSet(state, exercise: 0)
        let day = try XCTUnwrap(WorkoutHistory.planChanges(state))
        XCTAssertEqual(day.weekday, 3)
        XCTAssertEqual(day.title, "Верх")
        XCTAssertEqual(day.exercises[0].sets, 4)
        XCTAssertEqual(day.exercises[0].restSeconds, 60)
        XCTAssertEqual(day.exercises[0].restAfterExercise, 90)
        XCTAssertEqual(day.exercises[0].id, "bench")

        var reordered = try sessionFromPlan()
        reordered = try WorkoutSessionEdit.moveExercise(reordered, from: 1, to: 0)
        XCTAssertEqual(WorkoutHistory.planChanges(reordered)?.exercises.map { $0.name }, ["Тяга", "Жим"])

        var retargeted = try sessionFromPlan()
        retargeted = try WorkoutSessionEdit.updateExercise(retargeted, index: 0, reps: 10, weightKg: .some(55))
        let changed = try XCTUnwrap(WorkoutHistory.planChanges(retargeted))
        XCTAssertEqual(changed.exercises[0].reps, 10)
        XCTAssertEqual(changed.exercises[0].weightKg, 55)

        var noPlan = try sessionFromPlan()
        noPlan.planDay = nil
        XCTAssertNil(WorkoutHistory.planChanges(noPlan))
    }

    func testReplaceDayClampsNumbersAndAddsMissingIds() throws {
        let plan = WorkoutTrainingPlan(days: [WorkoutDayPlan(weekday: 5, exercises: [WorkoutExercisePlan(name: "Присед", reps: 5)])])
        let day = WorkoutDayPlan(weekday: 1, exercises: [
            WorkoutExercisePlan(name: " Жим ", sets: 50, reps: 500, restSeconds: 99_999, weightKg: 60.1)
        ])
        let next = try WorkoutProgram.replaceDay(plan, with: day)
        XCTAssertEqual(next.days.map { $0.weekday }, [1, 5])
        let bench = next.days[0].exercises[0]
        XCTAssertEqual(bench.name, "Жим")
        XCTAssertEqual(bench.sets, WorkoutProgram.setsRange.upperBound)
        XCTAssertEqual(bench.reps, WorkoutProgram.repsRange.upperBound)
        XCTAssertEqual(bench.weightKg, 60)
        XCTAssertNotNil(bench.id)

        let replaced = try WorkoutProgram.replaceDay(next, with: WorkoutDayPlan(weekday: 5, exercises: [WorkoutExercisePlan(name: "Тяга", reps: 5)]))
        XCTAssertEqual(replaced.days.count, 2)
        XCTAssertEqual(replaced.days[1].exercises.map { $0.name }, ["Тяга"])

        XCTAssertThrowsError(try WorkoutProgram.replaceDay(plan, with: WorkoutDayPlan(weekday: 8, exercises: [WorkoutExercisePlan(name: "A", reps: 1)])))
        XCTAssertThrowsError(try WorkoutProgram.replaceDay(plan, with: WorkoutDayPlan(weekday: 2, exercises: [])))
    }

    // MARK: - Streak and totals

    func testWeeksStartOnMonday() {
        let calendar = utc()
        // 2026-11-08 is a Sunday, 2026-11-09 a Monday.
        let sunday = WorkoutHistory.date(ms(2026, 11, 8))
        let monday = WorkoutHistory.date(ms(2026, 11, 9))
        XCTAssertNotEqual(WorkoutHistory.weekStart(sunday, calendar: calendar), WorkoutHistory.weekStart(monday, calendar: calendar))
        XCTAssertEqual(WorkoutHistory.weekStart(monday, calendar: calendar), WorkoutHistory.date(ms(2026, 11, 9, 0)))
    }

    func testEffectiveGoalFallsBackToThePlanAndStaysInRange() {
        XCTAssertEqual(WorkoutHistory.effectiveGoal(nil, planDays: 3), 3)
        XCTAssertEqual(WorkoutHistory.effectiveGoal(2, planDays: 3), 2)
        XCTAssertEqual(WorkoutHistory.effectiveGoal(nil, planDays: 0), 1)
        XCTAssertEqual(WorkoutHistory.effectiveGoal(40, planDays: 3), 14)
    }

    func testStreakCountsFullWeeksAndAnUnfinishedWeekDoesNotBreakIt() {
        let calendar = utc()
        // Weeks of 26 Oct, 2 Nov: two each; this week (9 Nov): one so far.
        let records = [
            record(start: ms(2026, 10, 26)), record(start: ms(2026, 10, 29)),
            record(start: ms(2026, 11, 2)), record(start: ms(2026, 11, 8)),
            record(start: ms(2026, 11, 10)),
            // A workout with nothing done does not count.
            record(start: ms(2026, 10, 20), sets: [WorkoutRecordSet(done: false)])
        ]
        let now = WorkoutHistory.date(ms(2026, 11, 11))
        let streak = WorkoutHistory.streak(records, goal: 2, now: now, calendar: calendar)
        XCTAssertEqual(streak.weeks, 2)
        XCTAssertEqual(streak.thisWeek, 1)
        XCTAssertEqual(streak.goal, 2)

        let reached = WorkoutHistory.streak(records + [record(start: ms(2026, 11, 11))], goal: 2, now: now, calendar: calendar)
        XCTAssertEqual(reached.weeks, 3)

        // A missed week ends the streak.
        let gap = WorkoutHistory.streak([record(start: ms(2026, 10, 26)), record(start: ms(2026, 11, 10))], goal: 1, now: now, calendar: calendar)
        XCTAssertEqual(gap.weeks, 1)
        XCTAssertEqual(WorkoutHistory.streak([], goal: 1, now: now, calendar: calendar).weeks, 0)
    }

    func testPeriodsCompareThisWeekWithTheLast() {
        let calendar = utc()
        let records = [
            record(start: ms(2026, 11, 3), minutes: 40, sets: [WorkoutRecordSet(done: true, weightKg: 50, reps: 10)]),
            record(start: ms(2026, 11, 9), minutes: 60, sets: [WorkoutRecordSet(done: true, weightKg: 60, reps: 8), WorkoutRecordSet(done: false, weightKg: 60, reps: 8)]),
            record(start: ms(2026, 11, 10), minutes: 30, sets: [WorkoutRecordSet(done: true, reps: 12)])
        ]
        let now = WorkoutHistory.date(ms(2026, 11, 11))
        let week = WorkoutHistory.periods(records, component: .weekOfYear, now: now, calendar: calendar)
        XCTAssertEqual(week.current.workouts, 2)
        XCTAssertEqual(week.current.totalSeconds, 5_400)
        XCTAssertEqual(week.current.averageSeconds, 2_700)
        XCTAssertEqual(week.current.sets, 2)
        XCTAssertEqual(week.current.tonnageKg, 480, accuracy: 0.001)
        XCTAssertEqual(week.previous.workouts, 1)
        XCTAssertEqual(week.previous.tonnageKg, 500, accuracy: 0.001)

        let month = WorkoutHistory.periods(records, component: .month, now: now, calendar: calendar)
        XCTAssertEqual(month.current.workouts, 3)
        XCTAssertEqual(month.previous, .empty)
        XCTAssertEqual(PeriodSummary.empty.averageSeconds, 0)
    }

    func testActiveDaysCountWorkoutsPerDay() {
        let calendar = utc()
        let days = WorkoutHistory.activeDays([
            record(start: ms(2026, 11, 9, 8)), record(start: ms(2026, 11, 9, 19)),
            record(start: ms(2026, 11, 10)),
            record(start: ms(2026, 11, 11), sets: [WorkoutRecordSet(done: false)])
        ], calendar: calendar)
        XCTAssertEqual(days[WorkoutHistory.date(ms(2026, 11, 9, 0))], 2)
        XCTAssertEqual(days[WorkoutHistory.date(ms(2026, 11, 10, 0))], 1)
        XCTAssertNil(days[WorkoutHistory.date(ms(2026, 11, 11, 0))])
    }

    func testHistoryFileRoundTripsThroughJSON() throws {
        var file = WorkoutHistoryFile()
        file.records = [record(id: "a", start: t0)]
        file.weeklyGoal = 3
        let decoded = try JSONDecoder().decode(WorkoutHistoryFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(decoded, file)
    }

    // MARK: - Apple Health

    func testHealthChangesWriteNewRemoveDeletedAndRewriteMovedWorkouts() {
        let a = record(id: "a", start: t0)
        let b = record(id: "b", start: t0 + 86_400_000)
        let empty = record(id: "e", start: t0 + 2 * 86_400_000, sets: [WorkoutRecordSet(done: false)])

        let added = WorkoutHealthPlan.changes(previous: [a], next: [a, b, empty])
        XCTAssertEqual(added.remove, [])
        XCTAssertEqual(added.write.map { $0.id }, ["b"], "a workout with nothing done is not exported")

        let removed = WorkoutHealthPlan.changes(previous: [a, b], next: [b])
        XCTAssertEqual(removed.remove, ["a"])
        XCTAssertTrue(removed.write.isEmpty)

        var noted = a
        noted.note = "лёгкая"
        noted.exercises[0].sets[0].weightKg = 65
        let unchanged = WorkoutHealthPlan.changes(previous: [a], next: [noted])
        XCTAssertTrue(unchanged.remove.isEmpty && unchanged.write.isEmpty, "Health does not see notes or weights")

        var moved = a
        moved.endedAt += 600_000
        let rewritten = WorkoutHealthPlan.changes(previous: [a], next: [moved])
        XCTAssertEqual(rewritten.remove, ["a"])
        XCTAssertEqual(rewritten.write.map { $0.endedAt }, [moved.endedAt])

        var emptied = a
        emptied.exercises[0].sets[0].done = false
        let dropped = WorkoutHealthPlan.changes(previous: [a], next: [emptied])
        XCTAssertEqual(dropped.remove, ["a"])
        XCTAssertTrue(dropped.write.isEmpty)
    }
}
