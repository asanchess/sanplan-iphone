import XCTest
import AlarmKit
@testable import SanPlan

final class PlanAlarmSoundTests: XCTestCase {
    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "plan-alarm-sound-\(UUID().uuidString)")! }

    func testDefaultIsSystemTone() {
        XCTAssertNil(AlertSoundSettings.planAlarmSoundName(defaults: freshDefaults()))
    }

    func testMissingCustomFileFallsBackToSystemTone() {
        let defaults = freshDefaults()
        defaults.set("custom:missing-file.mp3", forKey: AlertSoundSettings.planKey)
        XCTAssertNil(AlertSoundSettings.planAlarmSoundName(defaults: defaults))
    }

    func testPlanAndRestChoicesAreIndependent() {
        let defaults = freshDefaults()
        defaults.set("custom:missing-file.mp3", forKey: AlertSoundSettings.restKey)
        XCTAssertNil(AlertSoundSettings.planAlarmSoundName(defaults: defaults))
    }

    func testChangedComparesWithWhatWasApplied() {
        let sound = freshDefaults(), store = freshDefaults()
        XCTAssertFalse(PlanAlarmSound.changed(soundDefaults: sound, store: store), "nothing recorded = system tone was scheduled")
        store.set("arna-tone-01-pulse.caf", forKey: PlanAlarmSound.appliedKey)
        XCTAssertTrue(PlanAlarmSound.changed(soundDefaults: sound, store: store))
        PlanAlarmSound.markApplied(soundDefaults: sound, store: store)
        XCTAssertFalse(PlanAlarmSound.changed(soundDefaults: sound, store: store))
    }

    @MainActor
    func testSoundChangeReschedulesFutureAlarmsWithoutDoubles() async {
        let defaults = freshDefaults()
        let service = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: service, userDefaults: defaults)
        let fire = Date().addingTimeInterval(7200)
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = TimeZone(secondsFromGMT: 0)
        let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"; clock.timeZone = TimeZone(secondsFromGMT: 0)
        let plan = NativePlan(id: "plan-sound-1", title: "Звук", date: day.string(from: fire), time: clock.string(from: fire), reminderOffsets: [0], timeZone: "UTC")
        await coordinator.syncAlarms(plans: [plan])
        XCTAssertEqual(service.systemIDs.count, 1)
        let id = service.systemIDs.first!
        XCTAssertEqual(service.scheduleCallCount[id], 1)

        await coordinator.syncAlarms(plans: [plan])
        XCTAssertEqual(service.scheduleCallCount[id], 1, "same sound: nothing is rebuilt")

        defaults.set("arna-tone-01-pulse.caf", forKey: PlanAlarmSound.appliedKey) // the schedule was built with another sound
        await coordinator.syncAlarms(plans: [plan])
        XCTAssertEqual(service.cancelCallCount[id], 1)
        XCTAssertEqual(service.scheduleCallCount[id], 2)
        XCTAssertEqual(service.systemIDs.count, 1, "no double alarm")
        XCTAssertEqual(defaults.string(forKey: PlanAlarmSound.appliedKey), "")
    }

    @MainActor
    func testSoundChangeBeforePlansAreLoadedDoesNotTouchAlarms() async {
        let defaults = freshDefaults()
        let service = FakeAlarmService()
        let coordinator = AlarmCoordinator(service: service, userDefaults: defaults)
        let fire = Date().addingTimeInterval(7200)
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = TimeZone(secondsFromGMT: 0)
        let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"; clock.timeZone = TimeZone(secondsFromGMT: 0)
        let plan = NativePlan(id: "plan-guard-1", title: "Звук", date: day.string(from: fire), time: clock.string(from: fire), reminderOffsets: [0], timeZone: "UTC")
        await coordinator.syncAlarms(plans: [plan])
        let id = service.systemIDs.first!
        defaults.set("arna-tone-01-pulse.caf", forKey: PlanAlarmSound.appliedKey)

        var loaded = false
        let resync = PlanAlarmResync(alarms: coordinator, plansLoaded: { loaded }, plans: { loaded ? [plan] : [] })
        await resync.soundChanged()
        XCTAssertNil(service.cancelCallCount[id], "plans not loaded yet: the alarm stays")
        XCTAssertEqual(service.systemIDs.count, 1)

        loaded = true
        await resync.soundChanged()
        XCTAssertEqual(service.cancelCallCount[id], 1)
        XCTAssertEqual(service.scheduleCallCount[id], 2)
        XCTAssertEqual(service.systemIDs.count, 1)
    }
}
