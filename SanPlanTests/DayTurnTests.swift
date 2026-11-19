import XCTest
@testable import SanPlan

/// Midnight with the app open: screens on «сегодня» move to the new day, a day picked on purpose stays.
final class DayTurnTests: XCTestCase {
    func testTheDayOnTodayFollowsAndAPickedDayStays() {
        XCTAssertEqual(DayTurn.follow(selected: "2026-11-19", oldToday: "2026-11-19", newToday: "2026-11-20"), "2026-11-20")
        XCTAssertEqual(DayTurn.follow(selected: "2026-11-25", oldToday: "2026-11-19", newToday: "2026-11-20"), "2026-11-25")
        XCTAssertEqual(DayTurn.follow(selected: "2026-11-18", oldToday: "2026-11-19", newToday: "2026-11-20"), "2026-11-18")
    }

    func testTheMonthAndTheWeekdayFollowTheSameWay() {
        // The ledger on «this month» moves on the 1st; another month stays.
        XCTAssertEqual(DayTurn.follow(selected: "2026-11", oldToday: "2026-11", newToday: "2026-12"), "2026-12")
        XCTAssertEqual(DayTurn.follow(selected: "2026-10", oldToday: "2026-11", newToday: "2026-12"), "2026-10")
        // The program builder on today's weekday moves to tomorrow's; a weekday picked on purpose stays.
        XCTAssertEqual(DayTurn.follow(weekday: 4, oldToday: 4, newToday: 5), 5)
        XCTAssertEqual(DayTurn.follow(weekday: 1, oldToday: 4, newToday: 5), 1)
        XCTAssertEqual(DayTurn.follow(weekday: 7, oldToday: 7, newToday: 1), 1)
    }

    @MainActor
    func testPlansMoveOnlyWhenTheyShowedToday() {
        // Nothing answers here: the calendar reload after the turn fails quietly and keeps the day.
        let client = APIClient(baseURL: URL(string: "https://example.invalid")!, session: .shared)
        let store = PlanStore(client: client, onUnauthorized: {})
        store.selectedDate = "2026-11-19"
        store.dayTurned(from: "2026-11-19", to: "2026-11-20")
        XCTAssertEqual(store.selectedDate, "2026-11-20")

        store.selectedDate = "2026-11-23"
        store.dayTurned(from: "2026-11-20", to: "2026-11-21")
        XCTAssertEqual(store.selectedDate, "2026-11-23")
    }
}
