import XCTest
import SwiftUI
@testable import SanPlan

final class WorkoutProgramTests: XCTestCase {
    private func plan(withDay weekday: Int = 2, names: [String] = ["Жим", "Тяга"]) throws -> WorkoutTrainingPlan {
        var p = WorkoutProgram.empty()
        for (i, name) in names.enumerated() {
            p = try WorkoutProgram.addExercise(p, weekday: weekday, name: name, id: "e\(i)")
        }
        return p
    }

    func testAddExerciseUsesDefaultsAndSortsDays() throws {
        var p = try WorkoutProgram.setDefaults(WorkoutProgram.empty(), WorkoutDefaults(sets: 5, restBetweenSets: 60, restBetweenExercises: 180))
        p = try WorkoutProgram.addExercise(p, weekday: 5, name: "  Присед  ", id: "a")
        p = try WorkoutProgram.addExercise(p, weekday: 1, name: "Жим", id: "b")
        XCTAssertEqual(p.days.map(\.weekday), [1, 5])
        let ex = try XCTUnwrap(WorkoutProgram.day(p, weekday: 5)?.exercises.first)
        XCTAssertEqual(ex.name, "Присед")
        XCTAssertEqual(ex.sets, 5)
        XCTAssertEqual(ex.reps, WorkoutProgram.defaultReps)
        XCTAssertEqual(ex.restSeconds, 60)
        XCTAssertEqual(ex.restAfterExercise, 180)
        XCTAssertEqual(p.version, WorkoutProgram.currentVersion)
    }

    func testAddExerciseRejectsEmptyNameAndBadWeekday() {
        XCTAssertThrowsError(try WorkoutProgram.addExercise(WorkoutProgram.empty(), weekday: 1, name: "   "))
        XCTAssertThrowsError(try WorkoutProgram.addExercise(WorkoutProgram.empty(), weekday: 8, name: "Жим"))
    }

    func testChangingDefaultsLeavesExistingExercises() throws {
        var p = try plan()
        p = try WorkoutProgram.setDefaults(p, WorkoutDefaults(sets: 8, restBetweenSets: 30, restBetweenExercises: 30))
        let existing = try XCTUnwrap(WorkoutProgram.day(p, weekday: 2)?.exercises.first)
        XCTAssertEqual(existing.sets, WorkoutDefaults.standard.sets)
        XCTAssertEqual(existing.restSeconds, WorkoutDefaults.standard.restBetweenSets)
        p = try WorkoutProgram.addExercise(p, weekday: 2, name: "Новое", id: "n")
        XCTAssertEqual(WorkoutProgram.day(p, weekday: 2)?.exercises.last?.sets, 8)
    }

    func testSetDefaultsRejectsOutOfRange() {
        XCTAssertThrowsError(try WorkoutProgram.setDefaults(WorkoutProgram.empty(), WorkoutDefaults(sets: 0, restBetweenSets: 90, restBetweenExercises: 90)))
        XCTAssertThrowsError(try WorkoutProgram.setDefaults(WorkoutProgram.empty(), WorkoutDefaults(sets: 3, restBetweenSets: 5, restBetweenExercises: 90)))
        XCTAssertThrowsError(try WorkoutProgram.setDefaults(WorkoutProgram.empty(), WorkoutDefaults(sets: 3, restBetweenSets: 90, restBetweenExercises: 9999)))
    }

    func testUpdateExerciseClampsAndClearsCustomRests() throws {
        var p = try plan()
        p.days[0].exercises[0].restAfterSets = [10, 10, 10]
        p = try WorkoutProgram.updateExercise(p, weekday: 2, id: "e0") {
            $0.sets = 99
            $0.reps = 0
            $0.restSeconds = 1
            $0.restAfterExercise = 10_000
        }
        let ex = p.days[0].exercises[0]
        XCTAssertEqual(ex.sets, WorkoutProgram.setsRange.upperBound)
        XCTAssertEqual(ex.reps, WorkoutProgram.repsRange.lowerBound)
        XCTAssertEqual(ex.restSeconds, WorkoutProgram.restRange.lowerBound)
        XCTAssertEqual(ex.restAfterExercise, WorkoutProgram.restRange.upperBound)
        XCTAssertNil(ex.restAfterSets)
        XCTAssertThrowsError(try WorkoutProgram.updateExercise(p, weekday: 2, id: "e0") { $0.name = " " })
        XCTAssertThrowsError(try WorkoutProgram.updateExercise(p, weekday: 2, id: "missing") { _ in })
    }

