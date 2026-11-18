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

/// The workout plate from the canvas (`docs/design/canvas-r5/Widget.html`): the hero in the pose of the phase,
/// a coral kicker «ОТДЫХ · 2/4», the exercise, a big Dela timer and the two buttons that make sense now.
/// Data comes only from `WorkoutActivityAttributes.ContentState`, as before.
struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLockScreenView(state: context.state)
                .activityBackgroundTint(WidgetPalette.plate)
                .activitySystemActionForegroundColor(WidgetPalette.coral)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WidgetPet(pose: WidgetPet.Pose(state.phase))
                        .frame(width: 40, height: 54)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WorkoutTimerText(state: state)
                        .font(WidgetType.display(24).monospacedDigit())
                        .foregroundStyle(WidgetPalette.coral)
                        .lineLimit(1)
                        .frame(maxWidth: 96, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.kicker)
                            .font(WidgetType.text(12, .heavy))
                            .tracking(0.7)
                            .foregroundStyle(WidgetPalette.coral)
                            .lineLimit(1)
                        Text(state.exerciseName)
                            .font(WidgetType.text(16, .bold))
                            .foregroundStyle(WidgetPalette.text)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WorkoutActionButtons(state: state)
                        .padding(.top, 4)
                }
            } compactLeading: {
                ARNAProgressMark(progress: state.progress, tint: WidgetPalette.coral, track: .white.opacity(0.25), lineWidth: 2.5)
                    .frame(width: 18, height: 15)
            } compactTrailing: {
                WorkoutTimerText(state: state)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(WidgetPalette.coral)
                    .frame(maxWidth: 52)
            } minimal: {
                ARNAProgressMark(progress: state.progress, tint: WidgetPalette.coral, track: .white.opacity(0.25), lineWidth: 2.5)
                    .frame(width: 16, height: 14)
            }
            .keylineTint(WidgetPalette.coral)
        }
    }
}

