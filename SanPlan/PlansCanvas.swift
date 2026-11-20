import SwiftUI

// Round 6: the pieces of `docs/design/canvas-r5/Plans.html`, ported 1:1. Every colour that the canvas
// paints in #7FB2FF comes from `sectionAccent`, so the section stays blue wherever it is shown.

/// Canvas colours used only in «Планы».
enum PlansStyle {
    /// Border of an empty check box and of an open timeline dot (#5A4A8A).
    static let boxBorder = DS.Colors.hex(0x5A4A8A)
    /// A habit tile whose norm for the day is reached (#2C3F6B).
    static let doneTile = DS.Colors.hex(0x2C3F6B)
    /// Track of a goal bar (#33295A).
    static let goalTrack = DS.Colors.hex(0x33295A)
}

// MARK: - Backdrop

/// The soft glow and dot pattern in the top-right corner of the canvas.
struct PlansBackdrop: View {
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            // radial-gradient(circle, accent 22% → 0 at 68%) on a 320 pt circle at right -90, top -110.
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.22), accent.opacity(0)], center: .center, startRadius: 0, endRadius: 154))
                .frame(width: 320, height: 320)
                .offset(x: 90, y: -110)
            // 11 pt dot grid, faded out from 72% / 28% of a 230 pt square at right -30, top -30.
            Canvas { context, size in
                let center = CGPoint(x: size.width * 0.72, y: size.height * 0.28)
                let fade: CGFloat = 159
                var y: CGFloat = 5.5
                while y < size.height {
                    var x: CGFloat = 5.5
                    while x < size.width {
                        let distance = hypot(x - center.x, y - center.y)
                        let alpha = max(0, 1 - distance / fade)
                        if alpha > 0 {
                            context.opacity = Double(alpha)
                            context.fill(Path(ellipseIn: CGRect(x: x - 1.9, y: y - 1.9, width: 3.8, height: 3.8)), with: .color(accent))
                        }
                        x += 11
                    }
                    y += 11
                }
            }
            .frame(width: 230, height: 230)
            .opacity(0.3)
            .offset(x: 30, y: -30)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Bars

/// A rounded progress bar: accent fill over a track.
struct PlansBar: View {
    let fraction: Double
    var height: CGFloat = 8
    var track: Color = Color.white.opacity(0.14)
    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(track)
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .fill(accent)
                        .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
                        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: fraction)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - View filter (Сегодня / Неделя / Все / Готово)

/// The plan filter. Not on the canvas; drawn as small chips in the canvas switcher style.
struct PlansFilterChips<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isOn = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(DS.Fonts.text(14, .bold, relativeTo: .subheadline))
                        .lineLimit(1)
                        .foregroundColor(isOn ? DS.Colors.canvas : DS.Colors.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(accent)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.ink).offset(x: 3, y: 3))
                                    .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.087, d: 1, tx: 1.5, ty: 0))
                            } else {
                                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface)
                            }
                        }
                        .frame(minHeight: DS.Metrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Какие планы показать")
    }
}

// MARK: - Day strip

