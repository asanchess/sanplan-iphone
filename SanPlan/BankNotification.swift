import Foundation

/// A bank's notification as the iOS 27 Shortcuts automation «When I get a notification from <app>» hands it over
/// (docs/finance/BANK-AUTO-IMPORT.md): a purchase, a cash withdrawal, a transfer out or money that came in.
/// Kaspi and Halyk do not publish their wording, so this reads keywords and the tenge amount, and keeps what it cannot
/// place for the owner to look at. Codes, passwords, adverts and declined payments are never kept.
public enum BankNotification {
    public enum Reading: Equatable {
        case operation(BankFeed.Tap)
        /// Money is mentioned, but not what happened to it.
        case review(bank: String?)
        case ignore
    }

    enum Operation: Equatable {
        case purchase
        case cash
        case transferOut
        case income(transfer: Bool)
    }

    /// `app` is the app the notification came from («Kaspi.kz», «Homebank»), `time` the local time it arrived.
    public static func read(app: String, text raw: String, time: String) -> Reading {
        let text = raw.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        let lower = text.lowercased()
        if matches(secretPattern, lower) || declinedWords.contains(where: { lower.contains($0) }) || hasWord(promoWords, lower) {
            return .ignore
        }
        let bank = BankFeed.knownBank(in: app) ?? BankFeed.knownBank(in: text)
        var found = Self.operation(in: lower)
        guard let amount = tengeAmount(in: text) else {
            return found != nil ? .review(bank: bank) : .ignore
        }
        if amount.sign == "+" { found = .income(transfer: lower.contains("перевод")) }
        guard let operation = found, let bank else { return .review(bank: bank) }
        var tap = BankFeed.Tap(amount: amount.number + " ₸", merchant: merchant(in: text, around: amount.range),
                               card: bank, time: time, source: BankFeed.Tap.notificationSource)
        switch operation {
        case .purchase: tap.operation = "Покупка"
        case .cash: tap.operation = "Снятие"
        case .transferOut: tap.operation = "Перевод"
        case .income(let transfer):
            tap.kind = "income"
            tap.operation = transfer ? "Перевод" : "Пополнение"
        }
        return .operation(tap)
    }

    // MARK: - Words

    /// A one-time code or a password: such a notification is dropped whole, amount or not.
    /// «QR-коду» and «кодекс» are not codes.
    static let secretPattern = #"(?<![а-яёa-z-])(код(?!екс)|code(?![a-z])|парол|password|otp|cvv|cvc)"#
    static let declinedWords = ["отклон", "недостаточно", "отказ", "не прошл", "не выполн", "неуспеш", "не удалось"]
    /// Adverts mention amounts too («рассрочка на покупки от 50 000 ₸»). Bonuses are not here: a purchase notification
    /// may name the bonuses it earned.
    static let promoWords = ["скидк", "акци", "рассрочк", "розыгрыш", "выгодн", "предлагаем", "успейте", "только до", "дарим"]
    /// «Пополнение» alone is also a phone top-up, which is a payment, so it is not here.
    static let incomeWords = ["вы получили", "получен перевод", "входящий перевод", "перевод получен", "перевод от",
                              "вам перевели", "вам отправили", "зачислен", "поступлен", "поступил", "возврат", "отмена",
                              "пополнена", "пополнен на", "пополнение карты", "пополнение счет", "пополнение счёт",
                              "пополнение gold", "зарплат"]
    static let cashWords = ["снятие", "снятия", "сняли", "наличн", "банкомат", "atm"]
    /// Only a transfer that says it went out. «Перевод 5 000 ₸» alone could be either way and waits for the owner.
    static let transferWords = ["вы перевели", "вы отправили", "перевод на", "перевод отправлен", "отправлен", "перевели"]
    static let purchaseWords = ["покупка", "оплат", "списан", "платеж", "платёж", "погашени", "purchase", "payment"]

    static func operation(in lower: String) -> Operation? {
        if incomeWords.contains(where: { lower.contains($0) }) { return .income(transfer: lower.contains("перевод")) }
        if hasWord(cashWords, lower) { return .cash }
        if transferWords.contains(where: { lower.contains($0) }) { return .transferOut }
        if lower.contains("перевод") { return nil }
        if purchaseWords.contains(where: { lower.contains($0) }) { return .purchase }
        return nil
    }

    // MARK: - The amount

    struct Amount {
        let number: String
        let sign: String
        let range: Range<String.Index>
    }

    /// «1 500», «1 500,00», «1,500.00», «990»: never the tail of a card number («*1234 500 ₸» reads 500).
    private static let number = #"(?<![\d*.,])(\d{1,3}(?:[ ,]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?!\d)"#
    private static let amountRegex = try! NSRegularExpression(
        pattern: #"([+\-−]?) ?(?:₸|kzt) ?"# + number + "|" + #"([+\-−]?) ?"# + number + #" ?(?:₸|тг(?![а-яё])|тенге|kzt)"#,
        options: [.caseInsensitive]
    )
    /// Words before an amount that make it a balance or a limit, not the operation.
    static let balanceWords = ["доступн", "остат", "баланс", "лимит", "бонус", "кэшбэк", "кешбэк", "cashback", "задолж"]