/// Lock screen plate. The canvas plate is 16 + 86 + 12 + 48 + 16 pt tall, more than the 160 pt the system gives
/// a Live Activity, so the hero is 76 pt and the buttons 44 pt here; everything else is as drawn.
struct WorkoutLockScreenView: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                WidgetPet(pose: WidgetPet.Pose(state.phase))
                    .frame(width: 56, height: 76)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.kicker)
                        .font(WidgetType.text(13, .heavy))
                        .tracking(0.78)
                        .foregroundStyle(WidgetPalette.coral)
                        .lineLimit(1)
                    Text(state.exerciseName)
                        .font(WidgetType.text(18, .bold))
                        .foregroundStyle(WidgetPalette.text)
                        .lineLimit(1)
                    Text(state.hint)
                        .font(WidgetType.text(14, .medium))
                        .foregroundStyle(WidgetPalette.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                WorkoutTimerText(state: state)
                    .font(WidgetType.display(30).monospacedDigit())
                    .foregroundStyle(WidgetPalette.coral)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 104, alignment: .trailing)
                    .accessibilityHint(state.timerLabel)
            }
            WorkoutActionButtons(state: state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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

/// The buttons that make sense in the current phase: the main one coral with an ink frame and shadow (flex 1.7),
/// the second outlined (flex 1), as on the canvas. They send the same commands as before.
struct WorkoutActionButtons: View {
    let state: WorkoutActivityAttributes.ContentState

    private struct Item {
        let title: String
        let action: WorkoutLiveIntent.Action
        let primary: Bool
    }

    private var items: [Item] {
        switch state.phase {
        case .preparing:
            var list = [Item(title: "Начать", action: .startNow, primary: true)]
            if !state.isLastSet { list.append(Item(title: "Отдых", action: .startRest, primary: false)) }
            return list
        case .working:
            return state.isLastSet
                ? [Item(title: "Последний сделан", action: .finish, primary: true)]
                : [Item(title: "Подход сделан", action: .startRest, primary: true)]
        case .resting:
            return [Item(title: "Пропустить отдых", action: .skipRest, primary: true),
                    Item(title: "+30 сек", action: .addThirty, primary: false)]
        case .paused:
            return [Item(title: "Продолжить", action: .resume, primary: true),
                    Item(title: "+30 сек", action: .addThirty, primary: false)]
        case .alerting:
            return state.isLastSet
                ? [Item(title: "Завершить", action: .finish, primary: true)]
                : [Item(title: "Следующий подход", action: .nextSet, primary: true)]
        }
    }

    var body: some View {
        let list = items
        let single = list.count == 1
        GeometryReader { proxy in
            let spacing: CGFloat = 8
            let free = max(0, proxy.size.width - spacing * CGFloat(list.count - 1) - 3)
            let weights = list.map { $0.primary ? 1.7 : 1.0 }
            let sum = weights.reduce(0, +)
            HStack(spacing: spacing) {
                ForEach(list.indices, id: \.self) { index in
                    let item = list[index]
                    button(item)
                        .frame(width: single ? free : free * weights[index] / sum)
                }
            }
        }
        .frame(height: 47)
    }

    private func button(_ item: Item) -> some View {
        Button(intent: WorkoutLiveIntent(item.action)) {
            Text(item.title)
                .font(WidgetType.text(15, .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(item.primary ? WidgetPalette.onCoral : WidgetPalette.text)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                    if item.primary {
                        shape.fill(WidgetPalette.coral)
                            .overlay(shape.stroke(WidgetPalette.ink, lineWidth: 2))
                            .background(shape.fill(WidgetPalette.ink).offset(x: 3, y: 3))
                    } else {
                        shape.stroke(WidgetPalette.outline, lineWidth: 1.5)
                    }
                }
                .padding(.trailing, item.primary ? 3 : 0)
                .padding(.bottom, 3)
        }
        .buttonStyle(.plain)
    }
}

/// The hero in the pose of the phase, from the widget's own small copies of the app's pose images.
struct WidgetPet: View {
    enum Pose: String {
        case think = "WidgetPetThink", cheer = "WidgetPetCheer", rest = "WidgetPetRest",
             shrug = "WidgetPetShrug", point = "WidgetPetPoint"

        /// Canvas: rest → «отдых», a set → pointing, pause → shrug, done → cheer.
        init(_ phase: WorkoutActivityAttributes.Phase) {
            switch phase {
            case .preparing: self = .think
            case .working: self = .point
            case .resting: self = .rest
            case .paused: self = .shrug
            case .alerting: self = .cheer
            }
        }
    }

    let pose: Pose

    var body: some View {
        Image(pose.rawValue)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .accessibilityHidden(true)
    }
}

extension WorkoutActivityAttributes.ContentState {
    /// «ОТДЫХ · 2/4» — the canvas kicker.
    var kicker: String {
        "\(phaseTitle.uppercased()) · \(setNumber)/\(setTotal)"
    }

    /// The grey line under the exercise: what the timer is counting.
    var hint: String {
        switch phase {
        case .preparing: return "Разминка до первого подхода"
        case .working: return "Время подхода"
        case .resting: return "До следующего подхода"
        case .paused: return "Отдых на паузе"
        case .alerting: return isLastSet ? "Можно завершать" : "Пора к следующему подходу"
        }
    }

    var timerLabel: String {
        switch phase {
        case .working: return "Время подхода"
        case .paused: return "Осталось отдыхать, пауза"
        default: return "Осталось отдыхать"
        }
    }
}

/// Canvas colours of the plate (the widget has no access to the app's design system).
enum WidgetPalette {
    private static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
    }
    /// rgba(12, 9, 24, .88)
    static let plate = hex(0x0C0918, 0.88)
    static let coral = hex(0xEE9A8C)
    static let onCoral = hex(0x2A0F0B)
    static let ink = hex(0x0B0816)
    static let outline = hex(0x5A4A8A)
    static let text = hex(0xF1ECFF)
    static let muted = hex(0xB8AFD4)
}

/// Dela Gothic One and Golos Text at fixed sizes: the plate has a hard 160 pt height limit.
/// The fonts ship in `SanPlanWidgets/Fonts`; until they are listed in the widget's Info.plist the system font stands in.
enum WidgetType {
    static func display(_ size: CGFloat) -> Font {
        .custom("DelaGothicOne-Regular", fixedSize: size)
    }
    static func text(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .custom("Golos Text", fixedSize: size).weight(weight)
    }
}
