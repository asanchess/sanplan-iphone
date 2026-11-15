import AlarmKit
import ActivityKit
import Combine
import Foundation

/// Звук напоминаний планов в AlarmKit: выбранный в настройках, а без выбора (или если файла нет) — системный тон.
enum PlanAlarmSound {
    static let appliedKey = "arna.alarms.plan-sound.applied.v1"

    static func alertSound(defaults: UserDefaults = .standard) -> AlertConfiguration.AlertSound {
        guard let name = AlertSoundSettings.planAlarmSoundName(defaults: defaults) else { return .default }
        return .named(name)
    }

    /// Какой звук сейчас выбран; пусто — системный. Громкость входит в имя файла.
    static func signature(soundDefaults: UserDefaults = .standard) -> String {
        AlertSoundSettings.planAlarmSoundName(defaults: soundDefaults) ?? ""
    }

    /// Звук сменился с тех пор, как расписание AlarmKit собирали в последний раз (не записано — значит, был системный).
    static func changed(soundDefaults: UserDefaults = .standard, store: UserDefaults = .standard) -> Bool {
        (store.string(forKey: appliedKey) ?? "") != signature(soundDefaults: soundDefaults)
    }

    static func markApplied(soundDefaults: UserDefaults = .standard, store: UserDefaults = .standard) {
        store.set(signature(soundDefaults: soundDefaults), forKey: appliedKey)
    }
}

/// Смена звука или громкости напоминаний → `onChange` (пересборка расписания).
@MainActor
final class PlanSoundWatcher {
    private var bag = Set<AnyCancellable>()

    init(settings: AlertSoundSettings = .shared, onChange: @escaping () -> Void) {
        Publishers.CombineLatest(settings.$plan.removeDuplicates(), settings.$planVolume.removeDuplicates())
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { _ in onChange() }
            .store(in: &bag)
    }
}

/// Пересборка расписания после смены звука. Пока планы аккаунта не прочитаны, список пуст не потому что планов нет:
/// пересборка сняла бы все будильники. После загрузки плановый `onPlansChanged` пересоберёт их сам (звук уже сменился).
@MainActor
struct PlanAlarmResync {
    let alarms: AlarmCoordinator
    let plansLoaded: () -> Bool
    let plans: () -> [NativePlan]

    func soundChanged() async {
        guard plansLoaded() else { return }
        await alarms.syncAlarms(plans: plans())
    }
}
