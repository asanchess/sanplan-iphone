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
        self.finance = FinanceStore()
        self.workouts = WorkoutStore()
    }

    /// Plan data belongs to the signed-in account and must not show after sign-out.
    /// Workouts and money are local to the phone, never tied to the account, so they stay.
    public func clearAccountData() {
        recorder.cancel()
        plans.resetForSignOut()
    }

    public func launched() async {
        await alarms.reconcileWithSystem()
    }

    public func becameActive() {
        finance.reloadIfUnavailable()
        workouts.reconcileClock()
        if case .signedIn = auth.phase {
            Task { await plans.reload() }
        }
    }
}
