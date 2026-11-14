import Foundation
import Combine

/// The shared app settings record `s-app-settings` (kind `app`) is a `SettingsPayload` like every record of the `settings`
/// collection; the web writes the same record (src/settings-store.mjs). Notification permission, Apple Health and volume stay on the device.
public typealias AppSettingsRecord = SettingsPayload

/// Shared settings of the signed-in account. Closed (nothing readable) until the account's vault key is available.
@MainActor
public final class AppSettingsStore: ObservableObject {
    public static let recordID = "s-app-settings"

    private var collection: VaultCollection<AppSettingsRecord>?
    private var sub: AnyCancellable?

    public init() {}

    /// The account's `settings` collection, or nil while the vault is closed. The creator keeps it attached to the account.
    public func setCollection(_ next: VaultCollection<AppSettingsRecord>?) {
        guard next !== collection else { return }
        sub = nil
        collection = next
        if let next {
            sub = next.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
        objectWillChange.send()
    }

    /// True once the collection is open and has heard from the server at least once, so «not set» really means not set.
    public var isLoaded: Bool { collection?.isAvailable == true && collection?.hasSynced == true }

    public var record: AppSettingsRecord { collection?.item(Self.recordID)?.data ?? SettingsPayload(kind: "app") }

    public var onboardingDone: Bool { record.onboardingDone == true }

    @discardableResult
    public func setOnboardingDone(_ done: Bool) -> Bool {
        guard let collection, collection.isAvailable else { return false }
        var next = record
        next.kind = "app"
        next.onboardingDone = done
        return collection.put(Self.recordID, next) != nil
    }
}
