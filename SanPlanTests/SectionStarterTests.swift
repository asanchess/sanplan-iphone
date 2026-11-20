import XCTest
@testable import SanPlan

/// After «Что ведём?»: only kept sections get first steps, in section order, each with its place.
final class SectionStarterTests: XCTestCase {
    func testMoneyAndNotesOnly() {
        let s = SectionStarter.suggestions(keep: [.notes, .money])
        XCTAssertEqual(s.map(\.title), ["Поставить лимит на день", "Начать копить (конверт)", "Загрузить выписку", "Первая заметка"])
        XCTAssertEqual(s.map(\.link), [.moneyPlan, .moneyPlan, .moneyOperations, .notes])
    }

    func testPlansAndWorkout() {
        let s = SectionStarter.suggestions(keep: [.workout, .plans])
        XCTAssertEqual(s.map(\.title), ["Добавить первый план", "Выбрать программу"])
        XCTAssertEqual(s.last?.tab, .workout)
        XCTAssertNil(s.last?.link)
    }

    func testNothingKeptNoCard() {
        XCTAssertTrue(SectionStarter.suggestions(keep: []).isEmpty)
        XCTAssertTrue(SectionStarter.suggestions(keep: [.today]).isEmpty)
    }
}
