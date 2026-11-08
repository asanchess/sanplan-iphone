import XCTest
import SwiftUI
@testable import SanPlan

final class WorkoutBuilderAndLibraryTests: XCTestCase {

    // MARK: - WorkoutFormat (builder labels)

    func testRestFormatBoundaries() {
        XCTAssertEqual(WorkoutFormat.rest(0), "0 с")
        XCTAssertEqual(WorkoutFormat.rest(59), "59 с")
        XCTAssertEqual(WorkoutFormat.rest(60), "1:00")
        XCTAssertEqual(WorkoutFormat.rest(61), "1:01")
        XCTAssertEqual(WorkoutFormat.rest(605), "10:05")
    }

    func testExerciseSummaryMentionsSidesOnlyWhenPerSide() {
        let lunges = WorkoutExercisePlan(name: "Выпады", sets: 3, reps: 12, perSide: true, restSeconds: 45)
        XCTAssertEqual(WorkoutFormat.exerciseSummary(lunges), "3 × 12 на сторону · отдых 45 с")
        let press = WorkoutExercisePlan(name: "Жим", sets: 4, reps: 8, restSeconds: 90)
        XCTAssertEqual(WorkoutFormat.exerciseSummary(press), "4 × 8 · отдых 1:30")
    }

    // MARK: - ExerciseLibrary

    func testLibraryGroupsAreWellFormed() {
        let ids = ExerciseLibrary.groups.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Group ids are unique")
        for group in ExerciseLibrary.groups {
            XCTAssertFalse(group.title.isEmpty)
            XCTAssertFalse(group.exercises.isEmpty, "\(group.id) has no exercises")
            for name in group.exercises {
                XCTAssertEqual(name, name.trimmingCharacters(in: .whitespacesAndNewlines), "«\(name)» has stray spaces")
            }
        }
        XCTAssertEqual(ExerciseLibrary.allExercises.count, ExerciseLibrary.groups.reduce(0) { $0 + $1.exercises.count })
    }

    func testSearchKeepsGroupIdentityAndOrder() {
        let result = ExerciseLibrary.search("тяга")
        XCTAssertEqual(result.map(\.id), ["back", "legs", "shoulders"])
        XCTAssertEqual(result.map(\.title), ["Спина", "Ноги", "Плечи"])
        XCTAssertTrue(result.flatMap(\.exercises).allSatisfy { $0.lowercased().contains("тяга") })
        XCTAssertEqual(result.first(where: { $0.id == "legs" })?.exercises, ["Румынская тяга"])
        // Hits keep the library's own order inside a group.
        let back = result.first
        let fullBack = ExerciseLibrary.groups.first(where: { $0.id == "back" })?.exercises ?? []
        XCTAssertEqual(back?.exercises, fullBack.filter { $0.lowercased().contains("тяга") })
    }

    func testWhitespaceQueryReturnsEverything() {
        XCTAssertEqual(ExerciseLibrary.search("   \n"), ExerciseLibrary.groups)
    }

    func testSearchTreatsYoAndYeAlikeInBothDirections() {
        XCTAssertEqual(ExerciseLibrary.search("МЁРТВЫЙ").flatMap(\.exercises), ["Мёртвый жук"])
        XCTAssertEqual(ExerciseLibrary.search("мертвый").flatMap(\.exercises), ["Мёртвый жук"])
        XCTAssertEqual(ExerciseLibrary.search("face").flatMap(\.exercises), ["Face pull"], "Latin names are found case-insensitively")
    }

    // MARK: - WorkoutProgress

    func testSetsFractionAcrossExercisesAndEdges() {
        var s = WorkoutSessionState(exercises: [], lastNow: 0)
        XCTAssertEqual(WorkoutProgress.setsFraction(s), 0, "No sets means no progress, not a division by zero")

        s = WorkoutSessionState(
            phase: .working,
            exercises: [SessionExercise(name: "A", rests: [60, 60, 60]), SessionExercise(name: "B", rests: [60])],
            exerciseIndex: 1,
            setIndex: 0,
            lastNow: 0
        )
        XCTAssertEqual(WorkoutProgress.setsFraction(s), 0.75, accuracy: 0.0001)

        s.setIndex = 10
        XCTAssertEqual(WorkoutProgress.setsFraction(s), 1, "Never above one")
    }

