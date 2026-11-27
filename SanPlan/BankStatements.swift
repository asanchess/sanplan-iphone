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
        /// Statements of several accounts in one file (Halyk «Аналитический отчет»): the last four digits of the card
        /// or account this line belongs to. Nil when the whole statement is one account.
        public var account: String? = nil
        /// The bank's own category, e.g. «Супермаркеты», when the statement gives one.
        public var bankCategory: String? = nil

        public init(date: String, amountMinor: Int64, operation: String, details: String, account: String? = nil, bankCategory: String? = nil) {
            self.date = date
            self.amountMinor = amountMinor
            self.operation = operation
            self.details = details
            self.account = account
            self.bankCategory = bankCategory
        }
    }

    /// `account` of a statement that covers every account of the owner at the bank, each line naming its own.
    public static let allAccounts = "все"

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
    /// The owner's surname, where the header gives it; with the first name it tells the owner's own transfers apart.
    /// In memory only, like the first name.
    public var ownerSurname: String? = nil
    /// A report over all accounts: the last four digits that are cards (the other `account`s are plain accounts).
    public var cards: Set<String> = []
    /// A report over all accounts: the other person of a transfer line, by the line's index.
    public var counterparties: [Int: String] = [:]
    /// A statement of one account: every mask it goes by («card:0006», «kz:0006»).
    public var identifiers: [String] = []
    public var isDeposit = false
    /// The text it was read from, kept (encrypted, with the money) so a better parser can read it again.
    public var source: String? = nil

    public static func ==(lhs: ParsedStatement, rhs: ParsedStatement) -> Bool {
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
    /// Some line or total did not read: nothing is loaded, so no money is silently lost.
    case mismatch(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "Не удалось прочитать PDF. Нужна выписка в виде текста, а не скан."
        case .unknownBank: return "Это не похоже на выписку Kaspi или Halyk."
        case .noTransactions: return "В выписке не нашлось операций."
        case .alreadyImported: return "Эта выписка уже загружена: все её операции уже есть."
        case .mismatch(let what): return "Выписка прочитана не полностью: \(what). Ничего не загружено."
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

    /// Every account in one PDF: a file with several accounts («Номер счета» changes) gives one statement per
    /// account, each keeping the document head (bank, period). A one-account file gives just `parse(raw)`.
    public static func parseAll(_ raw: String) throws -> [ParsedStatement] {
        let text = flat(normalise(raw))
        let headers = matchesWithRange(accountHeader, text)
        // A page header repeats the same account; only a change of account starts a new part.
        var cuts: [(start: String.Index, account: String)] = []
        for (range, account) in headers where cuts.last?.account != account {
            cuts.append((range.lowerBound, account))
        }
        guard Set(cuts.map(\.account)).count > 1, let first = cuts.first else { return [try parse(raw)] }
        let head = String(text[..<first.start])
        var parts: [ParsedStatement] = []
        for (index, cut) in cuts.enumerated() {
            let end = index + 1 < cuts.count ? cuts[index + 1].start : text.endIndex
            let body = String(text[cut.start..<end])
            if let part = try? parse(head + " " + body) { parts.append(part) }
        }
        guard !parts.isEmpty else { throw StatementError.noTransactions }
        return parts
    }

    public static func parse(_ raw: String) throws -> ParsedStatement {
        let clean = normalise(raw)
        let text = flat(clean)
        // The bank named first is the header; later mentions are counterparties, e.g. a Halyk transfer to a Kaspi card.
        let lower = text.lowercased()
        func firstIndex(_ words: [String]) -> String.Index? {
            words.compactMap { lower.range(of: $0)?.lowerBound }.min()
        }
        let kaspi = firstIndex(["kaspi"])
        let halyk = firstIndex(["halyk", "народный банк"])
        var statement: ParsedStatement
        // Halyk's report over all accounts names no bank at all, only its title.
        if let report = firstIndex(halykReportTitles), report < min(kaspi ?? lower.endIndex, halyk ?? lower.endIndex) {
            statement = try parseHalykReport(clean)
        } else {
            switch (kaspi, halyk) {
            case let (k?, h?): statement = k < h ? try parseKaspi(text) : parseHalyk(text)
            case (_?, nil): statement = try parseKaspi(text)
            case (nil, _?): statement = parseHalyk(text)
            case (nil, nil): throw StatementError.unknownBank
            }
        }
        guard !statement.transactions.isEmpty else { throw StatementError.noTransactions }
        statement.source = raw
        return statement
    }

    /// «2 500,00», «1 234 567,89».
    static let number = #"\d{1,3}(?: \d{3})*[.,]\d{2}"#
    static let date = #"\d{2}\.\d{2}\.\d{2,4}"#

    // MARK: - Kaspi Gold
    // Cells: «07.11.26» «- 500,00 ₸» «Покупка      Beeline». Two-line operations put the details between their halves:
    // «Поступление со      С Kaspi Депозита» «своего счета». Header: «за период с 01.11.25 по 30.11.25», «Доступно на 30.11.25: + 10 000,00 ₸».

    static let kaspiNoise = [
        #"АО [«"]Kaspi Bank[»"], БИК CASPKZKA,? www\.kaspi\.kz"#,
        #"<<PAGE>>"#,
        #"Приложение к Справке (?:№|No)\s?\d+ от \d{1,2} \S+ \d{4}"#,
        #"Дата Сумма Операция Детали(?: На Депозите)?"#,
        #"\(\s?[+\-]\s?\d[\d ]*[.,]\d{2} [A-Z]{3}\)"#,
        #"-? ?Сумма заблокирована\. Банк ожидает подтверждения от платежной системы\."#,
        #"Раздел «Краткое содержание операций по карте».*$"#,
    ]

    static func parseKaspi(_ text: String) throws -> ParsedStatement {
        var body = text
        for pattern in kaspiNoise {
            body = regex(pattern).stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: " ")
        }
        body = flat(body)
        // «Доступно на 07.11.25 + 3 756,34 ₸» in the summary is not an operation.
        let row = regex(#"(?<!Доступно на )(\d{2}\.\d{2}\.\d{2,4}) ([+\-]) ?("# + number + #") ?(?:₸|KZT|тг|т)(?![\p{L}]) ?(.*?)(?= \d{2}\.\d{2}\.\d{2,4} [+\-] ?\d|$)"#)
        // A deposit statement prints what is on the deposit after every operation.
        let isDeposit = text.range(of: "по депозиту за период", options: .caseInsensitive) != nil
        var running: Int64? = isDeposit
            ? match(regex(#"Краткое содержание операций по депозиту:? На Депозите "# + date + " (" + number + ")"), text).flatMap { minor($0[1]) }
            : nil
        var transactions: [ParsedStatement.Transaction] = []
        for m in matches(row, body) {
            guard let date = isoDate(m[1]), let amount = minor(m[3]), amount > 0 else { continue }
            let signed = m[2] == "+" ? amount : -amount
            var rest = m[4].trimmingCharacters(in: .whitespaces)
            if isDeposit {
                guard let tail = match(regex(#"^(.*?) ?("# + number + #") ?₸$"#), rest), let after = minor(tail[2]),
                      running.map({ $0 + signed == after }) ?? true else {
                    throw StatementError.mismatch("строка \(m[1]) не сходится с остатком «На Депозите»")
                }
                rest = tail[1]
                running = after
            }
            let (operation, details) = splitKaspiBody(rest)
            transactions.append(.init(date: date, amountMinor: signed, operation: operation, details: details))
        }
        if !isDeposit { try checkKaspiTotals(text, transactions) }
        let period = match(regex(#"(?:период|period)\D{0,30}("# + date + #")\D{1,8}("# + date + #")"#), text)
        var closing: (String, Int64)?
        // On a deposit the first «На Депозите <date>:» is the header's closing; the summary repeats the opening later.
        let balanceLabel = isDeposit ? "На Депозите" : "Доступно на"
        if let m = match(regex(balanceLabel + " (" + date + #"):? ?([+\-]?) ?("# + number + ")"), text),
           let date = isoDate(m[1]), let amount = minor(m[3]) {
            closing = (date, m[2] == "-" ? -amount : amount)
        }
        if let running, let closing, closing.1 != running {
            throw StatementError.mismatch("остаток на депозите не сходится с операциями")
        }
        let owner = match(regex(#"подтверждает, что (\p{L}+) (\p{L}+)"#), text)
        var statement = ParsedStatement(
            bank: .kaspi,
            periodStart: period.flatMap { isoDate($0[1]) },
            periodEnd: period.flatMap { isoDate($0[2]) },
            closingBalance: closing.map { (date: $0.0, amountMinor: $0.1) },
            transactions: transactions,
            account: accountSuffix(text),
            ownerFirstName: owner?[2],
            ownerSurname: owner?[1]
        )
        statement.isDeposit = isDeposit
        let card = match(regex(#"Номер карты:? ?\*(\d{4})"#), text)?[1]
        statement.identifiers = (card.map { ["card:" + $0] } ?? []) + (statement.account.map { ["kz:" + $0] } ?? [])
        return statement
    }

    /// «Краткое содержание операций по карте» gives a total per kind of operation; the lines must add up to each.
    private static func checkKaspiTotals(_ text: String, _ transactions: [ParsedStatement.Transaction]) throws {
        guard let from = text.range(of: "Краткое содержание операций", options: .caseInsensitive),
              let to = text.range(of: "Дата Сумма", range: from.upperBound..<text.endIndex) else { return }
        let summary = String(text[from.upperBound..<to.lowerBound])
        let groups = [("Пополнения", "Пополнение"), ("Поступления со своих счетов", "Поступление со своего счета"),
                      ("Переводы", "Перевод"), ("Переводы на свои счета", "Перевод на свой счет"),
                      ("Покупки", "Покупка"), ("Снятия", "Снятие"), ("Разное", "Разное")]
        for (label, operation) in groups {
            guard let m = match(regex(label + #" ([+\-]) ?("# + number + ")"), summary), let value = minor(m[2]) else { continue }
            let sum = transactions.filter { $0.operation == operation }.reduce(Int64(0)) { $0 + $1.amountMinor }
            if sum != (m[1] == "-" ? -value : value) {
                throw StatementError.mismatch("операции не сходятся с итогом «\(label)» в шапке")
            }
        }
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
        for op in ["Покупка", "Пополнение", "Перевод", "Снятие", "Разное", "Платеж", "Платёж", "Оплата", "Вознаграждение"] where body.hasPrefix(op) {
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
        let owner = match(regex(#"Name: (\p{L}+) (\p{L}+)"#), text)
        var statement = ParsedStatement(
            bank: .halyk,
            periodStart: period.flatMap { isoDate($0[1]) },
            periodEnd: period.flatMap { isoDate($0[2]) },
            closingBalance: closing.map { (date: $0.0, amountMinor: $0.1) },
            transactions: transactions,
            account: accountSuffix(text),
            ownerFirstName: owner?[1],
            ownerSurname: owner?[2]
        )
        statement.identifiers = statement.account.map { ["kz:" + $0] } ?? []
        return statement
    }

    /// Details Halyk gives to transfers between cards, which carry no counterparty.
    public static let halykTransferDetails: Set<String> = ["Входящий перевод", "Перевод на другую карту", "Перевод со счёта", "Исходящий перевод"]

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

    // MARK: - Halyk report over all accounts
    // «Аналитический отчет по операциям клиента <ФИО> за период с 18.10.2026 по 18.11.2026». A row: date (split over two
    // lines, «2026-11-» and «06»), «Расход» or «Доход», product, card «400000******0001» or account «KZ*0002», the bank's
    // category, MCC or «-», name, signed whole-tenge amount with «₸», description. No balance and no bank name.

    static let halykReportTitles = ["аналитический отчет по операциям клиента", "аналитический отчёт по операциям клиента",
                                    "analytical report on the transactions of customer"]

    /// `text` is normalised but not flattened: when the cells of a row come out line by line rather than cell by
    /// cell, the day of the date starts a line of its own. The date breaks as «2026-11-» «24» or «2026-» «11-24».
    /// Every date must give a line and the lines must add up to the header's totals, or nothing is loaded.
    static func parseHalykReport(_ text: String) throws -> ParsedStatement {
        let flatText = flat(text)
        let starts = regex(#"(\d{4})-\s?(\d{2})-"#).matches(in: text, range: NSRange(text.startIndex..., in: text))
        let account = regex(#"(?:\d{4,6}\*{2,}|KZ\*+|\*{2,})(\d{4})(?!\d)"#)
        let kind = regex(#"(?<![\p{L}])(Расход|Доход|Expense|Income)(?![\p{L}])"#)
        let cells = regex(#"^(.+?) (\d{4}|-) (.+)$"#)
        var transactions: [ParsedStatement.Transaction] = []
        var cards: Set<String> = []
        var counterparties: [Int: String] = [:]
        // Sums as the header counts them: everything but the owner's transfers between own cards.
        var spent: Int64 = 0, received: Int64 = 0
        for (n, start) in starts.enumerated() {
            guard let range = Range(start.range, in: text) else { continue }
            let end = n + 1 < starts.count ? Range(starts[n + 1].range, in: text)?.lowerBound ?? text.endIndex : text.endIndex
            let rawRow = String(text[range.upperBound..<end])
            let row = flat(rawRow)
            let yearMonth = groups(start, text)
            let accountMatch = account.firstMatch(in: row, range: NSRange(row.startIndex..., in: row))
            let accRange = accountMatch.flatMap { Range($0.range, in: row) }
            let unreadable = StatementError.mismatch("не читается строка \(n + 1) отчёта (\(yearMonth[1])-\(yearMonth[2]))")
            guard let money = reportAmount(row, after: accRange?.upperBound), let amount = wholeOrMinor(money.number), amount > 0,
                  let day = reportDay(rawRow, row: row) else { throw unreadable }
            let date = yearMonth[1] + "-" + yearMonth[2] + "-" + String(format: "%02d", day)
            guard isValidDateString(date) else { throw unreadable }
            let type = match(kind, row)?[1].lowercased()
            let incoming = type.map { $0 == "доход" || $0 == "income" } ?? (money.sign == "+")
            // Bonus points are not money: the header counts them, no account holds them.
            if accRange == nil, row.range(of: "bonus|бонус", options: [.regularExpression, .caseInsensitive]) != nil {
                if incoming { received += amount } else { spent += amount }
                continue
            }
            // Category, MCC and name sit between the account and the amount when the cells come out in order.
            var bankCategory = ""
            var name = ""
            if let accRange, accRange.upperBound <= money.range.lowerBound {
                let between = row[accRange.upperBound..<money.range.lowerBound].trimmingCharacters(in: .whitespaces)
                if let c = match(cells, between) {
                    bankCategory = c[1]
                    name = c[3]
                } else {
                    // Cells line by line: the lone MCC dash of a transfer may lead what is left of the name.
                    name = between.hasPrefix("- ") ? String(between.dropFirst(2)) : between
                }
            }
            let suffix = accountMatch.map { groups($0, row)[1] }
            if let suffix, let accRange, !row[accRange].uppercased().hasPrefix("KZ") { cards.insert(suffix) }
            if let who = match(regex(#"(?:Transfer by phone number|Credit to account|Перевод по номеру телефона|Поступление на сч[её]т) ?: ?(.+)$"#), name) {
                counterparties[transactions.count] = who[1].trimmingCharacters(in: .whitespaces)
            }
            let (operation, details) = reportOperation(category: bankCategory, name: name, incoming: incoming)
            if (bankCategory + " " + name).range(of: "between own|между своими", options: [.regularExpression, .caseInsensitive]) == nil {
                if incoming { received += amount } else { spent += amount }
            }
            transactions.append(.init(date: date, amountMinor: incoming ? amount : -amount, operation: operation, details: details,
                                      account: suffix, bankCategory: bankCategory.isEmpty ? nil : bankCategory))
        }
        let sum = #"(\d{1,3}(?: \d{3})*(?:[.,]\d{1,2})?)"#
        if let m = match(regex(#"(?:Expenses amount|Сумма расходов) ?(?:(?:Income amount|Сумма доходов) ?)?"# + sum
                               + #"\D{0,5}?(?:(?:Income amount|Сумма доходов) ?)?"# + sum), flatText),
           let expenses = wholeOrMinor(m[1]), let income = wholeOrMinor(m[2]) {
            // The header adds kopecks the rows round to whole tenge: at most one tenge a row apart.
            let slack = Int64(max(100, starts.count)) * 100
            guard abs(expenses - spent) <= slack, abs(income - received) <= slack else {
                throw StatementError.mismatch("суммы строк не сходятся с итогами в шапке отчёта")
            }
        }
        let period = match(regex(#"(?:период|period)\D{0,30}(\d{2}\.\d{2}\.\d{4})\D{1,8}(\d{2}\.\d{2}\.\d{4})"#), flatText)
        let owner = match(regex(#"(?:по операциям клиента|transactions of customer) (\p{L}+) (\p{L}+)"#), flatText)
        var statement = ParsedStatement(
            bank: .halyk,
            periodStart: period.flatMap { isoDate($0[1]) },
            periodEnd: period.flatMap { isoDate($0[2]) },
            closingBalance: nil,
            transactions: transactions,
            account: ParsedStatement.allAccounts,
            ownerFirstName: owner?[2],
            ownerSurname: owner?[1]
        )
        statement.cards = cards
        statement.counterparties = counterparties
        return statement
    }

    /// A row's amount: «-1 895 ₸», the first one after the account. Without the currency («22 000» of a transfer
    /// between own cards in the English report) a signed number, or the bare number before a repeated description.
    private static func reportAmount(_ row: String, after account: String.Index?) -> (sign: String, number: String, range: Range<String.Index>)? {
        let patterns: [(String, String.Index)] = [
            (#"(?<![\p{L}\d*])(?:([+\-]) ?)?((?:\d{1,3}(?: \d{3})+|\d+)(?:[.,]\d{1,2})?) ?(?:₸|KZT|тг)(?![\p{L}])"#, account ?? row.startIndex),
            (#"(?<![\p{L}\d*])([+\-])(\d{1,3}(?: \d{3})*(?:[.,]\d{1,2})?)(?!\d)"#, row.startIndex),
        ]
        for (pattern, start) in patterns {
            if let m = regex(pattern).firstMatch(in: row, range: NSRange(start..., in: row)), let whole = Range(m.range, in: row) {
                let g = groups(m, row)
                return (g[1], g[2], whole)
            }
        }
        for m in regex(#"(?<![\d*])(\d{1,3}(?: \d{3})*(?:[.,]\d{1,2})?)(?!\d)"#).matches(in: row, range: NSRange(row.startIndex..., in: row)) {
            guard let r = Range(m.range, in: row) else { continue }
            let after = row[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !after.isEmpty, row[..<r.lowerBound].trimmingCharacters(in: .whitespaces).hasSuffix(after) {
                return ("", String(row[r]), r)
            }
        }
        return nil
    }

    /// The day right after «2026-11-», or else the first line of the row that starts with a day.
    private static func reportDay(_ rawRow: String, row: String) -> Int? {
        if let m = match(regex(#"^ ?(\d{2})(?!\d)"#), row), let day = Int(m[1]), (1...31).contains(day) { return day }
        for line in rawRow.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ")
            if let first = words.first, first.count == 2, let day = Int(first), (1...31).contains(day) { return day }
        }
        return nil
    }

    /// The bank's category into the operation the rest of the import understands, and the name the owner sees.
    private static func reportOperation(category: String, name: String, incoming: Bool) -> (String, String) {
        let lower = category.lowercased()
        var details = name
        for prefix in ["Поступление на счет", "Поступление на счёт", "Credit to account"] where details.hasPrefix(prefix) {
            details = String(details.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        }
        if details.isEmpty { details = name.isEmpty ? category : name }
        let operation: String
        // Without the category (cells line by line), the name still tells a transfer.
        // The English report («Transfers between own accounts», «Credit to account») reads the same way.
        let transferName = ["Поступление на сч", "Исходящий перевод", "Credit to account", "Transfer between own", "Outgoing transfer"]
            .contains { name.hasPrefix($0) }
        let has = { (words: [String]) in words.contains { lower.contains($0) } }
        if has(["перевод", "transfer"]) || transferName { operation = "Перевод" }
        else if has(["зарплат", "salary"]) { operation = "Зарплата" }
        else if has(["налич", "cash"]) { operation = "Снятие наличных" }
        else if has(["пополн", "top-up", "top up", "replenish"]) { operation = "Пополнение" }
        else if has(["возврат", "refund"]) { operation = "Возврат" }
        else { operation = incoming ? "Зачисление" : "Покупка" }
        return (operation, details)
    }

    /// «-500», «20 200», «1 234,5» → minor units; whole tenge when there are no kopecks.
    static func wholeOrMinor(_ raw: String) -> Int64? {
        let digits = raw.filter { $0.isNumber || $0 == "," || $0 == "." }.replacingOccurrences(of: ",", with: ".")
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = Int64(parts[0]), parts.count <= 2 else { return nil }
        var cents: Int64 = 0
        if parts.count == 2 {
            guard (1...2).contains(parts[1].count), let c = Int64(parts[1]) else { return nil }
            cents = parts[1].count == 1 ? c * 10 : c
        }
        let value = whole * 100 + cents
        return value <= FinanceConstants.maxAmountMinor ? value : nil
    }

    // MARK: - Helpers

    /// «Номер счета: KZ00…0001» or «Account number KZT: KZ00…0002» → «0001».
    static func accountSuffix(_ text: String) -> String? {
        match(accountHeader, text).map { String($0[1].suffix(4)) }
    }

    static let accountHeader = regex(#"(?:Номер счета|Номер счёта|Account number)[^:]{0,8}: ?(KZ[0-9A-Z]{18})"#)

    /// Each account header with where it starts and the account's last four characters.
    private static func matchesWithRange(_ regex: NSRegularExpression, _ text: String) -> [(Range<String.Index>, String)] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let whole = Range(m.range, in: text), let number = Range(m.range(at: 1), in: text) else { return nil }
            return (whole, String(text[number].suffix(4)))
        }
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

    /// The balance checkpoint earlier builds made from statements; accounts keep their own balances now.
    public static let balanceRecordId = "statement-balance"

    /// Words in the details of a transfer between the owner's own accounts and cards.
    static let ownTransferMarkers = [
        "между своими счетами", "со своего счета", "со своего счёта", "на свой счет", "на свой счёт",
        "на свою карту", "со своей карты", "с kaspi депозита", "на kaspi депозит", "с депозита", "на депозит",
        "собственных средств", "своих средств", "own account", "between own", "между своими картами", "с kaspi gold", "на kaspi gold",
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

    /// «Арман Тестов» or «Арман Т.» sending money, when the header says the owner is Тестов Арман: money from the
    /// owner's account at another bank. Needs both names, so a stranger who shares the first name stays a stranger.
    static func isOwnerByName(_ details: String, _ statement: ParsedStatement) -> Bool {
        guard let first = statement.ownerFirstName?.lowercased(), first.count > 1,
              let surname = statement.ownerSurname?.lowercased(), let initial = surname.first else { return false }
        let words = details.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard words.count >= 2, words[0] == first[...] else { return false }
        let second = words[1].trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return second == surname || (second.count == 1 && second.first == initial)
    }

    /// The account a statement line belongs to: the statement's own, or for a statement over all accounts the one
    /// its id carries. For the «Деньги» screens, to show which card or account an operation went through.
    public static func account(of record: FinanceRecord, in state: FinanceState) -> String? {
        guard let importId = record.importId, let source = state.imports?.first(where: { $0.id == importId }) else { return nil }
        guard source.account == ParsedStatement.allAccounts else { return source.account }
        return reportAccount(record)
    }

    /// «<import>-3-0001» → «0001».
    static func reportAccount(_ record: FinanceRecord) -> String? {
        guard let importId = record.importId, record.id.hasPrefix(importId + "-") else { return nil }
        let parts = record.id.dropFirst(importId.count + 1).split(separator: "-")
        return parts.count == 2 && parts[1].count == 4 ? String(parts[1]) : nil
    }

    /// Records for a statement. Own-account transfers come in excluded from totals.
    public static func preview(_ statement: ParsedStatement, importId: String, rules: [String: String]?) -> Preview {
        var records: [FinanceRecord] = []
        var excluded = 0
        for (index, t) in statement.transactions.enumerated() where t.amountMinor != 0 {
            let merchant = t.details.isEmpty ? t.operation : t.details
            let incoming = t.amountMinor > 0
            // The owner's rule for the merchant first, then the bank's own category, then the merchant's name.
            let category = rules?[MerchantCategories.key(merchant)]
                ?? t.bankCategory.flatMap { MerchantCategories.fromBank($0, operation: t.operation, incoming: incoming) }
                ?? MerchantCategories.category(operation: t.operation, merchant: merchant, incoming: incoming, rules: rules)
            var record = FinanceRecord(
                // A line of a statement over several accounts keeps its account in the id (`account(of:in:)`).
                id: t.account.map { "\(importId)-\(index)-\($0)" } ?? "\(importId)-\(index)",
                kind: incoming ? "income" : "expense",
                title: String(merchant.prefix(FinanceConstants.maxTitleLen)),
                amountMinor: abs(t.amountMinor),
                date: t.date,
                category: category
            )
            record.importId = importId
            record.merchant = String(merchant.prefix(FinanceConstants.maxTitleLen))
            let fromOwner = isFromOwnOtherBank(t.details, ownerFirstName: statement.ownerFirstName)
                || (incoming && t.operation == "Перевод" && isOwnerByName(t.details, statement))
            if isOwnTransfer(t, ownerFirstName: statement.ownerFirstName) || fromOwner {
                record.excluded = true
                excluded += 1
                if fromOwner {
                    record.note = ownTransferNote
                }
            }
            // The account (made real in `apply`), what kind of movement it is, and whether it is money back.
            let bank = statement.bank.rawValue
            if statement.account != ParsedStatement.allAccounts {
                let card = statement.bank == .kaspi || statement.identifiers.contains { $0.hasPrefix("card:") }
                record.accountId = "\(bank)|\(statement.isDeposit ? "deposit" : card ? "card" : "account")|"
            } else if let last4 = t.account {
                record.accountId = statement.cards.contains(last4) ? "\(bank)|card|card:\(last4)" : "\(bank)|account|kz:\(last4)"
            }
            record.hint = FinanceLedger.hint(t, index: index, statement: statement)
            if record.hint == "fee" {
                record.category = FinanceLedger.feeCategory
            } else if record.hint == nil, incoming {
                let spending = t.bankCategory.flatMap { MerchantCategories.fromBank($0, operation: "Покупка", incoming: false) }
                let refill = t.bankCategory?.lowercased().contains("refill") == true
                if t.operation == "Возврат" || t.operation == "Покупка" || spending != nil || refill {
                    record.refund = true
                    record.category = rules?[MerchantCategories.key(merchant)] ?? spending
                        ?? MerchantCategories.category(operation: "Покупка", merchant: merchant, incoming: false, rules: rules)
                }
            }
            records.append(record)
        }
        FinanceLedger.markFees(&records)
        return Preview(statement: statement, records: records, excludedCount: excluded)
    }

    public static func apply(_ preview: Preview, to state: FinanceState, importId: String, fileName: String, today: String) throws -> FinanceState {
        var next = try validateFinance(state)
        guard !(next.imports ?? []).contains(where: { $0.id == importId }) else { return next }
        var ledger = next.ledger ?? FinanceLedgerState()
        let records = FinanceLedger.assign(preview, in: &ledger)
        next.ledger = ledger
        let fresh = newRecords(Preview(statement: preview.statement, records: records, excludedCount: preview.excludedCount), in: next)
        guard !fresh.isEmpty else { throw StatementError.alreadyImported }
        next.records.append(contentsOf: fresh)
        var imports = next.imports ?? []
        let closing = preview.statement.closingBalance
        imports.append(FinanceImport(
            id: importId,
            bank: preview.statement.bank.rawValue,
            fileName: String(fileName.prefix(FinanceConstants.maxTitleLen)),
            periodStart: preview.statement.periodStart ?? records.compactMap(\.date).min(),
            periodEnd: preview.statement.periodEnd ?? records.compactMap(\.date).max(),
            importedAt: today,
            count: fresh.count,
            closingMinor: closing?.amountMinor,
            closingDate: closing?.date,
            account: preview.statement.account
        ))
        next.imports = imports
        let accounts = Array(Set(records.compactMap(\.accountId))).sorted()
        if let source = preview.statement.source {
            ledger.statements.append(FinanceStatementSource(
                importId: importId, parserVersion: FinanceLedger.parserVersion, text: FinanceLedger.pack(source), accounts: accounts))
        }
        if let first = preview.statement.ownerFirstName {
            let owner = "\(first)|\(preview.statement.ownerSurname ?? "")".lowercased()
            if !ledger.owners.contains(owner) { ledger.owners.append(owner) }
        }
        // An account without a balance yet starts from the statement's closing one; the owner can change it.
        if accounts.count == 1, let closing, let i = ledger.accounts.firstIndex(where: { $0.id == accounts[0] }),
           ledger.accounts[i].anchorDate == nil {
            ledger.accounts[i].anchorMinor = closing.amountMinor
            ledger.accounts[i].anchorDate = closing.date
        }
        next.ledger = ledger
        takeOverReportLines(&next, importId: importId)
        // Apple Pay payments already taken in one by one give way to the statement's lines (BankFeed.swift).
        BankFeed.reconcile(&next, statementImportId: importId)
        FinanceLedger.link(&next)
        return try validateFinance(next)
    }

    /// Operations of the same account that an earlier statement already brought in (the same file again, or an
    /// overlapping period) are left out. Repeats are counted, so two equal purchases on one day both stay.
    static func newRecords(_ preview: Preview, in state: FinanceState) -> [FinanceRecord] {
        let bank = preview.statement.bank.rawValue
        let account = preview.statement.account
        // Apple Pay payments are not the statement's own lines: BankFeed.reconcile replaces them after this.
        let statements = (state.imports ?? []).filter { $0.bank == bank && !BankFeed.isFeed($0.id) }
        // The same operation of any earlier statement, or one the owner deleted. A statement of one account is not
        // stopped by the report's lines: it takes their place (`takeOverReportLines`).
        let reports = Set(statements.filter { $0.account == ParsedStatement.allAccounts }.map(\.id))
        let blocking = account == ParsedStatement.allAccounts
            ? state.records : state.records.filter { !($0.importId.map(reports.contains) ?? false) }
        let linked = Set(blocking.compactMap(\.fp)).union(state.ledger?.removed ?? [])
        // Lines of earlier builds carry no fingerprint: they are compared by what they say.
        let sameAccount = Set(statements.filter { $0.account == account }.map(\.id))
        var seen: [String: Int] = [:]
        for record in state.records where record.fp == nil && record.importId.map({ sameAccount.contains($0) }) == true {
            seen[duplicateKey(record), default: 0] += 1
        }
        let fresh = preview.records.filter { record in
            if let fp = record.fp, linked.contains(fp) { return false }
            let key = duplicateKey(record)
            guard let count = seen[key], count > 0 else { return true }
            seen[key] = count - 1
            return false
        }
        // A report over all accounts after statements of single accounts: the two write a line differently (and a
        // card number is not the account number), so only kind, amount and day are compared.
        guard account == ParsedStatement.allAccounts else { return fresh }
        let perAccount = Set(statements.filter { $0.account != ParsedStatement.allAccounts }.map(\.id))
        let pool = state.records.filter { $0.importId.map { perAccount.contains($0) } == true && ["income", "expense"].contains($0.kind) }
        let known = Set(sameOperations(fresh, pool).map { $0.0 })
        return fresh.indices.filter { !known.contains($0) }.map { fresh[$0] }
    }

    /// The same operations written by two kinds of statement: the same kind and amount on the same day first, then
    /// a day apart (one counts the day of the purchase, the other the day the bank booked it). Each side once.
    static func sameOperations(_ lines: [FinanceRecord], _ pool: [FinanceRecord]) -> [(Int, Int)] {
        var usedLine = Set<Int>(), usedPool = Set<Int>(), pairs: [(Int, Int)] = []
        for tolerance in 0...1 {
            for (i, line) in lines.enumerated() where !usedLine.contains(i) {
                guard let lineDay = dayNumber(line.date) else { continue }
                let j = pool.indices.first { j in
                    guard !usedPool.contains(j), pool[j].kind == line.kind, pool[j].amountMinor == line.amountMinor,
                          let poolDay = dayNumber(pool[j].date) else { return false }
                    return abs(poolDay - lineDay) <= tolerance
                }
                if let j {
                    usedLine.insert(i)
                    usedPool.insert(j)
                    pairs.append((i, j))
                }
            }
        }
        return pairs
    }

    static func dayNumber(_ ymd: String?) -> Int? {
        guard let ymd, let (y, m, d) = parseYmd(ymd) else { return nil }
        return daysSinceEpoch(year: y, month: m, day: d)
    }

    /// A statement of one account after a report over all accounts: its lines take the place of the report's lines
    /// for the same operations, so the account's closing balance and its operations stay together. What the owner
    /// set on the report's line (category, note, left out of totals) and its transfer partner move over.
    static func takeOverReportLines(_ state: inout FinanceState, importId: String) {
        let imports = state.imports ?? []
        guard let source = imports.first(where: { $0.id == importId }), source.account != ParsedStatement.allAccounts else { return }
        let reports = Set(imports.filter { $0.bank == source.bank && $0.account == ParsedStatement.allAccounts }.map(\.id))
        guard !reports.isEmpty else { return }
        let lineIndices = state.records.indices.filter { state.records[$0].importId == importId }
        let poolIndices = state.records.indices.filter {
            state.records[$0].importId.map { reports.contains($0) } == true && ["income", "expense"].contains(state.records[$0].kind)
                && !state.records[$0].id.hasSuffix("-fee")
        }
        // The same fingerprint first, then the same kind, day and the amount the report wrote.
        var pairs: [(Int, Int)] = []
        for (a, i) in lineIndices.enumerated() {
            guard let fp = state.records[i].fp, let b = poolIndices.firstIndex(where: { state.records[$0].fp == fp }) else { continue }
            pairs.append((a, b))
        }
        let restA = lineIndices.indices.filter { a in !pairs.contains { $0.0 == a } }
        let restB = poolIndices.indices.filter { b in !pairs.contains { $0.1 == b } }
        pairs += sameOperations(restA.map { state.records[lineIndices[$0]] }, restB.map { b -> FinanceRecord in
            var r = state.records[poolIndices[b]]
            r.amountMinor = FinanceLedger.wholeAmount(r) ?? r.amountMinor
            return r
        }).map { (restA[$0.0], restB[$0.1]) }
        var replaced = Set<String>()
        for (a, b) in pairs {
            let i = lineIndices[a]
            let old = state.records[poolIndices[b]]
            let newId = state.records[i].id
            state.records[i].category = old.category ?? state.records[i].category
            state.records[i].note = old.note ?? state.records[i].note
            // Left out by a transfer rule is worked out again; left out by hand moves over.
            if old.excluded == true, old.hint == nil || old.ownerEdited == true { state.records[i].excluded = true }
            if old.ownerEdited == true { state.records[i].ownerEdited = true }
            // The owner's answer in «Проверь» moves to the line that takes this one's place.
            if let from = old.fp, let to = state.records[i].fp, let decision = state.ledger?.decisions.removeValue(forKey: from) {
                state.ledger?.decisions[to] = decision
            }
            state.records[i].pairedWith = old.pairedWith ?? state.records[i].pairedWith
            for k in state.records.indices where state.records[k].pairedWith == old.id {
                state.records[k].pairedWith = newId
            }
            replaced.insert(old.id)
        }
        state.records.removeAll { replaced.contains($0.id) }
    }

    private static func duplicateKey(_ r: FinanceRecord) -> String {
        "\(r.date ?? "")|\(r.kind)|\(r.amountMinor ?? 0)|\((r.merchant ?? r.title).lowercased())"
    }

    static let ownTransferNote = "Перевод между своими счетами"

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
        next.records[importedIndex].ownerEdited = true
        next.records.remove(at: manualIndex)
        return try validateFinance(next)
    }

    /// Removes one import and only its records. Hand-entered records merged into it come back, the other side of
    /// its transfers counts again unless it pairs with another statement, and the balance is rebuilt.
    public static func deleteImport(_ importId: String, from state: FinanceState) throws -> FinanceState {
        var next = try validateFinance(state)
        let removed = Set(next.records.filter { $0.importId == importId }.map(\.id))
        let item = next.imports?.first { $0.id == importId }
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
        next.ledger?.statements.removeAll { $0.importId == importId }
        // A balance the statement itself gave an account goes with the account's last statement.
        if let date = item?.closingDate, var ledger = next.ledger {
            for i in ledger.accounts.indices where ledger.accounts[i].anchorDate == date && ledger.accounts[i].anchorMinor == item?.closingMinor {
                let id = ledger.accounts[i].id
                guard !ledger.statements.contains(where: { $0.accounts.contains(id) }) else { continue }
                ledger.accounts[i].anchorMinor = nil
                ledger.accounts[i].anchorDate = nil
            }
            next.ledger = ledger
        }
        FinanceLedger.link(&next)
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
        let wasExcluded = next.records[index].excluded == true
        next.records[index].excluded = edit.excluded ? true : nil
        if !edit.excluded {
            next.records[index].pairedWith = nil
            next.records[index].transfer = nil
        }
        if next.records[index].importId != nil { next.records[index].ownerEdited = true }
        if wasExcluded != edit.excluded, let fp = next.records[index].fp {
            var ledger = next.ledger ?? FinanceLedgerState()
            ledger.decisions[fp] = FinanceDecision(excluded: edit.excluded)
            next.ledger = ledger
        }
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
        if next.ledger != nil { FinanceLedger.link(&next) }
        return try validateFinance(next)
    }
}

/// Automatic categories for statement operations. The owner's own per-merchant choices win.
public enum MerchantCategories {
    public static let all = [
        "Продукты", "Кафе и рестораны", "Доставка еды", "Транспорт", "Покупки", "Здоровье", "Связь и интернет",
        "Подписки", "Коммунальные", "Развлечения", "Учёба", "Наличные", "Переводы", "Люди", "Комиссии", "Пополнения", "Зарплата", "Без категории",
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

    /// Words of the bank's own purchase categories («Супермаркеты», «Здоровье и уход»…) and the category they mean here.
    private static let bankWords: [(String, [String])] = [
        // Russian and English report (Halyk gives the report in the app's language).
        ("Продукты", ["супермаркет", "продукт", "supermarket", "grocer"]),
        ("Доставка еды", ["доставк", "delivery"]),
        ("Кафе и рестораны", ["кафе", "ресторан", "фастфуд", "фаст-фуд", "кофейн", "cafe", "restaurant", "fast food", "coffee"]),
        ("Здоровье", ["здоров", "аптек", "медиц", "красот", "health", "pharmac", "medic", "beauty"]),
        ("Транспорт", ["такси", "транспорт", "азс", "топлив", "авто", "парков", "taxi", "transport", "fuel", "gas station", "parking"]),
        ("Связь и интернет", ["связь", "интернет", "мобильн", "телеком", "internet", "mobile", "telecom"]),
        ("Коммунальные", ["коммунал", "utilit"]),
        ("Развлечения", ["развлеч", "кино", "отдых", "игры", "entertain", "cinema", "games"]),
        ("Учёба", ["образован", "обучен", "education"]),
        ("Подписки", ["подписк", "цифров", "subscription", "digital"]),
        ("Покупки", ["одежд", "обув", "электроник", "маркетплейс", "товары", "дом и ремонт", "покупк", "clothing", "shoes", "electronics", "marketplace", "home"]),
    ]

    /// The bank's category of a purchase as one of ours; nil for money in, transfers and cash, which the operation
    /// already tells, and for a category this list does not know.
    public static func fromBank(_ bankCategory: String, operation: String, incoming: Bool) -> String? {
        guard !incoming, ["Покупка", "Оплата"].contains(operation) else { return nil }
        let lower = bankCategory.lowercased()
        return bankWords.first { $0.1.contains(where: { lower.contains($0) }) }?.0
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
