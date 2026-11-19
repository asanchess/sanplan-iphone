import SwiftUI

/// «Сегодня» as a dashboard (owner 19.11, D-A): one line from morning to midnight with a dot per thing of the day
/// in its section colour. Filled: done; outlined: still ahead. A thin mark shows the current time.
struct DayTimelineMark: Identifiable, Equatable {
    enum Kind: Equatable { case plan, workout }
    let id: String
    let minute: Int
    let kind: Kind
    let done: Bool
    let title: String
}

enum DayTimeline {
    static let startHour = 6
    static let endHour = 24

    /// Plans of the day with a time, and workouts started that day.
    static func marks(agenda: [AgendaItem], day: String, workouts: [WorkoutRecord], timeZone: TimeZone) -> [DayTimelineMark] {
        var marks: [DayTimelineMark] = agenda.compactMap { entry in
            guard entry.displayDate == day, let start = entry.startMin, entry.item.allDay != true else { return nil }
            return DayTimelineMark(id: "plan-\(entry.id)", minute: start, kind: .plan,
                                   done: entry.item.completed == true, title: entry.item.title)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        for record in workouts {
            let date = Date(timeIntervalSince1970: Double(record.startedAt) / 1000)
            guard PlanDomain.today(now: date, timeZone: timeZone.identifier) == day else { continue }
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            marks.append(DayTimelineMark(id: "workout-\(record.id)", minute: minute, kind: .workout,
                                         done: true, title: record.title ?? "Тренировка"))
        }
        return marks.sorted { $0.minute < $1.minute }
    }

    /// 0…1 along the line; earlier than the start sits at the start, later than midnight at the end.
    static func position(minute: Int) -> Double {
        let span = Double((endHour - startHour) * 60)
        return min(max(Double(minute - startHour * 60) / span, 0), 1)
    }

    /// «2 плана, 1 тренировка» for VoiceOver.
    static func spoken(_ marks: [DayTimelineMark]) -> String {
        let plans = marks.filter { $0.kind == .plan }.count
        let workouts = marks.filter { $0.kind == .workout }.count
        var parts: [String] = []
        if plans > 0 { parts.append(ReviewFormat.plural(plans, "план", "плана", "планов")) }
        if workouts > 0 { parts.append(ReviewFormat.plural(workouts, "тренировка", "тренировки", "тренировок")) }
        return parts.isEmpty ? "На сегодня по времени ничего нет" : "Лента дня: " + parts.joined(separator: ", ")
    }
}

struct DayTimelineView: View {
    let marks: [DayTimelineMark]
    /// Minutes after midnight now; nil hides the mark (a day other than today).
    let nowMinute: Int?
    let action: () -> Void
    @Environment(\.sectionAccent) private var accent

    private static let labels = [6, 12, 18, 24]

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(TodayPalette.ringTrack).frame(height: 6)
                        if let nowMinute {
                            Capsule().fill(accent.opacity(0.55))
                                .frame(width: width * DayTimeline.position(minute: nowMinute), height: 6)
                            RoundedRectangle(cornerRadius: 1.5).fill(DS.Colors.textPrimary)
                                .frame(width: 3, height: 26)
                                .offset(x: width * DayTimeline.position(minute: nowMinute) - 1.5)
                        }
                        ForEach(marks) { mark in
                            dot(mark).offset(x: width * DayTimeline.position(minute: mark.minute) - 8)
                        }
                    }
                    .frame(height: 28)
                }
                .frame(height: 28)
                HStack(spacing: 0) {
                    ForEach(Self.labels, id: \.self) { hour in
                        Text(hour == 24 ? "0" : "\(hour)")
                            .font(DS.Fonts.text(12, .bold, relativeTo: .caption2))
                            .monospacedDigit()
                            .foregroundColor(DS.Colors.textMuted)
                        if hour != Self.labels.last { Spacer(minLength: 0) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DayTimeline.spoken(marks))
        .accessibilityHint("Открыть планы")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("today-timeline")
    }

    private func dot(_ mark: DayTimelineMark) -> some View {
        let color = mark.kind == .workout ? DS.Colors.workout : DS.Colors.plans
        return ZStack {
            Circle().fill(mark.done ? color : DS.Colors.surface)
            Circle().strokeBorder(mark.done ? DS.Colors.ink : color, lineWidth: 2.5)
        }
        .frame(width: 16, height: 16)
    }
}
