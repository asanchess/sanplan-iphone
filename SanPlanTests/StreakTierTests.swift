import XCTest
@testable import SanPlan

final class StreakTierTests: XCTestCase {
    func testTierHeatsUpWithLength() {
        XCTAssertEqual(StreakTier.of(0), .none)
        XCTAssertEqual(StreakTier.of(1), .warm)
        XCTAssertEqual(StreakTier.of(2), .warm)
        XCTAssertEqual(StreakTier.of(3), .purple)
        XCTAssertEqual(StreakTier.of(6), .purple)
        XCTAssertEqual(StreakTier.of(7), .hot)
        XCTAssertEqual(StreakTier.of(29), .hot)
        XCTAssertEqual(StreakTier.of(30), .gold)
        XCTAssertEqual(StreakTier.of(365), .gold)
    }
}
