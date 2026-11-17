import SwiftUI
import UIKit

/// One arc of «Прогресс» (docs/design/ARCS-R6.md): 6 counted weeks; finishing it opens the next arc,
/// its scene `arc-<id>` and its mascot skin.
/// Round 6: a small local list on purpose. The skin catalogue lives in `MascotSkins.swift` (profile worker);
/// the lead unifies the two at merge.
struct ProgressArc: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let weeks: Int

    /// Scene picture of the arc in Assets.xcassets; a placeholder is drawn until it is added.
    var sceneAsset: String { "arc-\(id)" }
}

struct ProgressArcPosition: Equatable {
    let arc: ProgressArc
    /// Counted weeks inside this arc.
    let done: Int
    let next: ProgressArc?
    let finishedAll: Bool
    let totalCounted: Int

    var fraction: Double { arc.weeks == 0 ? 0 : min(1, Double(done) / Double(arc.weeks)) }

    /// «Неделя 3 из 6. Дальше — Шиноби.»
    var line: String {
        if finishedAll { return "Все арки пройдены. Засчитано недель: \(totalCounted)." }
        let weeksPart = done == 0 ? "Пока 0 недель из \(arc.weeks)." : "Неделя \(done) из \(arc.weeks)."
        guard let next else { return weeksPart }
        return "\(weeksPart) Дальше — \(next.name)."
    }
}

enum ProgressArcs {
    static let weeksPerArc = 6

    /// Owner's order, 17.11.2026.
    static let all: [ProgressArc] = [
        ProgressArc(id: "nobody", name: "Никто", weeks: weeksPerArc),
        ProgressArc(id: "shinobi", name: "Шиноби", weeks: weeksPerArc),
        ProgressArc(id: "pirate", name: "Пират", weeks: weeksPerArc),
        ProgressArc(id: "reaper", name: "Жнец душ", weeks: weeksPerArc),
        ProgressArc(id: "hunter", name: "Охотник", weeks: weeksPerArc),
    ]

    static let rule = "Неделя засчитана, если есть 3 тренировки или 5 дней с закрытыми планами. Пропуск ничего не обнуляет."

    /// Weeks (Monday on) with 3 workouts or 5 different days with closed tasks, over all history.
    /// Missing a week never resets anything, so the count only grows.
    static func countedWeeks(closedTaskDays: [String], workoutDays: [String]) -> Int {
        var closedByWeek: [String: Set<String>] = [:]
        for day in closedTaskDays {
            closedByWeek[HabitCalendar.weekStart(day), default: []].insert(day)
        }
        var workoutsByWeek: [String: Int] = [:]
        for day in workoutDays {
            workoutsByWeek[HabitCalendar.weekStart(day), default: 0] += 1
        }
        let weeks = Set(closedByWeek.keys).union(workoutsByWeek.keys)
        return weeks.filter { (workoutsByWeek[$0] ?? 0) >= 3 || (closedByWeek[$0]?.count ?? 0) >= 5 }.count
    }

    static func position(counted: Int) -> ProgressArcPosition {
        var left = max(0, counted)
        for (index, arc) in all.enumerated() {
            if left < arc.weeks {
                let next = index + 1 < all.count ? all[index + 1] : nil
                return ProgressArcPosition(arc: arc, done: left, next: next, finishedAll: false, totalCounted: counted)
            }
            left -= arc.weeks
        }
        let last = all[all.count - 1]
        return ProgressArcPosition(arc: last, done: last.weeks, next: nil, finishedAll: true, totalCounted: counted)
    }
}

/// The arc scene slot: the picture `arc-<id>` when it is in the asset catalogue, else a dashed placeholder.
struct ProgressArcScene: View {
    let arc: ProgressArc
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            if UIImage(named: arc.sceneAsset) != nil {
                Image(arc.sceneAsset)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    DS.Colors.canvas
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(DS.Colors.textMuted)
                }
                .overlay(shape.strokeBorder(accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}
