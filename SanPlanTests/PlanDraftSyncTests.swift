import XCTest
@testable import SanPlan

final class PlanDraftSyncTests: XCTestCase {
    private func draft(_ id: String, _ title: String = "x") -> PlanItem {
        PlanItem(id: id, kind: "task", title: title, date: "2026-11-14")
    }

    func testRecordIDIsValidForTheVault() {
        XCTAssertTrue(VaultCollection<SettingsPayload>.isValidID(PlanDraftCloud.recordID))
    }

    func testFirstRunKeepsEverythingAndCloudWinsForSameID() {
        let merged = PlanDraftCloud.mergeFirstRun(
            local: [draft("l1"), draft("both", "local")],
            remote: [draft("r1"), draft("both", "cloud")]
        )
        XCTAssertEqual(merged.map(\.id), ["r1", "both", "l1"])
        XCTAssertEqual(merged.first { $0.id == "both" }?.title, "cloud")
    }

    func testFirstRunWithEmptySidesStaysEmpty() {
        XCTAssertTrue(PlanDraftCloud.mergeFirstRun(local: [], remote: []).isEmpty)
        XCTAssertEqual(PlanDraftCloud.mergeFirstRun(local: [draft("a")], remote: []).map(\.id), ["a"])
        XCTAssertEqual(PlanDraftCloud.mergeFirstRun(local: [], remote: [draft("b")]).map(\.id), ["b"])
    }

    func testPayloadReadsTheWebFormat() throws {
        let json = #"{"kind":"planDrafts","drafts":[{"id":"d1","kind":"event","title":"Встреча","date":"2026-11-14","time":"10:00","durationMinutes":30,"timeZone":"Asia/Qyzylorda"}]}"#
        let payload = try JSONDecoder().decode(SettingsPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.kind, "planDrafts")
        XCTAssertEqual(payload.drafts?.first?.title, "Встреча")
        let back = try JSONDecoder().decode(SettingsPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(back, payload)
    }

    func testEmptyListIsAValidClearingPayload() throws {
        let data = try JSONEncoder().encode(SettingsPayload(drafts: []))
        let back = try JSONDecoder().decode(SettingsPayload.self, from: data)
        XCTAssertEqual(back.kind, "planDrafts")
        XCTAssertEqual(back.drafts, [])
    }
}
