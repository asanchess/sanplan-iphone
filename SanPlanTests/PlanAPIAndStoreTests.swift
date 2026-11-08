import XCTest
@testable import SanPlan

// MARK: - Network stub

/// Answers by "METHOD /path" and records every request with its body. Never reaches the network.
final class PlanStubURLProtocol: URLProtocol {
    enum Reply {
        case json(Int, String)
        case data(Int, Data)
        case failure(URLError.Code)
    }

    struct Recorded {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?

        var path: String { url.path }

        var query: [String: String] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var result: [String: String] = [:]
            for item in items { result[item.name] = item.value ?? "" }
            return result
        }

        var json: [String: Any] {
            guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
            return object
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Reply] = [:]
    nonisolated(unsafe) private static var log: [Recorded] = []

    static func reset() {
        lock.withLock {
            routes = [:]
            log = []
        }
    }

    static func stub(_ method: String, _ path: String, _ reply: Reply) {
        lock.withLock { routes["\(method) \(path)"] = reply }
    }

    static var requests: [Recorded] {
        lock.withLock { log }
    }

    static func calls(to path: String) -> [Recorded] {
        requests.filter { $0.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        guard let url = request.url else { return }
        let body = request.httpBody ?? Self.readAll(request.httpBodyStream)
        let headers = request.allHTTPHeaderFields ?? [:]
        let reply: Reply = Self.lock.withLock {
            Self.log.append(Recorded(method: method, url: url, headers: headers, body: body))
            return Self.routes["\(method) \(url.path)"] ?? .json(404, #"{"message":"Нет заглушки"}"#)
        }
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .json(let status, let text):
            respond(status: status, data: Data(text.utf8), url: url)
        case .data(let status, let data):
            respond(status: status, data: data, url: url)
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, data: Data, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands a protocol the body as a stream, not as httpBody.
    private static func readAll(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private func makeStubClient(base: String = "https://example.test") -> APIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PlanStubURLProtocol.self]
    return APIClient(baseURL: URL(string: base)!, session: URLSession(configuration: configuration))
}

private let planJSON = #"{"id":"p1","kind":"event","title":"Встреча","date":"2026-12-01","time":"10:00","durationMinutes":60,"reminderOffsets":[60]}"#

// MARK: - PlanAPI and APIClient

final class PlanAPITests: XCTestCase {

    override func setUp() {
        super.setUp()
        PlanStubURLProtocol.reset()
    }

    override func tearDown() {
        PlanStubURLProtocol.reset()
        super.tearDown()
    }

    private func apiError(_ work: () async throws -> Void) async -> APIError? {
        do {
            try await work()
            return nil
        } catch let error as APIError {
            return error
        } catch {
            XCTFail("Unexpected error: \(error)")
            return nil
        }
    }

    func testGetPlansPrefersThePlansList() async throws {
        PlanStubURLProtocol.stub("GET", "/api/plans", .json(200, #"{"plans":[\#(planJSON)],"events":[{"id":"e1"}]}"#))
        let plans = try await PlanAPI.getPlans(client: makeStubClient())
        XCTAssertEqual(plans.map(\.id), ["p1"])
        let request = try XCTUnwrap(PlanStubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["Accept"], "application/json")
        XCTAssertNil(request.body)
    }

    func testGetPlansFallsBackToEventsThenTasks() async throws {
        PlanStubURLProtocol.stub("GET", "/api/plans", .json(200, #"{"events":[{"id":"e1"}],"tasks":[{"id":"t1"},{"id":"t2"}]}"#))
        let combined = try await PlanAPI.getPlans(client: makeStubClient())
        XCTAssertEqual(combined.map(\.id), ["e1", "t1", "t2"])

        PlanStubURLProtocol.stub("GET", "/api/plans", .json(200, "{}"))
        let none = try await PlanAPI.getPlans(client: makeStubClient())
        XCTAssertTrue(none.isEmpty)
    }

    func testCalendarCallsSendTheirQueries() async throws {
        PlanStubURLProtocol.stub("GET", "/api/calendar", .json(200, #"{"events":[{"id":"g1"}]}"#))
        let client = makeStubClient()
        let range = try await PlanAPI.getCalendarRange(client: client, start: "2026-12-01", end: "2026-12-15", timeZone: "Asia/Qyzylorda")
        _ = try await PlanAPI.getUpcoming(client: client, timeZone: "Asia/Almaty")
        _ = try await PlanAPI.getCalendarDate(client: client, date: "2026-12-03", timeZone: "UTC")
        XCTAssertEqual(range.map(\.id), ["g1"])

        let queries = PlanStubURLProtocol.calls(to: "/api/calendar").map(\.query)
        XCTAssertEqual(queries, [
            ["start": "2026-12-01", "end": "2026-12-15", "timeZone": "Asia/Qyzylorda"],
            ["view": "upcoming", "timeZone": "Asia/Almaty"],
            ["date": "2026-12-03", "timeZone": "UTC"],
        ])

        PlanStubURLProtocol.stub("GET", "/api/calendar", .json(200, #"{"message":"нет событий"}"#))
        let empty = try await PlanAPI.getUpcoming(client: client, timeZone: "UTC")
        XCTAssertTrue(empty.isEmpty)
    }

    func testParsePostsTextAndTimeZone() async throws {
        PlanStubURLProtocol.stub("POST", "/api/parse", .json(200, #"{"message":"Планы не найдены"}"#))
        let plans = try await PlanAPI.parse(client: makeStubClient(), text: "завтра в 10 встреча", timeZone: "Asia/Qyzylorda")
        XCTAssertTrue(plans.isEmpty)

        let request = try XCTUnwrap(PlanStubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertEqual(request.json["text"] as? String, "завтра в 10 встреча")
        XCTAssertEqual(request.json["timeZone"] as? String, "Asia/Qyzylorda")
    }

    func testTranscribeSendsAudioWithDefaultIntent() async throws {
        PlanStubURLProtocol.stub("POST", "/api/transcribe", .json(200, #"{"transcript":"купить хлеб"}"#))
        let response = try await PlanAPI.transcribe(client: makeStubClient(), audioBase64: "AQID", mimeType: "audio/mp4", timeZone: "UTC")
        XCTAssertEqual(response.transcript, "купить хлеб")
        XCTAssertNil(response.plans)

        let body = try XCTUnwrap(PlanStubURLProtocol.requests.first).json
        XCTAssertEqual(body["intent"] as? String, "plans")
        XCTAssertEqual(body["audioBase64"] as? String, "AQID")
        XCTAssertEqual(body["mimeType"] as? String, "audio/mp4")
    }

    func testSavePlansSendsFlagsAndDecodesPerPlanResults() async throws {
        PlanStubURLProtocol.stub("POST", "/api/plans/save", .json(200, """
        {"results":[{"id":"a","status":"saved"},{"status":"refused","message":"Обнаружено пересечение"}]}
        """))
        let plan = PlanItem(id: "a", title: "Встреча", date: "2026-12-01", time: "10:00")
        let response = try await PlanAPI.savePlans(client: makeStubClient(), plans: [plan], keepConflicts: true)

        let results = try XCTUnwrap(response.results)
        XCTAssertEqual(results.map(\.status), ["saved", "refused"])
        XCTAssertNil(results[1].id)
        XCTAssertEqual(results[1].message, PlanAPI.conflictMessage)
        XCTAssertNil(response.plans)

        let body = try XCTUnwrap(PlanStubURLProtocol.requests.first).json
        XCTAssertEqual(body["confirmed"] as? Bool, true)
        XCTAssertEqual(body["keepConflicts"] as? Bool, true)
        let sent = try XCTUnwrap(body["plans"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0]["id"] as? String, "a")
        XCTAssertEqual(sent[0]["title"] as? String, "Встреча")
    }

    func testExportToGoogleBuildsTheScheduleFromThePlan() async throws {
        PlanStubURLProtocol.stub("POST", "/api/plans/google", .json(200, #"{"plan":{"id":"p9","title":"Звонок","googleEventId":"g-1"}}"#))
        let plan = PlanItem(
            id: "p9", title: "Звонок", date: "2026-12-02", time: "09:30",
            durationMinutes: 30, reminderMinutes: 15, reminderOffsets: [15, 0], timeZone: "Asia/Almaty"
        )
        let updated = try await PlanAPI.exportToGoogle(client: makeStubClient(), plan: plan)
        XCTAssertEqual(updated?.googleEventId, "g-1")

        let body = try XCTUnwrap(PlanStubURLProtocol.requests.first).json
        XCTAssertEqual(body["id"] as? String, "p9")
        XCTAssertEqual(body["confirmed"] as? Bool, true)
        XCTAssertEqual(body["keepConflicts"] as? Bool, false)
        let schedule = try XCTUnwrap(body["schedule"] as? [String: Any])
        XCTAssertEqual(schedule["date"] as? String, "2026-12-02")
        XCTAssertEqual(schedule["time"] as? String, "09:30")
        XCTAssertEqual(schedule["durationMinutes"] as? Int, 30)
        XCTAssertEqual(schedule["reminderMinutes"] as? Int, 15)
        XCTAssertEqual(schedule["reminderOffsets"] as? [Int], [15, 0])
        XCTAssertEqual(schedule["timeZone"] as? String, "Asia/Almaty")
    }

    func testCompleteAndAlarmBodiesOmitMissingFields() async throws {
        PlanStubURLProtocol.stub("POST", "/api/plans/complete", .json(200, #"{"success":true}"#))
        PlanStubURLProtocol.stub("POST", "/api/alarms", .json(200, "{}"))
        let client = makeStubClient()

        let completed = try await PlanAPI.completePlan(client: client, id: "t1", completed: false)
        XCTAssertNil(completed)
        let completeBody = try XCTUnwrap(PlanStubURLProtocol.calls(to: "/api/plans/complete").first).json
        XCTAssertEqual(completeBody["id"] as? String, "t1")
        XCTAssertEqual(completeBody["completed"] as? Bool, false)

        let plans = try await PlanAPI.mutateAlarm(client: client, request: AlarmMutationRequest(action: "delete", id: "p1"))
        XCTAssertTrue(plans.isEmpty)
        let schedule = AlarmSchedulePayload(date: "2026-12-05", time: "07:00", timeZone: "UTC", reminderOffsets: [0])
        _ = try await PlanAPI.mutateAlarm(client: client, request: AlarmMutationRequest(action: "create", title: "Подъём", schedule: schedule))

        let alarmBodies = PlanStubURLProtocol.calls(to: "/api/alarms").map(\.json)
        XCTAssertEqual(Set(alarmBodies[0].keys), ["action", "id"])
        XCTAssertEqual(Set(alarmBodies[1].keys), ["action", "title", "schedule"])
        let sentSchedule = try XCTUnwrap(alarmBodies[1]["schedule"] as? [String: Any])
        XCTAssertEqual(sentSchedule["reminderOffsets"] as? [Int], [0])
    }

    func testClientJoinsBasePathAndKeepsPortInOrigin() async throws {
        PlanStubURLProtocol.stub("GET", "/base/api/plans", .json(200, "{}"))
        let client = makeStubClient(base: "https://example.test:8443/base")
        _ = try await PlanAPI.getPlans(client: client)
        let _: PlanListResponse = try await client.get(path: "api/plans")

        let requests = PlanStubURLProtocol.requests
        XCTAssertEqual(requests.map(\.path), ["/base/api/plans", "/base/api/plans"], "A leading slash is optional")
        XCTAssertEqual(requests.first?.headers["Origin"], "https://example.test:8443")
    }

    func testUndecodableSuccessIsAnInvalidResponse() async {
        PlanStubURLProtocol.stub("GET", "/api/status", .json(200, "[1,2,3]"))
        let client = makeStubClient()
        let error = await apiError { let _: StatusResponse = try await client.get(path: "/api/status") }
        XCTAssertEqual(error, .invalidResponse)
    }

    func testServerErrorWithoutMessageUsesStatusText() async {
        let client = makeStubClient()
        PlanStubURLProtocol.stub("GET", "/api/plans", .data(503, Data()))
        let fallback = HTTPURLResponse.localizedString(forStatusCode: 503)
        var error = await apiError { _ = try await PlanAPI.getPlans(client: client) }
        XCTAssertEqual(error, .server(status: 503, message: fallback))

        PlanStubURLProtocol.stub("GET", "/api/plans", .json(503, #"{"message":""}"#))
        error = await apiError { _ = try await PlanAPI.getPlans(client: client) }
        XCTAssertEqual(error, .server(status: 503, message: fallback), "An empty message is no message")
    }

    func testEmptyBodyIsFineForEmptyResponseAndPostWithoutBody() async throws {
        PlanStubURLProtocol.stub("POST", "/api/logout", .data(200, Data()))
        let _: EmptyResponse = try await makeStubClient().post(path: "/api/logout")
        let request = try XCTUnwrap(PlanStubURLProtocol.requests.first)
        XCTAssertNil(request.headers["Content-Type"])
        XCTAssertTrue(request.body?.isEmpty ?? true)
    }

    func testOversizedResponseAndTransportFailure() async {
        let client = makeStubClient()
        PlanStubURLProtocol.stub("GET", "/api/plans", .data(200, Data(repeating: 0x20, count: 5 * 1024 * 1024 + 1)))
        var error = await apiError { _ = try await PlanAPI.getPlans(client: client) }
        XCTAssertEqual(error, .responseTooLarge)

        PlanStubURLProtocol.stub("GET", "/api/plans", .failure(.notConnectedToInternet))
        error = await apiError { _ = try await PlanAPI.getPlans(client: client) }
        guard case .transport(_)? = error else {
            return XCTFail("Expected a transport error, got \(String(describing: error))")
        }
    }
}

// MARK: - PlanStore

@MainActor
final class PlanStoreBehaviourTests: XCTestCase {
    private static let draftKey = "arna.planner.draft.json"

    private final class Probe {
        var unauthorized = 0
        var changes: [[PlanItem]] = []
    }

    private func makeStore(_ probe: Probe = Probe()) -> PlanStore {
        PlanStubURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: Self.draftKey)
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: "arna.planner.draft.json")
            PlanStubURLProtocol.reset()
        }
        return PlanStore(
            client: makeStubClient(),
            onUnauthorized: { probe.unauthorized += 1 },
            onPlansChanged: { probe.changes.append($0) }
        )
    }

    private func event(_ id: String, _ title: String = "Встреча") -> PlanItem {
        PlanItem(id: id, kind: "event", title: title, date: "2026-12-01", time: "10:00", durationMinutes: 60, reminderOffsets: [60], timeZone: "Asia/Qyzylorda")
    }

    func testReloadLoadsPlansAndCalendar() async {
        let probe = Probe()
        let store = makeStore(probe)
        PlanStubURLProtocol.stub("GET", "/api/plans", .json(200, #"{"plans":[\#(planJSON)]}"#))
        PlanStubURLProtocol.stub("GET", "/api/calendar", .json(200, #"{"events":[{"id":"g1","title":"Google","date":"2026-12-01","time":"12:00"}]}"#))

        await store.reload()

        XCTAssertEqual(store.plans.map(\.id), ["p1"])
        XCTAssertEqual(probe.changes.map { $0.map(\.id) }, [["p1"]])
        XCTAssertEqual(store.remoteEvents.map(\.id), ["g1"])
        XCTAssertEqual(store.upcomingEvents.map(\.id), ["g1"])
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)

        let rangeQuery = PlanStubURLProtocol.calls(to: "/api/calendar").map(\.query).first { $0["start"] != nil }
        XCTAssertEqual(rangeQuery?["start"], PlanDomain.addDays(dateStr: store.selectedDate, days: -7))
        XCTAssertEqual(rangeQuery?["end"], PlanDomain.addDays(dateStr: store.selectedDate, days: 14))
    }

    func testEnsureRangeLoadedOnlyFetchesOutsideTheLoadedWindow() async {
        let store = makeStore()
        PlanStubURLProtocol.stub("GET", "/api/plans", .json(200, #"{"plans":[]}"#))
        PlanStubURLProtocol.stub("GET", "/api/calendar", .json(200, #"{"events":[]}"#))
        await store.reload()
        let afterReload = PlanStubURLProtocol.calls(to: "/api/calendar").count
        XCTAssertEqual(afterReload, 2)

        store.selectedDate = PlanDomain.addDays(dateStr: store.selectedDate, days: 3)
        await store.ensureRangeLoaded()
        XCTAssertEqual(PlanStubURLProtocol.calls(to: "/api/calendar").count, afterReload, "Inside the window: no request")

        store.selectedDate = PlanDomain.addDays(dateStr: store.selectedDate, days: 30)
        await store.ensureRangeLoaded()
        XCTAssertEqual(PlanStubURLProtocol.calls(to: "/api/calendar").count, afterReload + 2)
    }

    func testReloadUnauthorizedSignsOutWithoutTouchingCalendar() async {
        let probe = Probe()
        let store = makeStore(probe)
        store.plans = [event("old")]
        PlanStubURLProtocol.stub("GET", "/api/plans", .json(401, "{}"))

        await store.reload()

        XCTAssertEqual(probe.unauthorized, 1)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.plans.map(\.id), ["old"])
        XCTAssertTrue(PlanStubURLProtocol.calls(to: "/api/calendar").isEmpty)
        XCTAssertFalse(store.isLoading)
    }

    func testCalendarFailureKeepsSavedPlans() async {
        let store = makeStore()
        PlanStubURLProtocol.stub("GET", "/api/plans", .json(200, #"{"plans":[\#(planJSON)]}"#))
        PlanStubURLProtocol.stub("GET", "/api/calendar", .json(500, #"{"message":"Google недоступен"}"#))

        await store.reload()

        XCTAssertEqual(store.plans.map(\.id), ["p1"])
        XCTAssertEqual(store.errorMessage, "Google Календарь сейчас недоступен. Показаны только планы ARNA.")
        XCTAssertTrue(store.remoteEvents.isEmpty)
    }

    func testSaveDraftsRejectsInvalidDraftLocally() async {
        let store = makeStore()
        store.setDraftPlans([event("a"), event("b", "   ")])

        let saved = await store.saveDrafts()

        XCTAssertFalse(saved)
        XCTAssertTrue(store.errorMessage?.hasPrefix("«") == true)
        XCTAssertEqual(store.draftPlans.count, 2)
        XCTAssertTrue(PlanStubURLProtocol.requests.isEmpty, "Nothing invalid is sent")
    }

    func testSaveDraftsKeepsRefusedDraftAndMarksConflict() async throws {
        let probe = Probe()
        let store = makeStore(probe)
        store.setDraftPlans([event("a"), event("b", "Тренировка")])
        PlanStubURLProtocol.stub("POST", "/api/plans/save", .json(200, """
        {"results":[{"id":"a","status":"saved"},{"id":"b","status":"refused","message":"Обнаружено пересечение"}],"plans":[\(planJSON)]}
        """))
        PlanStubURLProtocol.stub("GET", "/api/calendar", .json(200, #"{"events":[]}"#))

        let saved = await store.saveDrafts()

        XCTAssertFalse(saved)
        XCTAssertEqual(store.draftPlans.map(\.id), ["b"])
        XCTAssertEqual(store.editingPlanId, "b")
        XCTAssertEqual(store.conflictedDraftIds, ["b"])
        XCTAssertEqual(store.errorMessage, PlanAPI.conflictMessage)
        XCTAssertEqual(store.plans.map(\.id), ["p1"])
        XCTAssertEqual(probe.changes.count, 1)
        XCTAssertFalse(store.isLoading)

        let body = try XCTUnwrap(PlanStubURLProtocol.calls(to: "/api/plans/save").first).json
        XCTAssertEqual(body["keepConflicts"] as? Bool, false)
        XCTAssertEqual((body["plans"] as? [[String: Any]])?.count, 2)
    }

    func testSaveDraftsWithEverythingSavedClearsDrafts() async {
        let store = makeStore()
        let emptySave = await store.saveDrafts()
        XCTAssertTrue(emptySave, "No drafts is a successful no-op")
        XCTAssertTrue(PlanStubURLProtocol.requests.isEmpty)

        store.setDraftPlans([event("a")])
        store.conflictedDraftIds = ["a"]
        PlanStubURLProtocol.stub("POST", "/api/plans/save", .json(200, #"{"results":[{"id":"a","status":"saved"}]}"#))
        PlanStubURLProtocol.stub("GET", "/api/calendar", .json(200, #"{"events":[]}"#))

        let saved = await store.saveDrafts(keepConflicts: true)

        XCTAssertTrue(saved)
        XCTAssertTrue(store.draftPlans.isEmpty)
        XCTAssertNil(store.editingPlanId)
        XCTAssertTrue(store.conflictedDraftIds.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testParseTextIgnoresBlankInputAndReportsNothingFound() async {
        let store = makeStore()
        await store.parseText("   \n ")
        XCTAssertTrue(PlanStubURLProtocol.requests.isEmpty)

        PlanStubURLProtocol.stub("POST", "/api/parse", .json(200, #"{"plans":[]}"#))
        await store.parseText("  что-то непонятное  ")

        XCTAssertEqual(store.errorMessage, "Не удалось распознать планы в тексте.")
        XCTAssertFalse(store.isParsing)
        let body = PlanStubURLProtocol.calls(to: "/api/parse").first?.json
        XCTAssertEqual(body?["text"] as? String, "что-то непонятное", "The text is trimmed before sending")
        XCTAssertEqual(body?["timeZone"] as? String, store.timeZone)
    }

    func testParsedPlansBecomeDraftsWithDefaultReminders() async throws {
        let store = makeStore()
        store.conflictedDraftIds = ["stale"]
        PlanStubURLProtocol.stub("POST", "/api/parse", .json(200, """
        {"plans":[{"id":"n1","kind":"event","title":"Встреча","date":"2026-12-01","time":"10:00","durationMinutes":60}]}
        """))

        await store.parseText("завтра в 10 встреча")

        let draft = try XCTUnwrap(store.draftPlans.first)
        XCTAssertEqual(draft.id, "n1")
        XCTAssertEqual(draft.reminderOffsets, PlanDomain.defaultReminderOffsets)
        XCTAssertEqual(draft.reminderMinutes, 1440)
        XCTAssertEqual(store.editingPlanId, "n1")
        XCTAssertTrue(store.conflictedDraftIds.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testTranscribeRejectsLongAudioAndEmptyResult() async {
        let store = makeStore()
        await store.transcribe(audio: Data(count: PlanStore.maxAudioBytes + 1), mimeType: "audio/mp4")
        XCTAssertTrue(store.errorMessage?.contains("слишком длинная") == true)
        XCTAssertTrue(PlanStubURLProtocol.requests.isEmpty)
        XCTAssertFalse(store.isParsing)

        PlanStubURLProtocol.stub("POST", "/api/transcribe", .json(200, #"{"transcript":"","plans":[]}"#))
        await store.transcribe(audio: Data([1, 2, 3]), mimeType: "audio/mp4")
        XCTAssertEqual(store.errorMessage, "Не удалось разобрать запись. Попробуй ещё раз.")
        XCTAssertTrue(store.draftPlans.isEmpty)
    }

    func testTranscribedPlansBecomeDrafts() async throws {
        let store = makeStore()
        PlanStubURLProtocol.stub("POST", "/api/transcribe", .json(200, #"{"transcript":"встреча","plans":[\#(planJSON)]}"#))

        await store.transcribe(audio: Data([1, 2, 3]), mimeType: "audio/mp4")

        XCTAssertEqual(store.draftPlans.map(\.id), ["p1"])
        XCTAssertNil(store.errorMessage)
        let body = try XCTUnwrap(PlanStubURLProtocol.calls(to: "/api/transcribe").first).json
        XCTAssertEqual(body["audioBase64"] as? String, "AQID")
        XCTAssertEqual(body["mimeType"] as? String, "audio/mp4")
        XCTAssertEqual(body["intent"] as? String, "plans")
    }

    func testToggleCompletionUsesServerCopy() async {
        let probe = Probe()
        let store = makeStore(probe)
        store.plans = [PlanItem(id: "t1", kind: "task", title: "Купить", reminderMinutes: -1, reminderOffsets: nil)]
        PlanStubURLProtocol.stub("POST", "/api/plans/complete", .json(200, #"{"plan":{"id":"t1","kind":"task","title":"Купить хлеб","completed":true}}"#))

        await store.toggleTaskCompletion(id: "t1", completed: true)

        XCTAssertEqual(store.plans.first?.completed, true)
        XCTAssertEqual(store.plans.first?.title, "Купить хлеб")
        XCTAssertTrue(store.pendingTaskIds.isEmpty)
        XCTAssertEqual(probe.changes.count, 1)
    }

    func testToggleCompletionRollsBackOnFailure() async {
        let probe = Probe()
        let store = makeStore(probe)
        store.plans = [PlanItem(id: "t1", kind: "task", title: "Купить", reminderMinutes: -1, reminderOffsets: nil)]
        PlanStubURLProtocol.stub("POST", "/api/plans/complete", .json(500, #"{"message":"Сервер занят"}"#))

        await store.toggleTaskCompletion(id: "t1", completed: true)

        XCTAssertEqual(store.plans.first?.completed, false)
        XCTAssertEqual(store.errorMessage, "Сервер занят")
        XCTAssertTrue(store.pendingTaskIds.isEmpty)
        XCTAssertTrue(probe.changes.isEmpty, "Alarms are not resynced for a change that did not happen")
    }

    func testMutateAlarmReturnsRefusalAndHandlesSignOut() async {
        let probe = Probe()
        let store = makeStore(probe)
        store.plans = [event("p0")]
        let request = AlarmMutationRequest(action: "delete", id: "p0")

        PlanStubURLProtocol.stub("POST", "/api/alarms", .json(400, #"{"message":"Неверное время"}"#))
        let refusal = await store.mutateAlarm(request)
        XCTAssertEqual(refusal, "Неверное время")
        XCTAssertEqual(store.plans.map(\.id), ["p0"])

        PlanStubURLProtocol.stub("POST", "/api/alarms", .json(401, "{}"))
        let signedOut = await store.mutateAlarm(request)
        XCTAssertNil(signedOut)
        XCTAssertEqual(probe.unauthorized, 1)

        PlanStubURLProtocol.stub("POST", "/api/alarms", .json(200, #"{"plans":[\#(planJSON)]}"#))
        let success = await store.mutateAlarm(request)
        XCTAssertNil(success)
        XCTAssertEqual(store.plans.map(\.id), ["p1"])
        XCTAssertEqual(probe.changes.last?.map(\.id), ["p1"])
    }

    func testDraftsSurviveRelaunchButNotSignOut() {
        let store = makeStore()
        store.setDraftPlans([event("a"), event("b")])

        let relaunched = PlanStore(client: makeStubClient(), onUnauthorized: {})
        XCTAssertEqual(relaunched.draftPlans.map(\.id), ["a", "b"])
        XCTAssertEqual(relaunched.editingPlanId, "a")

        store.plans = [event("p")]
        store.errorMessage = "Ошибка"
        store.resetForSignOut()
        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertTrue(store.draftPlans.isEmpty)
        XCTAssertNil(store.editingPlanId)
        XCTAssertNil(store.errorMessage)

        let afterSignOut = PlanStore(client: makeStubClient(), onUnauthorized: {})
        XCTAssertTrue(afterSignOut.draftPlans.isEmpty, "The next account never sees the previous drafts")
    }

    func testRemoveDraftMovesEditingAndClearsConflict() {
        let store = makeStore()
        store.setDraftPlans([event("a"), event("b"), event("c")])
        store.conflictedDraftIds = ["a", "c"]

        store.removeDraft(id: "a")
        XCTAssertEqual(store.editingPlanId, "b")
        XCTAssertEqual(store.conflictedDraftIds, ["c"])

        store.removeDraft(id: "c")
        XCTAssertEqual(store.editingPlanId, "b", "Removing another draft keeps the one being edited")
        XCTAssertTrue(store.conflictedDraftIds.isEmpty)
        XCTAssertEqual(store.activeDraft?.id, "b")
    }

    func testSameContentComparesOnlyEditableFields() {
        let base = event("a")
        var annotated = base
        annotated.googleEventId = "g-1"
        annotated.sourceText = "из голосового ввода"
        XCTAssertTrue(PlanStore.sameContent(base, annotated), "Fields a person cannot edit are ignored")

        var twoOffsets = base
        twoOffsets.reminderOffsets = [60, 0]
        var swapped = base
        swapped.reminderOffsets = [0, 60]
        XCTAssertTrue(PlanStore.sameContent(twoOffsets, swapped), "Reminder order does not matter")

        var scalar = base
        scalar.reminderOffsets = nil
        scalar.reminderMinutes = 60
        XCTAssertTrue(PlanStore.sameContent(base, scalar), "A legacy scalar reminder equals the same single offset")

        var retitled = base
        retitled.title = "Другое"
        XCTAssertFalse(PlanStore.sameContent(base, retitled))
        var longer = base
        longer.durationMinutes = 90
        XCTAssertFalse(PlanStore.sameContent(base, longer))
    }
}
