import Foundation

/// Purchases that reach A-san one at a time, without a statement: an Apple Pay payment handed over by a Shortcuts
/// automation (the Wallet «When I tap» trigger, see docs/finance/BANK-AUTO-IMPORT.md). Each becomes an expense of a
/// feed import, one per bank and day, so the statement pipeline treats it like any imported operation, and a later
/// statement of that bank replaces it with its own line. Nothing here touches the network.
public enum BankFeed {
    /// What the automation passes in, kept as text so an older inbox file always reads.
    public struct Tap: Codable, Equatable {
        public var amount: String
        public var merchant: String
        public var card: String
        /// Local time of the payment: «2026-11-18T14:05», or a date alone.
        public var time: String
        /// «income» for money that came in; nil (an Apple Pay payment) is an expense.
        public var kind: String?
        /// The bank's word for it: «Покупка», «Снятие», «Перевод», «Пополнение». Nil is a purchase.
        public var operation: String?
        /// «notification» for a bank notification read by BankNotification; nil is the Wallet automation.
        public var source: String?

        public init(amount: String, merchant: String, card: String, time: String,
                    kind: String? = nil, operation: String? = nil, source: String? = nil) {
            self.amount = amount
            self.merchant = merchant
            self.card = card
            self.time = time
            self.kind = kind
            self.operation = operation
            self.source = source
        }

        public static let notificationSource = "notification"
        var isIncome: Bool { kind == "income" }
        var fromNotification: Bool { source == Self.notificationSource }
    }

    public enum Outcome: Equatable {
        case added(recordId: String)
        /// A statement of that bank already has it (the trigger came late): kept with that statement, not shown twice.
        case inStatement(recordId: String)
        /// The same payment again.
        case duplicate
    }

    public enum TapError: LocalizedError, Equatable {
        case amount
        case time
        case currency

        public var errorDescription: String? {
            switch self {
            case .amount: return "Не удалось понять сумму оплаты."
            case .time: return "Не удалось понять дату оплаты."
            case .currency: return "Оплата не в тенге: запишите её в «Деньгах» вручную."
            }
        }
    }

    public static let importPrefix = "feed-"
    /// Shown as the «file» of a feed import in the list of statements.
    public static let source = "Apple Pay"
    /// The «file» of a feed import that began with a bank notification.
    public static let notificationsSource = "Уведомления банка"
    /// A payment inside a statement's period that the statement does not have: often a declined payment, which the
    /// Wallet trigger reports too.
    public static let missingNote = "Нет в выписке"

    public static func isFeed(_ importId: String?) -> Bool { importId?.hasPrefix(importPrefix) == true }

    // MARK: - Reading what the automation passes

