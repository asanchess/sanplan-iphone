import Foundation

public struct PlanItem: Codable, Identifiable, Equatable, Hashable {
    public var id: String
    public var kind: String // "event" | "task"
    public var title: String
    public var date: String?
    public var time: String?
    public var durationMinutes: Int?
    public var reminderMinutes: Int?
    public var reminderOffsets: [Int]?
    public var timeZone: String
    public var sourceText: String?
    public var completed: Bool?
    public var googleEventId: String?
    public var googleSync: String?
    public var googleSchedule: NativeSchedule?
    public var alarmSchedule: NativeSchedule?
    public var alarmDeleted: Bool?
    public var alarmOnly: Bool?
    public var savedAt: String?
    public var source: String?
    public var destination: String?
    public var description: String?
    public var allDay: Bool?

    public init(
        id: String = UUID().uuidString,
        kind: String = "event",
        title: String = "",
        date: String? = nil,
        time: String? = nil,
        durationMinutes: Int? = 60,
        reminderMinutes: Int? = 1440,
        reminderOffsets: [Int]? = [1440, 60, 0],
        timeZone: String = "Asia/Qyzylorda",
        sourceText: String? = nil,
        completed: Bool? = nil,
        googleEventId: String? = nil,
        googleSync: String? = nil,
        googleSchedule: NativeSchedule? = nil,
        alarmSchedule: NativeSchedule? = nil,
        alarmDeleted: Bool? = nil,
        alarmOnly: Bool? = nil,
        savedAt: String? = nil,
        source: String? = nil,
        destination: String? = nil,
        description: String? = nil,
        allDay: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.date = date
        self.time = time
        self.durationMinutes = durationMinutes
        self.reminderMinutes = reminderMinutes
        self.reminderOffsets = reminderOffsets
        self.timeZone = timeZone
        self.sourceText = sourceText
        self.completed = completed
        self.googleEventId = googleEventId
        self.googleSync = googleSync
        self.googleSchedule = googleSchedule
        self.alarmSchedule = alarmSchedule
        self.alarmDeleted = alarmDeleted
        self.alarmOnly = alarmOnly
        self.savedAt = savedAt
        self.source = source
        self.destination = destination
        self.description = description
        self.allDay = allDay
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, date, time, durationMinutes, reminderMinutes, reminderOffsets, timeZone
        case sourceText, completed, googleEventId, googleSync, googleSchedule, alarmSchedule
        case alarmDeleted, alarmOnly, savedAt, source, destination, description, allDay
    }

