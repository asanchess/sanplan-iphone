import Foundation

/// The one record type of the encrypted `settings` collection, shared by every section (docs/ONE-APP-PLAN.md).
/// Each record says what it is in `kind`; each section adds its own optional fields here and reads only its records:
/// - `s-plan-drafts`, kind `planDrafts`: `drafts` (PlanDraftSync.swift; web src/plan-drafts-sync.mjs).
/// - `s-app-settings`, kind `app`: `onboardingDone` (AppSettingsStore.swift; web src/settings-store.mjs).
/// - `s-training`, kind `training`: `restSound` (rest sound on/off; web src/workout-sync.mjs). Volume and Apple Health stay on the device.
/// Keep ONE `VaultCollection<SettingsPayload>` (AppModel.settingsVault): a second collection named `settings`
/// would share its cache and overwrite it. JSON is the same as the web's; fields this app does not know are ignored.
public struct SettingsPayload: Codable, Equatable, @unchecked Sendable {
    public var kind: String
    public var drafts: [PlanItem]?
    public var restSound: Bool?
    public var onboardingDone: Bool?

    public init(kind: String) { self.kind = kind }
    public init(restSound: Bool) { self.kind = "training"; self.restSound = restSound }
    public init(drafts: [PlanItem]) { self.kind = "planDrafts"; self.drafts = drafts }
    public init(onboardingDone: Bool) { self.kind = "app"; self.onboardingDone = onboardingDone }

    private enum CodingKeys: String, CodingKey { case kind, drafts, restSound, onboardingDone }
    /// A record without `kind` (written before kinds existed) still opens; its owner reads it by record id.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        drafts = try c.decodeIfPresent([PlanItem].self, forKey: .drafts)
        restSound = try c.decodeIfPresent(Bool.self, forKey: .restSound)
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone)
    }
}
