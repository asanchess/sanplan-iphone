import Foundation
import PDFKit

/// A bank statement read on the phone. Nothing here touches the network.
public struct ParsedStatement: Equatable {
    public enum Bank: String, Codable, Equatable {
        case kaspi = "Kaspi"
        case halyk = "Halyk"
    }

    public struct Transaction: Equatable {
        public var date: String
        /// Positive for money in, negative for money out.
        public var amountMinor: Int64
        /// The bank's operation type, e.g. «Покупка» or «Перевод».
        public var operation: String
        public var details: String

        public init(date: String, amountMinor: Int64, operation: String, details: String) {
            self.date = date
            self.amountMinor = amountMinor
            self.operation = operation
            self.details = details
        }
    }

    public var bank: Bank
    public var periodStart: String?
    public var periodEnd: String?
    public var closingBalance: (date: String, amountMinor: Int64)?
    public var transactions: [Transaction]
    /// The last four characters of the account number, to tell two accounts at one bank apart.
    public var account: String? = nil
    /// The owner's first name from the header; the bank shows transfers from the owner's other accounts with it.
    /// Kept in memory for the import only, never saved.
    public var ownerFirstName: String? = nil

    public static func == (lhs: ParsedStatement, rhs: ParsedStatement) -> Bool {
        lhs.bank == rhs.bank && lhs.periodStart == rhs.periodStart && lhs.periodEnd == rhs.periodEnd
            && lhs.closingBalance?.date == rhs.closingBalance?.date
            && lhs.closingBalance?.amountMinor == rhs.closingBalance?.amountMinor
            && lhs.transactions == rhs.transactions && lhs.account == rhs.account
    }
}

public enum StatementError: LocalizedError, Equatable {
    case unreadable
    case unknownBank
    case noTransactions
    case alreadyImported

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "Не удалось прочитать PDF. Нужна выписка в виде текста, а не скан."
        case .unknownBank: return "Это не похоже на выписку Kaspi или Halyk."
        case .noTransactions: return "В выписке не нашлось операций."
        case .alreadyImported: return "Эта выписка уже загружена: все её операции уже есть."
        }
    }
}

public enum BankStatementParser {
    /// The text of every page, in order.
    public static func text(ofPDFAt url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { throw StatementError.unreadable }
        return try text(of: document)
    }

