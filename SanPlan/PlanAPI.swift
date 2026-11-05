import Foundation

public struct PlanParseRequest: Encodable {
    public let text: String
    public let timeZone: String

    public init(text: String, timeZone: String) {
        self.text = text
        self.timeZone = timeZone
    }
}

public struct PlanParseResponse: Decodable {
    public let plans: [PlanItem]?
    public let message: String?
    public let error: String?
}

public struct PlanTranscribeRequest: Encodable {
    public let audioBase64: String
    public let mimeType: String
    public let timeZone: String
    public let intent: String

    public init(audioBase64: String, mimeType: String, timeZone: String, intent: String = "plans") {
        self.audioBase64 = audioBase64
        self.mimeType = mimeType
        self.timeZone = timeZone
        self.intent = intent
    }
}

public struct PlanTranscribeResponse: Decodable {
    public let transcript: String?
    public let plans: [PlanItem]?
    public let message: String?
    public let error: String?
}

public struct PlanSaveRequest: Encodable {
    public let plans: [PlanItem]
    public let confirmed: Bool
    public let keepConflicts: Bool

    public init(plans: [PlanItem], confirmed: Bool = true, keepConflicts: Bool = false) {
        self.plans = plans
        self.confirmed = confirmed
        self.keepConflicts = keepConflicts
    }
}

/// The save call answers 200 even when a plan is refused; each plan has its own result.
public struct PlanSaveResult: Decodable {
    public let id: String?
    public let status: String
    public let message: String?
}

public struct PlanSaveResponse: Decodable {
    public let results: [PlanSaveResult]?
    public let plans: [PlanItem]?
    public let message: String?
}

public struct AlarmSchedulePayload: Encodable {
    public let date: String
    public let time: String
    public let timeZone: String
    public let reminderOffsets: [Int]

    public init(date: String, time: String, timeZone: String, reminderOffsets: [Int]) {
        self.date = date
        self.time = time
        self.timeZone = timeZone
        self.reminderOffsets = reminderOffsets
    }
}

public struct AlarmMutationRequest: Encodable {
    public let action: String
    public let id: String?
    public let title: String?
    public let schedule: AlarmSchedulePayload?

    public init(action: String, id: String? = nil, title: String? = nil, schedule: AlarmSchedulePayload? = nil) {
        self.action = action
        self.id = id
        self.title = title
        self.schedule = schedule
    }
}

public struct AlarmMutationResponse: Decodable {
    public let plans: [PlanItem]?
}

public struct PlanListResponse: Decodable {
    public let plans: [PlanItem]?
    public let events: [PlanItem]?
    public let tasks: [PlanItem]?
    public let message: String?
    public let error: String?
}

public struct CalendarQueryResponse: Decodable {
    public let events: [PlanItem]?
    public let message: String?
    public let error: String?
}

public struct CompletePlanRequest: Encodable {
    public let id: String
    public let completed: Bool

    public init(id: String, completed: Bool) {
        self.id = id
        self.completed = completed
    }
}

public struct CompletePlanResponse: Decodable {
    public let plan: PlanItem?
    public let success: Bool?
    public let message: String?
    public let error: String?
}

public struct GoogleSyncSchedule: Encodable {
    public let date: String?
    public let time: String?
    public let durationMinutes: Int?
    public let reminderMinutes: Int?
    public let reminderOffsets: [Int]?
    public let timeZone: String?

    public init(
        date: String? = nil,
        time: String? = nil,
        durationMinutes: Int? = nil,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        timeZone: String? = nil
    ) {
        self.date = date
        self.time = time
        self.durationMinutes = durationMinutes
        self.reminderMinutes = reminderMinutes
        self.reminderOffsets = reminderOffsets
        self.timeZone = timeZone
    }
}

public struct GoogleSyncRequest: Encodable {
    public let id: String
    public let confirmed: Bool
    public let schedule: GoogleSyncSchedule?
    public let keepConflicts: Bool

