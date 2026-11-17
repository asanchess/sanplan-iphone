import SwiftUI

/// Round 6 «Тренировка» canvas (docs/design/canvas-r5/Training.html): the shades around the section colour
/// and the small building blocks the section's screens share.
enum TrainingPalette {
    /// Hard shadow under accent buttons: a dark shade of the workout colour.
    static let inkShade = DS.Colors.hex(0x7A2E25)
    /// Start of the hero card gradient.
    static let heroStart = DS.Colors.hex(0xC9574A)
    /// Text on the workout colour.
    static let onAccent = DS.Colors.hex(0x2A0F0B)
    /// Number badge behind the exercise index.
    static let badge = DS.Colors.hex(0x3A2A3F)
    /// Empty part of a timer or chart.
    static let track = DS.Colors.hex(0x33295A)
    /// Dashed outline of a rest day in the week row.
    static let restDay = DS.Colors.hex(0x5A4A8A)
    /// Bars that are not highlighted in a chart.
    static let quietBar = DS.Colors.hex(0x8C4A43)
}

/// The glow and the dot field in the top right corner of every Training screen.
struct TrainingBackdrop: View {
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        let dot = accent
        ZStack(alignment: .topTrailing) {
            DS.Colors.canvas
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.22), accent.opacity(0)], center: .center, startRadius: 0, endRadius: 160))
                .frame(width: 320, height: 320)
                .offset(x: 90, y: -110)
            Canvas { context, size in
                let step: CGFloat = 11
                var y: CGFloat = step / 2
                while y < size.height {
                    var x: CGFloat = step / 2
                    while x < size.width {
                        context.fill(Path(ellipseIn: CGRect(x: x - 0.85, y: y - 0.85, width: 1.7, height: 1.7)), with: .color(dot))
                        x += step
                    }
                    y += step
                }
            }
            .frame(width: 230, height: 230)
            .opacity(0.3)
            .mask(RadialGradient(colors: [.black, .clear], center: .topTrailing, startRadius: 0, endRadius: 230))
            .offset(x: 30, y: -30)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// «ПЛАН», «ВСЕ УПРАЖНЕНИЯ»: 13 bold capitals with wide tracking.
struct TrainingKicker: View {
    let text: String
    var color: Color = DS.Colors.textSecondary

    var body: some View {
        Text(text.uppercased())
            .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
            .tracking(0.8)
            .foregroundColor(color)
            .accessibilityLabel(text)
    }
}

/// The big accent button of the canvas: 64 high, radius 22, dark text, hard shadow in the dark workout shade.
struct TrainingMainButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Metrics.spacing8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(DS.Fonts.text(19, .heavy, relativeTo: .headline))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(TrainingPalette.onAccent)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(accent))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(DS.Colors.ink, lineWidth: 2))
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(TrainingPalette.inkShade).offset(x: 4, y: 4))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(title)
    }
}

/// The outlined companion buttons («+30 сек», «Пауза»): 52 high, 1.5 hairline border, radius 18.
struct TrainingOutlineButton: View {
    let title: String
    var icon: String? = nil
    var accessibilityTitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(DS.Fonts.text(16, .bold, relativeTo: .subheadline))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DS.Colors.hairline, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(accessibilityTitle ?? title)
    }
}

/// Seven cells for this week: done, today, a rest day (no workout in the plan) or a planned day still ahead.
struct TrainingRhythmRow: View {
    struct Day: Identifiable {
        let id: Int
        let label: String
        let isDone: Bool
        let isToday: Bool
        let isRestDay: Bool
    }

    let days: [Day]
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    cell(day)
                        .frame(height: 36)
                    Text(day.label)
                        .font(DS.Fonts.text(12, .bold, relativeTo: .caption2))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibility(day))
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: Day) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if day.isDone {
            shape.fill(accent)
        } else if day.isToday {
            shape.fill(DS.Colors.surface).overlay(shape.stroke(accent, lineWidth: 2))
        } else if day.isRestDay {
            shape.stroke(TrainingPalette.restDay, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
        } else {
            shape.fill(DS.Colors.surface)
        }
    }

    private func accessibility(_ day: Day) -> String {
        let state = day.isDone ? "тренировка была" : day.isRestDay ? "отдых" : day.isToday ? "сегодня" : "по плану"
        return "\(day.label): \(state)"
    }
}

/// The canvas chart card: a kicker, a total on the right and rounded bars with labels; the current bar is accent.
struct TrainingBarChart: View {
    struct Bar: Identifiable {
        let id: Int
        let label: String
        let value: Double
        let isCurrent: Bool
    }

    let title: String
    let total: String
    let bars: [Bar]
    let accessibilitySummary: String
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        let top = max(bars.map(\.value).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                TrainingKicker(text: title)
                Spacer()
                Text(total)
                    .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(bars) { bar in
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(color(bar))
                            .frame(height: bar.value > 0 ? max(10, CGFloat(bar.value / top) * 84) : 6)
                        Text(bar.label)
                            .font(DS.Fonts.text(12, .bold, relativeTo: .caption2))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: DS.Metrics.cardRadius, style: .continuous).fill(DS.Colors.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilitySummary)
    }

    private func color(_ bar: Bar) -> Color {
        if bar.isCurrent { return accent }
        return bar.value > 0 ? TrainingPalette.quietBar : TrainingPalette.track
    }
}

/// Russian word forms: 1 упражнение, 2 упражнения, 5 упражнений.
enum TrainingWords {
    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }

    static let shortWeekdays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    /// Rough length of a plan day: 45 s per set plus the rests, rounded to five minutes.
    static func estimatedMinutes(_ day: WorkoutDayPlan) -> Int {
        var seconds = 0
        for (index, exercise) in day.exercises.enumerated() {
            let sets = max(1, exercise.sets)
            seconds += sets * 45 + (sets - 1) * exercise.restSeconds
            if index < day.exercises.count - 1 {
                seconds += exercise.restAfterExercise ?? exercise.restSeconds
            }
        }
        let minutes = Int((Double(seconds) / 60).rounded())
        return max(5, Int((Double(minutes) / 5).rounded()) * 5)
    }

    /// «5 упражнений · ~50 мин».
    static func daySummary(_ day: WorkoutDayPlan) -> String {
        let count = day.exercises.count
        return "\(count) \(plural(count, "упражнение", "упражнения", "упражнений")) · ~\(estimatedMinutes(day)) мин"
    }
}
