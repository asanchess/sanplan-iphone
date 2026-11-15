import XCTest
@testable import SanPlan

/// «Все» shows the nearest plans first; «Готово» lists finished ones newest first; a saved plan reopened for editing keeps its id.
final class PlanListOrderTests: XCTestCase {
    private let tz = "Asia/Qyzylorda"
    private var now: Int64 { PlanDomain.zonedEpoch(dateStr: "2026-11-16", timeStr: "12:00", timeZone: tz)! }

    private func task(_ id: String, _ date: String?, done: Bool = false) -> PlanItem {
        PlanItem(id: id, kind: "task", title: id, date: date, time: date == nil ? nil : "10:00", timeZone: tz, completed: done, savedAt: "2026-11-01T00:00:00Z")
    }

    func testUpcomingPutsTodayAndFutureBeforeOldOverdue() {
        let items = PlanDomain.getUpcomingItems(
            plans: [task("old", "2026-10-01"), task("later", "2026-11-20"), task("recent", "2026-11-14"), task("today", "2026-11-16"), task("nodate", nil)],
            nowEpochMs: now, timeZone: tz)
        XCTAssertEqual(items.map(\.item.id), ["today", "later", "recent", "old", "nodate"])
    }

    func testCompletedListsDoneTasksAndPastEventsNewestFirst() {
        let pastEvent = PlanItem(id: "ev", kind: "event", title: "ev", date: "2026-11-15", time: "09:00", durationMinutes: 60, timeZone: tz, savedAt: "x")
        let futureEvent = PlanItem(id: "fut", kind: "event", title: "fut", date: "2026-11-18", time: "09:00", durationMinutes: 60, timeZone: tz, savedAt: "x")
        let items = PlanDomain.getCompletedItems(
            plans: [task("a", "2026-11-10", done: true), task("open", "2026-11-12"), pastEvent, futureEvent, task("b", "2026-11-16", done: true)],
            nowEpochMs: now, timeZone: tz)
        XCTAssertEqual(items.map(\.item.id), ["b", "ev", "a"])
    }

    @MainActor
    func testEditingSavedPlanKeepsItsIdAfterReload() {
        UserDefaults.standard.removeObject(forKey: "arna.planner.draft.json")
        let store = PlanStore(client: APIClient(baseURL: URL(string: "https://example.invalid")!, session: .shared), onUnauthorized: {})
        let saved = task("p1", "2026-11-20")
        store.plans = [saved]
        store.beginEdit(saved)
        var edited = store.draftPlans[0]
        edited.title = "Новое название"
        store.updateDraft(edited)
        store.plans = [saved] // a reload must not turn the edit into a separate new plan
        XCTAssertEqual(store.draftPlans.map(\.id), ["p1"])
        XCTAssertEqual(store.draftPlans.first?.title, "Новое название")
    }
}
