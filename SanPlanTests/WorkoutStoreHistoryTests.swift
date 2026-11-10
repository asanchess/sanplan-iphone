import XCTest
@testable import SanPlan

/// The workout store with a temporary folder: undo, the history it keeps, accounts and Health sync.
@MainActor
final class WorkoutStoreHistoryTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let t0: Int64 = 1_700_000_000_000

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("workout-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suiteName = "workout-store-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private final class HealthSpy: WorkoutHealthSyncing {
        var calls: [(previous: [WorkoutRecord], next: [WorkoutRecord])] = []
        func sync(previous: [WorkoutRecord], next: [WorkoutRecord]) { calls.append((previous, next)) }
    }

    private func makeStore(owner: FinanceStore.Owner? = .device, remember: Bool = false) -> WorkoutStore {
        WorkoutStore(
            restAlarm: RestAlarmCoordinator(service: FakeRestAlarmService()),
            baseDirectory: base,
            owner: owner,
            defaults: defaults,
            rememberOwner: remember
        )
    }

    private func day() -> WorkoutDayPlan {
        WorkoutDayPlan(weekday: 2, exercises: [
            WorkoutExercisePlan(name: "Жим", sets: 2, reps: 8, restSeconds: 60, id: "bench", restAfterExercise: 60, weightKg: 60)
        ], title: "Верх")
    }

    private func record(id: String, start: Int64) -> WorkoutRecord {
        WorkoutRecord(id: id, startedAt: start, endedAt: start + 3_600_000, exercises: [
            WorkoutRecordExercise(exerciseId: "bench", name: "Жим", targetReps: 8,
                                  sets: [WorkoutRecordSet(done: true, weightKg: 60, reps: 8), WorkoutRecordSet(done: true, weightKg: 60, reps: 8)])
        ])
    }

    func testEditsOfferUndoAndUndoGoesBackOneStepAtATime() {
        let store = makeStore()
        store.setTrainingPlan(WorkoutTrainingPlan(days: [day()]))
        XCTAssertFalse(store.canUndo, "loading a plan is not an undoable edit")

        store.startWorkout(day: day(), now: t0)
        XCTAssertEqual(store.undoOffer?.label, "Тренировка начата")
        store.dispatch(command: .startNow(), now: t0 + 1_000)
        store.dispatch(command: .startRest(), now: t0 + 5_000)
        XCTAssertEqual(store.undoOffer?.label, "Подход отмечен")
        XCTAssertEqual(store.activeSession?.exercises[0].doneCount, 1)

        // Undone before the 30 s warm-up would have run out, so it is put back as it was.
        store.undoLast(now: t0 + 6_000)
        XCTAssertEqual(store.activeSession?.phase, .working)
        XCTAssertEqual(store.activeSession?.exercises[0].doneCount, 0)
        XCTAssertNil(store.undoOffer)

        store.undoLast(now: t0 + 7_000)
        XCTAssertEqual(store.activeSession?.phase, .preparing)
        store.undoLast(now: t0 + 8_000)
        XCTAssertNil(store.activeSession)
        XCTAssertFalse(store.canUndo)
    }

    func testStepperEditsDoNotOfferUndoAndFailedEditsChangeNothing() {
        let store = makeStore()
        store.startWorkout(day: day(), now: t0)
        store.dismissUndo(store.undoOffer!.id)
        XCTAssertNil(store.undoOffer)

        store.editSession(nil, now: t0 + 1_000) { try WorkoutSessionEdit.setValues($0, exercise: 0, set: 0, weightKg: 65) }
        XCTAssertNil(store.undoOffer)
        XCTAssertEqual(store.activeSession?.exercises[0].sets[0].weightKg, 65)

        let before = store.activeSession
        store.editSession("Подход удалён", now: t0 + 2_000) { try WorkoutSessionEdit.removeSet($0, exercise: 0, set: 9) }
        XCTAssertEqual(store.activeSession, before)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.undoOffer)
    }

    func testAFinishedWorkoutIsArchivedAndFollowsLaterEdits() throws {
        let store = makeStore()
        let health = HealthSpy()
        store.health = health
        store.startWorkout(day: day(), now: t0)
        store.dispatch(command: .startNow(), now: t0 + 1_000)
        store.dispatch(command: .finishSet(), now: t0 + 1_200_000)

        XCTAssertEqual(store.records.count, 1)
        let record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(record.id, store.activeSession?.recordId)
        XCTAssertEqual(record.doneSetCount, 1)
        XCTAssertEqual(record.title, "Верх")
        XCTAssertEqual(health.calls.last?.next.map { $0.id }, [record.id])

        // Ticking the second set on the summary updates the same record.
        store.editSession("Подход отмечен", now: t0 + 1_300_000) { try WorkoutSessionEdit.setDone($0, exercise: 0, set: 1, done: true, now: t0 + 1_300_000) }
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.doneSetCount, 2)

        // Undoing the finish takes the record out of the history again.
        store.undoLast(now: t0 + 1_301_000)
        store.undoLast(now: t0 + 1_302_000)
        XCTAssertNotEqual(store.activeSession?.phase, .complete)
        XCTAssertTrue(store.records.isEmpty)

        // Closing the finished summary keeps the record.
        store.dispatch(command: .finishSet(), now: t0 + 1_400_000)
        store.discardWorkout(now: t0 + 1_401_000)
        XCTAssertNil(store.activeSession)
        XCTAssertEqual(store.records.count, 1)
    }

    func testAWorkoutWithNothingDoneIsNotKept() {
        let store = makeStore()
        store.startWorkout(day: day(), now: t0)
        store.dispatch(command: .finish(), now: t0 + 60_000)
        XCTAssertEqual(store.activeSession?.phase, .complete)
        XCTAssertTrue(store.records.isEmpty)
        store.discardWorkout(now: t0 + 61_000)
        XCTAssertNil(store.activeSession)
    }

    func testHistoryIsSavedEditedAndDeletedWithUndo() {
        let store = makeStore()
        store.saveRecord(record(id: "a", start: t0), now: t0)
        XCTAssertEqual(store.undoOffer?.label, "Тренировка добавлена")
        var edited = record(id: "a", start: t0)
        edited.note = "легко"
        store.saveRecord(edited, now: t0 + 1)
        XCTAssertEqual(store.undoOffer?.label, "Тренировка изменена")
        XCTAssertEqual(store.records.first?.note, "легко")

        var broken = edited
        broken.endedAt = broken.startedAt - 1
        store.saveRecord(broken, now: t0 + 2)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.records.first?.endedAt, edited.endedAt)

        store.deleteRecord(id: "a", now: t0 + 3)
        XCTAssertTrue(store.records.isEmpty)
        store.undoLast(now: t0 + 4)
        XCTAssertEqual(store.records.first?.note, "легко")

        // Saved to disk: a fresh store reads the same history.
        XCTAssertEqual(makeStore().records.map { $0.id }, ["a"])
    }

    func testDeletingTheRecordOfTheSummaryOnScreenClosesIt() {
        let store = makeStore()
        store.startWorkout(day: day(), now: t0)
        store.dispatch(command: .finishSet(), now: t0 + 60_000)
        let id = store.activeSession!.recordId!
        store.deleteRecord(id: id, now: t0 + 61_000)
        XCTAssertNil(store.activeSession)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testWeeklyGoalDefaultsToThePlanDays() {
        let store = makeStore()
        store.setTrainingPlan(WorkoutTrainingPlan(days: [day(), WorkoutDayPlan(weekday: 4, exercises: day().exercises)]))
        XCTAssertEqual(store.weeklyGoal, 2)
        store.setWeeklyGoal(4)
        XCTAssertEqual(store.weeklyGoal, 4)
        store.setWeeklyGoal(30)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.weeklyGoal, 4)
        store.setWeeklyGoal(nil)
        XCTAssertEqual(store.weeklyGoal, 2)
        XCTAssertNil(store.undoOffer)
    }

    func testSavingSessionChangesToThePlan() {
        let store = makeStore()
        store.setTrainingPlan(WorkoutTrainingPlan(days: [day()]))
        store.startWorkout(day: day(), now: t0)
        XCTAssertNil(store.pendingPlanChanges)
        store.editSession("Подход добавлен", now: t0 + 1_000) { try WorkoutSessionEdit.addSet($0, exercise: 0) }
        XCTAssertNotNil(store.pendingPlanChanges)
        XCTAssertEqual(store.program.days[0].exercises[0].sets, 2, "edits during a workout do not touch the plan by themselves")

        store.saveSessionChangesToPlan(now: t0 + 2_000)
        XCTAssertEqual(store.program.days[0].exercises[0].sets, 3)
        XCTAssertEqual(store.program.days[0].exercises[0].id, "bench")
        XCTAssertNil(store.pendingPlanChanges)

        store.undoLast(now: t0 + 3_000)
        XCTAssertEqual(store.program.days[0].exercises[0].sets, 2)
    }

    func testEachAccountHasItsOwnWorkoutsAndSignOutKeepsThem() {
        // Workouts from before accounts: in the phone's shared files.
        let legacy = makeStore(owner: .device)
        legacy.saveRecord(record(id: "legacy", start: t0), now: t0)

        let store = makeStore(owner: .device, remember: true)
        store.switchOwner(to: .account(email: "a@example.com"), now: t0)
        XCTAssertEqual(store.records.map { $0.id }, ["legacy"], "the first account takes over the shared files")
        store.saveRecord(record(id: "a1", start: t0 + 86_400_000), now: t0)
        store.startWorkout(day: day(), now: t0 + 100_000)

        store.switchOwner(to: .none, now: t0 + 200_000)
        XCTAssertTrue(store.isSignedOut)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.activeSession)
        XCTAssertFalse(store.canUndo, "undo never crosses accounts")
        store.saveRecord(record(id: "nobody", start: t0), now: t0)
        XCTAssertTrue(store.records.isEmpty, "nothing is saved while signed out")

        store.switchOwner(to: .account(email: "b@example.com"), now: t0 + 300_000)
        XCTAssertTrue(store.records.isEmpty, "a second account does not see the first one's workouts")

        store.switchOwner(to: .account(email: " A@Example.com "), now: t0 + 400_000)
        XCTAssertEqual(Set(store.records.map { $0.id }), ["legacy", "a1"])
        XCTAssertNotNil(store.activeSession, "a workout in progress waits for its account")

        // The shared store reopens the remembered account after a restart.
        let reopened = makeStore(owner: nil, remember: true)
        XCTAssertEqual(Set(reopened.records.map { $0.id }), ["legacy", "a1"])
    }

    func testACorruptHistoryFileIsSetAsideNotFatal() throws {
        let folder = base.appendingPathComponent("ARNA", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent(WorkoutStore.historyFile))
        let store = makeStore()
        XCTAssertTrue(store.records.isEmpty)
        store.saveRecord(record(id: "a", start: t0), now: t0)
        XCTAssertEqual(makeStore().records.map { $0.id }, ["a"])
    }

    func testUndoLabelsForCommands() {
        XCTAssertEqual(WorkoutStore.undoLabel(for: "finishSet"), "Тренировка завершена")
        XCTAssertEqual(WorkoutStore.undoLabel(for: "startRest"), "Подход отмечен")
        XCTAssertNil(WorkoutStore.undoLabel(for: "tick"))
        XCTAssertNil(WorkoutStore.undoLabel(for: "adjustRest"))
    }
}
