import AppIntents
import Foundation
import UniformTypeIdentifiers

/// The Shortcuts action for the Wallet automation («When I tap» a card). It runs without opening A-san and only leaves
/// the payment in a folder on the phone; money takes it in the next time A-san is open (BankFeed.swift).
/// Setup for the owner: docs/finance/BANK-AUTO-IMPORT.md.
struct RecordWalletPaymentIntent: AppIntent {
    static var title: LocalizedStringResource = "Записать покупку из Wallet"
    static var description = IntentDescription("Для автоматизации «Wallet» в «Командах»: сумма, магазин и карта оплаты попадут в «Деньги».")
    static var openAppWhenRun = false

    @Parameter(title: "Сумма") var amount: String
    @Parameter(title: "Магазин") var merchant: String?
    @Parameter(title: "Карта") var card: String?

    func perform() async throws -> some IntentResult {
        if BankFeed.isForeignCurrency(amount) { throw BankFeed.TapError.currency }
        guard BankFeed.amountMinor(amount) != nil else { throw BankFeed.TapError.amount }
        let tap = BankFeed.Tap(amount: amount, merchant: merchant ?? "", card: card ?? "", time: BankFeed.localTime(Date()))
        try BankFeedInbox.standard().add(tap)
        return .result()
    }
}

/// The Shortcuts action for the iOS 27 automation «When I get a notification from Kaspi.kz / Homebank». The owner
/// passes the notification and its app. A purchase, withdrawal, transfer or incoming money waits in the same folder as
/// Apple Pay payments; a notification with money that A-san cannot place waits for the owner to look at; codes and
/// adverts are dropped (BankNotification.swift). Nothing leaves the phone.
struct RecordBankNotificationIntent: AppIntent {
    static var title: LocalizedStringResource = "Записать уведомление банка"
    static var description = IntentDescription("Для автоматизации «Уведомление» в «Командах»: покупки, переводы и поступления из уведомлений Kaspi и Halyk попадут в «Деньги». Коды и реклама не сохраняются.")
    static var openAppWhenRun = false

    @Parameter(title: "Уведомление") var text: String
    @Parameter(title: "Приложение") var app: String?

    func perform() async throws -> some IntentResult {
        let time = BankFeed.localTime(Date())
        switch BankNotification.read(app: app ?? "", text: text, time: time) {
        case .operation(let tap):
            try BankFeedInbox.standard().add(tap)
        case .review(let bank):
            try BankNotificationReview.standard().add(.init(bank: bank, text: text, time: time))
        case .ignore:
            break
        }
        return .result()
    }
}

/// «Поделиться → Загрузить выписку в A-san»: a Kaspi or Halyk PDF statement shared from the bank's app waits on the
/// phone and is loaded the next time A-san is open (FinanceStore.takeInStatements). Opening the PDF in A-san works too.
struct ImportStatementIntent: AppIntent {
    static var title: LocalizedStringResource = "Загрузить выписку в A-san"
    static var description = IntentDescription("Выписка Kaspi или Halyk в PDF загрузится в «Деньги», когда вы откроете A-san. Повторы не добавляются.")
    static var openAppWhenRun = false

    @Parameter(title: "Выписка", supportedContentTypes: [.pdf]) var file: IntentFile

    func perform() async throws -> some IntentResult {
        try BankStatementInbox.standard().add(data: file.data, name: file.filename)
        return .result()
    }
}
