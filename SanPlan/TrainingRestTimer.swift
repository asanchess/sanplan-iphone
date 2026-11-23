import SwiftUI

/// The letter «А» of the ARNA mark as a solid glyph: two legs, a crossbar and a triangular counter.
/// Fill it with `FillStyle(eoFill: true)` so the counter stays open.
struct TrainingLetterA: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.addLines([p(0, 1), p(0.36, 0), p(0.64, 0), p(1, 1), p(0.72, 1), p(0.635, 0.76), p(0.365, 0.76), p(0.28, 1)])
        path.closeSubpath()
        path.addLines([p(0.435, 0.56), p(0.5, 0.38), p(0.565, 0.56)])
        path.closeSubpath()
        return path
    }
}

/// The rest timer sign: the «А» filling smoothly from the bottom in the workout colour, with an ink outline and a hard ink shadow.
struct TrainingLetterTimer: View {
    let progress: Double
    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let clamped = min(1, max(0, progress))
        let evenOdd = FillStyle(eoFill: true)
        ZStack {
            TrainingLetterA()
                .fill(DS.Colors.ink, style: evenOdd)
                .offset(x: 4, y: 4)
            TrainingLetterA()
                .fill(TrainingPalette.track, style: evenOdd)
            GeometryReader { geometry in
                Rectangle()
                    .fill(accent)
                    .frame(height: geometry.size.height * clamped)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .mask(TrainingLetterA().fill(style: evenOdd))
            .animation(reduceMotion ? nil : .linear(duration: 0.5), value: clamped)
            TrainingLetterA()
                .stroke(DS.Colors.edge, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// «ДЗЫНЬ!» when the rest has run out: the skewed tag, gently pulsing unless motion is reduced.
struct TrainingDzyn: View {
    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isUp = false

    var body: some View {
        SkewTag("ДЗЫНЬ!", color: accent)
            .scaleEffect(isUp ? 1.12 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: isUp)
            .onAppear { isUp = !reduceMotion }
            .accessibilityLabel("Дзынь, отдых окончен")
    }
}

/// The phase, the set in progress and the set or rest clock, with the «А» beside the digits.
/// Ticks the store when a countdown runs out while the screen is open.
struct WorkoutTimerCard: View {
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let now = max(session.lastNow, Int64(context.date.timeIntervalSince1970 * 1000))
            let remaining = (try? WorkoutDomain.remainingSeconds(state: session, now: now)) ?? 0
            let elapsed = WorkoutDomain.elapsedWorkSeconds(state: session, now: now)
            let exercise = session.exercises[session.exerciseIndex]
            let fill = session.phase == .alerting ? 1 : WorkoutProgress.fraction(session, remainingSeconds: remaining)

            VStack(spacing: DS.Metrics.spacing12) {
                HStack(alignment: .center, spacing: 22) {
                    TrainingLetterTimer(progress: fill)
                        .frame(width: 104, height: 112)
                        .padding(.trailing, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(phaseTitle(session.phase))
                            .textCase(.uppercase)
                            .font(DS.Fonts.text(14, .heavy, relativeTo: .caption))
                            .tracking(0.8)
                            .foregroundColor(phaseColor(session.phase))
                            .accessibilityLabel(phaseTitle(session.phase))
                        Text(timerText(seconds: elapsed ?? remaining, hasStopwatch: elapsed != nil))
                            .font(DS.Fonts.display(52, relativeTo: .largeTitle))
                            .monospacedDigit()
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .shadow(color: DS.Colors.drop, radius: 3, y: 2)
                            .contentTransition(.numericText(countsDown: elapsed == nil))
                            .animation(.snappy, value: elapsed ?? remaining)
                        Text(setHeader(exercise))
                            .font(DS.Fonts.text(15, .semibold, relativeTo: .subheadline))
                            .monospacedDigit()
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if session.phase == .alerting {
                    TrainingDzyn()
                }
                if elapsed != nil {
                    Text(session.phase == .alerting ? "Следующий подход уже идёт" : "Время подхода")
                        .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(DS.Colors.surface))
            .onChange(of: context.date) { _, _ in
                if session.phase == .preparing || session.phase == .resting,
                   let deadline = session.deadline, now >= deadline {
                    store.dispatch(command: .tick(), now: now)
                }
            }
        }
    }

    /// «Подход 2 из 4». Once the rest has run out the clock already counts the next set, so the header names that one.
    private func setHeader(_ exercise: SessionExercise) -> String {
        guard session.phase == .alerting, let next = WorkoutDomain.nextSet(session) else {
            return "Подход \(session.setIndex + 1) из \(exercise.rests.count)"
        }
        guard next.exercise == session.exerciseIndex else {
            return "Далее: \(session.exercises[next.exercise].baseName)"
        }
        return "Подход \(next.set + 1) из \(exercise.rests.count)"
    }

    private func timerText(seconds: Int, hasStopwatch: Bool) -> String {
        if session.phase == .working && !hasStopwatch { return "—:—" }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func phaseTitle(_ phase: WorkoutPhase) -> String {
        switch phase {
        case .preparing: return "Подготовка"
        case .working: return "Рабочий подход"
        case .resting: return "Отдых"
        case .paused: return "Отдых на паузе"
        case .alerting: return "Отдых окончен"
        case .complete: return "Завершено"
        }
    }

    private func phaseColor(_ phase: WorkoutPhase) -> Color {
        switch phase {
        case .paused: return DS.Colors.warning
        case .working: return DS.Colors.textPrimary
        default: return accent
        }
    }
}
