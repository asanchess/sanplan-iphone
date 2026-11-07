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

    public static func == (lhs: ParsedStatement, rhs: ParsedStatement) -> Bool {
        lhs.bank == rhs.bank && lhs.periodStart == rhs.periodStart && lhs.periodEnd == rhs.periodEnd
            && lhs.closingBalance?.date == rhs.closingBalance?.date
            && lhs.closingBalance?.amountMinor == rhs.closingBalance?.amountMinor
            && lhs.transactions == rhs.transactions
    }
}

public enum StatementError: LocalizedError, Equatable {
    case unreadable
    case unknownBank
    case noTransactions

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "Не удалось прочитать PDF. Нужна выписка в виде текста, а не скан."
        case .unknownBank: return "Это не похоже на выписку Kaspi или Halyk."
        case .noTransactions: return "В выписке не нашлось операций."
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
        for (from, to) in [("ĸ", "к"), ("\u{00A0}", " "), ("\u{202F}", " "), ("\u{2007}", " "), ("\u{2009}", " "), ("\u{2212}", "-")] {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    public static func parse(_ raw: String) throws -> ParsedStatement {
        let text = normalise(raw)
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

    // MARK: - Kaspi Gold
    // Rows look like «05.11.25 - 2 500,00 ₸ Покупка MAGNUM» and «06.11.25 + 50 000,00 ₸ Пополнение С Kaspi Депозита».
    // The header has «за период с 01.11.25 по 30.11.25» and «Доступно на 30.11.25 123 456,78 ₸».

    static func parseKaspi(_ text: String) -> ParsedStatement {
        let operations = ["Покупка", "Пополнение", "Перевод", "Снятие", "Разное", "Платеж", "Платёж", "Оплата"]
        let opPattern = operations.joined(separator: "|")
        let row = regex(#"^(\d{2}\.\d{2}\.\d{2,4})\s+([+\-−–])\s*([\d\s ]+[.,]\d{2})\s*(?:₸|KZT|т)?\s+("# + opPattern + #")\s*(.*)$"#)
        var transactions: [ParsedStatement.Transaction] = []
        for line in lines(text) {
            guard let m = match(row, line), let date = isoDate(m[1]), let amount = minor(m[3]) else { continue }
            let sign: Int64 = m[2] == "+" ? 1 : -1
            transactions.append(.init(date: date, amountMinor: sign * amount, operation: m[4] == "Платёж" ? "Платеж" : m[4], details: clean(m[5])))
        }
        let period = match(regex(#"(?:период|period)\D{0,12}(\d{2}\.\d{2}\.\d{2,4})\D{1,8}(\d{2}\.\d{2}\.\d{2,4})"#), text)
        var closing: (String, Int64)?
        if let m = match(regex(#"Доступно на\s+(\d{2}\.\d{2}\.\d{2,4})\D{0,6}?([+\-−–]?\s*[\d\s ]+[.,]\d{2})"#), text),
           let date = isoDate(m[1]), let amount = signedMinor(m[2]) {
            closing = (date, amount)
        }
        return ParsedStatement(
            bank: .kaspi,
            periodStart: period.flatMap { isoDate($0[1]) },
            periodEnd: period.flatMap { isoDate($0[2]) },
            closingBalance: closing.map { (date: $0.0, amountMinor: $0.1) },
            transactions: transactions
        )
    }

    // MARK: - Halyk
    // Rows start with the operation date, optionally the posting date, then the description and the amount in the
    // account currency with its sign: «05.11.2025 06.11.2025 Покупка MAGNUM ALMATY -2 500,00 KZT».
    // The end balance is «Остаток на конец периода» or «Исходящий остаток».

    static func parseHalyk(_ text: String) -> ParsedStatement {
        let row = regex(#"^(\d{2}\.\d{2}\.\d{4})\s+(?:\d{2}\.\d{2}\.\d{4}\s+)?(?:\d{2}:\d{2}(?::\d{2})?\s+)?(.+?)\s+([+\-−–]?\s?[\d\s ]+[.,]\d{2})\s*(?:KZT|₸|тг)?(.*)$"#)
        var transactions: [ParsedStatement.Transaction] = []
        for line in lines(text) {
            guard let m = match(row, line), let date = isoDate(m[1]), let amount = signedMinor(m[3]) else { continue }
            let description = clean(m[2])
            let (operation, details) = splitHalykDescription(description)
            var signed = amount
            // Some statements print expenses without a minus but name them; incoming words flip it back.
            if !m[3].contains(where: { "+-−–".contains($0) }) {
                signed = isHalykIncome(operation) ? abs(amount) : -abs(amount)
            }
            transactions.append(.init(date: date, amountMinor: signed, operation: operation, details: details))
        }
        let period = match(regex(#"(?:период|period)\D{0,12}(\d{2}\.\d{2}\.\d{4})\D{1,8}(\d{2}\.\d{2}\.\d{4})"#), text)
        var closing: (String, Int64)?
        if let m = match(regex(#"(?:Остаток на конец периода|Исходящий остаток|Доступный остаток)[^\d\-+−–]{0,40}([+\-−–]?\s*[\d\s ]+[.,]\d{2})"#), text),
           let amount = signedMinor(m[1]),
           let end = period.flatMap({ isoDate($0[2]) }) ?? transactions.map(\.date).max() {
            closing = (end, amount)
        }
        return ParsedStatement(
            bank: .halyk,
            periodStart: period.flatMap { isoDate($0[1]) },
            periodEnd: period.flatMap { isoDate($0[2]) },
            closingBalance: closing.map { (date: $0.0, amountMinor: $0.1) },
            transactions: transactions
        )
    }

    private static let halykOperations = ["Покупка", "Оплата", "Перевод", "Пополнение", "Снятие наличных", "Снятие", "Зачисление", "Возврат", "Комиссия", "Платеж", "Платёж"]

    private static func splitHalykDescription(_ text: String) -> (String, String) {
        for op in halykOperations where text.lowercased().hasPrefix(op.lowercased()) {
            let rest = text.dropFirst(op.count).trimmingCharacters(in: CharacterSet(charactersIn: " :-—"))
            return (op, rest.isEmpty ? op : rest)
        }
        return ("Операция", text)
    }

    private static func isHalykIncome(_ operation: String) -> Bool {
        ["Пополнение", "Зачисление", "Возврат"].contains(operation)
    }

    // MARK: - Helpers

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines])
    }

    private static func match(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
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

    /// Words in the details of a transfer between the owner's own accounts and cards.
    static let ownTransferMarkers = [
        "между своими счетами", "со своего счета", "со своего счёта", "на свой счет", "на свой счёт",
        "на свою карту", "со своей карты", "с kaspi депозита", "на kaspi депозит", "с депозита", "на депозит",
        "собственных средств", "своих средств", "own account", "между своими картами", "с kaspi gold", "на kaspi gold",
    ]

    public static func isOwnTransfer(_ t: ParsedStatement.Transaction) -> Bool {
        let text = (t.operation + " " + t.details).lowercased()
        return ownTransferMarkers.contains { text.contains($0) }
    }

    /// Records for a statement. Own-card transfers come in excluded from totals; the closing balance becomes the checkpoint.
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
            if isOwnTransfer(t) {
                record.excluded = true
                excluded += 1
            }
            records.append(record)
        }
        // After the transactions, so ones on the same day are already inside the checkpoint.
        if let closing = statement.closingBalance, closing.amountMinor >= 0 {
            var balance = FinanceRecord(
                id: "\(importId)-balance",
                kind: "balance",
                title: "Остаток \(statement.bank.rawValue)",
                amountMinor: closing.amountMinor,
                date: closing.date
            )
            balance.importId = importId
            records.append(balance)
        }
        return Preview(statement: statement, records: records, excludedCount: excluded)
    }

    public static func apply(_ preview: Preview, to state: FinanceState, importId: String, fileName: String, today: String) throws -> FinanceState {
        var next = try validateFinance(state)
        guard !(next.imports ?? []).contains(where: { $0.id == importId }) else { return next }
        next.records.append(contentsOf: preview.records)
        var imports = next.imports ?? []
        imports.append(FinanceImport(
            id: importId,
            bank: preview.statement.bank.rawValue,
            fileName: String(fileName.prefix(FinanceConstants.maxTitleLen)),
            periodStart: preview.statement.periodStart,
            periodEnd: preview.statement.periodEnd,
            importedAt: today,
            count: preview.records.filter { $0.kind != "balance" }.count
        ))
        next.imports = imports
        return try validateFinance(next)
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
        next.records.remove(at: manualIndex)
        return try validateFinance(next)
    }

    /// Removes one import and only its records.
    public static func deleteImport(_ importId: String, from state: FinanceState) throws -> FinanceState {
        var next = try validateFinance(state)
        next.records.removeAll { $0.importId == importId }
        next.imports?.removeAll { $0.id == importId }
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
        "Коммунальные", "Развлечения", "Наличные", "Переводы", "Пополнения", "Зарплата", "Без категории",
    ]

    private static let keywords: [(String, [String])] = [
        ("Продукты", ["magnum", "small", "galmart", "anvar", "арбуз", "arbuz", "toimart", "дешевле", "fix price", "metro", "супермаркет", "market", "маркет", "продукт"]),
        ("Доставка еды", ["wolt", "glovo", "yandex eda", "яндекс еда", "chocofood", "доставка"]),
        ("Кафе и рестораны", ["kfc", "burger", "mcdonald", "starbucks", "coffee", "кофе", "cafe", "кафе", "ресторан", "restaurant", "pizza", "пицц", "doner", "донер", "bar "]),
        ("Транспорт", ["yandex go", "яндекс go", "uber", "indrive", "индрайв", "taxi", "такси", "onay", "азс", "helios", "qazaq oil", "sinooil", "kazmunaygas", "gas", "парков"]),
        ("Здоровье", ["аптек", "pharm", "europharma", "клиник", "clinic", "стомат", "med"]),
        ("Связь и интернет", ["beeline", "kcell", "activ", "tele2", "altel", "kazakhtelecom", "казахтелеком", "izi"]),
        ("Коммунальные", ["алсеко", "alseco", "энерго", "водоканал", "коммунал", "ерц"]),
        ("Развлечения", ["kinopark", "кино", "chaplin", "netflix", "spotify", "apple.com", "steam", "playstation", "youtube"]),
        ("Покупки", ["wildberries", "ozon", "kaspi магазин", "kaspi.kz магазин", "lamoda", "technodom", "sulpak", "mechta", "ikea", "zara", "lc waikiki"]),
    ]

    public static func key(_ merchant: String) -> String {
        merchant.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func category(operation: String, merchant: String, incoming: Bool, rules: [String: String]?) -> String {
        if let rule = rules?[key(merchant)] { return rule }
        let text = (operation + " " + merchant).lowercased()
        if incoming {
            if text.contains("зарплат") || text.contains("salary") { return "Зарплата" }
            return operation.lowercased().contains("перевод") ? "Переводы" : "Пополнения"
        }
        if operation.lowercased().hasPrefix("снятие") { return "Наличные" }
        for (category, words) in keywords where words.contains(where: { text.contains($0) }) {
            return category
        }
        if operation.lowercased().hasPrefix("перевод") { return "Переводы" }
        return operation.lowercased().hasPrefix("покупка") || operation.lowercased().hasPrefix("оплата") ? "Покупки" : "Без категории"
    }
}
