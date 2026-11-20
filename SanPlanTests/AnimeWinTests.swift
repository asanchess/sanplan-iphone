import XCTest
@testable import SanPlan

final class AnimeWinTests: XCTestCase {
    func testAllDone() {
        XCTAssertFalse(AnimeWin.allDone([]))
        XCTAssertFalse(AnimeWin.allDone([true, false]))
        XCTAssertTrue(AnimeWin.allDone([true, true]))
    }
}
