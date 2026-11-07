import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct SanPlanWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivityWidget()
    }
}

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(ARNABrand.lilac)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ARNAProgressMark(progress: state.progress, tint: ARNABrand.lilac, track: .white.opacity(0.2), lineWidth: 4)
                        .frame(width: 36, height: 30)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WorkoutTimerText(state: state)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(ARNABrand.lilac)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(state.exerciseName).font(.headline).lineLimit(1)
                        Text("\(state.phaseTitle) · \(state.setLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WorkoutActionButtons(state: state)
                }
            } compactLeading: {
                ARNAProgressMark(progress: state.progress, tint: ARNABrand.lilac, track: .white.opacity(0.25), lineWidth: 2.5)
                    .frame(width: 18, height: 15)
            } compactTrailing: {
                WorkoutTimerText(state: state)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(ARNABrand.lilac)
                    .frame(maxWidth: 52)
            } minimal: {
                ARNAProgressMark(progress: state.progress, tint: ARNABrand.lilac, track: .white.opacity(0.25), lineWidth: 2.5)
                    .frame(width: 16, height: 14)
            }
            .keylineTint(ARNABrand.lilac)
        }
    }
}

struct WorkoutLockScreenView: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ARNAProgressMark(progress: state.progress, tint: ARNABrand.lilac, track: .white.opacity(0.18), lineWidth: 5)
                    .frame(width: 44, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.exerciseName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(state.phaseTitle) · \(state.setLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 8)
                WorkoutTimerText(state: state)
                    .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(state.phase == .alerting ? Color.green : ARNABrand.lilac)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
            WorkoutActionButtons(state: state)
        }
        .padding(16)
    }
}

/// Counts down during warm-up and rest, up during a set, and stands still while paused.
struct WorkoutTimerText: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        if let end = state.countdownEnd, end > Date() {
            Text(timerInterval: Date()...end, countsDown: true)
                .multilineTextAlignment(.trailing)
        } else if let start = state.stopwatchStart {
            Text(start, style: .timer)
                .multilineTextAlignment(.trailing)
        } else if let paused = state.pausedRemainingSeconds {
            Text(String(format: "%d:%02d", paused / 60, paused % 60))
        } else if state.countdownEnd != nil {
            Text("0:00")
        } else {
            Text("—")
        }
    }
}

/// The two buttons that make sense in the current phase.
struct WorkoutActionButtons: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            switch state.phase {
            case .preparing:
                button("Начать", icon: "play.fill", .startNow, primary: true)
                if !state.isLastSet {
                    button("Отдых", icon: "bed.double.fill", .startRest)
                }
            case .working:
                if state.isLastSet {
                    button("Завершить", icon: "checkmark", .finish, primary: true)
                } else {
                    button("Подход выполнен", icon: "checkmark", .startRest, primary: true)
                }
            case .resting:
                button("+30 с", icon: "goforward.30", .addThirty)
                button("Пропустить", icon: "forward.fill", .skipRest, primary: true)
            case .paused:
                button("Продолжить", icon: "play.fill", .resume, primary: true)
                button("+30 с", icon: "goforward.30", .addThirty)
            case .alerting:
                if state.isLastSet {
                    button("Завершить", icon: "checkmark", .finish, primary: true)
                } else {
                    button("Следующий подход", icon: "play.fill", .nextSet, primary: true)
                }
            }
        }
    }

    private func button(_ title: String, icon: String, _ action: WorkoutLiveIntent.Action, primary: Bool = false) -> some View {
        Button(intent: WorkoutLiveIntent(action)) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(primary ? Color.black : ARNABrand.lilac)
        .background(primary ? ARNABrand.lilac : ARNABrand.lilac.opacity(0.18), in: Capsule())
    }
}
