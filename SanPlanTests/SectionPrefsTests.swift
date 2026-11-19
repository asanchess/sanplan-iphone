import XCTest
@testable import SanPlan

/// «Настройки» per section (G) and the day line on «Сегодня» (D-A).
final class SectionPrefsTests: XCTestCase {
    private let suite = "SectionPrefsTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    func testUnsetSwitchesKeepTheOldBehaviour() {
        XCTAssertEqual(SectionPrefs.newPlanOffsets(in: defaults), PlanDomain.defaultReminderOffsets)
        XCTAssertEqual(SectionPrefs.keepDays(in: defaults), 30)
        XCTAssertFalse(SectionPrefs.noteStartsAsList(in: defaults))
        XCTAssertTrue(SectionPrefs.lockScreenCard(in: defaults))
        XCTAssertTrue(SectionPrefs.raiseWeight(in: defaults))
    }

    func testReminderChoicesRoundTripAndBadValuesFallBack() {
        for choice in SectionPrefs.reminderChoices {
            defaults.set(choice.id, forKey: SectionPrefs.Key.planReminders)
            XCTAssertEqual(SectionPrefs.newPlanOffsets(in: defaults), choice.offsets.sorted(by: >))
        }
        XCTAssertEqual(SectionPrefs.decodeOffsets("none"), [])
        XCTAssertNil(SectionPrefs.decodeOffsets("abc"))
        XCTAssertNil(SectionPrefs.decodeOffsets("-5"))
        XCTAssertNil(SectionPrefs.decodeOffsets("99999"))
        defaults.set(3, forKey: SectionPrefs.Key.deletedKeepDays)
        XCTAssertEqual(SectionPrefs.keepDays(in: defaults), 30)
    }

    func testHiddenCardsRoundTrip() {
        let raw = SectionPrefs.encode(hidden: ["review", "rings"])
        XCTAssertEqual(SectionPrefs.hiddenCards(raw), ["review", "rings"])
        XCTAssertEqual(SectionPrefs.hiddenCards(""), [])
    }

    func testNoRaiseKeepsLastWeight() {
        let full = WorkoutRecordExercise(name: "Жим", targetReps: 8, sets: Array(repeating: WorkoutRecordSet(done: true, weightKg: 60, reps: 8), count: 3))
        let kept = WorkoutHistory.target(planReps: 8, planSets: 3, planWeightKg: 55, bodyweight: false, stepKg: nil, last: full, raise: false)
        XCTAssertEqual(kept.weightKg, 60)
        XCTAssertFalse(kept.progressed)
    }

    func testDayLineTakesTimedPlansAndTodaysWorkoutsInOrder() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Qyzylorda"))
        let day = "2026-11-19"
        func agenda(_ id: String, start: Int?, allDay: Bool? = nil, done: Bool? = nil, date: String = day) -> AgendaItem {
            AgendaItem(item: PlanItem(id: id, title: id, date: date, completed: done, allDay: allDay),
                       startMin: start, endMin: nil, displayTime: "", displayDate: date, badge: "")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let at18 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 18, minute: 30)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 18)))
        func workout(_ id: String, _ date: Date) -> WorkoutRecord {
            let ms = Int64(date.timeIntervalSince1970 * 1000)
            return WorkoutRecord(id: id, startedAt: ms, endedAt: ms + 3_000_000, title: nil, exercises: [])
        }
        let marks = DayTimeline.marks(
            agenda: [agenda("late", start: 20 * 60), agenda("early", start: 9 * 60, done: true),
                     agenda("allday", start: 0, allDay: true), agenda("notime", start: nil),
                     agenda("tomorrow", start: 600, date: "2026-11-20")],
            day: day,
            workouts: [workout("w", at18), workout("old", yesterday)],
            timeZone: zone
        )
        XCTAssertEqual(marks.map(\.id), ["plan-early", "workout-w", "plan-late"])
        XCTAssertEqual(marks.map(\.minute), [540, 1110, 1200])
        XCTAssertTrue(marks[0].done)
        XCTAssertFalse(marks[2].done)
        XCTAssertEqual(DayTimeline.spoken(marks), "Лента дня: 2 плана, 1 тренировка")
        XCTAssertEqual(DayTimeline.position(minute: 0), 0)
        XCTAssertEqual(DayTimeline.position(minute: 15 * 60), 0.5)
        XCTAssertEqual(DayTimeline.position(minute: 2000), 1)
    }
}