    /// The first tenge amount that is not a balance: «Покупка 1 500 ₸ … Доступно 9 000 ₸» → «1 500».
    static func tengeAmount(in text: String) -> Amount? {
        let all = NSRange(text.startIndex..., in: text)
        for match in amountRegex.matches(in: text, range: all) {
            let first = match.range(at: 2).location != NSNotFound
            guard let whole = Range(match.range, in: text),
                  let digits = Range(match.range(at: first ? 2 : 4), in: text),
                  let signRange = Range(match.range(at: first ? 1 : 3), in: text) else { continue }
            if isBalance(before: whole.lowerBound, in: text) { continue }
            let sign = text[signRange] == "+" ? "+" : (text[signRange].isEmpty ? "" : "-")
            return Amount(number: String(text[digits]), sign: sign, range: whole)
        }
        return nil
    }

    private static func isBalance(before index: String.Index, in text: String) -> Bool {
        var window = String(text[..<index].suffix(30)).lowercased()
        if let cut = window.lastIndex(where: { ".,;!\n|".contains($0) }) {
            window = String(window[window.index(after: cut)...])
        }
        return balanceWords.contains(where: { window.contains($0) })
    }

    // MARK: - Who was paid

    /// Where a merchant's name stops: the balance, the card, a status word, the next sentence.
    static let stopWords = ["доступн", "остат", "баланс", " с карты", "картой", "карта ", "карты ", "*", "\n", ". ",
                            "отправлен", "выполнен", "успешн", "зачислен", "получен"]

    /// «Покупка 1 500 ₸ в MAGNUM. Доступно …» → «MAGNUM»; «Перевод от Т. Марина: 5 000 ₸» → «Т. Марина».
    static func merchant(in text: String, around amount: Range<String.Index>) -> String {
        let after = clean(String(text[amount.upperBound...]))
        if !after.isEmpty { return after }
        let before = String(text[..<amount.lowerBound].split(separator: "\n").last ?? "")
        for preposition in [" в ", " от ", " у "] {
            if let found = before.range(of: preposition, options: [.caseInsensitive, .backwards]) {
                return clean(String(before[found.upperBound...]))
            }
        }
        return ""
    }

    private static func clean(_ raw: String) -> String {
        var text = raw
        if let cut = stopWords.compactMap({ raw.range(of: $0, options: .caseInsensitive)?.lowerBound }).min() {
            text = String(raw[..<cut])
        }
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":;,.-—–"))
        text = text.trimmingCharacters(in: edges)
        for preposition in ["в ", "на ", "от ", "у "] where text.lowercased().hasPrefix(preposition) {
            text = String(text.dropFirst(preposition.count)).trimmingCharacters(in: edges)
        }
        return String(text.prefix(60))
    }

    /// A word starting with one of the stems: «акци» is not inside «транзакция», «atm» not inside «katmandu».
    static func hasWord(_ stems: [String], _ lower: String) -> Bool {
        stems.contains { stem in matches("(?<![а-яёa-z])" + NSRegularExpression.escapedPattern(for: stem), lower) }
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Bank notifications A-san could not place, kept on the phone for the owner to look at: the newest 30, only the text.
public struct BankNotificationReview {
    public struct Item: Codable, Equatable {
        public var bank: String?
        public var text: String
        public var time: String
    }

    public let folder: URL
    private let fileManager: FileManager
    static let limit = 30

    public init(folder: URL, fileManager: FileManager = .default) {
        self.folder = folder
        self.fileManager = fileManager
    }

    /// Next to the Apple Pay inbox (BankFeedInbox.standard()).
    public static func standard(fileManager: FileManager = .default) -> BankNotificationReview {
        let feed = BankFeedInbox.standard(fileManager: fileManager).folder
        return BankNotificationReview(folder: feed.deletingLastPathComponent().appendingPathComponent("bank-feed-review", isDirectory: true),
                                      fileManager: fileManager)
    }

    public func add(_ item: Item) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        var kept = item
        kept.text = String(item.text.prefix(300))
        let url = folder.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(kept).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let all = items()
        if all.count > Self.limit { remove(all.prefix(all.count - Self.limit).map { $0.url }) }
    }

    /// Oldest first.
    public func items() -> [(url: URL, item: Item)] {
        guard let urls = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let read: [(url: URL, item: Item)] = urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let item = try? JSONDecoder().decode(Item.self, from: data) else { return nil }
            return (url: url, item: item)
        }
        return read.sorted { $0.item.time < $1.item.time }
    }

    public func remove(_ urls: [URL]) {
        for url in urls { try? fileManager.removeItem(at: url) }
    }

    public func clear() {
        try? fileManager.removeItem(at: folder)
    }
}
