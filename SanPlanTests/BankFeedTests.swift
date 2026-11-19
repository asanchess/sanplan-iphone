import XCTest
@testable import SanPlan

/// Apple Pay payments handed over by the Shortcuts Wallet automation, and how statements take them over.
/// Made-up merchants, amounts and the anonymised statements of StatementImportTests only.
final class BankFeedTests: XCTestCase {
    private let today = "2025-11-20"

    private func tap(_ amount: String, _ merchant: String, card: String = "Kaspi Gold", time: String) -> BankFeed.Tap {
        BankFeed.Tap(amount: amount, merchant: merchant, card: card, time: time)
    }

    private func taking(_ taps: [BankFeed.Tap], into state: FinanceState = FinanceState()) throws -> FinanceState {
        var state = state
        for t in taps { state = try BankFeed.ingest(t, into: state, today: today).state }
        return state
    }

    private func importing(_ text: String, id: String, into state: FinanceState) throws -> FinanceState {
        let preview = StatementImport.preview(try BankStatementParser.parse(text), importId: id, rules: state.merchantCategories)
        return try StatementImport.apply(preview, to: state, importId: id, fileName: "\(id).pdf", today: "2025-12-01")
    }

    private func expenses(_ s: FinanceState, amount: Int64, date: String) -> [FinanceRecord] {
        s.records.filter { $0.kind == "expense" && $0.amountMinor == amount && $0.date == date }
    }

    // MARK: - Reading what the automation passes

    func testAmountsInTheFormatsShortcutsWrites() {
        XCTAssertEqual(BankFeed.amountMinor("₸1 500,00"), 150_000)
        XCTAssertEqual(BankFeed.amountMinor("1\u{00A0}500 ₸"), 150_000)
        XCTAssertEqual(BankFeed.amountMinor("KZT 1,500.00"), 150_000)
        XCTAssertEqual(BankFeed.amountMinor("1.500,50"), 150_050)
        XCTAssertEqual(BankFeed.amountMinor("1,500"), 150_000)
        XCTAssertEqual(BankFeed.amountMinor("2 500,5 ₸"), 250_050)
        XCTAssertEqual(BankFeed.amountMinor("-990"), 99_000)
        XCTAssertNil(BankFeed.amountMinor("₸0,00"))
        XCTAssertNil(BankFeed.amountMinor("бесплатно"))
        XCTAssertNil(BankFeed.amountMinor(""))
    }

    func testCardNamesGiveTheBankItsStatementsName() {
        XCTAssertEqual(BankFeed.bank(ofCard: "Kaspi Gold"), ParsedStatement.Bank.kaspi.rawValue)
        XCTAssertEqual(BankFeed.bank(ofCard: "Halyk Visa"), ParsedStatement.Bank.halyk.rawValue)
        XCTAssertEqual(BankFeed.bank(ofCard: "Freedom Card"), "Freedom")
        XCTAssertEqual(BankFeed.bank(ofCard: "Моя карта Jusan"), "Jusan")
        XCTAssertEqual(BankFeed.bank(ofCard: "Тестовая карта"), "Тестовая карта")
        XCTAssertEqual(BankFeed.bank(ofCard: " "), "Apple Pay")
    }