    public static func text(of document: PDFDocument) throws -> String {
        var pages: [String] = []
        for index in 0..<document.pageCount {
            if let page = document.page(at: index)?.string { pages.append(page) }
        }
        let text = pages.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StatementError.unreadable }
        return text
    }

    /// PDF text extraction can return lookalike glyphs (Latin «ĸ» for Cyrillic «к») and odd spaces; parse a clean copy.
    static func normalise(_ text: String) -> String {
        var result = text.precomposedStringWithCompatibilityMapping
        for (from, to) in [("ĸ", "к"), ("\u{00A0}", " "), ("\u{202F}", " "), ("\u{2007}", " "), ("\u{2009}", " "), ("\u{2212}", "-"), ("\u{2013}", "-")] {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    /// Every line joined with single spaces. The PDFs put each table cell on its own line (or a whole row on one),
    /// and either way a row reads the same once flattened.
    static func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func parse(_ raw: String) throws -> ParsedStatement {
        let text = flat(normalise(raw))
        // The bank named first is the header; later mentions are counterparties, e.g. a Halyk transfer to a Kaspi card.
        let lower = text.lowercased()
        func firstIndex(_ words: [String]) -> String.Index? {
            words.compactMap { lower.range(of: $0)?.lowerBound }.min()
        }
        let kaspi = firstIndex(["kaspi"])
        let halyk = firstIndex(["halyk", "народный банк"])
        let statement: ParsedStatement
        switch (kaspi, halyk) {
        case let (k?, h?): statement = k < h ? parseKaspi(text) : parseHalyk(text)
        case (_?, nil): statement = parseKaspi(text)
        case (nil, _?): statement = parseHalyk(text)
        case (nil, nil): throw StatementError.unknownBank
        }
        guard !statement.transactions.isEmpty else { throw StatementError.noTransactions }
        return statement
    }

    /// «2 500,00», «1 234 567,89».
    static let number = #"\d{1,3}(?: \d{3})*[.,]\d{2}"#
    static let date = #"\d{2}\.\d{2}\.\d{2,4}"#

    // MARK: - Kaspi Gold
    // Cells: «07.11.26» «- 500,00 ₸» «Покупка      Beeline». Two-line operations put the details between their halves:
    // «Поступление со      С Kaspi Депозита» «своего счета». Header: «за период с 01.11.25 по 30.11.25», «Доступно на 30.11.25: + 10 000,00 ₸».

    static let kaspiNoise = [
        #"АО «Kaspi Bank», БИК CASPKZKA, www\.kaspi\.kz"#,
        #"Приложение к Справке (?:№|No)\s?\d+ от \d{1,2} \S+ \d{4}"#,
        #"Дата Сумма Операция Детали"#,
        #"\(\s?[+\-]\s?\d[\d ]*[.,]\d{2} [A-Z]{3}\)"#,
        #"-? ?Сумма заблокирована\. Банк ожидает подтверждения от платежной системы\."#,
        #"Раздел «Краткое содержание операций по карте».*$"#,
    ]

    static func parseKaspi(_ text: String) -> ParsedStatement {
        var body = text
        for pattern in kaspiNoise {
            body = regex(pattern).stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: " ")
        }
        body = flat(body)
        // «Доступно на 07.11.25 + 3 756,34 ₸» in the summary is not an operation.
        let row = regex(#"(?<!Доступно на )(\d{2}\.\d{2}\.\d{2,4}) ([+\-]) ?("# + number + #") ?(?:₸|KZT|тг|т)(?![\p{L}]) ?(.*?)(?= \d{2}\.\d{2}\.\d{2,4} [+\-] ?\d|$)"#)
        var transactions: [ParsedStatement.Transaction] = []
        for m in matches(row, body) {
            guard let date = isoDate(m[1]), let amount = minor(m[3]), amount > 0 else { continue }
            let (operation, details) = splitKaspiBody(m[4].trimmingCharacters(in: .whitespaces))
            transactions.append(.init(date: date, amountMinor: m[2] == "+" ? amount : -amount, operation: operation, details: details))
        }
        let period = match(regex(#"(?:период|period)\D{0,30}("# + date + #")\D{1,8}("# + date + #")"#), text)
        var closing: (String, Int64)?
        if let m = match(regex(#"Доступно на ("# + date + #"):? ?([+\-]?) ?("# + number + #")"#), text),
           let date = isoDate(m[1]), let amount = minor(m[3]) {
            closing = (date, m[2] == "-" ? -amount : amount)
        }
        return ParsedStatement(
            bank: .kaspi,
            periodStart: period.flatMap { isoDate($0[1]) },
            periodEnd: period.flatMap { isoDate($0[2]) },
            closingBalance: closing.map { (date: $0.0, amountMinor: $0.1) },
            transactions: transactions,
            account: accountSuffix(text),
            ownerFirstName: match(regex(#"подтверждает, что (\p{L}+) (\p{L}+)"#), text)?[2]
        )
    }

    static func splitKaspiBody(_ body: String) -> (String, String) {
        for (head, tail) in [("Поступление со", "своего счета"), ("Перевод на свой", "счет")] where body == head || body.hasPrefix(head + " ") {
            var rest = String(body.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix(tail) {
                rest = String(rest.dropFirst(tail.count))
            } else if rest.hasSuffix(" " + tail) || rest == tail {
                rest = String(rest.dropLast(tail.count))
            }
            return (head + " " + tail, rest.trimmingCharacters(in: .whitespaces))
        }
        for op in ["Покупка", "Пополнение", "Перевод", "Снятие", "Разное", "Платеж", "Платёж", "Оплата"] where body.hasPrefix(op) {
            return (op == "Платёж" ? "Платеж" : op, body.dropFirst(op.count).trimmingCharacters(in: .whitespaces))
        }
        return ("Операция", body)
    }

    // MARK: - Halyk
    // Cells: operation date, processing date, description (several lines), amount, currency, then in the account
    // currency credit, debit (with minus), fee, and the card or account. «Closing balance: 195 400,00». English or Russian.

    static func parseHalyk(_ text: String) -> ParsedStatement {
        let currency = #"(?:KZT|USD|EUR|RUB|GBP|CNY|TRY|AED|UZS|KGS|HKD|₸|тг)(?![\p{L}])"#
        let signed = #"[+\-]? ?"# + number
        let row = regex(
            #"(\d{2}\.\d{2}\.\d{4}) \d{2}\.\d{2}\.\d{4} (?:\d{2}:\d{2}(?::\d{2})? )?((?:(?!\d{2}\.\d{2}\.\d{4} ).){1,240}?) ("#
                + signed + #") ?"# + currency + #"(?: ("# + signed + #") ("# + signed + #") ("# + signed + #")(?![\d,]))?"#
        )
        var transactions: [ParsedStatement.Transaction] = []
        for m in matches(row, text) {
            guard let date = isoDate(m[1]), let amount = signedMinor(m[3]) else { continue }
            let (operation, details, incoming) = splitHalykDescription(m[2].trimmingCharacters(in: .whitespaces))
            var value: Int64
            if let credit = signedMinor(m[4]), let debit = signedMinor(m[5]), let fee = signedMinor(m[6]) {
                // Account-currency columns: the debit already includes conversion; the fee is charged on top.
                value = credit - abs(debit) - abs(fee)
            } else if m[3].contains(where: { "+-".contains($0) }) {
                value = amount
            } else {
                value = incoming ? abs(amount) : -abs(amount)
            }
            guard value != 0 else { continue }
            transactions.append(.init(date: date, amountMinor: value, operation: operation, details: details))
        }
        let period = match(regex(#"(?:период|period)\D{0,30}(\d{2}\.\d{2}\.\d{4})\D{1,8}(\d{2}\.\d{2}\.\d{4})"#), text)
        var closing: (String, Int64)?
        if let m = match(regex(#"(?:Closing balance|Остаток на конец периода|Исходящий остаток|Доступный остаток)[^\d\-+]{0,40}("# + signed + #")"#), text),
           let amount = signedMinor(m[1]),
           let end = period.flatMap({ isoDate($0[2]) }) ?? transactions.map(\.date).max() {
            closing = (end, amount)
        }
        return ParsedStatement(
            bank: .halyk,
            periodStart: period.flatMap { isoDate($0[1]) },
            periodEnd: period.flatMap { isoDate($0[2]) },
            closingBalance: closing.map { (date: $0.0, amountMinor: $0.1) },
            transactions: transactions,
            account: accountSuffix(text),
            ownerFirstName: match(regex(#"Name: (\p{L}+) \p{L}+"#), text)?[1]
        )
    }

    /// Details Halyk gives to transfers between cards, which carry no counterparty.
    public static let halykTransferDetails: Set<String> = ["Входящий перевод", "Перевод на другую карту", "Перевод со счёта"]

    /// Prefix, operation, details when the bank gives none, and whether money comes in (used only without columns).
    private static let halykOperations: [(String, String, String, Bool)] = [
        ("Merchant payment transaction", "Покупка", "Покупка", false),
        ("Merchant payment", "Покупка", "Покупка", false),
        ("Receipt of transfer", "Перевод", "Входящий перевод", true),
        ("Transfer to another card", "Перевод", "Перевод на другую карту", false),
        ("OpenAPI перевод со счёта", "Перевод", "Перевод со счёта", false),
        ("Receipt to the account", "Пополнение", "Зачисление на счёт", true),
        ("Recharge card account through payment terminal", "Пополнение", "Пополнение через терминал", true),
        ("Cash withdrawal", "Снятие наличных", "Снятие наличных", false),
        ("Снятие наличных", "Снятие наличных", "Снятие наличных", false),
        ("Покупка", "Покупка", "Покупка", false),
        ("Оплата", "Оплата", "Оплата", false),
        ("Перевод", "Перевод", "Перевод", false),
        ("Пополнение", "Пополнение", "Пополнение", true),
        ("Снятие", "Снятие наличных", "Снятие наличных", false),
        ("Зачисление", "Зачисление", "Зачисление", true),
        ("Возврат", "Возврат", "Возврат", true),
        ("Комиссия", "Комиссия", "Комиссия", false),
        ("Платеж", "Платеж", "Платеж", false),
        ("Платёж", "Платеж", "Платеж", false),
    ]

    private static func splitHalykDescription(_ text: String) -> (String, String, Bool) {
        for (prefix, op, fallback, incoming) in halykOperations where text.lowercased().hasPrefix(prefix.lowercased()) {
            let rest = text.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: " :-—"))
            // A bare terminal number says nothing to the owner.
            let useful = rest.contains(where: \.isLetter) ? rest : ""
            return (op, useful.isEmpty ? fallback : useful, incoming)
        }
        return ("Операция", text, false)
    }

    // MARK: - Helpers

    /// «Номер счета: KZ00…0001» or «Account number KZT: KZ00…0002» → «0001».
    static func accountSuffix(_ text: String) -> String? {
        match(regex(#"(?:Номер счета|Номер счёта|Account number)[^:]{0,8}: ?(KZ[0-9A-Z]{18})"#), text).map { String($0[1].suffix(4)) }
    }

    /// «2 500,00» → 250000.
    static func minor(_ raw: String) -> Int64? {
        let digits = raw.filter { $0.isNumber || $0 == "," || $0 == "." }
        let parts = digits.replacingOccurrences(of: ",", with: ".").split(separator: ".")
        guard parts.count == 2, parts[1].count == 2, let whole = Int64(parts[0]), let cents = Int64(parts[1]) else { return nil }
        let value = whole * 100 + cents
        return value <= FinanceConstants.maxAmountMinor ? value : nil
    }

    static func signedMinor(_ raw: String) -> Int64? {
        guard let value = minor(raw) else { return nil }
        let negative = raw.trimmingCharacters(in: .whitespaces).first.map { "-−–".contains($0) } ?? false
        return negative ? -value : value
    }

    /// «05.11.25» or «05.11.2025» → «2025-11-05».
    static func isoDate(_ raw: String) -> String? {
        let parts = raw.split(separator: ".")
        guard parts.count == 3, let day = Int(parts[0]), let month = Int(parts[1]), var year = Int(parts[2]) else { return nil }
        if parts[2].count == 2 { year += 2000 }
        let value = String(format: "%04d-%02d-%02d", year, month, day)
        return isValidDateString(value) ? value : nil
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func groups(_ m: NSTextCheckingResult, _ text: String) -> [String] {
        (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func match(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { groups($0, text) }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [[String]] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { groups($0, text) }
    }
}

/// Turns a parsed statement into ARNA records and keeps them editable afterwards.
public enum StatementImport {
    public struct MergeSuggestion: Equatable, Identifiable {
        public var id: String { importedId + "|" + manualId }
        public let manualId: String
        public let importedId: String
    }

    public struct Preview: Equatable {
        public let statement: ParsedStatement
        public let records: [FinanceRecord]
        public let excludedCount: Int
    }

    /// The one balance checkpoint built from every statement's closing balance.
    public static let balanceRecordId = "statement-balance"

    /// Words in the details of a transfer between the owner's own accounts and cards.
    static let ownTransferMarkers = [
        "между своими счетами", "со своего счета", "со своего счёта", "на свой счет", "на свой счёт",
        "на свою карту", "со своей карты", "с kaspi депозита", "на kaspi депозит", "с депозита", "на депозит",
        "собственных средств", "своих средств", "own account", "между своими картами", "с kaspi gold", "на kaspi gold",
    ]

    public static func isOwnTransfer(_ t: ParsedStatement.Transaction, ownerFirstName: String? = nil) -> Bool {
        let text = (t.operation + " " + t.details).lowercased()
        return ownTransferMarkers.contains { text.contains($0) } || isFromOwnOtherBank(t.details, ownerFirstName: ownerFirstName)
    }

    /// «АРМАН Т., Halyk Bank»: the owner's name with another bank is money moving between the owner's own accounts.
    static func isFromOwnOtherBank(_ details: String, ownerFirstName: String?) -> Bool {
        guard let name = ownerFirstName?.lowercased(), name.count > 1 else { return false }
        let lower = details.lowercased()
        return lower.hasPrefix(name + " ") && lower.contains(",")
    }

    /// Records for a statement. Own-account transfers come in excluded from totals.
    public static func preview(_ statement: ParsedStatement, importId: String, rules: [String: String]?) -> Preview {
        var records: [FinanceRecord] = []
        var excluded = 0
        for (index, t) in statement.transactions.enumerated() where t.amountMinor != 0 {
            let merchant = t.details.isEmpty ? t.operation : t.details
            var record = FinanceRecord(
                id: "\(importId)-\(index)",
                kind: t.amountMinor > 0 ? "income" : "expense",
                title: String(merchant.prefix(FinanceConstants.maxTitleLen)),
                amountMinor: abs(t.amountMinor),
                date: t.date,
                category: MerchantCategories.category(operation: t.operation, merchant: merchant, incoming: t.amountMinor > 0, rules: rules)
            )
            record.importId = importId
            record.merchant = String(merchant.prefix(FinanceConstants.maxTitleLen))
            if isOwnTransfer(t, ownerFirstName: statement.ownerFirstName) {
                record.excluded = true
                excluded += 1
                if isFromOwnOtherBank(t.details, ownerFirstName: statement.ownerFirstName) {
                    record.note = ownTransferNote
                }
            }
            records.append(record)
        }
        return Preview(statement: statement, records: records, excludedCount: excluded)
    }

    public static func apply(_ preview: Preview, to state: FinanceState, importId: String, fileName: String, today: String) throws -> FinanceState {
        var next = try validateFinance(state)
        guard !(next.imports ?? []).contains(where: { $0.id == importId }) else { return next }
        let fresh = newRecords(preview, in: next)
        guard !fresh.isEmpty else { throw StatementError.alreadyImported }
        next.records.append(contentsOf: fresh)
        var imports = next.imports ?? []
        let closing = preview.statement.closingBalance
        imports.append(FinanceImport(
            id: importId,
            bank: preview.statement.bank.rawValue,
            fileName: String(fileName.prefix(FinanceConstants.maxTitleLen)),
            periodStart: preview.statement.periodStart,
            periodEnd: preview.statement.periodEnd,
            importedAt: today,
            count: fresh.count,
            closingMinor: closing?.amountMinor,
            closingDate: closing?.date,
            account: preview.statement.account
        ))
        next.imports = imports
        pairTransfersBetweenStatements(&next, importId: importId)
        rebuildBalance(&next)
        return try validateFinance(next)
    }

    /// Operations of the same account that an earlier statement already brought in (the same file again, or an
    /// overlapping period) are left out. Repeats are counted, so two equal purchases on one day both stay.
    static func newRecords(_ preview: Preview, in state: FinanceState) -> [FinanceRecord] {
        let bank = preview.statement.bank.rawValue
        let account = preview.statement.account
        let sameAccount = Set((state.imports ?? []).filter { $0.bank == bank && $0.account == account }.map(\.id))
        var seen: [String: Int] = [:]
        for record in state.records where record.importId.map({ sameAccount.contains($0) }) == true {
            seen[duplicateKey(record), default: 0] += 1
        }
        return preview.records.filter { record in
            let key = duplicateKey(record)
            guard let count = seen[key], count > 0 else { return true }
            seen[key] = count - 1
            return false
        }
    }

    private static func duplicateKey(_ r: FinanceRecord) -> String {
        "\(r.date ?? "")|\(r.kind)|\(r.amountMinor ?? 0)|\((r.merchant ?? r.title).lowercased())"
    }

    static let ownTransferNote = "Перевод между своими счетами"

    /// Money that leaves one of the owner's statements and arrives in another on the same or next day is a transfer
    /// between own accounts: both sides stay in the list but leave the totals.
    static func pairTransfersBetweenStatements(_ state: inout FinanceState, importId: String) {
        // Only sides that name no stranger: a Halyk card-to-card line, or a line the bank marked with the owner's name.
        func candidate(_ r: FinanceRecord) -> Bool {
            guard ["income", "expense"].contains(r.kind) else { return false }
            return BankStatementParser.halykTransferDetails.contains(r.merchant ?? "") || r.note == ownTransferNote
        }
        func day(_ ymd: String?) -> Int? {
            guard let ymd, let (y, m, d) = parseYmd(ymd) else { return nil }
            return daysSinceEpoch(year: y, month: m, day: d)
        }
        var taken = Set(state.records.compactMap(\.pairedWith))
        taken.formUnion(state.records.filter { $0.pairedWith != nil }.map(\.id))
        for i in state.records.indices where state.records[i].importId == importId {
            let record = state.records[i]
            guard !taken.contains(record.id), candidate(record), let recordDay = day(record.date) else { continue }
            let match = state.records.indices.first { j in
                let other = state.records[j]
                guard !taken.contains(other.id), let otherImport = other.importId, otherImport != importId,
                      other.kind != record.kind, candidate(other),
                      other.amountMinor == record.amountMinor, let otherDay = day(other.date) else { return false }
                return abs(otherDay - recordDay) <= 1
            }
            if let j = match {
                taken.insert(record.id)
                taken.insert(state.records[j].id)
                link(&state.records[i], to: state.records[j].id)
                link(&state.records[j], to: record.id)
            }
        }
    }

    /// A side the bank already marked as the owner's stays out of the totals on its own and keeps no partner.
    private static func link(_ record: inout FinanceRecord, to partner: String) {
        guard record.excluded != true else { return }
        record.excluded = true
        record.pairedWith = partner
        if record.note == nil { record.note = ownTransferNote }
    }

    /// One checkpoint: the sum of each statement's latest closing balance, dated at the latest of them, placed after
    /// the imported operations so ones on that day are already inside it.
    static func rebuildBalance(_ state: inout FinanceState) {
        state.records.removeAll { $0.id == balanceRecordId }
        let latestPerAccount = Dictionary(grouping: (state.imports ?? []).filter { $0.closingMinor != nil && $0.closingDate != nil }) {
            "\($0.bank)|\($0.account ?? "")"
        }.compactMap { $0.value.max { ($0.closingDate ?? "") < ($1.closingDate ?? "") } }
        guard !latestPerAccount.isEmpty else { return }
        // An overdrawn account lowers the sum. A balance below zero has no checkpoint in the money model, so none is set.
        let total = latestPerAccount.reduce(Int64(0)) { $0 + ($1.closingMinor ?? 0) }
        guard total >= 0 else { return }
        let date = latestPerAccount.compactMap(\.closingDate).max() ?? ""
        state.records.append(FinanceRecord(id: balanceRecordId, kind: "balance", title: "Остаток по выпискам", amountMinor: total, date: date))
    }

    /// Hand-entered records that look like the same operation as an imported one: same kind, date and amount.
    public static func mergeSuggestions(in state: FinanceState, importId: String) -> [MergeSuggestion] {
        let imported = state.records.filter { $0.importId == importId && ($0.kind == "income" || $0.kind == "expense") }
        var usedManual = Set<String>()
        var result: [MergeSuggestion] = []
        for record in imported {
            if let manual = state.records.first(where: {
                $0.importId == nil && !usedManual.contains($0.id) && $0.kind == record.kind
                    && $0.date == record.date && $0.amountMinor == record.amountMinor
            }) {
                usedManual.insert(manual.id)
                result.append(MergeSuggestion(manualId: manual.id, importedId: record.id))
            }
        }
        return result
    }

    /// Keeps the imported record, takes the owner's title as a note and category if the owner set one, removes the manual one.
    public static func merge(_ suggestion: MergeSuggestion, in state: FinanceState) throws -> FinanceState {
        var next = try validateFinance(state)
        guard let manualIndex = next.records.firstIndex(where: { $0.id == suggestion.manualId }),
              let importedIndex = next.records.firstIndex(where: { $0.id == suggestion.importedId }) else { return next }
        let manual = next.records[manualIndex]
        if manual.title != next.records[importedIndex].title {
            next.records[importedIndex].note = next.records[importedIndex].note ?? manual.title
        }
        if let category = manual.category, category != "Без категории" {
            next.records[importedIndex].category = category
        }
        if let importId = next.records[importedIndex].importId,
           let item = next.imports?.firstIndex(where: { $0.id == importId }) {
            let earlier = next.imports?[item].mergedManual ?? []
            next.imports?[item].mergedManual = earlier + [manual]
        }
        next.records.remove(at: manualIndex)
        return try validateFinance(next)
    }

    /// Removes one import and only its records. Hand-entered records merged into it come back, the other side of
    /// its transfers counts again unless it pairs with another statement, and the balance is rebuilt.
    public static func deleteImport(_ importId: String, from state: FinanceState) throws -> FinanceState {
        var next = try validateFinance(state)
        let removed = Set(next.records.filter { $0.importId == importId }.map(\.id))
        let restored = next.imports?.first { $0.id == importId }?.mergedManual ?? []
        next.records.removeAll { $0.importId == importId }
        next.imports?.removeAll { $0.id == importId }
        for i in next.records.indices {
            guard let partner = next.records[i].pairedWith, removed.contains(partner) else { continue }
            next.records[i].pairedWith = nil
            next.records[i].excluded = nil
            if next.records[i].note == ownTransferNote { next.records[i].note = nil }
        }
        let ids = Set(next.records.map(\.id))
        next.records.append(contentsOf: restored.filter { !ids.contains($0.id) })
        for item in next.imports ?? [] {
            pairTransfersBetweenStatements(&next, importId: item.id)
        }
        rebuildBalance(&next)
        return try validateFinance(next)
    }

    public struct RecordEdit: Equatable {
        public var title: String
        public var amountMinor: Int64
        public var date: String
        public var category: String
        public var note: String
        public var excluded: Bool
        public var applyCategoryToMerchant: Bool

        public init(title: String, amountMinor: Int64, date: String, category: String, note: String, excluded: Bool, applyCategoryToMerchant: Bool = false) {
            self.title = title
            self.amountMinor = amountMinor
            self.date = date
            self.category = category
            self.note = note
            self.excluded = excluded
            self.applyCategoryToMerchant = applyCategoryToMerchant
        }
    }

    public static func edit(_ id: String, _ edit: RecordEdit, in state: FinanceState) throws -> FinanceState {
        var next = try validateFinance(state)
        guard let index = next.records.firstIndex(where: { $0.id == id }) else {
            throw FinanceError.invalidDraft("Запись не найдена")
        }
        let title = edit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = edit.category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FinanceError.invalidDraft("Введите описание") }
        guard isValidMoney(edit.amountMinor, allowZero: next.records[index].kind == "balance") else {
            throw FinanceError.invalidDraft("Неверная сумма")
        }
        guard isValidDateString(edit.date) else { throw FinanceError.invalidDraft("Неверная дата") }
        next.records[index].title = String(title.prefix(FinanceConstants.maxTitleLen))
        next.records[index].amountMinor = edit.amountMinor
        next.records[index].date = edit.date
        let note = edit.note.trimmingCharacters(in: .whitespacesAndNewlines)
        next.records[index].note = note.isEmpty ? nil : note
        next.records[index].excluded = edit.excluded ? true : nil
        if !edit.excluded { next.records[index].pairedWith = nil }
        if !category.isEmpty, ["income", "expense"].contains(next.records[index].kind) {
            next.records[index].category = category
            if edit.applyCategoryToMerchant, let merchant = next.records[index].merchant {
                let key = MerchantCategories.key(merchant)
                var rules = next.merchantCategories ?? [:]
                rules[key] = category
                next.merchantCategories = rules
                for i in next.records.indices where next.records[i].merchant.map(MerchantCategories.key) == key
                    && next.records[i].kind == next.records[index].kind {
                    next.records[i].category = category
                }
            }
        }
        return try validateFinance(next)
    }
}

/// Automatic categories for statement operations. The owner's own per-merchant choices win.
public enum MerchantCategories {
    public static let all = [
        "Продукты", "Кафе и рестораны", "Доставка еды", "Транспорт", "Покупки", "Здоровье", "Связь и интернет",
        "Подписки", "Коммунальные", "Развлечения", "Учёба", "Наличные", "Переводы", "Пополнения", "Зарплата", "Без категории",
    ]

    private static let keywords: [(String, [String])] = [
        ("Подписки", ["openai", "chatgpt", "anthropic", "claude", "netflix", "spotify", "apple.com", "youtube", "google", "yandex plus", "яндекс плюс"]),
        // Marketplaces before groceries: «Яндекс Маркет» and «Wildberries Marketplace» are shopping.
        ("Покупки", ["wildberries", "ozon", "яндекс маркет", "yandex market", "marketplace", "kaspi магазин", "kaspi.kz магазин", "lamoda", "technodom", "sulpak", "mechta", "ikea", "zara", "lc waikiki"]),
        ("Продукты", ["magnum", "small", "galmart", "anvar", "арбуз", "arbuz", "toimart", "дешевле", "fix price", "metro", "супермаркет", "market", "маркет", "продукт", "minimarket", "khleb", "хлеб", "gaumart"]),
        ("Доставка еды", ["wolt", "glovo", "yandex eda", "яндекс еда", "chocofood", "доставка"]),
        ("Кафе и рестораны", ["kfc", "burger", "mcdonald", "starbucks", "coffee", "кофе", "cafe", "кафе", "kafe", "ресторан", "restaura", "pizza", "пицц", "doner", "донер", "bar ", "fast food", "popeyes", "bahandi", "cafeteria", "kurochka", "dastarkhan", "дастархан"]),
        ("Транспорт", ["yandex go", "яндекс go", "uber", "indrive", "индрайв", "taxi", "такси", "onay", "азс", "helios", "qazaq oil", "sinooil", "kazmunaygas", "парков", "транспорт"]),
        ("Здоровье", ["аптек", "apteka", "pharm", "drug store", "europharma", "клиник", "clinic", "стомат"]),
        ("Связь и интернет", ["beeline", "kcell", "activ", "tele2", "altel", "kazakhtelecom", "казахтелеком", "izi", "связ"]),
        ("Коммунальные", ["алсеко", "alseco", "энерго", "водоканал", "коммунал", "ерц"]),
        ("Учёба", ["образоват", "школ", "курсы", "univer", "университет", "satpayev", "сатпаев"]),
        ("Развлечения", ["kinopark", "кино", "chaplin", "steam", "playstation"]),
        ("Покупки", ["shop"]),
    ]

    public static func key(_ merchant: String) -> String {
        merchant.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func category(operation: String, merchant: String, incoming: Bool, rules: [String: String]?) -> String {
        if let rule = rules?[key(merchant)] { return rule }
        // A trailing space lets whole-word keywords such as «bar » match at the end of the name.
        let text = (operation + " " + merchant + " ").lowercased()
        if incoming {
            if text.contains("зарплат") || text.contains("salary") { return "Зарплата" }
            return operation.lowercased().contains("перевод") ? "Переводы" : "Пополнения"
        }
        let op = operation.lowercased()
        if op.hasPrefix("снятие") { return "Наличные" }
        if op.hasPrefix("перевод") { return "Переводы" }
        for (category, words) in keywords where words.contains(where: { text.contains($0) }) {
            return category
        }
        return op.hasPrefix("покупка") || op.hasPrefix("оплата") ? "Покупки" : "Без категории"
    }
}
