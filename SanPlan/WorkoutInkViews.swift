import SwiftUI

// «Тушь» для раздела «Тренировка»: шапка вкладки и кадр дня плана (DESIGN-INK 11.2–11.3).
// Логика тренировки здесь не меняется: кнопки вызывают те же методы WorkoutStore, что и раньше.

/// Шапка вкладки: заголовок `ink.type.title`, справа квадрат 44×44 с рамкой 2 pt — настройки.
struct InkScreenHeader: View {
    let title: String
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: Ink.Metrics.gutter) {
            Text(title)
                .inkPoster(26)
                .foregroundColor(Ink.Colors.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button(action: onSettings) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Ink.Colors.fg)
                    .frame(width: Ink.Metrics.minHit, height: Ink.Metrics.minHit)
                    .overlay(Rectangle().strokeBorder(Ink.Colors.fg, lineWidth: Ink.Metrics.cellLine))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Настройки")
        }
    }
}

/// Кадр дня плана: название и число упражнений, список, внизу «Начать тренировку».
/// Сегодняшний день — `.tone` с фолио «СЕГОДНЯ» и главной кнопкой; остальные — `.plain` и вторичная кнопка.
struct InkDayPanel: View {
    let day: WorkoutDayPlan
    let isPrimary: Bool
    let isToday: Bool
    var showsMascot = false
    let onStart: () -> Void

    private var title: String { day.title ?? WorkoutFormat.weekdayNames[day.weekday - 1] }

    var body: some View {
        InkPanel(isToday ? .tone : .plain, halftoneCorner: .topTrailing, halftoneSize: CGSize(width: 72, height: 28)) {
            VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                head
                InkRule()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(day.exercises.enumerated()), id: \.offset) { _, exercise in
                        HStack(alignment: .firstTextBaseline, spacing: Ink.Metrics.framePadding) {
                            Text(exercise.name)
                                .inkText(.body)
                                .foregroundColor(Ink.Colors.fg)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(WorkoutFormat.exerciseSummary(exercise))
                                .inkText(.subheadline, weight: .bold, numeric: true)
                                .foregroundColor(Ink.Colors.muted)
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                InkButton(
                    title: "Начать тренировку",
                    icon: "play.fill",
                    kind: isPrimary ? .primary : .secondary,
                    action: onStart
                )
                .padding(.top, Ink.Metrics.gutter)
            }
        }
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isToday { InkFolio(text: "Сегодня") }
            HStack(alignment: .firstTextBaseline, spacing: Ink.Metrics.gutter) {
                Text(title)
                    .inkPoster(20, relativeTo: .headline)
                    .foregroundColor(Ink.Colors.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(isToday ? "\(title), сегодня" : title)
                    .accessibilityAddTraits(.isHeader)
                Text("\(day.exercises.count) упр.")
                    .inkText(.subheadline, weight: .medium, numeric: true)
                    .foregroundColor(Ink.Colors.muted)
                if showsMascot { InkMascotSlot(pose: .sleepy, size: 56) }
            }
            if day.title != nil {
                Text(WorkoutFormat.weekdayNames[day.weekday - 1])
                    .inkText(.subheadline, weight: .medium)
                    .foregroundColor(Ink.Colors.muted)
            }
        }
    }
}
