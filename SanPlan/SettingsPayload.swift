import Foundation

/// The one record type of the encrypted `settings` collection, shared by every section (docs/ONE-APP-PLAN.md).
/// Each record says what it is in `kind`; each section adds its own optional fields here and reads only its records:
/// - `s-plan-drafts`, kind `planDrafts`: `drafts` (PlanDraftSync.swift; web src/plan-drafts-sync.mjs).
/// - `s-app-settings`, kind `app`: `onboardingDone` (AppSettingsStore.swift; web src/settings-store.mjs).
/// - `s-training`, kind `training`: `restSound` (rest sound on/off; web src/workout-sync.mjs). Volume and Apple Health stay on the device.
/// - `s-profile`, kind `profile`: `nickname`, the name the profile shows (ProfileName.swift; the web does not use it yet).
/// Keep ONE `VaultCollection<SettingsPayload>` (AppModel.settingsVault): a second collection named `settings`
/// would share its cache and overwrite it. JSON is the same as the web's; fields this app does not know are ignored.
public struct SettingsPayload: Codable, Equatable, @unchecked Sendable {
    public var kind: String
    public var drafts: [PlanItem]?
    public var restSound: Bool?
    /// Звук сигнала: `AlertSoundChoice.stored` («system», «builtin:<файл>», «custom:<файл>»). `restTone` — в `s-training`, `planTone` — в `s-plan-sound` (kind `planSound`).
    public var restTone: String?
    public var planTone: String?
    /// Ступень громкости сигнала в процентах (100 / 60 / 35 / 20), рядом с тоном.
    public var restVolume: Int?
    public var planVolume: Int?
    public var onboardingDone: Bool?
    /// Имя в профиле вместо части почты до «@»; nil — не задано.
    public var nickname: String?

    public init(kind: String) { self.kind = kind }
    public init(restTone: String) { self.kind = "training"; self.restTone = restTone }
    public init(planTone: String) { self.kind = "planSound"; self.planTone = planTone }
    public init(restSound: Bool) { self.kind = "training"; self.restSound = restSound }
    public init(drafts: [PlanItem]) { self.kind = "planDrafts"; self.drafts = drafts }
    public init(onboardingDone: Bool) { self.kind = "app"; self.onboardingDone = onboardingDone }

    private enum CodingKeys: String, CodingKey { case kind, drafts, restSound, restTone, planTone, restVolume, planVolume, onboardingDone, nickname }
    /// A record without `kind` (written before kinds existed) still opens; its owner reads it by record id.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        drafts = try c.decodeIfPresent([PlanItem].self, forKey: .drafts)
        restSound = try c.decodeIfPresent(Bool.self, forKey: .restSound)
        restTone = try c.decodeIfPresent(String.self, forKey: .restTone)
        planTone = try c.decodeIfPresent(String.self, forKey: .planTone)
        restVolume = try c.decodeIfPresent(Int.self, forKey: .restVolume)
        planVolume = try c.decodeIfPresent(Int.self, forKey: .planVolume)
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
    }
}
