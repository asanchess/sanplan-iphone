import SwiftUI

/// Owns the feature stores above the tabs, so recordings, drafts and a running workout survive tab switches.
@MainActor
public final class AppModel: ObservableObject {
    public let auth: AuthService
    public let alarms: AlarmCoordinator
    public let plans: PlanStore
    public let recorder: VoiceRecorder
    public let finance: FinanceStore
    public let workouts: WorkoutStore
    public let inputs: InputDrafts
    public let dictation: SpeechDictation
    public let notes: NotesStore
    public let vault: VaultKeySession

    public init() {
        let auth = AuthService(client: APIClient())
        let alarms = AlarmCoordinator()
        self.auth = auth
        self.alarms = alarms
        self.plans = PlanStore(
            client: auth.client,
            onUnauthorized: { auth.signedOutLocally() },
            onPlansChanged: { plans in
                Task { await alarms.syncAlarms(plans: plans.map { $0.toNativePlan() }) }
            }
        )
        self.recorder = VoiceRecorder()
        // Money is loaded once the account is known; debug screenshots use the phone's shared file.
        #if DEBUG
        let screenshots = ProcessInfo.processInfo.arguments.contains("--screenshot-signed-in")
        #else
        let screenshots = false
        #endif
        self.finance = FinanceStore(owner: screenshots ? .device : .none)
        self.workouts = WorkoutStore.shared
        WorkoutStore.shared.health = WorkoutHealthExport.shared
        // Screenshots run signed in without an account, so their workouts live in the phone's shared folder too.
        if screenshots { WorkoutStore.shared.switchOwner(to: .device) }
        // Habits read the neighbours only through their day summaries (docs/contracts/DOMAINS.md §2).
        let finance = self.finance
        HabitStore.shared.context = HabitContext(
            trainingDay: { day in HabitTrainingDay(completed: WorkoutStore.shared.daySummary(for: day).completed) },
            financeDay: { day in
                let s = finance.daySummary(for: day)
                return HabitFinanceDay(spent: Int(s.spent), byCategory: s.byCategory.mapValues { Int($0) })
            }
        )
        if screenshots { HabitStore.shared.switchOwner(to: .device) }
        ReviewNotifications.shared.install()
        let inputs = InputDrafts()
        self.inputs = inputs
        self.dictation = SpeechDictation(drafts: inputs)
        WorkoutLiveActivityController.shared.attach(to: WorkoutStore.shared)
        let vault = VaultKeySession()
        self.vault = vault
        if screenshots {
            // Screenshots: a throwaway key and a temporary folder, nothing reaches the account's notes.
            let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ARNA-screenshots", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            self.notes = NotesStore(baseDirectory: folder)
        } else {
            self.notes = NotesStore()
        }
        let notes = self.notes
        notes.onUnauthorized = { auth.signedOutLocally() }
        vault.onReady = { [weak vault] in
            guard let vault, let account = vault.account, let key = vault.dataKey else { return }
            notes.attach(account: account, key: key, transport: HTTPVaultTransport(client: auth.client))
        }
        #if DEBUG
        if screenshots { seedScreenshotNotes() }
        #endif
    }

    #if DEBUG
    /// Debug screenshots only: made-up notes under a throwaway key, never synced.
    private func seedScreenshotNotes() {
        vault.useEphemeralKeyForScreenshots()
        guard let key = vault.dataKey else { return }
        notes.attach(account: "screenshots", key: key, transport: nil)
        notes.create(text: "Купить домой\n- [x] молоко\n- [ ] хлеб\n- [ ] яблоки", pinned: true)
        notes.create(text: "Идея для подарка маме: тёплый плед и книга про сад")
        notes.create(text: "Позвонить в автосервис в пятницу в 10:00")
        notes.create(text: "Посмотреть на выходных «Сталкера» Тарковского")
    }
    #endif

    /// Plans, money and workouts belong to the signed-in account and must not show after sign-out. Money and workouts
    /// stay saved in that account's own folder on the phone and come back on its next sign-in.
    public func clearAccountData() {
        recorder.cancel()
        if dictation.isListening(to: .plans) || dictation.isListening(to: .money) || dictation.isListening(to: .notes) { dictation.stop() }
        inputs.clear(.plans)
        inputs.clear(.money)
        inputs.clear(.notes)
        if dictation.isListening(to: .review) { dictation.stop() }
        inputs.clear(.review)
        notes.detach()
        vault.reset()
        plans.resetForSignOut()
        finance.switchOwner(to: .none)
        workouts.switchOwner(to: .none)
        HabitStore.shared.switchOwner(to: .none)
        // The 21:00 review reminder belongs to the account that set it.
        ReviewReminder.cancel()
    }

    /// Loads the money and workouts of the account that just signed in. A different account never sees the previous one's draft.
    public func accountSignedIn(email: String) {
        if vault.account != email {
            // Another account's unsaved note draft and decrypted notes must not carry over.
            if vault.account != nil {
                if dictation.isListening(to: .notes) { dictation.stop() }
                inputs.clear(.notes)
            }
            notes.detach()
            vault.attach(account: email, transport: HTTPVaultTransport(client: auth.client))
        }
        let next = FinanceStore.Owner.account(email)
        workouts.switchOwner(to: next)
        HabitStore.shared.switchOwner(to: next)
        guard finance.owner != next else { return }
        if case .account = finance.owner {
            if dictation.isListening(to: .money) { dictation.stop() }
            inputs.clear(.money)
        }
        finance.switchOwner(to: next)
    }

    public func launched() async {
        await alarms.reconcileWithSystem()
    }

    public func becameActive() {
        finance.reloadIfUnavailable()
        workouts.reloadIfUnavailable()
        workouts.reconcileClock()
        if case .signedIn = auth.phase {
            Task { await plans.reload() }
            notes.syncNow()
        }
    }
}