    func testDuplicateMoveDelete() throws {
        var p = try plan(names: ["A", "B", "C"])
        p = try WorkoutProgram.duplicateExercise(p, weekday: 2, id: "e0", newId: "copy")
        XCTAssertEqual(p.days[0].exercises.map(\.id), ["e0", "copy", "e1", "e2"])
        p = try WorkoutProgram.moveExercise(p, weekday: 2, id: "e2", by: -1)
        XCTAssertEqual(p.days[0].exercises.map(\.id), ["e0", "copy", "e2", "e1"])
        let unchanged = try WorkoutProgram.moveExercise(p, weekday: 2, id: "e0", by: -1)
        XCTAssertEqual(unchanged, p)
        for id in ["e0", "copy", "e2"] {
            p = try WorkoutProgram.deleteExercise(p, weekday: 2, id: id)
        }
        XCTAssertEqual(p.days.count, 1)
        p = try WorkoutProgram.deleteExercise(p, weekday: 2, id: "e1")
        XCTAssertTrue(p.days.isEmpty, "Removing the last exercise makes the day a rest day")
    }

    func testDayTitleTrimmedLimitedAndCleared() throws {
        var p = try plan()
        p = WorkoutProgram.setDayTitle(p, weekday: 2, title: "  Ноги  ")
        XCTAssertEqual(p.days[0].title, "Ноги")
        p = WorkoutProgram.setDayTitle(p, weekday: 2, title: String(repeating: "я", count: 60))
        XCTAssertEqual(p.days[0].title?.count, 40)
        p = WorkoutProgram.setDayTitle(p, weekday: 2, title: "   ")
        XCTAssertNil(p.days[0].title)
        XCTAssertEqual(WorkoutProgram.setDayTitle(p, weekday: 6, title: "X"), p)
    }

    func testOldTextProgramIsDroppedButSessionKept() throws {
        let session = WorkoutSessionState(
            exercises: [SessionExercise(name: "Жим · 10", rests: [90])],
            lastNow: 1_000
        )
        let old = WorkoutTrainingPlan(
            version: 1,
            days: [WorkoutDayPlan(weekday: 2, exercises: [WorkoutExercisePlan(name: "Жим", reps: 10)])],
            session: session
        )
        let migrated = WorkoutProgram.migrated(old)
        XCTAssertTrue(migrated.days.isEmpty)
        XCTAssertEqual(migrated.session, session)
        XCTAssertEqual(migrated.version, WorkoutProgram.currentVersion)
        let current = try plan()
        XCTAssertEqual(WorkoutProgram.migrated(current), current)
    }

    func testDecodesPlanWithoutNewFields() throws {
        let json = #"{"version":2,"days":[{"weekday":3,"exercises":[{"name":"Жим","sets":3,"reps":8,"perSide":false,"restSeconds":90}]}]}"#
        let decoded = try JSONDecoder().decode(WorkoutTrainingPlan.self, from: Data(json.utf8))
        XCTAssertNil(decoded.defaults)
        XCTAssertNil(decoded.days[0].title)
        XCTAssertNil(decoded.days[0].exercises[0].id)
        XCTAssertEqual(WorkoutProgram.defaults(of: decoded), .standard)
        // Exercises saved without ids get one when the builder next adds to the plan.
        let next = try WorkoutProgram.addExercise(decoded, weekday: 3, name: "Тяга")
        XCTAssertTrue(next.days[0].exercises.allSatisfy { $0.id != nil })
    }

    func testRestAfterExerciseEndsTheRestSchedule() throws {
        let day = WorkoutDayPlan(weekday: 1, exercises: [
            WorkoutExercisePlan(name: "Жим", sets: 3, reps: 8, restSeconds: 60, restAfterExercise: 150),
            WorkoutExercisePlan(name: "Тяга", sets: 2, reps: 8, restSeconds: 45),
        ])
        let session = try WorkoutDomain.sessionExercises(from: day)
        XCTAssertEqual(session[0].rests, [60, 60, 150])
        XCTAssertEqual(session[1].rests, [45, 45])
    }

    func testWeekdayIsMondayFirst() {
        let utc = TimeZone(identifier: "UTC")!
        // 2026-11-09 is a Monday, 2026-11-15 a Sunday.
        XCTAssertEqual(WorkoutProgram.weekday(of: Date(timeIntervalSince1970: 1_794_225_600), timeZone: utc), 1)
        XCTAssertEqual(WorkoutProgram.weekday(of: Date(timeIntervalSince1970: 1_794_744_000), timeZone: utc), 7)
    }

