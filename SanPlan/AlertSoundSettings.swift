import Combine
import Foundation

/// Выбранные звуки сигналов: конец отдыха (`rest`) и напоминания планов (`plan`).
/// Хранятся на устройстве (UserDefaults) и в общих настройках аккаунта: `s-training.restTone` и `s-plan-sound.planTone`.
/// Побеждает более свежее; свой файл остаётся на устройстве, а на другом без файла звучит системный тон.
@MainActor
public final class AlertSoundSettings: ObservableObject {
    public static let shared = AlertSoundSettings()

    public static let restKey = "arna.sound.rest.v1"
    public static let planKey = "arna.sound.plan.v1"
    public static let restVolumeKey = "arna.sound.rest.volume.v1"
    public static let planVolumeKey = "arna.sound.plan.volume.v1"
    public static let restRecord = "s-training"
    public static let planRecord = "s-plan-sound"

    @Published public private(set) var rest: AlertSoundChoice
    @Published public private(set) var plan: AlertSoundChoice
    /// Ступень громкости, %: 100 / 60 / 35 / 20.
    @Published public private(set) var restVolume: Int
    @Published public private(set) var planVolume: Int

    private let defaults: UserDefaults
    private let now: () -> Int64
    private var collection: VaultCollection<SettingsPayload>?
    private var observer: AnyCancellable?

    public init(defaults: UserDefaults = .standard, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.defaults = defaults
        self.now = now
        rest = AlertSoundChoice(stored: defaults.string(forKey: Self.restKey))
        plan = AlertSoundChoice(stored: defaults.string(forKey: Self.planKey))
        restVolume = AlertSoundVolume.normalized(defaults.integer(forKey: Self.restVolumeKey))
        planVolume = AlertSoundVolume.normalized(defaults.integer(forKey: Self.planVolumeKey))
    }

    // MARK: Что играть

    /// Имя файла для будильника отдыха; `nil` — системный тон (в том числе когда выбранного файла нет).
    public nonisolated static func restAlarmSoundName(defaults: UserDefaults = .standard) -> String? {
        AlertSoundLibrary.playableName(AlertSoundChoice(stored: defaults.string(forKey: restKey)), percent: defaults.integer(forKey: restVolumeKey))
    }

    public nonisolated static func planAlarmSoundName(defaults: UserDefaults = .standard) -> String? {
        AlertSoundLibrary.playableName(AlertSoundChoice(stored: defaults.string(forKey: planKey)), percent: defaults.integer(forKey: planVolumeKey))
    }

    // MARK: Выбор

    public func setRest(_ choice: AlertSoundChoice) {
        rest = choice
        save(choice, key: Self.restKey)
        pushRest()
    }

    public func setPlan(_ choice: AlertSoundChoice) {
        plan = choice
        save(choice, key: Self.planKey)
        pushPlan()
    }

    public func setRestVolume(_ percent: Int) {
        restVolume = AlertSoundVolume.normalized(percent)
        save(restVolume, key: Self.restVolumeKey)
        pushRest()
    }

    public func setPlanVolume(_ percent: Int) {
        planVolume = AlertSoundVolume.normalized(percent)
        save(planVolume, key: Self.planVolumeKey)
        pushPlan()
    }

    private func save(_ percent: Int, key: String) {
        defaults.set(percent, forKey: key)
        defaults.set(now(), forKey: key + ".at")
    }

    private func save(_ choice: AlertSoundChoice, key: String) {
        defaults.set(choice.stored, forKey: key)
        defaults.set(now(), forKey: key + ".at")
    }

    private func changedAt(_ key: String) -> Int64 { Int64(defaults.double(forKey: key + ".at")) }

    // MARK: Аккаунт

    /// Подключает общую коллекцию `settings` (одну на приложение: AppModel.settingsVault).
    public func attach(collection: VaultCollection<SettingsPayload>) {
        detach()
        self.collection = collection
        observer = collection.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        reconcile()
    }

    public func detach() {
        observer = nil
        collection = nil
    }

    private func reconcile() {
        guard let collection, collection.isAvailable else { return }
        let rest = collection.item(Self.restRecord).flatMap { $0.data?.kind == "training" ? $0 : nil }
        switch AlertSoundSync.decide(localStored: self.rest.stored, localAt: changedAt(Self.restKey), remoteStored: rest?.data?.restTone, remoteAt: rest?.updatedAt ?? 0) {
        case .none: break
        case .apply(let stored):
            self.rest = AlertSoundChoice(stored: stored)
            defaults.set(stored, forKey: Self.restKey)
            defaults.set(Double(rest?.updatedAt ?? now()), forKey: Self.restKey + ".at")
        case .push: pushRest()
        }
        let restRecord = rest?.data
        switch AlertSoundVolume.decide(localPercent: restVolume, localAt: changedAt(Self.restVolumeKey), remotePercent: restRecord?.restVolume, remoteAt: rest?.updatedAt ?? 0) {
        case .apply(let value):
            restVolume = AlertSoundVolume.normalized(Int(value))
            defaults.set(restVolume, forKey: Self.restVolumeKey)
            defaults.set(Double(rest?.updatedAt ?? now()), forKey: Self.restVolumeKey + ".at")
        case .push: pushRest()
        case .none: break
        }
        let plan = collection.item(Self.planRecord).flatMap { $0.data?.kind == "planSound" ? $0 : nil }
        switch AlertSoundSync.decide(localStored: self.plan.stored, localAt: changedAt(Self.planKey), remoteStored: plan?.data?.planTone, remoteAt: plan?.updatedAt ?? 0) {
        case .none: break
        case .apply(let stored):
            self.plan = AlertSoundChoice(stored: stored)
            defaults.set(stored, forKey: Self.planKey)
            defaults.set(Double(plan?.updatedAt ?? now()), forKey: Self.planKey + ".at")
        case .push: pushPlan()
        }
        switch AlertSoundVolume.decide(localPercent: planVolume, localAt: changedAt(Self.planVolumeKey), remotePercent: plan?.data?.planVolume, remoteAt: plan?.updatedAt ?? 0) {
        case .apply(let value):
            planVolume = AlertSoundVolume.normalized(Int(value))
            defaults.set(planVolume, forKey: Self.planVolumeKey)
            defaults.set(Double(plan?.updatedAt ?? now()), forKey: Self.planVolumeKey + ".at")
        case .push: pushPlan()
        case .none: break
        }
    }

    /// Запись `s-training` общая с веб-настройкой звука (`restSound`): её поля сохраняются.
    private func pushRest() {
        guard let collection, collection.isAvailable else { return }
        var payload = collection.item(Self.restRecord)?.data ?? SettingsPayload(kind: "training")
        guard payload.kind == "training", payload.restTone != rest.stored || payload.restVolume != restVolume else { return }
        payload.restTone = rest.stored
        payload.restVolume = restVolume
        collection.put(Self.restRecord, payload)
    }

    private func pushPlan() {
        guard let collection, collection.isAvailable else { return }
        var payload = collection.item(Self.planRecord)?.data ?? SettingsPayload(kind: "planSound")
        guard payload.kind == "planSound", payload.planTone != plan.stored || payload.planVolume != planVolume else { return }
        payload.planTone = plan.stored
        payload.planVolume = planVolume
        collection.put(Self.planRecord, payload)
    }
}
