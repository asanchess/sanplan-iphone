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
        let inputs = InputDrafts()
        self.inputs = inputs
        self.dictation = SpeechDictation(drafts: inputs)
        WorkoutLiveActivityController.shared.attach(to: WorkoutStore.shared)
    }

    /// Plans, money and workouts belong to the signed-in account and must not show after sign-out. Money and workouts
    /// stay saved in that account's own folder on the phone and come back on its next sign-in.
    public func clearAccountData() {
        recorder.cancel()
        if dictation.isListening(to: .plans) || dictation.isListening(to: .money) { dictation.stop() }
        inputs.clear(.plans)
        inputs.clear(.money)
        plans.resetForSignOut()
        finance.switchOwner(to: .none)
        workouts.switchOwner(to: .none)
    }

    /// Loads the money and workouts of the account that just signed in. A different account never sees the previous one's draft.
    public func accountSignedIn(email: String) {
        let next = FinanceStore.Owner.account(email)
        workouts.switchOwner(to: next)
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
        }
    }
}