    /// «₸1 500,00», «1 500 ₸», «KZT 1,500.00», «1.500,50» → minor units. A separator followed by one or two digits is
    /// the decimal one; any other separator groups thousands.
    public static func amountMinor(_ raw: String) -> Int64? {
        let kept = String(raw.filter { $0.isASCII && ($0.isNumber || $0 == "," || $0 == ".") })
        var whole = kept
        var fraction = ""
        if let last = kept.lastIndex(where: { $0 == "," || $0 == "." }) {
            let tail = kept[kept.index(after: last)...]
            if tail.count == 1 || tail.count == 2 {
                whole = String(kept[..<last])
                fraction = String(tail)
            }
        }
        let digits = whole.filter { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 12, let units = Int64(digits),
              let cents = Int64(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) else { return nil }
        let value = units * 100 + cents
        return value > 0 && value <= FinanceConstants.maxAmountMinor ? value : nil
    }

    /// «$4.99», «4,99 EUR»: a payment in another currency, which no tenge statement line would match.
    public static func isForeignCurrency(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        if lower.contains(where: { "$€£₽¥".contains($0) }) { return true }
        return ["usd", "eur", "rub", "gbp", "cny", "aed"].contains { lower.contains($0) }
    }

    /// «2026-11-18T14:05:31+05:00» → day «2026-11-18» and minute «2026-11-18T14:05». «18.11.2026, 14:05» reads too.
    static func moment(_ raw: String) -> (day: String, minute: String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let day: String
        if text.count >= 10, isValidDateString(String(text.prefix(10))) {
            day = String(text.prefix(10))
        } else if let first = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "T" }).first,
                  let iso = BankStatementParser.isoDate(String(first)) {
            day = iso
        } else {
            return nil
        }
        guard let clock = text.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) else { return (day, day) }
        return (day, day + "T" + String(text[clock]))
    }

    /// The time the intent stamps on a payment, in the phone's own time zone.
    public static func localTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    /// The bank a Wallet card belongs to, named as the statements name it, so a statement can find its payments.
    public static func bank(ofCard card: String) -> String {
        if let name = knownBank(in: card) { return name }
        let trimmed = card.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? source : String(trimmed.prefix(40))
    }

    /// The bank a card, an app («Kaspi.kz», «Homebank») or a text names, if it is one A-san knows.
    public static func knownBank(in text: String) -> String? {
        let lower = text.lowercased()
        return knownBanks.first(where: { bank in bank.words.contains(where: { lower.contains($0) }) })?.name
    }

    static let knownBanks: [(name: String, words: [String])] = [
        ("Kaspi", ["kaspi", "каспи"]),
        ("Halyk", ["halyk", "homebank", "халык", "народн"]),
        ("Freedom", ["freedom", "фридом"]),
        ("Jusan", ["jusan", "жусан"]),
        ("БЦК", ["bcc", "centercredit", "центркредит"]),
        ("Forte", ["forte", "форте"]),
        ("Bereke", ["bereke", "береке"]),
        ("Home Credit", ["home credit", "хоум кредит"]),
    ]

    // MARK: - Ids

    /// One feed import per bank and day.
    static func feedImportId(bank: String, day: String) -> String {
        importPrefix + slug(bank) + "-" + day
    }

    /// The same payment always gets the same id, so a repeated automation run adds nothing. The bank stays readable in
    /// it («feed-kaspi-…»), so a payment given back as a hand-entered record still finds its bank's next statement.
    static func recordId(bank: String, minute: String, amount: Int64, merchant: String) -> String {
        importPrefix + slug(bank) + "-" + hash("\(bank)|\(minute)|\(amount)|\(MerchantCategories.key(merchant))")
    }

    /// A bank notification's record: «feed-kaspi-n…». The «n» (never a hex digit) tells it from an Apple Pay payment,
    /// since the same purchase usually comes both ways.
    static func notificationRecordId(bank: String, minute: String, kind: String, amount: Int64, merchant: String) -> String {
        importPrefix + slug(bank) + "-" + notificationMark
            + hash("\(bank)|\(minute)|\(kind)|\(amount)|\(MerchantCategories.key(merchant))")
    }

    static let notificationMark = "n"

    /// «p0905»: the sort of a feed record and its minute of the day, kept at the end of its id, so neither depends on a
    /// category the owner may change later. The letters are never hex digits; «9999» is a payment with no clock.
    static func idTail(_ sort: Sort, minute: String) -> String {
        let letter: String
        switch sort {
        case .purchase: letter = "p"
        case .cash: letter = "k"
        case .transferOut: letter = "o"
        case .income: letter = "i"
        }
        var clock = 9999
        if minute.count >= 16, let h = Int(minute.dropFirst(11).prefix(2)), let m = Int(minute.dropFirst(14).prefix(2)) {
            clock = h * 60 + m
        }
        return letter + String(format: "%04d", clock)
    }

    /// The sort and minute of the day a feed record's id ends with; nil for records made before ids had them.
    static func tail(ofRecordId id: String) -> (sort: Sort, clock: Int?)? {
        guard isFeed(id), id.count > 5 else { return nil }
        let end = id.suffix(5)
        guard let letter = end.first, let clock = Int(end.dropFirst()) else { return nil }
        let sort: Sort
        switch letter {
        case "p": sort = .purchase
        case "k": sort = .cash
        case "o": sort = .transferOut
        case "i": sort = .income
        default: return nil
        }
        return (sort, clock == 9999 ? nil : clock)
    }

    static func sort(ofTap tap: Tap) -> Sort {
        if tap.isIncome { return .income }
        switch tap.operation {
        case "Снятие": return .cash
        case "Перевод": return .transferOut
        default: return .purchase
        }
    }

    /// Minutes since 1970 of a feed record, when its id has the clock.
    static func minuteOf(_ r: FinanceRecord) -> Int? {
        guard let day = dayNumber(r.date), let clock = tail(ofRecordId: r.id)?.clock else { return nil }
        return day * 1440 + clock
    }

    static func isNotificationRecord(_ id: String) -> Bool {
        guard isFeed(id), let dash = id.lastIndex(of: "-") else { return false }
        return id[id.index(after: dash)...].hasPrefix(notificationMark)
    }

    /// «feed-kaspi-0123…» → «kaspi».
    static func bankSlug(ofRecordId id: String) -> String? {
        guard id.hasPrefix(importPrefix), let dash = id.lastIndex(of: "-") else { return nil }
        let start = id.index(id.startIndex, offsetBy: importPrefix.count)
        guard start < dash else { return nil }
        return String(id[start..<dash])
    }

    static func slug(_ text: String) -> String {
        let ascii = String(text.lowercased().unicodeScalars
            .filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            .map { Character($0) })
        return ascii.isEmpty ? String(hash(text).prefix(8)) : String(ascii.prefix(24))
    }

    /// FNV-1a, the same on every device and every launch (unlike `Hasher`).
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", value)
    }

    // MARK: - Into money

    /// Adds one payment as an expense, unless it is already there: the same payment again, or a statement of its
    /// bank that covers the day and has it (the Wallet trigger can be hours late).
    public static func ingest(_ tap: Tap, into state: FinanceState, today: String) throws -> (state: FinanceState, outcome: Outcome) {
        if isForeignCurrency(tap.amount) { throw TapError.currency }
        guard let amount = amountMinor(tap.amount) else { throw TapError.amount }
        guard let when = moment(tap.time) else { throw TapError.time }
        var next = try validateFinance(state)
        let bankName = bank(ofCard: tap.card)
        let merchant = tap.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = tap.isIncome ? "income" : "expense"
        let operation = tap.operation ?? "Покупка"
        let tail = idTail(sort(ofTap: tap), minute: when.minute)
        let id = (tap.fromNotification
            ? notificationRecordId(bank: bankName, minute: when.minute, kind: kind, amount: amount, merchant: merchant)
            : recordId(bank: bankName, minute: when.minute, amount: amount, merchant: merchant)) + tail

        let replacedEarlier = (next.imports ?? []).contains { item in (item.mergedManual ?? []).contains { $0.id == id } }
        if next.records.contains(where: { $0.id == id }) || replacedEarlier {
            return (next, .duplicate)
        }
        let feedId = feedImportId(bank: bankName, day: when.day)
        let title = merchant.isEmpty ? operation : merchant
        var record = FinanceRecord(
            id: id,
            kind: kind,
            title: String(title.prefix(FinanceConstants.maxTitleLen)),
            amountMinor: amount,
            date: when.day,
            category: MerchantCategories.category(operation: operation, merchant: merchant, incoming: tap.isIncome, rules: next.merchantCategories)
        )
        record.importId = feedId
        record.merchant = merchant.isEmpty ? nil : String(merchant.prefix(FinanceConstants.maxTitleLen))

        if cameOtherWay(record, in: next) {
            return (next, .duplicate)
        }
        if let index = statementHolding(record, bank: bankName, in: next) {
            // Kept with the statement like a replaced payment: counted there, given back if the statement is deleted.
            record.importId = nil
            let merged = next.imports?[index].mergedManual ?? []
            next.imports?[index].mergedManual = merged + [record]
            let clean = try validateFinance(next)
            return (clean, .inStatement(recordId: id))
        }

        var imports = next.imports ?? []
        if let index = imports.firstIndex(where: { $0.id == feedId }) {
            imports[index].count += 1
        } else {
            let label = tap.fromNotification ? notificationsSource : source
            imports.append(FinanceImport(id: feedId, bank: bankName, fileName: label, periodStart: when.day, periodEnd: when.day, importedAt: today, count: 1))
        }
        next.imports = imports
        next.records.append(record)
        let clean = try validateFinance(next)
        return (clean, .added(recordId: id))
    }

    /// The same purchase already came the other way: an Apple Pay payment and the bank's notification about it.
    /// Of that bank, amount and sort within ten minutes, the other way has more than this way, so this one is its
    /// double. Two equal coffees paid both ways stay two; a QR payment of the same sum later in the day stays too.
    static let twinMinutes = 10

    static func cameOtherWay(_ record: FinanceRecord, in state: FinanceState) -> Bool {
        guard sort(of: record) == .purchase, let slug = bankSlug(ofRecordId: record.id), let at = minuteOf(record) else { return false }
        let mine = isNotificationRecord(record.id)
        let kept = state.records + (state.imports ?? []).flatMap { $0.mergedManual ?? [] }
        let same = kept.filter { r in
            guard isFeedRecord(r), bankSlug(ofRecordId: r.id) == slug, r.amountMinor == record.amountMinor,
                  sort(of: r) == .purchase, let m = minuteOf(r) else { return false }
            return abs(m - at) <= twinMinutes
        }
        let otherWay = same.filter { isNotificationRecord($0.id) != mine }.count
        return otherWay > same.count - otherWay
    }

    /// The statement of that bank that has this payment: it covers the day (or the day before its first, since the
    /// bank may book a late payment the next day) and has more lines of this amount and sort within a day than
    /// payments it already took. Two equal coffees stay two once one of them was taken.
    static func statementHolding(_ record: FinanceRecord, bank: String, in state: FinanceState) -> Int? {
        guard let target = dayNumber(record.date), let wanted = sort(of: record) else { return nil }
        func near(_ r: FinanceRecord) -> Bool {
            guard sort(of: r) == wanted, r.amountMinor == record.amountMinor, let d = dayNumber(r.date) else { return false }
            return abs(d - target) <= 1
        }
        for (index, statement) in (state.imports ?? []).enumerated() where !isFeed(statement.id) && statement.bank == bank {
            guard let days = Self.dayRange(of: statement, in: state), days.contains(target) else { continue }
            let lines = state.records.filter { $0.importId == statement.id && canStandFor($0, wanted) && near($0) }.count
            let taken = (statement.mergedManual ?? []).filter { isFeedRecord($0) && near($0) }.count
            if lines > taken { return index }
        }
        return nil
    }

    /// What a payment or a statement line is, so a purchase never stands for a transfer of the same amount.
    enum Sort: Equatable {
        case purchase
        case cash
        case transferOut
        case income
    }

    static func sort(of r: FinanceRecord) -> Sort? {
        if isFeedRecord(r), ["income", "expense"].contains(r.kind), let tail = tail(ofRecordId: r.id) { return tail.sort }
        switch r.kind {
        case "income": return .income
        case "expense":
            switch r.category ?? "" {
            case "Наличные": return .cash
            case "Переводы", "Пополнения", "Люди": return .transferOut
            default: return .purchase
            }
        default: return nil
        }
    }

    /// A statement line that can take a payment's place: of the same sort, and for a purchase not one the statement
    /// left out of the totals. A transfer between own accounts is left out and still is the one a notification told of.
    static func canStandFor(_ line: FinanceRecord, _ wanted: Sort) -> Bool {
        guard sort(of: line) == wanted else { return false }
        return wanted == .purchase ? isPurchaseLine(line) : true
    }

    /// A statement line an Apple Pay payment can be: not a transfer, a cash withdrawal or a top-up.
    static func isPurchaseLine(_ r: FinanceRecord) -> Bool {
        r.kind == "expense" && r.excluded != true && r.pairedWith == nil
            && !["Переводы", "Наличные", "Пополнения", "Люди", "Комиссии"].contains(r.category ?? "")
    }

    /// After a statement is applied: each Apple Pay payment of the same bank that the statement also has gives way to
    /// the statement's line. The owner's category and note move over; the payment is kept with the statement, so
    /// deleting the statement brings it back. A payment inside the period that the statement lacks gets a note.
    @discardableResult
    public static func reconcile(_ state: inout FinanceState, statementImportId: String) -> Int {
        guard !isFeed(statementImportId),
              let statementIndex = state.imports?.firstIndex(where: { $0.id == statementImportId }),
              let statement = state.imports?[statementIndex],
              let period = Self.dayRange(of: statement, in: state) else { return 0 }
        let statementSlug = slug(statement.bank)
        var used = Set<String>()
        var replaced: [FinanceRecord] = []
        for i in state.records.indices {
            let feed = state.records[i]
            // A payment still in its feed import, or one a deleted statement gave back as a hand-entered record.
            guard let wanted = sort(of: feed), isFeedRecord(feed), feed.importId == nil || isFeed(feed.importId),
                  bankSlug(ofRecordId: feed.id) == statementSlug,
                  let day = dayNumber(feed.date), period.contains(day) else { continue }
            let candidates = state.records.indices.filter { j in
                let r = state.records[j]
                guard r.importId == statementImportId, canStandFor(r, wanted), r.amountMinor == feed.amountMinor,
                      !used.contains(r.id), let d = dayNumber(r.date) else { return false }
                return abs(d - day) <= 1
            }
            guard let j = candidates.min(by: { distance(state.records[$0], feed, day) < distance(state.records[$1], feed, day) }) else {
                // Not on the statement's last day (it may have been printed before the payment), nor on the day before
                // its first (that payment belongs to the previous statement).
                if day > period.lowerBound, day < period.upperBound, feed.note == nil { state.records[i].note = missingNote }
                continue
            }
            used.insert(state.records[j].id)
            let automatic = MerchantCategories.category(operation: "Покупка", merchant: feed.merchant ?? "", incoming: false, rules: state.merchantCategories)
            if wanted == .purchase, let category = feed.category, category != automatic, category != "Без категории" {
                state.records[j].category = category
            }
            if let note = feed.note, note != missingNote, state.records[j].note == nil {
                state.records[j].note = note
            }
            replaced.append(feed)
        }
        guard !replaced.isEmpty else { return 0 }
        let gone = Set(replaced.map(\.id))
        state.records.removeAll { gone.contains($0.id) }
        // Given back as hand-entered records if the statement is deleted; their ids still stop a repeated run.
        let kept = replaced.map { record -> FinanceRecord in
            var copy = record
            copy.importId = nil
            if copy.note == missingNote { copy.note = nil }
            return copy
        }
        state.imports?[statementIndex].mergedManual = (statement.mergedManual ?? []) + kept
        for index in (state.imports ?? []).indices {
            guard let id = state.imports?[index].id, isFeed(id) else { continue }
            state.imports?[index].count = state.records.filter { $0.importId == id }.count
        }
        return replaced.count
    }

    /// A payment record made here, also after a statement replaced it.
    static func isFeedRecord(_ r: FinanceRecord) -> Bool { r.id.hasPrefix(importPrefix) }

    /// The statement's period, or the days of its lines when the bank printed none.
    static func span(of statement: FinanceImport, in state: FinanceState) -> (start: String, end: String)? {
        if let start = statement.periodStart, let end = statement.periodEnd { return (start, end) }
        let days = state.records.filter { $0.importId == statement.id }.compactMap(\.date)
        guard let first = days.min(), let last = days.max() else { return nil }
        return (first, last)
    }

    /// The days a statement speaks for: its period, and the day before it for payments the bank booked a day late.
    static func dayRange(of statement: FinanceImport, in state: FinanceState) -> ClosedRange<Int>? {
        guard let period = Self.span(of: statement, in: state),
              let first = dayNumber(period.start), let last = dayNumber(period.end), first <= last else { return nil }
        return (first - 1)...last
    }

    static func dayNumber(_ ymd: String?) -> Int? {
        guard let ymd, let (y, m, d) = parseYmd(ymd) else { return nil }
        return daysSinceEpoch(year: y, month: m, day: d)
    }

    /// Lower is a better match: the same day first, then a shared word in the merchant («MAGNUM CASH&CARRY» and «Magnum»).
    private static func distance(_ line: FinanceRecord, _ feed: FinanceRecord, _ day: Int) -> Int {
        let gap = abs((dayNumber(line.date) ?? day) - day)
        let a = Set(MerchantCategories.key(line.merchant ?? line.title).split(separator: " "))
        let b = Set(MerchantCategories.key(feed.merchant ?? feed.title).split(separator: " "))
        return gap * 2 + (a.isDisjoint(with: b) ? 1 : 0)
    }
}

