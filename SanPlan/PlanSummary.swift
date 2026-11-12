import Foundation

/// Сводка раздела «Планы» по договорённости DOMAINS.md §2: чистые функции,
/// которые вызывают «Сегодня» и «Итоги». Считаются только задачи: у события нет отметки «сделано».
public struct PlanOpenItem: Equatable, Hashable {
    public let id: String
    public let title: String
}

public struct PlanDaySummary: Equatable {
    public let done: Int
    public let total: Int
    public let open: [PlanOpenItem]
}

public enum PlanSummary {
    /// Задачи дня: сделано, всего и список незакрытых (по времени, затем по названию).
    public static func day(plans: [PlanItem], day: String) -> PlanDaySummary {
        let tasks = PlanDomain.visibleItems(plans).filter {
            $0.kind == "task" && $0.date == day && $0.alarmDeleted != true
        }
        let ordered = tasks.sorted {
            ($0.time ?? "99:99", $0.title) < ($1.time ?? "99:99", $1.title)
        }
        let open = ordered.filter { $0.completed != true }.map { PlanOpenItem(id: $0.id, title: $0.title) }
        return PlanDaySummary(done: tasks.count - open.count, total: tasks.count, open: open)
    }

    /// Копии незакрытых задач, перенесённые на день позже. Закрытые, чужие id и не-задачи не трогаются.
    public static func movedToNextDay(plans: [PlanItem], ids: [String]) -> [PlanItem] {
        let wanted = Set(ids)
        return PlanDomain.visibleItems(plans).compactMap { plan in
            guard wanted.contains(plan.id), plan.kind == "task", plan.completed != true,
                  let date = plan.date, !date.isEmpty else { return nil }
            var moved = plan
            moved.date = PlanDomain.addDays(dateStr: date, days: 1)
            return moved
        }
    }

    /// Дни из `from...to`, в которые было реальное действие в планах: закрыта задача
    /// (по дате задачи) или создана запись (по дню сохранения в часовом поясе владельца).
    public static func activityDays(
        plans: [PlanItem], from: String, to: String, timeZone: String = PlanDomain.defaultTimeZone
    ) -> [String] {
        var days = Set<String>()
        for plan in PlanDomain.visibleItems(plans) where plan.alarmDeleted != true {
            if plan.kind == "task", plan.completed == true, let date = plan.date { days.insert(date) }
            if let saved = plan.savedAt, let day = localDay(isoString: saved, timeZone: timeZone) { days.insert(day) }
        }
        return days.filter { $0 >= from && $0 <= to }.sorted()
    }

    static func localDay(isoString: String, timeZone: String) -> String? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = withFraction.date(from: isoString) ?? plain.date(from: isoString) else { return nil }
        return PlanDomain.today(now: date, timeZone: timeZone)
    }
}

extension PlanStore {
    public func daySummary(for day: String) -> PlanDaySummary {
        PlanSummary.day(plans: plans, day: day)
    }

    public func activityDays(from: String, to: String) -> [String] {
        PlanSummary.activityDays(plans: plans, from: from, to: to, timeZone: timeZone)
    }
}
