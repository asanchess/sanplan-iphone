import ActivityKit
import Combine
import Foundation

/// Builds the lock-screen state from a workout session. Pure, so it can be tested without ActivityKit.
public enum WorkoutLiveState {
    public static func content(for session: WorkoutSessionState) -> WorkoutActivityAttributes.ContentState? {
        guard session.exercises.indices.contains(session.exerciseIndex) else { return nil }
        let exercise = session.exercises[session.exerciseIndex]
        let phase: WorkoutActivityAttributes.Phase
        switch session.phase {
        case .preparing: phase = .preparing
        case .working: phase = .working
        case .resting: phase = .resting
        case .paused: phase = .paused
        case .alerting: phase = .alerting
        case .complete: return nil
        }
        let countdownEnd: Date?
        if session.phase == .preparing || session.phase == .resting, let deadline = session.deadline {
            countdownEnd = Date(timeIntervalSince1970: Double(deadline) / 1000)
        } else {
            countdownEnd = nil
        }
        let stopwatchStart = session.phase == .working
            ? session.workStartedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            : nil
        let paused = session.phase == .paused
            ? session.pausedRemainingMs.map { Int(($0 + 999) / 1000) }
            : nil
        return WorkoutActivityAttributes.ContentState(
            exerciseName: exercise.name,
            setNumber: session.setIndex + 1,
            setTotal: exercise.rests.count,
            phase: phase,
            countdownEnd: countdownEnd,
            stopwatchStart: stopwatchStart,
            pausedRemainingSeconds: paused,
            isLastSet: WorkoutDomain.isLastSet(session),
            progress: WorkoutProgress.setsFraction(session)
        )
    }

    /// The domain command a lock-screen button stands for in the session's current phase, or nil when it no longer applies.
    public static func command(for action: WorkoutLiveIntent.Action, phase: WorkoutPhase) -> WorkoutCommand? {
        switch (action, phase) {
        case (.startNow, .preparing): return .startNow()
        case (.startRest, .preparing), (.startRest, .working), (.startRest, .alerting): return .startRest()
        case (.skipRest, .resting), (.skipRest, .paused): return .skipRest()
        // The rest ran out while the phone was locked: «Следующий подход» then starts the set.
        case (.skipRest, .alerting), (.nextSet, .alerting): return .acknowledge()
        case (.addThirty, .resting), (.addThirty, .paused): return .adjust(seconds: 30)
        case (.resume, .paused): return .resume()
        case (.finish, _) where phase != .complete: return .finish()
        default: return nil
        }
    }
}

/// Keeps one workout Live Activity in step with the session and runs its buttons.
@MainActor
public final class WorkoutLiveActivityController {
    public static let shared = WorkoutLiveActivityController()

    private var observation: AnyCancellable?

    public func attach(to store: WorkoutStore) {
        guard observation == nil else { return }
        observation = store.$activeSession
            .removeDuplicates()
            .sink { [weak self] session in
                self?.sync(session)
            }
    }

    private func sync(_ session: WorkoutSessionState?) {
        let state = session.flatMap(WorkoutLiveState.content(for:))
        let running = Activity<WorkoutActivityAttributes>.activities
        guard let state else {
            for activity in running {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity = running.first {
            Task { await activity.update(content) }
            for extra in running.dropFirst() {
                Task { await extra.end(nil, dismissalPolicy: .immediate) }
            }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: WorkoutActivityAttributes(), content: content, pushType: nil)
        }
    }

    /// Called by `WorkoutLiveIntent` in the app process, also when the app was launched in the background for it.
    public static func handle(_ action: WorkoutLiveIntent.Action) async {
        let store = WorkoutStore.shared
        shared.attach(to: store)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // A countdown that ended while the phone was locked moves on first, as the open screen would.
        if let session = store.activeSession,
           session.phase == .preparing || session.phase == .resting,
           let deadline = session.deadline, now >= deadline {
            store.dispatch(command: .tick(), now: now)
        }
        guard let phase = store.activeSession?.phase,
              let command = WorkoutLiveState.command(for: action, phase: phase) else { return }
        store.dispatch(command: command, now: now)
    }
}