    /// Parsed drafts and Google events omit some fields; one such item must not fail the whole list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            kind: try c.decodeIfPresent(String.self, forKey: .kind) ?? "event",
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
            date: try c.decodeIfPresent(String.self, forKey: .date),
            time: try c.decodeIfPresent(String.self, forKey: .time),
            durationMinutes: try c.decodeIfPresent(Int.self, forKey: .durationMinutes),
            reminderMinutes: try c.decodeIfPresent(Int.self, forKey: .reminderMinutes),
            reminderOffsets: try c.decodeIfPresent([Int].self, forKey: .reminderOffsets),
            timeZone: try c.decodeIfPresent(String.self, forKey: .timeZone) ?? PlanDomain.defaultTimeZone,
            sourceText: try c.decodeIfPresent(String.self, forKey: .sourceText),
            completed: try c.decodeIfPresent(Bool.self, forKey: .completed),
            googleEventId: try c.decodeIfPresent(String.self, forKey: .googleEventId),
            googleSync: try c.decodeIfPresent(String.self, forKey: .googleSync),
            googleSchedule: try c.decodeIfPresent(NativeSchedule.self, forKey: .googleSchedule),
            alarmSchedule: try c.decodeIfPresent(NativeSchedule.self, forKey: .alarmSchedule),
            alarmDeleted: try c.decodeIfPresent(Bool.self, forKey: .alarmDeleted),
            alarmOnly: try c.decodeIfPresent(Bool.self, forKey: .alarmOnly),
            savedAt: try c.decodeIfPresent(String.self, forKey: .savedAt),
            source: try c.decodeIfPresent(String.self, forKey: .source),
            destination: try c.decodeIfPresent(String.self, forKey: .destination),
            description: try c.decodeIfPresent(String.self, forKey: .description),
            allDay: try c.decodeIfPresent(Bool.self, forKey: .allDay)
        )
    }

    public func toNativePlan() -> NativePlan {
        NativePlan(
            id: id,
            kind: kind,
            title: title,
            date: date,
            time: time,
            duration: durationMinutes,
            reminderMinutes: reminderMinutes,
            reminderOffsets: reminderOffsets,
            timeZone: timeZone,
            completed: completed,
            googleSchedule: googleSchedule,
            alarmSchedule: alarmSchedule,
            alarmDeleted: alarmDeleted
        )
    }

    public static func fromNativePlan(_ p: NativePlan) -> PlanItem {
        PlanItem(
            id: p.id,
            kind: p.kind ?? "event",
            title: p.title,
            date: p.date,
            time: p.time,
            durationMinutes: p.duration,
            reminderMinutes: p.reminderMinutes,
            reminderOffsets: p.reminderOffsets,
            timeZone: p.timeZone ?? "Asia/Qyzylorda",
            completed: p.completed,
            googleSchedule: p.googleSchedule,
            alarmSchedule: p.alarmSchedule,
            alarmDeleted: p.alarmDeleted
        )
    }
}

public struct PlanConflict: Identifiable, Equatable {
    public var id: String { "\(ids.joined(separator: "-"))-\(date)-\(startMinute)" }
    public let ids: [String]
    public let date: String
    public let startMinute: Int
    public let endMinute: Int
}

public struct AgendaItem: Identifiable, Equatable {
    public var id: String { item.id }
    public let item: PlanItem
    public let startMin: Int?
    public let endMin: Int?
    public let displayTime: String
    public let displayDate: String
    public let badge: String
}

public enum PlanDomain {
    public static let defaultTimeZone = "Asia/Qyzylorda"
    public static let defaultReminderOffsets = [1440, 60, 0]

    /// The current day in the owner's time zone.
    public static func today(now: Date = Date(), timeZone: String = defaultTimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZone) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    /// The fields the server stores for a set of reminder offsets.
    public static func withReminderOffsets(_ plan: PlanItem, offsets: [Int]) -> PlanItem {
        var updated = plan
        updated.reminderOffsets = offsets.sorted(by: >)
        updated.reminderMinutes = offsets.max() ?? -1
        return updated
    }

    /// Alarm-only records are not plans, and a plan sent to Google comes back as a calendar event too.
    /// Saved plans come first in the input, so the saved copy is the one kept.
    static func visibleItems(_ plans: [PlanItem]) -> [PlanItem] {
        var seenIds = Set<String>()
        var seenGoogleIds = Set<String>()
        var result: [PlanItem] = []
        for plan in plans where plan.alarmOnly != true {
            guard seenIds.insert(plan.id).inserted else { continue }
            if let googleId = plan.googleEventId, !seenGoogleIds.insert(googleId).inserted { continue }
            result.append(plan)
        }
        return result
    }

    public static func zonedEpoch(dateStr: String, timeStr: String, timeZone: String) -> Int64? {
        guard dateStr.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        guard timeStr.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { return nil }
        guard let tz = TimeZone(identifier: timeZone) else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tz
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false

        guard let parsed = formatter.date(from: "\(dateStr) \(timeStr):00") else { return nil }
        return Int64(parsed.timeIntervalSince1970 * 1000)
    }

