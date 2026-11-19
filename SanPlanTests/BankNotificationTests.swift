import XCTest
@testable import SanPlan

/// Bank notifications handed over by the iOS 27 Shortcuts automation, and statements shared to A-san.
/// The notification texts are made up in the style of the one published Halyk sample («Вы получили перевод:
/// 32 000 тенге»); amounts, merchants and names are invented. Statements are the anonymised ones of StatementImportTests.
final class BankNotificationTests: XCTestCase {
    private let today = "2025-11-20"

    private func tap(_ app: String, _ text: String, time: String = "2025-11-03T12:10") -> BankFeed.Tap? {
        if case .operation(let tap) = BankNotification.read(app: app, text: text, time: time) { return tap }
        return nil
    }

    private func taking(_ taps: [BankFeed.Tap?], into state: FinanceState = FinanceState()) throws -> FinanceState {
        var state = state
        for t in taps { state = try BankFeed.ingest(try XCTUnwrap(t), into: state, today: today).state }
        return state
    }

    private func importing(_ text: String, id: String, into state: FinanceState) throws -> FinanceState {
        let preview = StatementImport.preview(try BankStatementParser.parse(text), importId: id, rules: state.merchantCategories)
        return try StatementImport.apply(preview, to: state, importId: id, fileName: "\(id).pdf", today: "2025-12-01")
    }

    // MARK: - Reading

    func testAKaspiPurchase() throws {
        let t = try XCTUnwrap(tap("Kaspi.kz", "Покупка 1 500 ₸ в MAGNUM. Доступно 20 000 ₸"))
        XCTAssertEqual(t.card, "Kaspi")
        XCTAssertEqual(BankFeed.amountMinor(t.amount), 150_000)
        XCTAssertEqual(t.merchant, "MAGNUM")
        XCTAssertNil(t.kind)
        XCTAssertEqual(t.operation, "Покупка")
        XCTAssertEqual(t.source, BankFeed.Tap.notificationSource)
    }

    func testAHalykIncomingTransfer() throws {
        let t = try XCTUnwrap(tap("Homebank", "Вы получили перевод: 32 000 тенге"))
        XCTAssertEqual(t.card, "Halyk")
        XCTAssertEqual(t.kind, "income")
        XCTAssertEqual(t.operation, "Перевод")
        XCTAssertEqual(BankFeed.amountMinor(t.amount), 3_200_000)
        XCTAssertEqual(t.merchant, "")
    }

    func testWithdrawalTransferAndSignedIncome() throws {
        let cash = try XCTUnwrap(tap("Homebank", "Снятие наличных 10 000 ₸ ATM ТЕСТ"))
        XCTAssertEqual(cash.operation, "Снятие")
        XCTAssertEqual(cash.merchant, "ATM ТЕСТ")
        let out = try XCTUnwrap(tap("Kaspi.kz", "Перевод 5 000 ₸ отправлен"))
        XCTAssertEqual(out.operation, "Перевод")
        XCTAssertNil(out.kind)
        XCTAssertEqual(out.merchant, "")
        let plus = try XCTUnwrap(tap("Kaspi.kz", "+15 000 ₸ Пополнение"))
        XCTAssertEqual(plus.kind, "income")
        XCTAssertEqual(plus.operation, "Пополнение")
    }

    func testTheDirectionOfATransfer() throws {
        XCTAssertEqual(try XCTUnwrap(tap("Kaspi.kz", "Перевод от Т. Тестов: 5 000 ₸")).kind, "income")
        XCTAssertEqual(try XCTUnwrap(tap("Kaspi.kz", "Вам отправили 5 000 ₸")).kind, "income")
        XCTAssertEqual(try XCTUnwrap(tap("Kaspi.kz", "Отмена покупки 1 500 ₸ Тест")).kind, "income")
        XCTAssertNil(try XCTUnwrap(tap("Kaspi.kz", "Вы перевели 5 000 ₸ Т. Тестову")).kind)
        XCTAssertEqual(BankNotification.read(app: "Kaspi.kz", text: "Перевод 5 000 ₸", time: today), .review(bank: "Kaspi"))
    }

    func testWordsInsideOtherWordsDoNotDecide() throws {
        XCTAssertNotNil(tap("Homebank", "Транзакция: покупка 2 000 ₸ в Тест"))
        XCTAssertNotNil(tap("Kaspi.kz", "Оплата по QR-коду 1 500 ₸ Тест"))
        XCTAssertEqual(try XCTUnwrap(tap("Kaspi.kz", "Покупка 3 000 ₸ KATMANDU CAFE")).operation, "Покупка")
        XCTAssertEqual(BankFeed.amountMinor(try XCTUnwrap(tap("Kaspi.kz", "Доступно: 9 000 ₸, покупка 1 500 ₸ в Тест")).amount), 150_000)
        XCTAssertEqual(BankNotification.read(app: "Kaspi.kz", text: "Покупка в Тест", time: today), .review(bank: "Kaspi"))
    }

