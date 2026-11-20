import Combine
import Foundation

/// Неотправленные черновики планов, общие для всех устройств: одна запись `s-plan-drafts` в коллекции `settings`.
/// Формат тот же, что у веба (src/plan-drafts-sync.mjs): `{kind:"planDrafts", drafts:[…]}`.
/// Payload type: SettingsPayload.swift (`kind` "planDrafts", field `drafts`).

public enum PlanDraftCloud {
    public static let recordID = "s-plan-drafts"

    /// Первый запуск: всё с обеих сторон; для одного id побеждает копия из облака, локальные добавляются следом.
    public static func mergeFirstRun(local: [PlanItem], remote: [PlanItem]) -> [PlanItem] {
        let ids = Set(remote.map(\.id))
        return remote + local.filter { !ids.contains($0.id) }
    }
}

/// Связывает черновики `PlanStore` с коллекцией `settings`: новейшее побеждает, очистка тоже передаётся.
@MainActor
public final class PlanDraftSync {
    private let collection: VaultCollection<SettingsPayload>
    private let getDrafts: () -> [PlanItem]
    private let setDrafts: ([PlanItem]) -> Void
    private let defaults: UserDefaults
    private let mergedKey: String
    private let debounce: Duration
    private let now: () -> Int64
    private var observer: AnyCancellable?
    private var pushTask: Task<Void, Never>?
    private var editedAt: Int64 = 0
    private var lastSynced: [PlanItem]?
    private var ready = false
    private var stopped = false

    public init(
        collection: VaultCollection<SettingsPayload>,
        account: String,
        defaults: UserDefaults = .standard,
        debounce: Duration = .milliseconds(600),
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        getDrafts: @escaping () -> [PlanItem],
        setDrafts: @escaping ([PlanItem]) -> Void
    ) {
        self.collection = collection
        self.defaults = defaults
        self.mergedKey = "arna.plan-drafts-merged.v1.\(FinanceStore.accountFolderName(account))"
        self.debounce = debounce
        self.now = now
        self.getDrafts = getDrafts
        self.setDrafts = setDrafts
    }

    private var record: VaultItem<SettingsPayload>? {
        guard let item = collection.item(PlanDraftCloud.recordID), item.data?.kind == "planDrafts" else { return nil }
        return item
    }

    public func start() async {
        guard collection.isAvailable else { return }
        _ = await collection.whenSynced()
        guard !stopped, collection.isAvailable else { return }
        let local = getDrafts()
        let remote = record?.data?.drafts
        if !defaults.bool(forKey: mergedKey) {
            let merged = remote.map { PlanDraftCloud.mergeFirstRun(local: local, remote: $0) } ?? local
            if merged != local { setDrafts(merged) }
            if remote != nil || !merged.isEmpty {
                if merged != remote { push(merged) } else { lastSynced = merged }
            }
            defaults.set(true, forKey: mergedKey)
        } else if let remote, let rec = record {
            lastSynced = remote
            if remote != local {
                if editedAt > 0, editedAt >= rec.updatedAt { push(local) } else { setDrafts(remote) }
            }
        } else if !local.isEmpty {
            push(local)
        }
        ready = true
        observer = collection.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.remoteChanged() }
        }
    }

    public func stop() {
        stopped = true
        pushTask?.cancel()
        observer = nil
    }

    /// Вызывать при каждом изменении локальных черновиков.
    public func localChanged(_ drafts: [PlanItem]) {
        guard !stopped, drafts != lastSynced else { return }
        // An edit made before the first sync finishes must still beat the older cloud copy in start().
        editedAt = now()
        guard ready else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.push(self.getDrafts())
        }
    }

    private func push(_ drafts: [PlanItem]) {
        lastSynced = drafts
        collection.put(PlanDraftCloud.recordID, SettingsPayload(drafts: drafts))
    }

    private func remoteChanged() {
        guard ready, !stopped, let rec = record, let remote = rec.data?.drafts else { return }
        if rec.updatedAt <= editedAt { return }
        lastSynced = remote
        if remote != getDrafts() { setDrafts(remote) }
    }
}
