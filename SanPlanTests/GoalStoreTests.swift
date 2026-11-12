import XCTest
@testable import SanPlan

@MainActor
final class GoalStoreTests: XCTestCase {
    private func makeStore() -> GoalStore {
        GoalStore(defaults: UserDefaults(suiteName: "goal-tests-\(UUID().uuidString)")!)
    }

    private func goal(_ id: String) -> Goal {
        Goal(id: id, title: "Цель", sphereId: "health", createdDay: "2026-11-01",
             kind: .milestones([GoalMilestone(id: "m1", title: "Один"), GoalMilestone(id: "m2", title: "Два")]))
    }

    func testNoOwnerStoresNothingAndAccountsAreSeparate() {
        let store = makeStore()
        store.add(goal("goal-0001"))
        XCTAssertTrue(store.goals.isEmpty)

        store.switchOwner(to: .account("a@example.com"))
        store.add(goal("goal-0001"))
        store.switchOwner(to: .account("b@example.com"))
        XCTAssertTrue(store.goals.isEmpty)
        store.switchOwner(to: .none)
        store.switchOwner(to: .account(" A@example.com "))
        XCTAssertEqual(store.goals.map(\.id), ["goal-0001"])
    }

    func testMilestonesProgressAndWeekGoal() {
        let store = makeStore()
        store.switchOwner(to: .device)
        store.add(goal("goal-0001"))
        store.setMilestone(goalId: "goal-0001", milestoneId: "m1", done: true)
        let today = "2026-11-12"
        XCTAssertEqual(store.progress(for: store.goals[0], today: today).fraction, 0.5)

        XCTAssertNil(store.weekGoal(today: today))
        store.setWeekGoal("goal-0001", today: today)
        XCTAssertEqual(store.weekGoal(today: today)?.goal.id, "goal-0001")
        XCTAssertNil(store.weekGoal(today: "2026-11-16"), "на следующей неделе выбор сбрасывается")
        store.archive(id: "goal-0001")
        XCTAssertNil(store.weekGoal(today: today))
        store.delete(id: "goal-0001")
        XCTAssertNil(store.weekPick)
    }

    func testSpheresEditableAndNeverEmpty() {
        let store = makeStore()
        store.switchOwner(to: .device)
        store.setSpheres([GoalSphere(id: "x", title: "Семья"), GoalSphere(id: "y", title: "  ")])
        XCTAssertEqual(store.spheres.map(\.id), ["x"])
        XCTAssertEqual(store.sphereTitle("x"), "Семья")
        store.setSpheres([])
        XCTAssertEqual(store.spheres, GoalSphere.defaults)
    }

    func testCloudRecordsRoundTrip() {
        let records = GoalCloud.records(goals: [goal("goal-0001"), goal("g1")], spheres: GoalSphere.defaults, weekGoal: nil)
        XCTAssertEqual(Set(records.map(\.id)), ["g-goal-0001", "g-meta-state"])
        for r in records {
            let data = try? JSONEncoder().encode(r.payload)
            XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(GoalPayload.self, from: $0) }, r.payload)
        }
    }
}
