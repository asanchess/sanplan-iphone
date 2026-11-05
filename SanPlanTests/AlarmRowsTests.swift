import XCTest
@testable import SanPlan

final class AlarmRowsTests: XCTestCase {
    private let zone = PlanDomain.defaultTimeZone

    private func plan(_ id: String, time: String = "12:00", offsets: [Int]? = [0]) -> PlanItem {
        PlanItem(id: id, title: id, date: "2030-01-10", time: time, reminderMinutes: nil, reminderOffsets: offsets)
    }

    private func ms(_ time: String) -> Int64 {
        PlanDomain.zonedEpoch(dateStr: "2030-01-10", timeStr: time, timeZone: zone)!
    }

    func testAlarmScheduleOverridesPlanTimeAndOffsets() {
        var item = plan("a")
        item.alarmSchedule = NativeSchedule(date: "2030-01-10", time: "08:00", timeZone: zone, reminderOffsets: [10])
        let row = AlarmRows.row(for: item, nowMs: ms("00:00"))
        XCTAssertEqual(row.eventMs, ms("08:00"))
        XCTAssertEqual(row.signals.map(\.fireMs), [ms("07:50")])
    }

    func testPastSignalsAreKeptButNotNext() {
        let row = AlarmRows.row(for: plan("a", offsets: [60, 0]), nowMs: ms("11:30"))
        XCTAssertEqual(row.signals.map(\.isPast), [true, false])
        XCTAssertEqual(row.nextSignal?.offset, 0)
    }

    func testDefaultListHidesCompletedDeletedAndSilentPlans() {
        var done = plan("done")
        done.completed = true
        var deleted = plan("deleted")
        deleted.alarmDeleted = true
        let silent = plan("silent", offsets: [])
        let rows = AlarmRows.build(plans: [done, deleted, silent, plan("kept")], nowMs: ms("00:00"), showAll: false)
        XCTAssertEqual(rows.map(\.plan.id), ["kept"])
        XCTAssertEqual(AlarmRows.build(plans: [done, deleted, silent], nowMs: ms("00:00"), showAll: true).count, 3)
    }

    func testRowsSortByNextSignalThenPast() {
        let rows = AlarmRows.build(
            plans: [plan("later", time: "15:00"), plan("past", time: "06:00"), plan("soon", time: "10:00")],
            nowMs: ms("09:00"),
            showAll: false
        )
        XCTAssertEqual(rows.map(\.plan.id), ["soon", "later", "past"])
    }

    func testAgendaDropsAlarmOnlyAndGoogleDuplicateOfSavedPlan() {
        var saved = plan("saved")
        saved.kind = "event"
        saved.durationMinutes = 30
        saved.googleEventId = "g1"
        saved.savedAt = "2030-01-01"
        var remote = plan("remote-copy")
        remote.durationMinutes = 30
        remote.googleEventId = "g1"
        var alarm = plan("alarm")
        alarm.alarmOnly = true
        let items = PlanDomain.getAgendaItems(plans: [saved, remote, alarm], targetDate: "2030-01-10", targetTimeZone: zone)
        XCTAssertEqual(items.map(\.item.id), ["saved"])
    }

    func testPlanItemDecodesPartialServerItem() throws {
        let json = #"{"title":"Встреча","date":"2030-01-10","time":"12:00","durationMinutes":null,"googleEventId":null}"#
        let item = try JSONDecoder().decode(PlanItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.kind, "event")
        XCTAssertEqual(item.timeZone, zone)
        XCTAssertFalse(item.id.isEmpty)
    }

    func testReminderFieldsMatchServerConvention() {
        XCTAssertEqual(PlanDomain.withReminderOffsets(plan("a"), offsets: [0, 60]).reminderMinutes, 60)
        XCTAssertEqual(PlanDomain.withReminderOffsets(plan("a"), offsets: []).reminderMinutes, -1)
    }
}