    func testAmountsTheBalanceAndACardNumber() throws {
        XCTAssertEqual(BankFeed.amountMinor(try XCTUnwrap(tap("Kaspi.kz", "Доступно 9 000 ₸. Покупка 1 500 ₸ в Тест")).amount), 150_000)
        XCTAssertEqual(BankFeed.amountMinor(try XCTUnwrap(tap("Homebank", "Покупка 12\u{00A0}345,50 ₸ в ТОО Тест")).amount), 1_234_550)
        XCTAssertEqual(BankFeed.amountMinor(try XCTUnwrap(tap("Homebank", "Оплата картой *1234 500 ₸ Тест")).amount), 50_000)
        XCTAssertEqual(BankFeed.amountMinor(try XCTUnwrap(tap("Kaspi.kz", "Списание 2 990 тг Тестовая подписка")).amount), 299_000)
        XCTAssertEqual(try XCTUnwrap(tap("Kaspi.kz", "Покупка в Тестовой кофейне: 1 200 ₸")).merchant, "Тестовой кофейне")
    }

    func testCodesAdvertsAndDeclinedPaymentsAreNotKept() {
        XCTAssertEqual(BankNotification.read(app: "Kaspi.kz", text: "Ваш код подтверждения: 1234. Никому не сообщайте", time: today), .ignore)
        XCTAssertEqual(BankNotification.read(app: "Kaspi.kz", text: "Код для оплаты 5 000 ₸ в Тест: 5821", time: today), .ignore)
        XCTAssertEqual(BankNotification.read(app: "Kaspi.kz", text: "Рассрочка 0-0-12 на покупки от 50 000 ₸", time: today), .ignore)
        XCTAssertEqual(BankNotification.read(app: "Homebank", text: "Покупка 3 000 ₸ отклонена: недостаточно средств", time: today), .ignore)
        XCTAssertEqual(BankNotification.read(app: "Homebank", text: "Обновите приложение", time: today), .ignore)
    }

    func testWhatCannotBePlacedWaitsForTheOwner() {
        XCTAssertEqual(BankNotification.read(app: "Kaspi.kz", text: "Покупка $4.99 TEST.COM", time: today), .review(bank: "Kaspi"))
        XCTAssertEqual(BankNotification.read(app: "Homebank", text: "Операция 1 000 ₸", time: today), .review(bank: "Halyk"))
        XCTAssertEqual(BankNotification.read(app: "Тест", text: "Покупка 1 000 ₸", time: today), .review(bank: nil))
    }

    // MARK: - Into money

    func testAPurchaseThatCameBothWaysIsOneButTwoEqualCoffeesStayTwo() throws {
        let wallet = BankFeed.Tap(amount: "₸1 200", merchant: "Тестовая кофейня", card: "Kaspi Gold", time: "2025-11-03T09:00")
        let note = tap("Kaspi.kz", "Покупка 1 200 ₸ в TEST COFFEE", time: "2025-11-03T09:00")
        var state = try taking([wallet, note])
        XCTAssertEqual(state.records.filter { $0.amountMinor == 120_000 }.count, 1)
        XCTAssertEqual(try BankFeed.ingest(XCTUnwrap(note), into: state, today: today).outcome, .duplicate)

        let wallet2 = BankFeed.Tap(amount: "₸1 200", merchant: "Тестовая кофейня", card: "Kaspi Gold", time: "2025-11-03T15:00")
        let note2 = tap("Kaspi.kz", "Покупка 1 200 ₸ в TEST COFFEE", time: "2025-11-03T15:01")
        state = try taking([note2], into: state)
        XCTAssertEqual(state.records.filter { $0.amountMinor == 120_000 }.count, 2, "A QR payment later in the day is not the morning's twin")
        XCTAssertEqual(try BankFeed.ingest(wallet2, into: state, today: today).outcome, .duplicate)
    }

    func testATwinAcrossMidnightIsOne() throws {
        let wallet = BankFeed.Tap(amount: "₸1 200", merchant: "Тест", card: "Kaspi Gold", time: "2025-11-03T23:59")
        let state = try taking([wallet, tap("Kaspi.kz", "Покупка 1 200 ₸ в Тест", time: "2025-11-04T00:01")])
        XCTAssertEqual(state.records.filter { $0.amountMinor == 120_000 }.count, 1)
    }