    func testTimesFromShortcuts() {
        XCTAssertEqual(BankFeed.moment("2025-11-03T14:05:31+05:00")?.day, "2025-11-03")
        XCTAssertEqual(BankFeed.moment("2025-11-03T14:05:31+05:00")?.minute, "2025-11-03T14:05")
        XCTAssertEqual(BankFeed.moment("18.11.2025, 9:41")?.day, "2025-11-18")
        XCTAssertEqual(BankFeed.moment("2025-11-03")?.minute, "2025-11-03")
        XCTAssertNil(BankFeed.moment("вчера"))
        XCTAssertEqual(BankFeed.localTime(Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 5 * 3600)!), "1970-01-01T05:00")
    }

    // MARK: - Into money

    func testAPaymentBecomesAnExpenseOfItsBankAndDay() throws {
        let result = try BankFeed.ingest(tap("₸2 500,00", "MAGNUM", time: "2025-11-03T12:10"), into: FinanceState(), today: today)
        guard case .added(let id) = result.outcome else { return XCTFail("The payment was not added") }
        let record = try XCTUnwrap(result.state.records.first { $0.id == id })
        XCTAssertEqual(record.kind, "expense")
        XCTAssertEqual(record.amountMinor, 250_000)
        XCTAssertEqual(record.date, "2025-11-03")
        XCTAssertEqual(record.category, "Продукты")
        XCTAssertEqual(record.merchant, "MAGNUM")
        let item = try XCTUnwrap(result.state.imports?.first { $0.id == record.importId })
        XCTAssertEqual(item.bank, "Kaspi")
        XCTAssertEqual(item.fileName, BankFeed.source)
        XCTAssertEqual(item.count, 1)
        XCTAssertNil(item.closingMinor, "A payment says nothing about the balance")
        XCTAssertThrowsError(try BankFeed.ingest(tap("бесплатно", "Тест", time: "2025-11-03T12:10"), into: FinanceState(), today: today))
        XCTAssertThrowsError(try BankFeed.ingest(tap("₸100", "Тест", time: "вчера"), into: FinanceState(), today: today))
    }

    func testTheSameRunTwiceAddsOnceButTwoEqualCoffeesStayTwo() throws {
        let coffee = tap("1 000 ₸", "Coffee Boom", time: "2025-11-03T09:15:02+05:00")
        let state = try taking([coffee])
        let again = try BankFeed.ingest(coffee, into: state, today: today)
        XCTAssertEqual(again.outcome, .duplicate)
        let afternoon = try taking([tap("1 000 ₸", "Coffee Boom", time: "2025-11-03T16:40")], into: again.state)
        XCTAssertEqual(expenses(afternoon, amount: 100_000, date: "2025-11-03").count, 2)
        XCTAssertEqual(afternoon.imports?.count, 1, "One feed import per bank and day")
        XCTAssertEqual(afternoon.imports?.first?.count, 2)
    }

    // MARK: - Statements take over

    func testStatementReplacesPaymentsAndKeepsTheOwnersCategoryAndNote() throws {
        var state = try taking([
            tap("2 500,00 ₸", "Magnum", time: "2025-11-03T12:10"),
            // Paid late in the evening; the bank books it the next day.
            tap("1 200 ₸", "Yandex Go", time: "2025-11-04T23:55"),
        ])
        let ride = try XCTUnwrap(state.records.firstIndex { $0.merchant == "Yandex Go" })
        state.records[ride].category = "Развлечения"
        state.records[ride].note = "в кино"

        state = try importing(StatementImportTests.kaspiText, id: "k", into: state)
        XCTAssertFalse(state.records.contains { BankFeed.isFeed($0.importId) }, "No Apple Pay record is left beside the statement")
        XCTAssertEqual(expenses(state, amount: 250_000, date: "2025-11-03").map(\.id), ["k-0"])
        XCTAssertEqual(expenses(state, amount: 120_000, date: "2025-11-05").map(\.id), ["k-2"])
        XCTAssertTrue(expenses(state, amount: 120_000, date: "2025-11-04").isEmpty)
        let line = try XCTUnwrap(state.records.first { $0.id == "k-2" })
        XCTAssertEqual(line.category, "Развлечения", "The owner's choice moves to the statement's line")
        XCTAssertEqual(line.note, "в кино")
        XCTAssertEqual(state.records.first { $0.id == "k-0" }?.category, "Продукты")
        XCTAssertFalse(state.imports?.contains { BankFeed.isFeed($0.id) } ?? false, "An emptied feed import goes")
    }

    func testALatePaymentAfterTheStatementIsNotAddedAgain() throws {
        let state = try importing(StatementImportTests.kaspiText, id: "k", into: FinanceState())
        // The Wallet trigger can come hours late, after the statement was loaded.
        let late = try BankFeed.ingest(tap("₸3 750,50", "MAGNUM", time: "2025-11-09T19:00"), into: state, today: today)
        guard case .inStatement(let lateId) = late.outcome else { return XCTFail("The statement has this payment") }
        XCTAssertEqual(late.state.records.count, state.records.count)
        XCTAssertEqual(late.state.imports?.first { $0.id == "k" }?.mergedManual?.map(\.id), [lateId], "Kept with the statement")
        // A second equal payment the same evening is not the statement's one line again.
        let second = try BankFeed.ingest(tap("₸3 750,50", "MAGNUM", time: "2025-11-09T21:30"), into: late.state, today: today)
        guard case .added = second.outcome else { return XCTFail("A second equal payment was lost") }
        XCTAssertEqual(try BankFeed.ingest(tap("₸3 750,50", "MAGNUM", time: "2025-11-09T19:00"), into: second.state, today: today).outcome, .duplicate)
        // Deleting the statement gives the late payment back.
        XCTAssertNotNil(try StatementImport.deleteImport("k", from: late.state).records.first { $0.id == lateId })
        // Another bank's card, or a day after the statement, still counts.
        let halykCard = try BankFeed.ingest(tap("₸3 750,50", "MAGNUM", card: "Halyk", time: "2025-11-09T19:00"), into: state, today: today)
        XCTAssertNotEqual(halykCard.outcome, .duplicate)
        let december = try BankFeed.ingest(tap("₸3 750,50", "MAGNUM", time: "2025-12-02T10:00"), into: state, today: today)
        XCTAssertNotEqual(december.outcome, .duplicate)
    }

    func testASecondEqualPaymentAfterOneTheStatementReplacedStays() throws {
        var state = try taking([tap("₸2 500", "Magnum", time: "2025-11-03T09:00")])
        state = try importing(StatementImportTests.kaspiText, id: "k", into: state)
        let second = try BankFeed.ingest(tap("₸2 500", "Magnum", time: "2025-11-03T18:30"), into: state, today: today)
        XCTAssertNotEqual(second.outcome, .duplicate)
        XCTAssertEqual(expenses(second.state, amount: 250_000, date: "2025-11-03").count, 2)
        let rerun = try BankFeed.ingest(tap("₸2 500", "Magnum", time: "2025-11-03T09:00"), into: second.state, today: today)
        XCTAssertEqual(rerun.outcome, .duplicate, "The replaced payment's run again is still known")
    }

    func testAPaymentTheStatementLacksIsKeptWithANote() throws {
        var state = try taking([tap("₸7 777", "Тестовый магазин", time: "2025-11-12T13:00")])
        state = try importing(StatementImportTests.kaspiText, id: "k", into: state)
        let kept = try XCTUnwrap(state.records.first { BankFeed.isFeed($0.importId) })
        XCTAssertEqual(kept.amountMinor, 777_700)
        XCTAssertEqual(kept.note, BankFeed.missingNote, "Often a declined payment, which the trigger reports too")
    }

    func testOnlyAStatementOfTheCardsBankTakesItsPayments() throws {
        // The anonymised Halyk statement has «SMALL ALMATY» −4 200,00 on 02.11.
        let kaspi = try importing(StatementImportTests.halykText, id: "h", into: try taking([tap("₸4 200", "SMALL", time: "2025-11-02T10:00")]))
        XCTAssertEqual(expenses(kaspi, amount: 420_000, date: "2025-11-02").count, 2, "A Kaspi card payment is not Halyk's line")
        XCTAssertNil(kaspi.records.first { BankFeed.isFeed($0.importId) }?.note, "Only its own bank's statement can miss it")

        let halyk = try importing(StatementImportTests.halykText, id: "h", into: try taking([tap("₸4 200", "SMALL ALMATY", card: "Halyk Visa", time: "2025-11-02T10:00")]))
        XCTAssertEqual(expenses(halyk, amount: 420_000, date: "2025-11-02").map(\.id), ["h-0"])
    }

    func testDeletingTheStatementBringsThePaymentBack() throws {
        var state = try taking([tap("₸2 500", "Magnum", time: "2025-11-03T12:10")])
        let id = try XCTUnwrap(state.records.first?.id)
        state = try importing(StatementImportTests.kaspiText, id: "k", into: state)
        XCTAssertNil(state.records.first { $0.id == id })

        let decoded = try JSONDecoder().decode(FinanceState.self, from: JSONEncoder().encode(state))
        let restored = try StatementImport.deleteImport("k", from: decoded)
        let back = try XCTUnwrap(restored.records.first { $0.id == id })
        XCTAssertEqual(back.amountMinor, 250_000)
        XCTAssertEqual(back.date, "2025-11-03")
        XCTAssertEqual(try BankFeed.ingest(tap("₸2 500", "Magnum", time: "2025-11-03T12:10"), into: restored, today: today).outcome, .duplicate)
    }

    func testUndoThenTheSameStatementAgainLeavesNoDouble() throws {
        // Booked a day after the payment, so the hand-entered merge suggestions alone would miss it.
        var state = try taking([tap("1 200 ₸", "Yandex Go", time: "2025-11-04T23:55")])
        state = try importing(StatementImportTests.kaspiText, id: "k", into: state)
        state = try StatementImport.deleteImport("k", from: state)
        XCTAssertEqual(expenses(state, amount: 120_000, date: "2025-11-04").count, 1, "Given back after the undo")
        state = try importing(StatementImportTests.kaspiText, id: "k", into: state)
        XCTAssertTrue(expenses(state, amount: 120_000, date: "2025-11-04").isEmpty)
        XCTAssertEqual(expenses(state, amount: 120_000, date: "2025-11-05").map(\.id), ["k-2"])
    }

    func testATransferLineDoesNotSwallowAPayment() throws {
        // The statement has «Перевод на свой счет» −30 000 on 10.11 and «Снятие» −20 000 on 08.11.
        var state = try taking([
            tap("₸30 000", "Тестовый магазин", time: "2025-11-10T12:00"),
            tap("₸20 000", "Тестовый магазин", time: "2025-11-08T12:00"),
        ])
        state = try importing(StatementImportTests.kaspiText, id: "k", into: state)
        let kept = state.records.filter { BankFeed.isFeed($0.importId) }
        XCTAssertEqual(kept.map(\.amountMinor).sorted(), [2_000_000, 3_000_000])
        XCTAssertTrue(kept.allSatisfy { $0.note == BankFeed.missingNote })
        XCTAssertNil(state.records.first { $0.id == "k-5" }?.note)
    }

    func testAPaymentOnTheDayBeforeAStatementBookedOnItsFirstDayIsReplaced() throws {
        var state = try taking([tap("₸4 000", "Тестовая кофейня", time: "2025-11-30T23:55")])
        let line = FinanceRecord(id: "d-0", kind: "expense", title: "Тестовая кофейня", amountMinor: 400_000, date: "2025-12-01", category: "Кафе")
        var withLine = line
        withLine.importId = "d"
        state.records.append(withLine)
        state.imports = (state.imports ?? []) + [FinanceImport(id: "d", bank: "Kaspi", fileName: "d.pdf", periodStart: "2025-12-01", periodEnd: "2025-12-31", importedAt: today, count: 1)]
        XCTAssertEqual(BankFeed.reconcile(&state, statementImportId: "d"), 1)
        XCTAssertEqual(state.records.map(\.id), ["d-0"])
    }

    func testAPaymentInAnotherCurrencyIsRefused() {
        XCTAssertTrue(BankFeed.isForeignCurrency("$4.99"))
        XCTAssertTrue(BankFeed.isForeignCurrency("4,99 EUR"))
        XCTAssertFalse(BankFeed.isForeignCurrency("₸1 500,00"))
        XCTAssertFalse(BankFeed.isForeignCurrency("KZT 1,500.00"))
        XCTAssertThrowsError(try BankFeed.ingest(tap("$4.99", "Тест", time: "2025-11-03T12:10"), into: FinanceState(), today: today)) {
            XCTAssertEqual($0 as? BankFeed.TapError, .currency)
        }
    }

    // MARK: - The inbox on the phone

    @MainActor
    func testInboxIsTakenInOnceAndClearedOnSignOut() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bank-feed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = FinanceStore(owner: .device, baseDirectory: base)
        let inbox = store.bankFeedInbox
        try inbox.add(tap("₸2 500", "Magnum", time: "2025-11-03T12:10"))
        try inbox.add(tap("₸1 000", "Coffee Boom", time: "2025-11-03T09:00"))
        try inbox.add(tap("₸1 000", "Coffee Boom", time: "2025-11-03T09:00"))
        try inbox.add(tap("бесплатно", "Тест", time: "2025-11-03T10:00"))
        XCTAssertEqual(inbox.pending().count, 4)

        XCTAssertEqual(store.takeInBankFeed(today: today), 2, "The repeated run and the unreadable amount add nothing")
        XCTAssertEqual(store.state.records.filter { $0.kind == "expense" }.count, 2)
        XCTAssertTrue(inbox.pending().isEmpty)
        XCTAssertEqual(store.takeInBankFeed(today: today), 0)

        try inbox.add(tap("₸500", "Тест", time: "2025-11-04T10:00"))
        store.discardBankFeed()
        XCTAssertTrue(inbox.pending().isEmpty)
        XCTAssertEqual(store.state.records.filter { $0.kind == "expense" }.count, 2)
    }

    @MainActor
    func testNothingIsTakenInWhileSignedOut() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bank-feed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = FinanceStore(owner: .none, baseDirectory: base)
        try store.bankFeedInbox.add(tap("₸2 500", "Magnum", time: "2025-11-03T12:10"))
        XCTAssertEqual(store.takeInBankFeed(today: today), 0)
        XCTAssertEqual(store.bankFeedInbox.pending().count, 1, "It waits for the account to sign in")
    }
}
