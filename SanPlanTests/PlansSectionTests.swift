import XCTest
@testable import SanPlan

final class PlansSectionTests: XCTestCase {
    private func fresh() -> UserDefaults { UserDefaults(suiteName: "plans-section-\(UUID().uuidString)")! }

    func testDefaultsToPlans() {
        XCTAssertEqual(PlansSection.stored(fresh()), .plans)
    }

    func testRemembersChoicePerDevice() {
        let d = fresh()
        PlansSection.habits.store(d)
        XCTAssertEqual(PlansSection.stored(d), .habits)
        PlansSection.goals.store(d)
        XCTAssertEqual(PlansSection.stored(d), .goals)
    }

    func testUnknownStoredValueFallsBackToPlans() {
        let d = fresh()
        d.set("что-то другое", forKey: PlansSection.storageKey)
        XCTAssertEqual(PlansSection.stored(d), .plans)
    }

    func testOrderIsPlansHabitsGoals() {
        XCTAssertEqual(PlansSection.allCases.map(\.rawValue), ["Планы", "Привычки", "Цели"])
    }
}
