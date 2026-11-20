import XCTest
@testable import SanPlan

/// Items inside an envelope: fill in order, «Хватает», «Куплено», rename and old data. Synthetic amounts.
final class EnvelopeItemsTests: XCTestCase {

    private func pc(saved: Int64) -> FinanceRecord {
        var g = FinanceRecord(id: "pc", kind: "goal", title: "Компьютер", amountMinor: 1_000_000_00, savedMinor: saved)
        g.items = [
            EnvelopeItem(id: "gpu", title: "Видеокарта", amountMinor: 400_000_00),
            EnvelopeItem(id: "cpu", title: "Процессор", amountMinor: 200_000_00),
            EnvelopeItem(id: "ram", title: "Память", amountMinor: 100_000_00),
        ]
        return g
    }

    func testSavedMoneyFillsItemsTopToBottom() {
        let fills = FinanceBudgeting.itemFills(pc(saved: 500_000_00))
        XCTAssertEqual(fills.map(\.filledMinor), [400_000_00, 100_000_00, 0])
        XCTAssertEqual(fills.map(\.isEnough), [true, false, false])
    }

    func testEnoughWhenFillCoversItemExactly() {
        let fills = FinanceBudgeting.itemFills(pc(saved: 600_000_00))
        XCTAssertEqual(fills.map(\.isEnough), [true, true, false])
    }

    func testBoughtItemIsLeftOutOfTheFill() {
        var g = pc(saved: 250_000_00)
        g.items?[0].bought = true
        let fills = FinanceBudgeting.itemFills(g)
        XCTAssertEqual(fills.map(\.filledMinor), [0, 200_000_00, 50_000_00])
        XCTAssertEqual(fills.map(\.isEnough), [false, true, false])
    }

    func testMarkBoughtWithdrawsTheItemAndKeepsItStruck() throws {
        let state = FinanceState(records: [pc(saved: 500_000_00)])
        let next = try FinanceBudgeting.markItemBought(state, goalId: "pc", itemId: "gpu", date: "2026-11-20")
        let g = try XCTUnwrap(next.records.first)
        XCTAssertEqual(g.savedMinor, 100_000_00)
        XCTAssertEqual(g.amountMinor, 600_000_00)
        XCTAssertEqual(g.items?.first?.bought, true)
        XCTAssertEqual(g.items?.count, 3)
        XCTAssertEqual(FinanceBudgeting.envelopeHistory(next, goalId: "pc").first?.amountMinor, -400_000_00)
        XCTAssertEqual(FinanceBudgeting.itemFills(g).map(\.filledMinor), [0, 100_000_00, 0])
        XCTAssertThrowsError(try FinanceBudgeting.markItemBought(next, goalId: "pc", itemId: "gpu"))
    }

    func testRenameAndItemsSurviveValidation() throws {
        let state = FinanceState(records: [pc(saved: 0)])
        let renamed = try FinanceBudgeting.renameEnvelope(state, goalId: "pc", title: "  Игровой ПК ")
        XCTAssertEqual(renamed.records.first?.title, "Игровой ПК")
        XCTAssertEqual(renamed.records.first?.items?.count, 3)
        XCTAssertThrowsError(try FinanceBudgeting.renameEnvelope(state, goalId: "pc", title: "  "))
    }

    func testOldEnvelopeWithoutItemsDecodes() throws {
        let json = #"{"id":"g1","kind":"goal","title":"Подушка","amountMinor":10000,"savedMinor":500}"#
        let g = try JSONDecoder().decode(FinanceRecord.self, from: Data(json.utf8))
        XCTAssertNil(g.items)
        XCTAssertTrue(FinanceBudgeting.itemFills(g).isEmpty)
    }
}