    public static func addDays(dateStr: String, days: Int) -> String {
        guard let tz = TimeZone(secondsFromGMT: 0) else { return dateStr }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tz
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: dateStr) else { return dateStr }
        guard let shifted = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: parsed) else { return dateStr }
        return formatter.string(from: shifted)
    }

    public static func getLocalMinutes(epochMs: Int64, targetDateStr: String, targetTimeZone: String) -> Int? {
        guard let targetStartEpoch = zonedEpoch(dateStr: targetDateStr, timeStr: "00:00", timeZone: targetTimeZone) else {
            return nil
        }
        return Int(floor(Double(epochMs - targetStartEpoch) / 60000.0))
    }

    public static func getReminderOffsets(plan: PlanItem) throws -> [Int]? {
        if let offsets = plan.reminderOffsets {
            if offsets.count > 5 {
                throw NSError(domain: "SanPlan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Выбери до пяти разных напоминаний, не более четырёх недель заранее."])
            }
            var seen = Set<Int>()
            for n in offsets {
                if n < 0 || n > 40320 {
                    throw NSError(domain: "SanPlan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Выбери до пяти разных напоминаний, не более четырёх недель заранее."])
                }
                if seen.contains(n) {
                    throw NSError(domain: "SanPlan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Выбери до пяти разных напоминаний, не более четырёх недель заранее."])
                }
                seen.insert(n)
            }
            return offsets.sorted(by: >)
        }
        if let scalar = plan.reminderMinutes {
            if scalar < -1 || scalar > 40320 {
                throw NSError(domain: "SanPlan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Проверь время напоминания."])
            }
            return scalar == -1 ? [] : [scalar]
        }
        return nil
    }

    public static func withDefaultReminders(_ plan: PlanItem) -> PlanItem {
        guard plan.kind == "event" || plan.kind == "task",
              let date = plan.date, !date.isEmpty,
              let time = plan.time, !time.isEmpty else {
            return plan
        }
        if (try? getReminderOffsets(plan: plan)) != nil {
            return plan
        }
        var updated = plan
        updated.reminderOffsets = defaultReminderOffsets
        updated.reminderMinutes = 1440
        return updated
    }

    public static func formatReminderOffset(_ n: Int) -> String {
        if n == 0 { return "В момент начала" }
        if n == -1 { return "Без напоминания" }
        let d = n / 1440
        let h = (n % 1440) / 60
        let m = n % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d) дн.") }
        if h > 0 { parts.append("\(h) ч.") }
        if m > 0 { parts.append("\(m) мин.") }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? "В момент начала" : "За \(joined)"
    }

    public static func validatePlan(_ plan: PlanItem) -> [String] {
        var errors: [String] = []
        let trimmedTitle = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            errors.append("Название не может быть пустым.")
        }
        if plan.kind != "event" && plan.kind != "task" {
            errors.append("Выбери событие или задачу.")
        }
        if plan.timeZone.isEmpty || TimeZone(identifier: plan.timeZone) == nil {
            errors.append("Укажи корректный часовой пояс.")
        }
        if let t = plan.time, !t.isEmpty {
            if t.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) == nil {
                errors.append("Укажи корректное время.")
            }
        }

        do {
            _ = try getReminderOffsets(plan: plan)
        } catch {
            errors.append(error.localizedDescription)
        }

        if plan.kind == "task" {
            if plan.reminderMinutes == nil && plan.reminderOffsets == nil {
                errors.append("Укажите время напоминания для задачи (или выберите 'Без напоминания').")
            } else if plan.reminderMinutes != -1 && (plan.reminderOffsets?.isEmpty != true) && (plan.date == nil || plan.time == nil) {
                errors.append("Задача с напоминанием требует точной даты и времени (или выберите 'Без напоминания').")
            }
        } else {
            if plan.date == nil || plan.date?.isEmpty == true { errors.append("Укажите дату события.") }
            if plan.time == nil || plan.time?.isEmpty == true { errors.append("Укажите время события.") }
            if plan.durationMinutes == nil { errors.append("Укажите длительность события.") }
            if plan.reminderMinutes == nil && plan.reminderOffsets == nil { errors.append("Укажите время напоминания.") }
        }

        if let dur = plan.durationMinutes {
            if dur < 1 || dur > 1440 {
                errors.append("Длительность должна быть от 1 до 1440 минут.")
            }
        }
        if let rem = plan.reminderMinutes {
            if rem < -1 || rem > 40320 {
                errors.append("Напоминание должно быть от -1 до 40320 минут.")
            }
        }
        if let d = plan.date, !d.isEmpty, !plan.timeZone.isEmpty {
            let t = plan.time ?? "00:00"
            if zonedEpoch(dateStr: d, timeStr: t, timeZone: plan.timeZone) == nil {
                errors.append("Недопустимое время (возможно, переход на летнее/зимнее время или неверная дата).")
            }
        }

        return errors
    }

    public static func getConflicts(plans: [PlanItem]) -> [PlanConflict] {
        struct ResolvedEvent {
            let id: String
            let timeZone: String
            let start: Int64
            let end: Int64
        }
        var resolved: [ResolvedEvent] = []
        for p in plans where p.kind == "event" {
            guard let d = p.date, let t = p.time, let dur = p.durationMinutes else { continue }
            guard let start = zonedEpoch(dateStr: d, timeStr: t, timeZone: p.timeZone) else { continue }
            let end = start + Int64(dur * 60000)
            resolved.append(ResolvedEvent(id: p.id, timeZone: p.timeZone, start: start, end: end))
        }

        var conflicts: [PlanConflict] = []
        guard resolved.count > 1 else { return [] }
        for i in 0..<resolved.count {
            for j in (i + 1)..<resolved.count {
                let a = resolved[i]
                let b = resolved[j]
                if a.id != b.id && a.start < b.end && b.start < a.end {
                    let sM = max(a.start, b.start)
                    let eM = min(a.end, b.end)
                    guard let tz = TimeZone(identifier: a.timeZone) else { continue }

                    let cal = Calendar(identifier: .gregorian)
                    let dfDate = DateFormatter()
                    dfDate.calendar = cal
                    dfDate.locale = Locale(identifier: "en_US_POSIX")
                    dfDate.timeZone = tz
                    dfDate.dateFormat = "yyyy-MM-dd"

                    let dfTime = DateFormatter()
                    dfTime.calendar = cal
                    dfTime.locale = Locale(identifier: "en_US_POSIX")
                    dfTime.timeZone = tz
                    dfTime.dateFormat = "HH:mm"

                    var cursor = sM
                    while cursor < eM {
                        let cursorDate = Date(timeIntervalSince1970: Double(cursor) / 1000.0)
                        let dateStr = dfDate.string(from: cursorDate)
                        let nextDateStr = addDays(dateStr: dateStr, days: 1)
                        let midnight = zonedEpoch(dateStr: nextDateStr, timeStr: "00:00", timeZone: a.timeZone)
                        let segmentEnd = midnight == nil ? eM : min(eM, midnight!)

                        let startParts = dfTime.string(from: cursorDate).split(separator: ":").compactMap { Int($0) }
                        let endParts = dfTime.string(from: Date(timeIntervalSince1970: Double(segmentEnd) / 1000.0)).split(separator: ":").compactMap { Int($0) }

                        let sh = startParts.count > 0 ? startParts[0] : 0
                        let sm = startParts.count > 1 ? startParts[1] : 0
                        let eh = endParts.count > 0 ? endParts[0] : 0
                        let em = endParts.count > 1 ? endParts[1] : 0

                        let startMinute = sh * 60 + sm
                        let endMinute = segmentEnd == midnight ? 1440 : eh * 60 + em

                        conflicts.append(PlanConflict(ids: [a.id, b.id], date: dateStr, startMinute: startMinute, endMinute: endMinute))
                        cursor = segmentEnd
                    }
                }
            }
        }
        return conflicts
    }

    public static func getItemSourceBadge(item: PlanItem) -> String {
        if item.source == "google" || item.googleEventId != nil { return "Google" }
        if item.savedAt != nil || item.destination == "local" || item.source == "local" { return "ARNA" }
        return "Черновик"
    }

    public static func formatAgendaTime(item: PlanItem, targetDate: String?, targetTimeZone: String?) -> String {
        if item.allDay == true { return "Весь день" }
        if item.kind == "task" {
            if let t = item.time, let d = item.date, let tz = targetTimeZone, let td = targetDate {
                if let epoch = zonedEpoch(dateStr: d, timeStr: t, timeZone: item.timeZone) {
                    if let minute = getLocalMinutes(epochMs: epoch, targetDateStr: td, targetTimeZone: tz) {
                        let h = ((minute % 1440) + 1440) % 1440 / 60
                        let m = ((minute % 1440) + 1440) % 1440 % 60
                        return String(format: "%02d:%02d", h, m)
                    }
                }
            }
            return item.time ?? "Без времени"
        }
        guard let timeStr = item.time, !timeStr.isEmpty else { return "Весь день" }
        guard let duration = item.durationMinutes, duration > 0 else { return timeStr }

        if let td = targetDate, let tz = targetTimeZone, let d = item.date {
            if let epoch = zonedEpoch(dateStr: d, timeStr: timeStr, timeZone: item.timeZone) {
                if let startMin = getLocalMinutes(epochMs: epoch, targetDateStr: td, targetTimeZone: tz) {
                    let endMin = startMin + duration
                    let formatLocal = { (m: Int) -> String in
                        let norm = ((m % 1440) + 1440) % 1440
                        return String(format: "%02d:%02d", norm / 60, norm % 60)
                    }
                    let startStr = formatLocal(startMin)
                    let endStr = formatLocal(endMin)
                    if startMin < 0 {
                        return "до \(endStr) (с вчера)"
                    }
                    if endMin > 1440 {
                        return "\(startStr)–\(endStr) (+1)"
                    }
                    return "\(startStr)–\(endStr)"
                }
            }
        }

        let parts = timeStr.split(separator: ":").compactMap { Int($0) }
        let h = parts.count > 0 ? parts[0] : 0
        let m = parts.count > 1 ? parts[1] : 0
        let totalStart = h * 60 + m
        let totalEnd = totalStart + duration
        let eh = (totalEnd % 1440) / 60
        let em = totalEnd % 60
        let endStr = String(format: "%02d:%02d", eh, em)
        return totalEnd >= 1440 ? "\(timeStr)–\(endStr) (+1)" : "\(timeStr)–\(endStr)"
    }

    public static func getAgendaItems(
        plans: [PlanItem],
        targetDate: String,
        targetTimeZone: String = defaultTimeZone,
        search: String = ""
    ) -> [AgendaItem] {
        guard let dayStart = zonedEpoch(dateStr: targetDate, timeStr: "00:00", timeZone: targetTimeZone),
              let dayEnd = zonedEpoch(dateStr: addDays(dateStr: targetDate, days: 1), timeStr: "00:00", timeZone: targetTimeZone) else {
            return []
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var results: [AgendaItem] = []
        for it in visibleItems(plans) {
            if !query.isEmpty {
                let full = "\(it.title) \(it.description ?? "")".lowercased()
                if !full.contains(query) { continue }
            }
            if it.date == nil || it.date?.isEmpty == true {
                if it.kind != "task" { continue }
                results.append(AgendaItem(
                    item: it,
                    startMin: nil,
                    endMin: nil,
                    displayTime: formatAgendaTime(item: it, targetDate: targetDate, targetTimeZone: targetTimeZone),
                    displayDate: targetDate,
                    badge: getItemSourceBadge(item: it)
                ))
                continue
            }

            let planTz = it.timeZone.isEmpty ? targetTimeZone : it.timeZone
            let epoch: Int64?
            if let t = it.time, !t.isEmpty, let d = it.date {
                epoch = zonedEpoch(dateStr: d, timeStr: t, timeZone: planTz)
            } else {
                epoch = nil
            }

            if let epoch = epoch {
                let durMs = Int64((it.kind == "event" ? (it.durationMinutes ?? 1) : 0) * 60000)
                let end = epoch + durMs
                let inDay: Bool
                if it.kind == "event" {
                    inDay = epoch < dayEnd && end > dayStart
                } else {
                    inDay = epoch >= dayStart && epoch < dayEnd
                }
                if !inDay { continue }

                let startMin = getLocalMinutes(epochMs: epoch, targetDateStr: targetDate, targetTimeZone: targetTimeZone)
                let endMin = startMin == nil ? nil : startMin! + (it.durationMinutes ?? 0)
                results.append(AgendaItem(
                    item: it,
                    startMin: startMin,
                    endMin: endMin,
                    displayTime: formatAgendaTime(item: it, targetDate: targetDate, targetTimeZone: targetTimeZone),
                    displayDate: targetDate,
                    badge: getItemSourceBadge(item: it)
                ))
            } else {
                if it.date == targetDate {
                    results.append(AgendaItem(
                        item: it,
                        startMin: nil,
                        endMin: nil,
                        displayTime: formatAgendaTime(item: it, targetDate: targetDate, targetTimeZone: targetTimeZone),
                        displayDate: targetDate,
                        badge: getItemSourceBadge(item: it)
                    ))
                }
            }
        }

        results.sort { a, b in
            let aMin = a.startMin ?? Int.max
            let bMin = b.startMin ?? Int.max
            if aMin != bMin { return aMin < bMin }
            return a.item.title.localizedCaseInsensitiveCompare(b.item.title) == .orderedAscending
        }
        return results
    }

    public static func getUpcomingItems(
        plans: [PlanItem],
        nowEpochMs: Int64,
        timeZone: String = defaultTimeZone,
        search: String = ""
    ) -> [AgendaItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var results: [AgendaItem] = []
        for it in visibleItems(plans) {
            if !query.isEmpty {
                let full = "\(it.title) \(it.description ?? "")".lowercased()
                if !full.contains(query) { continue }
            }

            if it.kind == "task" {
                if it.completed == true { continue }
            } else {
                guard let d = it.date, !d.isEmpty else { continue }
                let t = it.time ?? "23:59"
                guard var eventMs = zonedEpoch(dateStr: d, timeStr: t, timeZone: it.timeZone.isEmpty ? timeZone : it.timeZone) else { continue }
                if let dur = it.durationMinutes {
                    eventMs += Int64(dur * 60000)
                }
                if eventMs < nowEpochMs { continue }
            }

            let displayDate = it.date ?? ""
            let startMin: Int?
            if let d = it.date, let t = it.time, let epoch = zonedEpoch(dateStr: d, timeStr: t, timeZone: it.timeZone) {
                startMin = getLocalMinutes(epochMs: epoch, targetDateStr: d, targetTimeZone: timeZone)
            } else {
                startMin = nil
            }

            results.append(AgendaItem(
                item: it,
                startMin: startMin,
                endMin: startMin == nil ? nil : startMin! + (it.durationMinutes ?? 0),
                displayTime: formatAgendaTime(item: it, targetDate: displayDate.isEmpty ? nil : displayDate, targetTimeZone: timeZone),
                displayDate: displayDate,
                badge: getItemSourceBadge(item: it)
            ))
        }

        results.sort { a, b in
            let ad = a.item.date ?? "9999-99-99"
            let bd = b.item.date ?? "9999-99-99"
            if ad != bd { return ad < bd }
            let at = a.item.time ?? "23:59"
            let bt = b.item.time ?? "23:59"
            if at != bt { return at < bt }
            if a.item.kind != b.item.kind { return a.item.kind == "event" }
            return a.item.title.localizedCaseInsensitiveCompare(b.item.title) == .orderedAscending
        }

        return results
    }

    public static func setPlanCompletion(plans: [PlanItem], id: String, completed: Bool) -> [PlanItem] {
        return plans.map { p in
            if p.id == id {
                var copy = p
                copy.completed = completed
                return copy
            }
            return p
        }
    }
}