    func testWarmUpFractionIsClamped() {
        let s = WorkoutSessionState(exercises: [SessionExercise(name: "A", rests: [60])], lastNow: 0)
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: WorkoutProgress.preparationSeconds + 20), 0)
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: 0), 1)
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: -5), 1)
    }

    func testPausedRestUsesThePlannedRestAndFallsBackOutsideThePlan() {
        var s = WorkoutSessionState(
            phase: .paused,
            exercises: [SessionExercise(name: "A", rests: [60, 120])],
            lastNow: 0
        )
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: 15), 0.75, accuracy: 0.0001)
        s.setIndex = 1
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: 30), 0.75, accuracy: 0.0001)
        // A set index the rests do not cover takes the remaining time as the whole rest.
        s.phase = .resting
        s.setIndex = 5
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: 20), 0, accuracy: 0.0001)
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: 0), 1)
    }

    func testAlertingShowsSetsDone() {
        let s = WorkoutSessionState(
            phase: .alerting,
            exercises: [SessionExercise(name: "A", rests: [60, 60]), SessionExercise(name: "B", rests: [60, 60])],
            setIndex: 1,
            lastNow: 0
        )
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: 999), 0.25, accuracy: 0.0001)
    }

    // MARK: - WorkoutHaptics

    func testHapticsForEveryTransitionKind() {
        XCTAssertEqual(WorkoutHaptics.feedback(from: .preparing, to: .working), .impact(weight: .light, intensity: 0.7))
        XCTAssertEqual(WorkoutHaptics.feedback(from: .paused, to: .working), .impact(weight: .light, intensity: 0.7))
        XCTAssertEqual(WorkoutHaptics.feedback(from: .preparing, to: .resting), .impact(weight: .medium, intensity: 0.8))
        XCTAssertEqual(WorkoutHaptics.feedback(from: .alerting, to: .resting), .impact(weight: .medium, intensity: 0.8))
        XCTAssertEqual(WorkoutHaptics.feedback(from: .resting, to: .complete), .success)
        XCTAssertNil(WorkoutHaptics.feedback(from: .paused, to: .resting), "Resuming a rest is silent")
        XCTAssertNil(WorkoutHaptics.feedback(from: .working, to: .paused))
        XCTAssertNil(WorkoutHaptics.feedback(from: .complete, to: .complete))
    }

    // MARK: - Live Activity state

    func testLiveContentForRestCountsDownAndAlertingDoesNot() throws {
        var s = WorkoutSessionState(
            phase: .resting,
            exercises: [SessionExercise(name: "A", rests: [60, 60])],
            deadline: 120_000,
            lastNow: 60_000,
            workStartedAt: 10_000
        )
        var live = try XCTUnwrap(WorkoutLiveState.content(for: s))
        XCTAssertEqual(live.phase, .resting)
        XCTAssertEqual(live.countdownEnd, Date(timeIntervalSince1970: 120))
        XCTAssertNil(live.stopwatchStart, "Only a set shows the stopwatch")
        XCTAssertNil(live.pausedRemainingSeconds)

        s.phase = .alerting
        live = try XCTUnwrap(WorkoutLiveState.content(for: s))
        XCTAssertEqual(live.phase, .alerting)
        XCTAssertNil(live.countdownEnd, "A rest that ran out has nothing left to count")
    }

    func testLiveContentPausedRoundsUpAndHandlesMissingValues() throws {
        var s = WorkoutSessionState(
            phase: .paused,
            exercises: [SessionExercise(name: "A", rests: [60])],
            pausedRemainingMs: 30_000,
            lastNow: 0
        )
        XCTAssertEqual(try XCTUnwrap(WorkoutLiveState.content(for: s)).pausedRemainingSeconds, 30)
        s.pausedRemainingMs = 1
        XCTAssertEqual(try XCTUnwrap(WorkoutLiveState.content(for: s)).pausedRemainingSeconds, 1)
        s.pausedRemainingMs = nil
        XCTAssertNil(try XCTUnwrap(WorkoutLiveState.content(for: s)).pausedRemainingSeconds)

        s.phase = .working
        s.workStartedAt = nil
        XCTAssertNil(try XCTUnwrap(WorkoutLiveState.content(for: s)).stopwatchStart)
    }

    func testLiveContentDescribesTheCurrentExercise() throws {
        let s = WorkoutSessionState(
            phase: .working,
            exercises: [SessionExercise(name: "A", rests: [60, 60]), SessionExercise(name: "B", rests: [45, 45, 45])],
            exerciseIndex: 1,
            setIndex: 2,
            lastNow: 0
        )
        let live = try XCTUnwrap(WorkoutLiveState.content(for: s))
        XCTAssertEqual(live.exerciseName, "B")
        XCTAssertEqual(live.setNumber, 3)
        XCTAssertEqual(live.setTotal, 3)
        XCTAssertTrue(live.isLastSet)
        XCTAssertEqual(live.progress, 0.8, accuracy: 0.0001)
        XCTAssertEqual(live.setLabel, "Подход 3 из 3")
    }

    func testLiveContentIsNilForAnOutOfRangeExercise() {
        let s = WorkoutSessionState(
            phase: .working,
            exercises: [SessionExercise(name: "A", rests: [60])],
            exerciseIndex: 3,
            lastNow: 0
        )
        XCTAssertNil(WorkoutLiveState.content(for: s))
        XCTAssertNil(WorkoutLiveState.content(for: WorkoutSessionState(exercises: [], lastNow: 0)))
    }

    func testLiveButtonMappingPerPhase() {
        let phases: [WorkoutPhase] = [.preparing, .working, .resting, .paused, .alerting, .complete]
        func types(_ action: WorkoutLiveIntent.Action) -> [String?] {
            phases.map { WorkoutLiveState.command(for: action, phase: $0)?.type }
        }
        XCTAssertEqual(types(.startNow), ["startNow", nil, nil, nil, nil, nil])
        XCTAssertEqual(types(.startRest), ["startRest", "startRest", nil, nil, "startRest", nil])
        XCTAssertEqual(types(.skipRest), [nil, nil, "skipRest", "skipRest", "acknowledge", nil])
        XCTAssertEqual(types(.nextSet), [nil, nil, nil, nil, "acknowledge", nil])
        XCTAssertEqual(types(.addThirty), [nil, nil, "adjust", "adjust", nil, nil])
        XCTAssertEqual(types(.resume), [nil, nil, nil, "resume", nil, nil])
        XCTAssertEqual(types(.finish), ["finish", "finish", "finish", "finish", "finish", nil])
        XCTAssertEqual(WorkoutLiveState.command(for: .addThirty, phase: .paused)?.seconds, 30)
    }

    // MARK: - Shared attributes

    func testPhaseTitlesAreDistinctAndLabelled() {
        let titles: [WorkoutActivityAttributes.Phase: String] = [
            .preparing: "Разминка", .working: "Подход", .resting: "Отдых", .paused: "Пауза", .alerting: "Отдых окончен",
        ]
        for (phase, title) in titles {
            let state = WorkoutActivityAttributes.ContentState(exerciseName: "A", setNumber: 1, setTotal: 1, phase: phase)
            XCTAssertEqual(state.phaseTitle, title)
        }
        XCTAssertEqual(Set(titles.values).count, titles.count)
    }

    func testContentStateSurvivesCoding() throws {
        let state = WorkoutActivityAttributes.ContentState(
            exerciseName: "Присед",
            setNumber: 2,
            setTotal: 4,
            phase: .paused,
            countdownEnd: Date(timeIntervalSince1970: 1_000),
            stopwatchStart: nil,
            pausedRemainingSeconds: 42,
            isLastSet: false,
            progress: 0.25
        )
        let decoded = try JSONDecoder().decode(
            WorkoutActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(WorkoutActivityAttributes.Phase(rawValue: "alerting"), .alerting)
        XCTAssertNil(WorkoutActivityAttributes.Phase(rawValue: "complete"), "A finished workout has no lock-screen phase")
    }
}
