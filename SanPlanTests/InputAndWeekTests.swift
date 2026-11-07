import XCTest
@testable import SanPlan

@MainActor
final class InputAndWeekTests: XCTestCase {
    func testLiveSpeechAppendsToTypedText() {
        let drafts = InputDrafts()
        drafts.edit("Завтра в 9", for: .plans)
        drafts.beginDictation(into: .plans)
        drafts.applySpeech("встреча", to: .plans)
        drafts.applySpeech("встреча с Аскаром", to: .plans)
        XCTAssertEqual(drafts.plans, "Завтра в 9 встреча с Аскаром")
        XCTAssertEqual(drafts.money, "", "Speech goes only to the field being dictated into")
    }

    func testDraftSurvivesWhileDictatingAndAfterTabSwitch() {
        // The drafts live in AppModel above the tabs; a tab switch only drops the view, never this object.
        let model = InputDrafts()
        model.beginDictation(into: .money)
        model.applySpeech("потратил 2500 на обед", to: .money)
        let sameObjectAfterTabSwitch = model
        sameObjectAfterTabSwitch.applySpeech("потратил 2500 на обед и 800 на такси", to: .money)
        XCTAssertEqual(sameObjectAfterTabSwitch.money, "потратил 2500 на обед и 800 на такси")
        XCTAssertTrue(model.isDictating(into: .money))
    }

    func testEditedLiveTextIsWhatGetsParsed() {
        let drafts = InputDrafts()
        drafts.beginDictation(into: .plans)
        drafts.applySpeech("в пятницу спорт зал", to: .plans)
        drafts.edit("в пятницу спортзал в 19:00", for: .plans)
        // A late result from the recogniser must not overwrite the edit.
        drafts.applySpeech("в пятницу спорт зал в семь", to: .plans)
        XCTAssertFalse(drafts.isDictating(into: .plans))
        XCTAssertEqual(drafts.take(.plans), "в пятницу спортзал в 19:00")
        XCTAssertEqual(drafts.plans, "", "Parsing empties the field")
    }

    func testComposeHandlesEmptyParts() {
        XCTAssertEqual(InputDrafts.compose(base: "", speech: "  обед 2000 "), "обед 2000")
        XCTAssertEqual(InputDrafts.compose(base: "обед", speech: ""), "обед")
        XCTAssertEqual(InputDrafts.compose(base: "обед ", speech: "2000"), "обед 2000")
    }

    func testWeekIsMondayToSundayAcrossMonthBoundary() {
        let tz = "Asia/Qyzylorda"
        let expected = ["2026-11-30", "2026-12-01", "2026-12-02", "2026-12-03", "2026-12-04", "2026-12-05", "2026-12-06"]
        XCTAssertEqual(PlanWeek.days(containing: "2026-12-02", timeZone: tz), expected)
        XCTAssertEqual(PlanWeek.days(containing: "2026-11-30", timeZone: tz), expected, "Monday starts its own week")
        XCTAssertEqual(PlanWeek.days(containing: "2026-12-06", timeZone: tz), expected, "Sunday ends the week")
        XCTAssertEqual(PlanWeek.title(of: expected, timeZone: tz), "30 ноября – 6 декабря")
        XCTAssertEqual(PlanWeek.title(of: PlanWeek.days(containing: "2026-11-11", timeZone: tz), timeZone: tz), "9–15 ноября")
    }

    func testTrainingRowsFollowTheProgramAndCreateNoPlans() throws {
        var program = WorkoutProgram.empty()
        program = try WorkoutProgram.addExercise(program, weekday: 1, name: "Жим", id: "a")
        program = try WorkoutProgram.addExercise(program, weekday: 1, name: "Тяга", id: "b")
        program = try WorkoutProgram.addExercise(program, weekday: 4, name: "Присед", id: "c")
        program = WorkoutProgram.setDayTitle(program, weekday: 4, title: "Ноги")
        let days = PlanWeek.days(containing: "2026-12-02", timeZone: "Asia/Qyzylorda")

        let rows = PlanWeek.trainingRows(program: program, days: days, timeZone: "Asia/Qyzylorda")
        XCTAssertEqual(rows, [
            PlanWeek.TrainingRow(date: "2026-11-30", title: "Тренировка", exerciseCount: 2),
            PlanWeek.TrainingRow(date: "2026-12-03", title: "Ноги", exerciseCount: 1),
        ])

        // Alarms are built only from PlanStore plans; showing the week leaves them untouched.
        UserDefaults.standard.removeObject(forKey: "arna.planner.draft.json")
        let client = APIClient(baseURL: URL(string: "https://example.invalid")!, session: .shared)
        let store = PlanStore(client: client, onUnauthorized: {}, onPlansChanged: { _ in
            XCTFail("Training rows must never reach the alarm sync")
        })
        _ = days.map { store.agenda(for: $0) }
        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertTrue(store.draftPlans.isEmpty)
    }

    func testExercisesLabelPlural() {
        XCTAssertEqual(PlanWeek.exercisesLabel(1), "1 упражнение")
        XCTAssertEqual(PlanWeek.exercisesLabel(3), "3 упражнения")
        XCTAssertEqual(PlanWeek.exercisesLabel(5), "5 упражнений")
        XCTAssertEqual(PlanWeek.exercisesLabel(11), "11 упражнений")
        XCTAssertEqual(PlanWeek.exercisesLabel(22), "22 упражнения")
    }
}
