import AlarmKit
import ActivityKit
import Foundation

/// Звук напоминаний планов в AlarmKit: выбранный в настройках, а без выбора (или если файла нет) — системный тон.
enum PlanAlarmSound {
    static func alertSound(defaults: UserDefaults = .standard) -> AlertConfiguration.AlertSound {
        guard let name = AlertSoundSettings.planAlarmSoundName(defaults: defaults) else { return .default }
        return .named(name)
    }
}
