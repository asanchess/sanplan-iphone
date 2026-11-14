import XCTest
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
}