    func testExerciseLibrarySearch() {
        XCTAssertEqual(ExerciseLibrary.search("").count, ExerciseLibrary.groups.count)
        let hits = ExerciseLibrary.search("  ЛЕЖА ").flatMap(\.exercises)
        XCTAssertTrue(hits.contains("Жим штанги лёжа"), "Search ignores case, spaces and ё")
        XCTAssertTrue(ExerciseLibrary.search("лёжа").flatMap(\.exercises).contains("Жим гантелей лёжа"))
        XCTAssertTrue(ExerciseLibrary.search("zzz").isEmpty)
        XCTAssertEqual(Set(ExerciseLibrary.allExercises).count, ExerciseLibrary.allExercises.count, "No duplicate names")
    }

    func testProgressFractionPerPhase() {
        let exercises = [
            SessionExercise(name: "A", rests: [60, 60]),
            SessionExercise(name: "B", rests: [90, 90]),
        ]
        var s = WorkoutSessionState(exercises: exercises, lastNow: 0)
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: 30), 0, accuracy: 0.001)
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: 15), 0.5, accuracy: 0.001)
        s.phase = .resting
        s.exerciseIndex = 1
        s.setIndex = 0
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: 45), 0.5, accuracy: 0.001)
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: 150), 0, accuracy: 0.001, "Extra time restarts the mark")
        s.phase = .working
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: 0), 0.5, accuracy: 0.001, "Two of four sets done")
        s.phase = .complete
        XCTAssertEqual(WorkoutProgress.fraction(s, remainingSeconds: 0), 1)
    }

    func testHapticsOnSetAndRestEnd() {
        XCTAssertNil(WorkoutHaptics.feedback(from: .resting, to: .resting))
        XCTAssertNil(WorkoutHaptics.feedback(from: .resting, to: .paused))
        XCTAssertEqual(WorkoutHaptics.feedback(from: .resting, to: .alerting), .impact(weight: .heavy, intensity: 1))
        XCTAssertEqual(WorkoutHaptics.feedback(from: .working, to: .resting), .impact(weight: .medium, intensity: 0.8))
        XCTAssertEqual(WorkoutHaptics.feedback(from: .working, to: .complete), .success)
    }

    func testLiveStateFollowsSession() throws {
        let exercises = [SessionExercise(name: "Жим · 8", rests: [60, 60])]
        var s = WorkoutSessionState(exercises: exercises, deadline: 40_000, lastNow: 10_000)
        var live = try XCTUnwrap(WorkoutLiveState.content(for: s))
        XCTAssertEqual(live.phase, .preparing)
        XCTAssertEqual(live.setLabel, "Подход 1 из 2")
        XCTAssertEqual(live.countdownEnd, Date(timeIntervalSince1970: 40))
        XCTAssertNil(live.stopwatchStart)
        XCTAssertFalse(live.isLastSet)

        s.phase = .working
        s.deadline = nil
        s.workStartedAt = 50_000
        live = try XCTUnwrap(WorkoutLiveState.content(for: s))
        XCTAssertEqual(live.stopwatchStart, Date(timeIntervalSince1970: 50))
        XCTAssertNil(live.countdownEnd)

        s.phase = .paused
        s.workStartedAt = nil
        s.pausedRemainingMs = 30_500
        live = try XCTUnwrap(WorkoutLiveState.content(for: s))
        XCTAssertEqual(live.pausedRemainingSeconds, 31)

        s.phase = .working
        s.setIndex = 1
        XCTAssertTrue(try XCTUnwrap(WorkoutLiveState.content(for: s)).isLastSet)

        s.phase = .complete
        XCTAssertNil(WorkoutLiveState.content(for: s), "A finished workout leaves the lock screen")
    }

    func testLiveButtonsMapToDomainCommands() {
        XCTAssertEqual(WorkoutLiveState.command(for: .startRest, phase: .working)?.type, WorkoutCommand.startRest().type)
        XCTAssertEqual(WorkoutLiveState.command(for: .skipRest, phase: .resting)?.type, WorkoutCommand.skipRest().type)
        XCTAssertEqual(WorkoutLiveState.command(for: .skipRest, phase: .alerting)?.type, WorkoutCommand.acknowledge().type,
                       "A rest that ended while locked moves on to the next set")
        XCTAssertEqual(WorkoutLiveState.command(for: .addThirty, phase: .resting)?.seconds, 30)
        XCTAssertNil(WorkoutLiveState.command(for: .addThirty, phase: .working))
        XCTAssertNil(WorkoutLiveState.command(for: .startNow, phase: .resting), "A stale button does nothing")
        XCTAssertNil(WorkoutLiveState.command(for: .finish, phase: .complete))
    }

    func testRestFormatting() {
        XCTAssertEqual(WorkoutFormat.rest(45), "45 с")
        XCTAssertEqual(WorkoutFormat.rest(90), "1:30")
        XCTAssertEqual(WorkoutFormat.rest(120), "2:00")
    }
}