/// Payments the Shortcuts action handed over, waiting until money is open: one small file each, so a payment
/// written while the app takes the folder in is never lost. On the phone only, protected like the money file.
public struct BankFeedInbox {
    public let folder: URL
    private let fileManager: FileManager

    public init(folder: URL, fileManager: FileManager = .default) {
        self.folder = folder
        self.fileManager = fileManager
    }

    /// The folder next to the money files, the same one `FinanceStore.bankFeedInbox` reads.
    public static func standard(fileManager: FileManager = .default) -> BankFeedInbox {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return BankFeedInbox(folder: appSupport.appendingPathComponent("ARNA", isDirectory: true)
            .appendingPathComponent("bank-feed-inbox", isDirectory: true), fileManager: fileManager)
    }

    public func add(_ tap: BankFeed.Tap) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        let url = folder.appendingPathComponent(UUID().uuidString + ".json")
        // Readable after the first unlock: the automation may run while the phone is locked again.
        try JSONEncoder().encode(tap).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Waiting payments, oldest first. A file that cannot be read now (phone locked) is left for later.
    public func pending() -> [(url: URL, tap: BankFeed.Tap)] {
        guard let urls = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let items: [(url: URL, tap: BankFeed.Tap)] = urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let tap = try? JSONDecoder().decode(BankFeed.Tap.self, from: data) else { return nil }
            return (url: url, tap: tap)
        }
        return items.sorted { $0.tap.time < $1.tap.time }
    }

    public func remove(_ urls: [URL]) {
        for url in urls { try? fileManager.removeItem(at: url) }
    }

    public func clear() {
        try? fileManager.removeItem(at: folder)
    }
}
