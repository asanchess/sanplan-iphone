import XCTest
@testable import SanPlan

final class FinanceCloudTests: XCTestCase {

    // Выдуманные данные, суммы в тенге.
    private func op(_ id: String, _ kind: String, _ tenge: Int64, _ date: String, category: String? = nil) -> FinanceRecord {
        FinanceRecord(id: id, kind: kind, title: id, amountMinor: tenge * 100, date: date, category: category)
    }

    private func sample() -> FinanceState {
        var transfer = op("t1", "expense", 9_000, "2026-10-31", category: "Переводы")
        transfer.excluded = true
        return FinanceState(
            records: [
                op("a1", "expense", 1_500, "2026-10-30", category: "Кафе"),
                transfer,
                op("i1", "income", 300_000, "2026-11-01", category: "Зарплата"),
                op("a2", "expense", 2_500, "2026-11-02", category: "Кафе"),
                FinanceRecord(id: "g1", kind: "goal", title: "Отпуск", amountMinor: 500_000_00, savedMinor: 40_000_00),
                FinanceRecord(id: "statement-balance", kind: "balance", title: "Остаток", amountMinor: 120_000_00, date: "2026-11-02"),
            ],
            committedBatches: ["batch-1"],
            merchantCategories: ["magnum": "Продукты"],
            budget: FinanceBudget(limits: ["Кафе": 10_000_00])
        )
    }

    private func items(_ entries: [(id: String, data: FinancePayload)]) -> [VaultItem<FinancePayload>] {
        entries.map { VaultItem(id: $0.id, updatedAt: 1, data: $0.data) }
    }

    func testRoundTripKeepsStateAndOrder() {
        let s = sample()
        let entries = FinanceCloud.plan(existing: [:], state: s).puts
        // Порядок записей в коллекции не важен: собираем из перемешанного списка.
        let back = FinanceCloud.state(from: items(entries.reversed()))
        XCTAssertEqual(back.records, s.records)
        XCTAssertEqual(back.committedBatches, s.committedBatches)
        XCTAssertEqual(back.merchantCategories, s.merchantCategories)
        XCTAssertEqual(back.budget, s.budget)
    }

    func testIdsAreValidAndLongestFitsServerLimit() {
        let odd = ["a1", "a b", "запись", "x/y", String(repeating: "z", count: 80), "meta-budget", "ok_id-1"]
        for id in odd {
            let c = FinanceCloud.collectionID(forLocal: id)
            XCTAssertTrue(VaultCollection<FinancePayload>.isValidID(c), c)
            XCTAssertLessThanOrEqual(c.count, 64)
        }
        XCTAssertEqual(FinanceCloud.collectionID(forLocal: "record-1"), "f-record-1")
        XCTAssertEqual(FinanceCloud.collectionID(forLocal: "a1").count, 43)
        XCTAssertEqual(FinanceCloud.collectionID(forLocal: String(repeating: "z", count: 80)).count, 43)
        XCTAssertNotEqual(FinanceCloud.collectionID(forLocal: "meta-budget"), FinanceCloud.budgetID)
        XCTAssertEqual(FinanceCloud.collectionID(forLocal: "a b"), FinanceCloud.collectionID(forLocal: "a b"))
        XCTAssertNotEqual(FinanceCloud.collectionID(forLocal: "a b"), FinanceCloud.collectionID(forLocal: "a  b"))
    }

    func testPlanWritesOnlyDifferences() {
        var s = sample()
        let first = FinanceCloud.plan(existing: [:], state: s)
        XCTAssertTrue(first.removes.isEmpty)
        let existing = FinanceCloud.existing(items(first.puts))
        XCTAssertTrue(FinanceCloud.plan(existing: existing, state: s).puts.isEmpty)

        s.records[0].category = "Такси"
        s.records.remove(at: 3)
        s.records.insert(op("new", "expense", 700, "2026-11-01", category: "Кафе"), at: 2)
        let next = FinanceCloud.plan(existing: existing, state: s)
        XCTAssertEqual(Set(next.puts.map(\.id)), [FinanceCloud.collectionID(forLocal: "a1"), FinanceCloud.collectionID(forLocal: "new")])
        XCTAssertEqual(next.removes, [FinanceCloud.collectionID(forLocal: "a2")])
        // Вставка в середину не переписывает соседей, а порядок сохраняется.
        var merged = existing
        for p in next.puts { merged[p.id] = p.data }
        for id in next.removes { merged[id] = nil }
        let back = FinanceCloud.state(from: merged.map { VaultItem(id: $0.key, updatedAt: 1, data: $0.value) })
        XCTAssertEqual(back.records.map(\.id), s.records.map(\.id))
    }

    func testFingerprintMatchesAfterRoundTrip() {
        let s = sample()
        let back = FinanceCloud.state(from: items(FinanceCloud.plan(existing: [:], state: s).puts))
        let f = FinanceCloud.fingerprint(s)
        XCTAssertEqual(f, FinanceCloud.fingerprint(back))
        XCTAssertEqual(f.operations, 4)
        XCTAssertEqual(f.byMonthCategory["2026-11|expense|Кафе"], 2_500_00)
        XCTAssertNil(f.byMonthCategory["2026-10|expense|Переводы"])
        XCTAssertEqual(f.goalsSavedMinor, 40_000_00)
        XCTAssertEqual(f.balanceMinor, 120_000_00)
        XCTAssertTrue(FinanceCloud.isVerified(local: s, remote: back))
    }

    func testVerificationFailsOnMissingOrChangedRecords() {
        let s = sample()
        var missing = s
        missing.records.removeLast()
        XCTAssertFalse(FinanceCloud.isVerified(local: s, remote: missing))
        var changed = s
        changed.records[0].amountMinor = 1
        XCTAssertFalse(FinanceCloud.isVerified(local: s, remote: changed))
        // Облако знает больше (второе устройство): локальное всё равно на месте.
        var richer = s
        richer.records.append(op("other", "expense", 100, "2026-11-03", category: "Кафе"))
        XCTAssertTrue(FinanceCloud.isVerified(local: s, remote: richer))
    }

    func testRerunAndInterruptedMigrationAddNothing() {
        let s = sample()
        let all = FinanceCloud.entries(s, updatedAt: 5)
        // Прерванный перенос: часть записей уже есть, остальные досылаются, лишнего нет.
        let half = FinanceCloud.existing(items(all.prefix(3).map { ($0.id, $0.data) }))
        let rest = FinanceCloud.plan(existing: half, state: s)
        XCTAssertEqual(rest.puts.count, all.count - 3)
        XCTAssertTrue(rest.removes.isEmpty)
        // Повтор после полной выгрузки: ни одной новой записи.
        let full = FinanceCloud.existing(items(all.map { ($0.id, $0.data) }))
        XCTAssertTrue(FinanceCloud.plan(existing: full, state: s).puts.isEmpty)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }
}
