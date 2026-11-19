import XCTest
@testable import SanPlan

/// The workout reminder becomes plan-like alarm entries on the program's training days.
final class WorkoutReminderTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "WorkoutReminderTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private let utc = TimeZone(identifier: "UTC")!

    /// Monday 16.11.2026, 19:00 UTC: today's 18:00 has passed.
    private var mondayEvening: Date { Date(timeIntervalSince1970: 1_794_855_600) }

    func testTrainingDaysInTheNextTwoWeeksAfterNow() {
        let d = defaults()
        d.set(true, forKey: WorkoutReminder.onKey)
        d.set([1, 3], forKey: WorkoutReminder.daysKey)
        d.set(18 * 60, forKey: WorkoutReminder.minutesKey)
        XCTAssertEqual(WorkoutProgram.weekday(of: mondayEvening, timeZone: utc), 1)
        let plans = WorkoutReminder.plans(defaults: d, now: mondayEvening, timeZone: utc)
        XCTAssertEqual(plans.map(\.id), ["workout-reminder-2026-11-18", "workout-reminder-2026-11-23", "workout-reminder-2026-11-25"])
        XCTAssertEqual(plans.first?.time, "18:00")
        XCTAssertEqual(plans.first?.resolvedReminderOffsets(), [0])
        // They go through the same planner as the plans and ring at 18:00.
        let alarms = NativePlanPlanner.planAlarms(plans: plans, referenceDate: mondayEvening).scheduledAlarms
        XCTAssertEqual(alarms.count, 3)
    }

    func testOffOrNoTrainingDaysGivesNothing() {
        let d = defaults()
        d.set([1, 3], forKey: WorkoutReminder.daysKey)
        XCTAssertTrue(WorkoutReminder.plans(defaults: d, now: mondayEvening, timeZone: utc).isEmpty)
        d.set(true, forKey: WorkoutReminder.onKey)
        d.set([Int](), forKey: WorkoutReminder.daysKey)
        XCTAssertTrue(WorkoutReminder.plans(defaults: d, now: mondayEvening, timeZone: utc).isEmpty)
    }

    @MainActor
    func testSettingsStoreAndReportChanges() {
        let d = defaults()
        let settings = WorkoutReminderSettings(defaults: d)
        var calls = 0
        settings.onChange = { calls += 1 }
        settings.setDays([3, 1, 3])
        XCTAssertEqual(settings.days, [1, 3])
        XCTAssertEqual(calls, 0, "days alone do not sync while the reminder is off")
        settings.setOn(true)
        settings.setMinutes(7 * 60 + 30)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(WorkoutReminderSettings(defaults: d).minutes, 450)
        XCTAssertTrue(WorkoutReminderSettings(defaults: d).isOn)
    }
}