    public init(id: String, confirmed: Bool = true, schedule: GoogleSyncSchedule? = nil, keepConflicts: Bool = false) {
        self.id = id
        self.confirmed = confirmed
        self.schedule = schedule
        self.keepConflicts = keepConflicts
    }
}

public struct GoogleSyncResponse: Decodable {
    public let plan: PlanItem?
    public let googleEventId: String?
    public let message: String?
    public let error: String?
}

public enum PlanAPI {
    public static func getPlans(client: APIClient) async throws -> [PlanItem] {
        let resp: PlanListResponse = try await client.get(path: "/api/plans")
        if let plans = resp.plans { return plans }
        var combined: [PlanItem] = []
        if let ev = resp.events { combined.append(contentsOf: ev) }
        if let tk = resp.tasks { combined.append(contentsOf: tk) }
        return combined
    }

    public static func getCalendarDate(client: APIClient, date: String, timeZone: String) async throws -> [PlanItem] {
        let resp: CalendarQueryResponse = try await client.get(path: "/api/calendar", query: ["date": date, "timeZone": timeZone])
        return resp.events ?? []
    }

    public static func getCalendarRange(client: APIClient, start: String, end: String, timeZone: String) async throws -> [PlanItem] {
        let resp: CalendarQueryResponse = try await client.get(path: "/api/calendar", query: ["start": start, "end": end, "timeZone": timeZone])
        return resp.events ?? []
    }

    public static func getUpcoming(client: APIClient, timeZone: String) async throws -> [PlanItem] {
        let resp: CalendarQueryResponse = try await client.get(path: "/api/calendar", query: ["view": "upcoming", "timeZone": timeZone])
        return resp.events ?? []
    }

    public static func parse(client: APIClient, text: String, timeZone: String) async throws -> [PlanItem] {
        let body = PlanParseRequest(text: text, timeZone: timeZone)
        let resp: PlanParseResponse = try await client.post(path: "/api/parse", body: body)
        return resp.plans ?? []
    }

    public static func transcribe(client: APIClient, audioBase64: String, mimeType: String, timeZone: String, intent: String = "plans") async throws -> PlanTranscribeResponse {
        let body = PlanTranscribeRequest(audioBase64: audioBase64, mimeType: mimeType, timeZone: timeZone, intent: intent)
        return try await client.post(path: "/api/transcribe", body: body)
    }

    /// The exact text the server sends for a plan that overlaps another one.
    public static let conflictMessage = "Обнаружено пересечение"

    public static func savePlans(client: APIClient, plans: [PlanItem], confirmed: Bool = true, keepConflicts: Bool = false) async throws -> PlanSaveResponse {
        let body = PlanSaveRequest(plans: plans, confirmed: confirmed, keepConflicts: keepConflicts)
        return try await client.post(path: "/api/plans/save", body: body)
    }

    public static func mutateAlarm(client: APIClient, request: AlarmMutationRequest) async throws -> [PlanItem] {
        let resp: AlarmMutationResponse = try await client.post(path: "/api/alarms", body: request)
        return resp.plans ?? []
    }

    public static func completePlan(client: APIClient, id: String, completed: Bool) async throws -> PlanItem? {
        let body = CompletePlanRequest(id: id, completed: completed)
        let resp: CompletePlanResponse = try await client.post(path: "/api/plans/complete", body: body)
        return resp.plan
    }

    public static func exportToGoogle(client: APIClient, plan: PlanItem, keepConflicts: Bool = false) async throws -> PlanItem? {
        let sched = GoogleSyncSchedule(
            date: plan.date,
            time: plan.time,
            durationMinutes: plan.durationMinutes,
            reminderMinutes: plan.reminderMinutes,
            reminderOffsets: plan.reminderOffsets,
            timeZone: plan.timeZone
        )
        let body = GoogleSyncRequest(id: plan.id, confirmed: true, schedule: sched, keepConflicts: keepConflicts)
        let resp: GoogleSyncResponse = try await client.post(path: "/api/plans/google", body: body)
        return resp.plan
    }
}
