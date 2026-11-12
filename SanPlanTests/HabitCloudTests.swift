import XCTest
@testable import SanPlan

final class HabitCloudTests: XCTestCase {
    private func habit(_ id: String) -> Habit { Habit(id: id, title: "Зарядка", createdDay: "2026-11-01") }

    func testRecordIDs() {
        XCTAssertEqual(HabitCloud.habitRecordID("abc12345"), "h-abc12345")
        XCTAssertEqual(HabitCloud.marksRecordID("abc12345", month: "2026-11"), "m-abc12345-202611")
        XCTAssertTrue(HabitCloud.isValidID("h-abc12345"))
        XCTAssertFalse(HabitCloud.isValidID("h-1"))
    }

    func testRecordsGroupMarksByMonthAndSkipInvalidIDs() {
        let marks = ["abc12345": ["2026-10-31": 1, "2026-11-02": 1, "2026-11-03": 0]]
        let records = HabitCloud.records(habits: [habit("abc12345"), habit("x")], marks: marks, streak: .standard)
        let ids = Set(records.map(\.id))
        XCTAssertEqual(ids, ["h-abc12345", "m-abc12345-202610", "m-abc12345-202611", "s-streak"])
    }

    func testRoundTripThroughPayloads() {
        let marks = ["abc12345": ["2026-10-31": 1, "2026-11-02": 2]]
        let records = HabitCloud.records(habits: [habit("abc12345")], marks: marks, streak: .standard)
        // Payload переживает JSON, как в зашифрованной записи.
        for r in records {
            let data = try? JSONEncoder().encode(r.payload)
            XCTAssertNotNil(data)
            XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(HabitPayload.self, from: $0) }, r.payload)
        }
    }
}