    func testTheSortStaysWhenTheOwnerChangesTheCategory() throws {
        var state = try taking([BankFeed.Tap(amount: "₸2 500", merchant: "MAGNUM", card: "Kaspi Gold", time: "2025-11-03T12:10")])
        state.records[0].category = "Переводы"
        state = try importing(StatementImportTests.kaspiText, id: "k", into: state)
        XCTAssertFalse(state.records.contains { BankFeed.isFeedRecord($0) }, "Still the purchase line's payment")
        XCTAssertEqual(state.records.first { $0.amountMinor == 250_000 }?.category, "Переводы")
    }

    func testIncomeTransferAndCashTakeTheirOwnStatementLines() throws {
        // The Kaspi statement has +350 000 on 06.11, «Перевод» −15 000 on 07.11 and «Снятие» −20 000 on 08.11.
        var state = try taking([
            tap("Kaspi.kz", "Пополнение карты 350 000 ₸ от ТОО Тест", time: "2025-11-06T10:00"),
            tap("Kaspi.kz", "Перевод 15 000 ₸ отправлен", time: "2025-11-07T10:00"),
            tap("Kaspi.kz", "Снятие наличных 20 000 ₸ Банкомат", time: "2025-11-08T10:00"),
        ])
        XCTAssertEqual(state.records.first { $0.kind == "income" }?.amountMinor, 35_000_000)
        XCTAssertEqual(state.records.first { $0.amountMinor == 1_500_000 }?.category, "Переводы")
        XCTAssertEqual(state.records.first { $0.amountMinor == 2_000_000 }?.category, "Наличные")

        state = try importing(StatementImportTests.kaspiText, id: "k", into: state)
        XCTAssertFalse(state.records.contains { BankFeed.isFeedRecord($0) }, "Each notification gave way to its line")
        XCTAssertEqual(state.records.filter { $0.kind == "income" && $0.amountMinor == 35_000_000 }.count, 1)
        XCTAssertEqual(state.records.filter { $0.kind == "expense" && $0.amountMinor == 1_500_000 }.count, 1)
        XCTAssertEqual(state.records.filter { $0.kind == "expense" && $0.amountMinor == 2_000_000 }.count, 1)
    }

    func testANotificationAfterItsStatementIsNotAddedAgain() throws {
        let state = try importing(StatementImportTests.kaspiText, id: "k", into: FinanceState())
        let result = try BankFeed.ingest(XCTUnwrap(tap("Kaspi.kz", "Перевод 15 000 ₸ отправлен", time: "2025-11-07T10:00")), into: state, today: today)
        guard case .inStatement = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(result.state.records.filter { $0.amountMinor == 1_500_000 }.count, 1)
    }

    func testAPurchaseNotificationDoesNotTakeATransferLine() throws {
        var state = try taking([tap("Kaspi.kz", "Покупка 15 000 ₸ в Тест", time: "2025-11-07T10:00")])
        state = try importing(StatementImportTests.kaspiText, id: "k", into: state)
        XCTAssertEqual(state.records.filter { $0.amountMinor == 1_500_000 }.count, 2)
        XCTAssertEqual(state.records.first { BankFeed.isFeedRecord($0) }?.note, BankFeed.missingNote)
    }

    // MARK: - On the phone

    func testReviewKeepsOnlyTheNewest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let review = BankNotificationReview(folder: folder)
        for i in 0..<(BankNotificationReview.limit + 5) {
            try review.add(.init(bank: "Kaspi", text: "Операция \(i) ₸", time: String(format: "2025-11-03T10:%02d", i)))
        }
        let items = review.items()
        XCTAssertEqual(items.count, BankNotificationReview.limit)
        XCTAssertEqual(items.first?.item.text, "Операция 5 ₸")
        review.clear()
        XCTAssertTrue(review.items().isEmpty)
    }

    @MainActor
    func testASharedFileThatIsNotAStatementIsDroppedWithAReason() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("statements-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = FinanceStore(owner: .device, baseDirectory: base)
        try store.bankStatementInbox.add(data: Data("не pdf".utf8), name: "тест.pdf")
        XCTAssertEqual(store.bankStatementInbox.pending().count, 1)
        let loaded = await store.takeInStatements(today: today)
        XCTAssertEqual(loaded, 0)
        XCTAssertTrue(store.bankStatementInbox.pending().isEmpty)
        XCTAssertNotNil(store.sharedStatementProblem)
        XCTAssertTrue(store.state.records.isEmpty)
    }

    @MainActor
    func testSharedStatementsWaitWhileSignedOut() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("statements-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = FinanceStore(owner: .none, baseDirectory: base)
        try store.bankStatementInbox.add(data: Data("%PDF".utf8), name: "Выписка.pdf")
        let loaded = await store.takeInStatements(today: today)
        XCTAssertEqual(loaded, 0)
        XCTAssertEqual(store.bankStatementInbox.pending().map(BankStatementInbox.originalName), ["Выписка.pdf"])
    }
}