/// Seven day buttons, Monday first: 62 pt tall, radius 16; the chosen day is filled with the section colour.
struct PlansDayStrip: View {
    let days: [String]
    let selected: String
    let today: String
    let weekday: (String) -> String
    let number: (String) -> String
    let spoken: (String) -> String
    let onPick: (String) -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                let isOn = day == selected
                Button { onPick(day) } label: {
                    VStack(spacing: 0) {
                        Text(weekday(day))
                            .font(DS.Fonts.text(12, .bold, relativeTo: .caption))
                            .opacity(0.8)
                        Text(number(day))
                            .font(DS.Fonts.text(17, .heavy))
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundColor(isOn ? DS.Colors.canvas : DS.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .background(isOn ? accent : DS.Colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .bottom) {
                        // Today stays findable after another day is picked.
                        if day == today && !isOn {
                            Circle().fill(accent).frame(width: 5, height: 5).padding(.bottom, 6)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel(day == today ? "Сегодня, \(spoken(day))" : spoken(day))
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - Timeline

/// One line of the day: the time, a dot on the rail, and the card with a check box.
struct PlansTimelineRow: View {
    let time: String
    let title: String
    let note: String?
    let done: Bool
    /// Tasks can be ticked; events and drafts cannot.
    let canCheck: Bool
    let isPending: Bool
    let onToggle: () -> Void
    let onOpen: (() -> Void)?
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(time)
                .font(DS.Fonts.text(14, .bold, relativeTo: .footnote))
                .monospacedDigit()
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.trailing)
                .frame(width: 42, alignment: .trailing)

            Circle()
                .fill(done ? accent : DS.Colors.canvas)
                .overlay { if !done { Circle().strokeBorder(PlansStyle.boxBorder, lineWidth: 2) } }
                .frame(width: 12, height: 12)
                .padding(.horizontal, -5)
                .accessibilityHidden(true)

            HStack(spacing: 12) {
                Button { onOpen?() } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(DS.Fonts.text(17, .semibold))
                            .lineSpacing(2)
                            .strikethrough(done)
                            .foregroundColor(DS.Colors.textPrimary)
                            .multilineTextAlignment(.leading)
                        if let note, !note.isEmpty {
                            Text(note)
                                .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                                .foregroundColor(DS.Colors.textSecondary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onOpen == nil)
                .accessibilityHint(onOpen == nil ? "" : "Открывает план для правки")

                if canCheck {
                    Button(action: onToggle) {
                        PlansCheckBox(done: done)
                            .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(isPending)
                    .accessibilityLabel(done ? "Вернуть задачу: \(title)" : "Выполнить задачу: \(title)")
                    .accessibilityAddTraits(done ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 10)
            .padding(.leading, 16)
            // The 44 pt hit area already holds 8 pt around the 28 pt box.
            .padding(.trailing, canCheck ? 6 : 14)
            .frame(minHeight: 64)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(done ? 0.6 : 1)
        }
    }
}

/// The 28 pt check box: an outlined square, or the section colour with a tick.
struct PlansCheckBox: View {
    let done: Bool
    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if done {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(DS.Colors.canvas)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PlansStyle.boxBorder, lineWidth: 2)
            }
        }
        .frame(width: 28, height: 28)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.6), value: done)
    }
}

/// A list on the timeline rail: the 2 pt line runs behind the dots.
struct PlansTimeline<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .background(alignment: .leading) {
            Rectangle()
                .fill(DS.Colors.hairline)
                .frame(width: 2)
                .padding(.vertical, 12)
                .padding(.leading, 53)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Outlined link (Будильники, Сферы)

/// The 52 pt outlined row from the canvas («Будильники · 2 включены»).
struct PlansOutlineLink: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(DS.Fonts.text(16, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.Colors.hairline, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Habit tile

/// What one habit tile shows; built from HabitStore, or made up for screenshots.
struct PlansHabitTileModel: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
    let goal: Int
    let note: String
    let streak: HabitStreak?
    /// Marked by a rule (training, no spending): the tile cannot be ticked by hand.
    let isAuto: Bool
    /// Done today, so the streak just grew.
    var streakToday = false

    var isFull: Bool { count >= goal }
    var fraction: Double { goal > 0 ? Double(count) / Double(goal) : 0 }
}

/// The canvas habit tile: name, «5 / 8» in Dela, an 8 pt bar and a note. Darker blue once the norm is reached.
struct PlansHabitTile: View {
    let model: PlansHabitTileModel
    let onTick: () -> Void
    let onEdit: (() -> Void)?
    /// Marks the whole norm at once (was the swipe on the old row).
    var onComplete: (() -> Void)? = nil

    var body: some View {
        Button(action: onTick) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.title)
                    .font(DS.Fonts.text(17, .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                Text("\(model.count) / \(model.goal)")
                    .font(DS.Fonts.display(26, relativeTo: .title))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                PlansBar(fraction: model.fraction, height: 8)
                Spacer(minLength: 6)
                Text(model.isFull ? "Готово на сегодня" : model.note)
                    .font(DS.Fonts.text(14, .semibold, relativeTo: .footnote))
                    .opacity(0.8)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let streak = model.streak, streak.count > 0 {
                    StreakBadge(count: streak.count, unit: streak.unit, extendedToday: model.streakToday, size: 18)
                        .padding(.top, 4)
                }
            }
            .foregroundColor(DS.Colors.textPrimary)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(model.isFull ? PlansStyle.doneTile : DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(model.isAuto)
        .contextMenu {
            if let onComplete, !model.isFull, !model.isAuto {
                Button("Готово", systemImage: "checkmark", action: onComplete)
            }
            if let onEdit {
                Button("Изменить", systemImage: "pencil", action: onEdit)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.title): \(model.count) из \(model.goal)")
        .accessibilityValue(model.isFull ? "выполнено" : "")
        .accessibilityHint(model.isAuto ? "Отмечается само" : "Отметить")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Отметить") { if !model.isAuto { onTick() } }
        .accessibilityAction(named: "Готово") { if !model.isFull && !model.isAuto { onComplete?() } }
        .accessibilityAction(named: "Изменить") { onEdit?() }
        .sensoryFeedback(trigger: model.count) { (old: Int, new: Int) -> SensoryFeedback? in
            guard new > old else { return nil }
            return new >= model.goal ? .success : .impact(weight: .light)
        }
    }
}

// MARK: - Goal card

/// What one goal card shows; built from GoalStore, or made up for screenshots.
struct PlansGoalCardModel: Identifiable, Equatable {
    let id: String
    let sphere: String?
    let title: String
    /// The short figure on the right: «2 из 3», «182 400 ₸», «61%».
    let figure: String
    let fraction: Double?
    let note: String
    let isOverdue: Bool
    let isWeekGoal: Bool
}

/// The canvas goal card: sphere in the section colour, the figure, the name, a 10 pt bar and a note.
struct PlansGoalCard: View {
    let model: PlansGoalCardModel
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text((model.sphere ?? "Без сферы").uppercased())
                    .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                    .tracking(0.8)
                    .foregroundColor(accent)
                    .lineLimit(1)
                if model.isWeekGoal {
                    SkewTag("Цель недели", color: accent)
                }
                Spacer(minLength: 0)
                Text(model.figure)
                    .font(DS.Fonts.text(15, .heavy, relativeTo: .subheadline))
                    .monospacedDigit()
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            Text(model.title)
                .font(DS.Fonts.text(19, .bold, relativeTo: .title3))
                .lineSpacing(2)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let fraction = model.fraction {
                PlansBar(fraction: fraction, height: 10, track: PlansStyle.goalTrack)
            }
            Text(model.note)
                .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                .foregroundColor(model.isOverdue ? DS.Colors.destructive : DS.Colors.textSecondary)
                .multilineTextAlignment(.leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - «Понял так» card

/// The card that shows what the bottom field understood before anything is saved.
struct PlansUnderstoodCard<Content: View>: View {
    let title: String
    let onCancel: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                SkewTag(title, color: accent)
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Отменить")
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .inked(cornerRadius: 20, shadow: 4)
    }
}

/// One «what — value» line inside the understood card.
struct PlansFactLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(DS.Fonts.text(14, .semibold, relativeTo: .footnote))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(DS.Fonts.text(16, .semibold, relativeTo: .callout))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
