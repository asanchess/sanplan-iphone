import Foundation

// MARK: - Constants

public enum FinanceConstants {
    public static let maxAmountMinor: Int64 = 100_000_000_000 // 10^11 minor units
    public static let maxRecords: Int = 5000
    public static let maxBatches: Int = 128
    public static let maxIdLen: Int = 100
    public static let maxTitleLen: Int = 200

    public static let allowedKinds: Set<String> = [
        "balance",
        "income",
        "expense",
        "obligation",
        "goal",
        "planned_income"
    ]

    public static let allowedFrequencies: Set<String> = [
        "monthly",
        "weekly"
    ]
}

// MARK: - Errors

public enum FinanceError: LocalizedError, Equatable {
    case invalidState(String)
    case invalidDraft(String)
    case invalidDate(String)
    case invalidAmount(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .invalidState(let message):
            return message
        case .invalidDraft(let message):
            return message
        case .invalidDate(let message):
            return message
        case .invalidAmount(let message):
            return message
        case .conflict(let message):
            return message
        }
    }
}

// MARK: - Models

public struct FinanceRecord: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var amountMinor: Int64?
    public var date: String?
    public var category: String?
    public var obligationId: String?
    public var frequency: String?
    public var savedMinor: Int64?
    /// Envelopes only: the part of `savedMinor` kept outside the accounts (cash, a deposit no statement shows).
    /// It counts toward the envelope and its target but is never taken out of «Чистыми».
    public var outsideMinor: Int64?
    public var dueDate: String?
    /// The bank statement import this record came from; nil for records entered by hand.
    public var importId: String?
    /// The merchant or counterparty as the bank wrote it, for per-merchant categories.
    public var merchant: String?
    /// Free text the owner added.
    public var note: String?
    /// Kept in the list but left out of every total, e.g. a transfer between the owner's own cards.
    public var excluded: Bool?
    /// The other side of a transfer between the owner's statements, set only on a side that the pairing took out
    /// of the totals, so deleting the other statement puts it back.
    public var pairedWith: String?

    public init(
        id: String,
        kind: String,
        title: String,
        amountMinor: Int64? = nil,
        date: String? = nil,
        category: String? = nil,
        obligationId: String? = nil,
        frequency: String? = nil,
        savedMinor: Int64? = nil,
        dueDate: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.amountMinor = amountMinor
        self.date = date
        self.category = category
        self.obligationId = obligationId
        self.frequency = frequency
        self.savedMinor = savedMinor
        self.dueDate = dueDate
    }
}

/// One imported bank statement, so it can be listed and deleted as a whole.
public struct FinanceImport: Codable, Equatable, Identifiable {
    public var id: String
    public var bank: String
    public var fileName: String
    public var periodStart: String?
    public var periodEnd: String?
    public var importedAt: String
    public var count: Int
    /// The account balance at the end of the statement, so several accounts add up to one checkpoint.
    public var closingMinor: Int64?
    public var closingDate: String?
    /// Last four characters of the account number; a newer statement of the same account replaces its balance.
    public var account: String?
    /// Hand-entered records merged into this statement's operations, given back if the statement is deleted.
    public var mergedManual: [FinanceRecord]?

    public init(id: String, bank: String, fileName: String, periodStart: String?, periodEnd: String?, importedAt: String, count: Int, closingMinor: Int64? = nil, closingDate: String? = nil, account: String? = nil) {
        self.id = id
        self.bank = bank
        self.fileName = fileName
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.importedAt = importedAt
        self.count = count
        self.closingMinor = closingMinor
        self.closingDate = closingDate
        self.account = account
    }
}

public struct FinanceState: Codable, Equatable {
    public var version: Int
    public var records: [FinanceRecord]
    public var committedBatches: [String]
    public var imports: [FinanceImport]?
    /// Category chosen by the owner for every operation with a merchant, keyed by the normalised merchant name.
    public var merchantCategories: [String: String]?
    /// Monthly plan: category limits, set-aside percent and what the owner already answered (see FinanceBudget.swift).
    public var budget: FinanceBudget?

    public init(
        version: Int = 1,
        records: [FinanceRecord] = [],
        committedBatches: [String] = [],
        imports: [FinanceImport]? = nil,
        merchantCategories: [String: String]? = nil,
        budget: FinanceBudget? = nil
    ) {
        self.version = version
        self.records = records
        self.committedBatches = committedBatches
        self.imports = imports
        self.merchantCategories = merchantCategories
        self.budget = budget
    }
}

public struct FinanceDraft: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: String?
    public var title: String?
    public var amountMinor: Int64?
    public var date: String?
    public var category: String?
    public var obligationId: String?
    public var frequency: String?
    public var savedMinor: Int64?
    public var dueDate: String?
    public var needsDueDate: Bool?
    public var recordId: String?
    public var balanceRelation: String?

    public init(
        id: String = UUID().uuidString,
        kind: String? = nil,
        title: String? = nil,
        amountMinor: Int64? = nil,
        date: String? = nil,
        category: String? = nil,
        obligationId: String? = nil,
        frequency: String? = nil,
        savedMinor: Int64? = nil,
        dueDate: String? = nil,
        needsDueDate: Bool? = nil,
        recordId: String? = nil,
        balanceRelation: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.amountMinor = amountMinor
        self.date = date
        self.category = category
        self.obligationId = obligationId
        self.frequency = frequency
        self.savedMinor = savedMinor
        self.dueDate = dueDate
        self.needsDueDate = needsDueDate
        self.recordId = recordId
        self.balanceRelation = balanceRelation
    }
}

public struct FinanceCategoryBreakdown: Codable, Equatable {
    public var name: String
    public var amountMinor: Int64

    public init(name: String, amountMinor: Int64) {
        self.name = name
        self.amountMinor = amountMinor
    }
}

public struct FinanceSummary: Codable, Equatable {
    public var balanceMinor: Int64?
    public var incomeMinor: Int64
    public var expenseMinor: Int64
    public var netMinor: Int64
    public var byCategory: [FinanceCategoryBreakdown]
    public var reservedGoalMinor: Int64
    public var obligationsMinor: Int64
    public var spendableMinor: Int64?
    public var dailyMinor: Int64?
    public var deficitMinor: Int64?
    public var plannedIncomeMinor: Int64

    public init(
        balanceMinor: Int64? = nil,
        incomeMinor: Int64 = 0,
        expenseMinor: Int64 = 0,
        netMinor: Int64 = 0,
        byCategory: [FinanceCategoryBreakdown] = [],
        reservedGoalMinor: Int64 = 0,
        obligationsMinor: Int64 = 0,
        spendableMinor: Int64? = nil,
        dailyMinor: Int64? = nil,
        deficitMinor: Int64? = nil,
        plannedIncomeMinor: Int64 = 0
    ) {
        self.balanceMinor = balanceMinor
        self.incomeMinor = incomeMinor
        self.expenseMinor = expenseMinor
        self.netMinor = netMinor
        self.byCategory = byCategory
        self.reservedGoalMinor = reservedGoalMinor
        self.obligationsMinor = obligationsMinor
        self.spendableMinor = spendableMinor
        self.dailyMinor = dailyMinor
        self.deficitMinor = deficitMinor
        self.plannedIncomeMinor = plannedIncomeMinor
    }
}

public struct FinanceQuestion: Equatable {
    public var field: String
    public var label: String
    public var type: String
    public var options: [String]?

    public init(field: String, label: String, type: String, options: [String]? = nil) {
        self.field = field
        self.label = label
        self.type = type
        self.options = options
    }
}

public struct GoalProgressResult: Equatable {
    public var remainingMinor: Int64
    public var progressPercent: Int
    public var daysLeft: Int?
    public var requiredDailyMinor: Int64?
    public var status: String

    public init(
        remainingMinor: Int64,
        progressPercent: Int,
        daysLeft: Int?,
        requiredDailyMinor: Int64?,
        status: String
    ) {
        self.remainingMinor = remainingMinor
        self.progressPercent = progressPercent
        self.daysLeft = daysLeft
        self.requiredDailyMinor = requiredDailyMinor
        self.status = status
    }
}

// MARK: - Validation Helpers

public func isValidDateString(_ str: String?) -> Bool {
    guard let str = str else { return false }
    let parts = str.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
          parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2]),
          month >= 1, month <= 12, day >= 1, day <= 31
    else {
        return false
    }

    let isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
    let daysInMonths = [0, 31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return day <= daysInMonths[month]
}

public func isValidMonthString(_ str: String?) -> Bool {
    guard let str = str else { return false }
    let parts = str.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2,
          parts[0].count == 4, parts[1].count == 2,
          Int(parts[0]) != nil,
          let month = Int(parts[1]),
          month >= 1, month <= 12
    else {
        return false
    }
    return true
}

public func isValidMoney(_ val: Int64?, allowZero: Bool = false) -> Bool {
    guard let val = val else { return false }
    if allowZero {
        return val >= 0 && val <= FinanceConstants.maxAmountMinor
    }
    return val > 0 && val <= FinanceConstants.maxAmountMinor
}

public func emptyFinance() -> FinanceState {
    FinanceState(version: 1, records: [], committedBatches: [])
}

// MARK: - Validation and State Invariants

/// Typed spending used to land in «Еда» and «Связь», names no statement or limit knows. Read as the current ones.
func legacyCategory(_ category: String, title: String) -> String {
    switch category {
    case "Еда":
        let eatingOut = title.lowercased().range(of: "обед|ужин|завтрак|кафе|ресторан|кофе", options: .regularExpression) != nil
        return eatingOut ? "Кафе и рестораны" : "Продукты"
    case "Связь": return "Связь и интернет"
    default: return category
    }
}

public func validateFinance(_ value: FinanceState) throws -> FinanceState {
    if value.version != 1 {
        throw FinanceError.invalidState("Unsupported finance state version")
    }
    if value.records.count > FinanceConstants.maxRecords {
        throw FinanceError.invalidState("Exceeded maximum records limit")
    }
    if value.committedBatches.count > FinanceConstants.maxBatches {
        throw FinanceError.invalidState("Exceeded maximum committed batches limit")
    }

    var batchSet = Set<String>()
    var cleanBatches: [String] = []
    for b in value.committedBatches {
        if b.isEmpty || b.count > FinanceConstants.maxIdLen {
            throw FinanceError.invalidState("Invalid batchId")
        }
        if batchSet.contains(b) {
            throw FinanceError.invalidState("Duplicate batchId: \(b)")
        }
        batchSet.insert(b)
        cleanBatches.append(b)
    }

    var recordIdSet = Set<String>()
    var cleanRecords: [FinanceRecord] = []

    for rec in value.records {
        if rec.id.isEmpty || rec.id.count > FinanceConstants.maxIdLen {
            throw FinanceError.invalidState("Invalid record id")
        }
        if recordIdSet.contains(rec.id) {
            throw FinanceError.invalidState("Duplicate record id: \(rec.id)")
        }
        recordIdSet.insert(rec.id)

        if !FinanceConstants.allowedKinds.contains(rec.kind) {
            throw FinanceError.invalidState("Unknown record kind: \(rec.kind)")
        }
        if rec.title.isEmpty || rec.title.count > FinanceConstants.maxTitleLen {
            throw FinanceError.invalidState("Invalid record title")
        }

        var clean = FinanceRecord(id: rec.id, kind: rec.kind, title: rec.title)
        clean.importId = rec.importId.flatMap { $0.isEmpty || $0.count > FinanceConstants.maxIdLen ? nil : $0 }
        clean.merchant = rec.merchant.flatMap { $0.isEmpty ? nil : String($0.prefix(FinanceConstants.maxTitleLen)) }
        clean.note = rec.note.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
        clean.excluded = rec.excluded == true ? true : nil
        clean.pairedWith = rec.pairedWith.flatMap { $0.isEmpty || $0.count > FinanceConstants.maxIdLen ? nil : $0 }

        switch rec.kind {
        case "balance":
            guard isValidMoney(rec.amountMinor, allowZero: true) else {
                throw FinanceError.invalidState("Invalid balance amount")
            }
            guard isValidDateString(rec.date) else {
                throw FinanceError.invalidState("Invalid balance date")
            }
            clean.amountMinor = rec.amountMinor
            clean.date = rec.date

        case "income", "expense":
            guard isValidMoney(rec.amountMinor, allowZero: false) else {
                throw FinanceError.invalidState("Invalid income/expense amount")
            }
            guard isValidDateString(rec.date) else {
                throw FinanceError.invalidState("Invalid income/expense date")
            }
            clean.amountMinor = rec.amountMinor
            clean.date = rec.date
            let trimmedCat = rec.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            clean.category = !trimmedCat.isEmpty ? legacyCategory(trimmedCat, title: rec.title) : "Без категории"

            if rec.kind == "expense" {
                if let obId = rec.obligationId, !obId.isEmpty {
                    clean.obligationId = obId
                } else {
                    clean.obligationId = nil
                }
            }

        case "obligation", "planned_income":
            guard isValidMoney(rec.amountMinor, allowZero: false) else {
                throw FinanceError.invalidState("Invalid obligation/planned_income amount")
            }
            guard let freq = rec.frequency, FinanceConstants.allowedFrequencies.contains(freq) else {
                throw FinanceError.invalidState("Invalid frequency (must be monthly or weekly)")
            }
            clean.amountMinor = rec.amountMinor
            clean.frequency = freq
            if let d = rec.date {
                guard isValidDateString(d) else {
                    throw FinanceError.invalidState("Invalid obligation/planned_income registration date")
                }
                clean.date = d
            } else {
                clean.date = nil
            }

        case "goal":
            guard isValidMoney(rec.amountMinor, allowZero: false) else {
                throw FinanceError.invalidState("Invalid goal target amount")
            }
            guard isValidMoney(rec.savedMinor, allowZero: true) else {
                throw FinanceError.invalidState("Invalid goal savedMinor")
            }
            guard let saved = rec.savedMinor, let target = rec.amountMinor, saved <= target else {
                throw FinanceError.invalidState("Goal saved amount cannot exceed target amount")
            }
            clean.amountMinor = rec.amountMinor
            clean.savedMinor = rec.savedMinor
            // An edit that lowers what is saved lowers the outside part with it.
            if let outside = rec.outsideMinor, outside > 0, isValidMoney(outside), saved > 0 {
                clean.outsideMinor = min(outside, saved)
            }
            if let dd = rec.dueDate {
                guard isValidDateString(dd) else {
                    throw FinanceError.invalidState("Invalid goal dueDate")
                }
                clean.dueDate = dd
            } else {
                clean.dueDate = nil
            }
            if let d = rec.date {
                guard isValidDateString(d) else {
                    throw FinanceError.invalidState("Invalid goal date")
                }
                clean.date = d
            } else {
                clean.date = nil
            }

        default:
            throw FinanceError.invalidState("Unknown record kind: \(rec.kind)")
        }

        cleanRecords.append(clean)
    }

    let importIds = Set(cleanRecords.compactMap(\.importId))
    // A statement whose operations were all deleted one by one still knows its account's closing balance; only
    // `deleteImport` drops a statement on purpose.
    let cleanImports = value.imports?.filter { importIds.contains($0.id) || ($0.closingMinor != nil && $0.closingDate != nil) }
    let cleanRules = value.merchantCategories?.filter { !$0.key.isEmpty && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    return FinanceState(
        version: 1,
        records: cleanRecords,
        committedBatches: cleanBatches,
        imports: (cleanImports?.isEmpty ?? true) ? nil : cleanImports,
        merchantCategories: (cleanRules?.isEmpty ?? true) ? nil : cleanRules,
        budget: try value.budget.flatMap { try FinanceBudget.validated($0, records: cleanRecords) }
    )
}

// MARK: - Questions and Clarifications

public func balanceRelationNeeded(_ draft: FinanceDraft, drafts: [FinanceDraft] = []) -> Bool {
    guard let kind = draft.kind, (kind == "income" || kind == "expense") else { return false }
    guard isValidDateString(draft.date) else { return false }
    return drafts.contains { other in
        other.id != draft.id && other.kind == "balance" && other.date == draft.date
    }
}

public func financeQuestions(_ draft: FinanceDraft?, drafts: [FinanceDraft] = []) -> [FinanceQuestion] {
    guard let draft = draft else {
        return [
            FinanceQuestion(
                field: "kind",
                label: "Тип операции",
                type: "select",
                options: Array(FinanceConstants.allowedKinds)
            )
        ]
    }

    var questions: [FinanceQuestion] = []

    guard let kind = draft.kind, FinanceConstants.allowedKinds.contains(kind) else {
        return [
            FinanceQuestion(
                field: "kind",
                label: "Тип операции",
                type: "select",
                options: ["balance", "income", "expense", "obligation", "goal", "planned_income"]
            )
        ]
    }

    let titleTrimmed = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if titleTrimmed.isEmpty || (draft.title?.count ?? 0) > FinanceConstants.maxTitleLen {
        questions.append(FinanceQuestion(field: "title", label: "Название или назначение", type: "text"))
    }

    switch kind {
    case "balance":
        if !isValidMoney(draft.amountMinor, allowZero: true) {
            questions.append(FinanceQuestion(field: "amountMinor", label: "Сумма остатка", type: "number"))
        }
        if !isValidDateString(draft.date) {
            questions.append(FinanceQuestion(field: "date", label: "Дата остатка", type: "date"))
        }
        if isValidDateString(draft.date) {
            let balanceCount = drafts.filter { $0.kind == "balance" && $0.date == draft.date }.count
            if balanceCount > 1 {
                questions.append(FinanceQuestion(
                    field: "balanceScope",
                    label: "Оставь один общий остаток на эту дату. Суммы по картам и наличным сначала сложи.",
                    type: "text"
                ))
            }
        }

    case "income", "expense":
        if !isValidMoney(draft.amountMinor, allowZero: false) {
            questions.append(FinanceQuestion(
                field: "amountMinor",
                label: kind == "income" ? "Сумма дохода" : "Сумма расхода",
                type: "number"
            ))
        }
        if !isValidDateString(draft.date) {
            questions.append(FinanceQuestion(field: "date", label: "Дата операции", type: "date"))
        }

    case "obligation", "planned_income":
        if !isValidMoney(draft.amountMinor, allowZero: false) {
            questions.append(FinanceQuestion(
                field: "amountMinor",
                label: kind == "obligation" ? "Сумма регулярного платежа" : "Сумма ожидаемого дохода",
                type: "number"
            ))
        }
        if let freq = draft.frequency {
            if !FinanceConstants.allowedFrequencies.contains(freq) {
                questions.append(FinanceQuestion(
                    field: "frequency",
                    label: "Периодичность",
                    type: "select",
                    options: ["monthly", "weekly"]
                ))
            }
        } else {
            questions.append(FinanceQuestion(
                field: "frequency",
                label: "Периодичность",
                type: "select",
                options: ["monthly", "weekly"]
            ))
        }

    case "goal":
        if !isValidMoney(draft.amountMinor, allowZero: false) {
            questions.append(FinanceQuestion(field: "amountMinor", label: "Целевая сумма накопления", type: "number"))
        }
        if draft.savedMinor == nil || !isValidMoney(draft.savedMinor, allowZero: true) {
            questions.append(FinanceQuestion(
                field: "savedMinor",
                label: "Сколько уже отложено на эту цель",
                type: "number"
            ))
        } else if isValidMoney(draft.amountMinor, allowZero: false), let saved = draft.savedMinor, let amt = draft.amountMinor, saved > amt {
            questions.append(FinanceQuestion(
                field: "savedMinor",
                label: "Сколько уже отложено на эту цель (не больше цели)",
                type: "number"
            ))
        }
        let needsDue = draft.needsDueDate == true || draft.dueDate != nil
        if needsDue && !isValidDateString(draft.dueDate) {
            questions.append(FinanceQuestion(field: "dueDate", label: "Срок накопления", type: "date"))
        }

    default:
        break
    }

    if balanceRelationNeeded(draft, drafts: drafts) {
        if draft.balanceRelation != "included" && draft.balanceRelation != "after" {
            questions.append(FinanceQuestion(
                field: "balanceRelation",
                label: "Операция уже учтена в названном остатке?",
                type: "select",
                options: ["included", "after"]
            ))
        }
    }

    return questions
}

// MARK: - Mutations

private struct PreparedDraftRecord {
    var record: FinanceRecord
    var targetId: String?
    var relation: String?
}

public func commitFinance(
    state: FinanceState,
    drafts: [FinanceDraft],
    batchId: String,
    nowDate: String
) throws -> FinanceState {
    let cleanState = try validateFinance(state)

    if batchId.isEmpty || batchId.count > FinanceConstants.maxIdLen {
        throw FinanceError.invalidDraft("Invalid batchId")
    }
    if !isValidDateString(nowDate) {
        throw FinanceError.invalidDate("Invalid nowDate")
    }

    // Repeated known batchId is a no-op
    if cleanState.committedBatches.contains(batchId) || cleanState.records.contains(where: { $0.id.hasPrefix(batchId + ":") }) {
        return cleanState
    }

    if drafts.isEmpty || drafts.count > 50 {
        throw FinanceError.invalidDraft("Drafts must contain 1..50 records")
    }

    var preparedRecords: [PreparedDraftRecord] = []

    for (i, d) in drafts.enumerated() {
        let q = financeQuestions(d, drafts: drafts)
        if !q.isEmpty {
            let missingFields = q.map { $0.field }.joined(separator: ", ")
            throw FinanceError.invalidDraft("Incomplete draft at index \(i): missing \(missingFields)")
        }

        if let recId = d.recordId {
            guard let kind = d.kind, (kind == "goal" || kind == "obligation"),
                  cleanState.records.contains(where: { $0.id == recId && $0.kind == kind })
            else {
                throw FinanceError.invalidDraft("Запись для обновления больше не существует. Обнови данные и выбери цель заново.")
            }
        }

        let id = "\(batchId):\(i)"
        if id.count > FinanceConstants.maxIdLen {
            throw FinanceError.invalidDraft("Generated record ID exceeds max length")
        }

        let title = (d.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var base = FinanceRecord(id: id, kind: d.kind ?? "", title: title)

        switch d.kind {
        case "balance":
            base.amountMinor = d.amountMinor
            base.date = d.date

        case "income", "expense":
            base.amountMinor = d.amountMinor
            base.date = d.date
            let trimmedCat = d.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            base.category = !trimmedCat.isEmpty ? trimmedCat : "Без категории"
            if d.kind == "expense" {
                base.obligationId = d.obligationId
            }

        case "obligation", "planned_income":
            base.amountMinor = d.amountMinor
            base.frequency = d.frequency
            base.date = d.date ?? nowDate

        case "goal":
            base.amountMinor = d.amountMinor
            base.savedMinor = d.savedMinor
            base.dueDate = d.dueDate
            base.date = d.date ?? nowDate

        default:
            break
        }

        let relation = balanceRelationNeeded(d, drafts: drafts) ? d.balanceRelation : nil
        preparedRecords.append(PreparedDraftRecord(record: base, targetId: d.recordId, relation: relation))
    }

    var nextRecords = cleanState.records

    let ordered = preparedRecords.filter { $0.relation == "included" }
        + preparedRecords.filter { $0.relation == nil }
        + preparedRecords.filter { $0.relation == "after" }

    for item in ordered {
        let rec = item.record
        let targetId = item.targetId

        if rec.kind == "goal" || rec.kind == "obligation" {
            let existingIdx = nextRecords.firstIndex { r in
                if r.kind != rec.kind { return false }
                if let targetId = targetId {
                    return r.id == targetId
                }
                return r.title.lowercased() == rec.title.lowercased()
            }

            if let targetId = targetId {
                if nextRecords.contains(where: { $0.id != targetId && $0.kind == rec.kind && $0.title.lowercased() == rec.title.lowercased() }) {
                    throw FinanceError.invalidDraft("Запись с таким названием уже существует. Выбери другое название.")
                }
            }

            if let idx = existingIdx {
                let old = nextRecords[idx]
                var updated = rec
                updated.id = old.id
                // A phrase about an existing envelope or payment changes what it says, not what it leaves out.
                if updated.outsideMinor == nil { updated.outsideMinor = old.outsideMinor }
                if updated.dueDate == nil { updated.dueDate = old.dueDate }
                if updated.note == nil { updated.note = old.note }
                nextRecords[idx] = updated
                continue
            }
        }
        nextRecords.append(rec)
    }

    var nextBatches = cleanState.committedBatches
    nextBatches.append(batchId)
    if nextBatches.count > FinanceConstants.maxBatches {
        nextBatches = Array(nextBatches.suffix(FinanceConstants.maxBatches))
    }

    let nextState = FinanceState(version: 1, records: nextRecords, committedBatches: nextBatches, imports: cleanState.imports, merchantCategories: cleanState.merchantCategories, budget: cleanState.budget)
    return try validateFinance(nextState)
}

public func removeFinanceRecord(state: FinanceState, id: String) throws -> FinanceState {
    let cleanState = try validateFinance(state)
    guard let target = cleanState.records.first(where: { $0.id == id }) else {
        return cleanState
    }

    let isObligation = target.kind == "obligation"
    let wasImported = target.importId != nil
    var updatedRecords: [FinanceRecord] = []

    for r in cleanState.records {
        if r.id == id {
            continue
        }
        var next = r
        if isObligation && next.kind == "expense" && next.obligationId == id {
            next.obligationId = nil
        }
        updatedRecords.append(next)
    }

    if wasImported {
        var rebuilt = FinanceState(
            version: 1, records: updatedRecords, committedBatches: cleanState.committedBatches, imports: cleanState.imports,
            merchantCategories: cleanState.merchantCategories, budget: cleanState.budget
        )
        StatementImport.rebuildBalance(&rebuilt)
        updatedRecords = rebuilt.records
    }

    return try validateFinance(FinanceState(
        version: 1,
        records: updatedRecords,
        committedBatches: cleanState.committedBatches,
        imports: cleanState.imports,
        merchantCategories: cleanState.merchantCategories,
        budget: cleanState.budget
    ))
}

// MARK: - Date and Calendar Math

func parseYmd(_ ymd: String) -> (year: Int, month: Int, day: Int)? {
    let parts = ymd.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return (parts[0], parts[1], parts[2])
}

public func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
    var y = year
    var m = month
    if m <= 2 {
        y -= 1
        m += 12
    }
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m - 3) + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

public func weekdayFromEpochDays(_ days: Int) -> Int {
    // 1970-01-01 was Thursday (index 4 in 0=Sun..6=Sat)
    let w = (days + 4) % 7
    return w >= 0 ? w : w + 7
}

public func countWeekdayDates(fromYmd: String, toYmd: String, targetWeekday: Int) -> Int {
    guard let (y1, m1, d1) = parseYmd(fromYmd),
          let (y2, m2, d2) = parseYmd(toYmd)
    else {
        return 0
    }

    let startDay = daysSinceEpoch(year: y1, month: m1, day: d1)
    let endDay = daysSinceEpoch(year: y2, month: m2, day: d2)

    if startDay > endDay { return 0 }

    var count = 0
    for day in startDay...endDay {
        if weekdayFromEpochDays(day) == targetWeekday {
            count += 1
        }
    }
    return count
}

public func getDaysInMonth(year: Int, month: Int) -> Int {
    let isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
    let daysInMonths = [0, 31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard month >= 1 && month <= 12 else { return 30 }
    return daysInMonths[month]
}

// MARK: - Finance Summary

public func financeSummary(
    _ state: FinanceState,
    today: String,
    month: String? = nil,
    horizonDays: Int = 30
) throws -> FinanceSummary {
    var cleanState = try validateFinance(state)
    cleanState.records.removeAll { $0.excluded == true }

    guard isValidDateString(today) else {
        throw FinanceError.invalidDate("Invalid today date")
    }

    let targetMonth = month ?? String(today.prefix(7))
    guard isValidMonthString(targetMonth) else {
        throw FinanceError.invalidDate("Invalid month")
    }

    guard horizonDays >= 1 && horizonDays <= 366 else {
        throw FinanceError.invalidDraft("Invalid horizonDays: must be integer 1..366")
    }

    // 1. Identify latest balance checkpoint with date <= today
    var latestBalance: FinanceRecord? = nil
    var latestBalanceIndex: Int = -1

    for (i, r) in cleanState.records.enumerated() {
        if r.kind == "balance", let rDate = r.date, rDate <= today {
            if latestBalance == nil || rDate > (latestBalance?.date ?? "") || (rDate == (latestBalance?.date ?? "") && i >= latestBalanceIndex) {
                latestBalance = r
                latestBalanceIndex = i
            }
        }
    }

    // 2. Realized income and expense for the specified month (only date <= today)
    var incomeMinor: Int64 = 0
    var expenseMinor: Int64 = 0
    var categoryOrder: [String] = []
    var categoryAmounts: [String: Int64] = [:]

    for r in cleanState.records {
        if (r.kind == "income" || r.kind == "expense"), let rDate = r.date, rDate <= today {
            if rDate.hasPrefix(targetMonth) {
                let amt = r.amountMinor ?? 0
                if r.kind == "income" {
                    incomeMinor += amt
                } else if r.kind == "expense" {
                    expenseMinor += amt
                    let cat = r.category ?? "Без категории"
                    if categoryAmounts[cat] == nil {
                        categoryOrder.append(cat)
                        categoryAmounts[cat] = amt
                    } else {
                        categoryAmounts[cat] = (categoryAmounts[cat] ?? 0) + amt
                    }
                }
            }
        }
    }

    let byCategory = categoryOrder.map { name in
        FinanceCategoryBreakdown(name: name, amountMinor: categoryAmounts[name] ?? 0)
    }
    let netMinor = incomeMinor - expenseMinor

    // 3. Current balance calculation
    var balanceMinor: Int64? = nil
    if let lb = latestBalance, let lbDate = lb.date, let lbAmt = lb.amountMinor {
        var bal = lbAmt
        for (i, r) in cleanState.records.enumerated() {
            if (r.kind == "income" || r.kind == "expense"), let rDate = r.date, rDate <= today {
                let afterCheckpointByDate = rDate > lbDate
                let sameDateLaterIndex = rDate == lbDate && i > latestBalanceIndex
                if afterCheckpointByDate || sameDateLaterIndex {
                    let amt = r.amountMinor ?? 0
                    if r.kind == "income" {
                        bal += amt
                    } else {
                        bal -= amt
                    }
                }
            }
        }
        balanceMinor = bal
    }

    // 4. Goals reserved
    var reservedGoalMinor: Int64 = 0
    for r in cleanState.records {
        if r.kind == "goal" {
            // Money kept outside the accounts was never in the balance, so it is not taken out of it.
            reservedGoalMinor += (r.savedMinor ?? 0) - (r.outsideMinor ?? 0)
        }
    }

    // 5. Obligations for current month
    guard parseYmd(today) != nil else {
        throw FinanceError.invalidDate("Invalid today date")
    }
    // One rule for «paid» across the header, the plan and the month review.
    var obligationsMinor: Int64 = 0
    for r in cleanState.records where r.kind == "obligation" {
        obligationsMinor += FinanceBudgeting.paymentStatus(cleanState, obligation: r, today: today).unpaidMinor
    }

    // 6. Planned income (informational, never increases balance/spendable)
    var plannedIncomeMinor: Int64 = 0
    let startOfMonthYmd = "\(targetMonth)-01"
    guard let (mYear, mMonth, _) = parseYmd("\(targetMonth)-01") else {
        throw FinanceError.invalidDate("Invalid month")
    }
    let daysInGivenMonth = getDaysInMonth(year: mYear, month: mMonth)
    let endOfGivenMonthYmd = String(format: "%04d-%02d-%02d", mYear, mMonth, daysInGivenMonth)

    for r in cleanState.records {
        if r.kind == "planned_income", let rDate = r.date, rDate <= endOfGivenMonthYmd {
            let amt = r.amountMinor ?? 0
            if r.frequency == "monthly" {
                plannedIncomeMinor += amt
            } else if r.frequency == "weekly" {
                let anchorDate = r.date ?? today
                guard let (ry, rm, rd) = parseYmd(anchorDate) else { continue }
                let weekday = weekdayFromEpochDays(daysSinceEpoch(year: ry, month: rm, day: rd))
                let startDate = (r.date ?? "") > startOfMonthYmd ? (r.date ?? "") : startOfMonthYmd
                let count = countWeekdayDates(fromYmd: startDate, toYmd: endOfGivenMonthYmd, targetWeekday: weekday)
                plannedIncomeMinor += amt * Int64(count)
            }
        }
    }

    // 7. Spendable, deficit, daily
    var spendableMinor: Int64? = nil
    var deficitMinor: Int64? = nil
    var dailyMinor: Int64? = nil

    if let bal = balanceMinor {
        let netAvailable = bal - reservedGoalMinor - obligationsMinor
        spendableMinor = max(0, netAvailable)
        deficitMinor = max(0, -netAvailable)
        dailyMinor = (spendableMinor ?? 0) / Int64(horizonDays)
    }

    return FinanceSummary(
        balanceMinor: balanceMinor,
        incomeMinor: incomeMinor,
        expenseMinor: expenseMinor,
        netMinor: netMinor,
        byCategory: byCategory,
        reservedGoalMinor: reservedGoalMinor,
        obligationsMinor: obligationsMinor,
        spendableMinor: spendableMinor,
        dailyMinor: dailyMinor,
        deficitMinor: deficitMinor,
        plannedIncomeMinor: plannedIncomeMinor
    )
}

// MARK: - Goal Progress

public func goalProgress(
    amountMinor: Int64,
    savedMinor: Int64,
    dueDate: String?,
    today: String
) throws -> GoalProgressResult {
    guard amountMinor >= 1 && amountMinor <= FinanceConstants.maxAmountMinor else {
        throw FinanceError.invalidAmount("amountMinor must be between 1 and 100000000000")
    }
    guard savedMinor >= 0 && savedMinor <= amountMinor else {
        throw FinanceError.invalidAmount("savedMinor must be between 0 and amountMinor")
    }
    guard isValidDateString(today), let (ty, tm, td) = parseYmd(today) else {
        throw FinanceError.invalidDate("today must be a valid YYYY-MM-DD string")
    }

    let todayDays = daysSinceEpoch(year: ty, month: tm, day: td)
    let remainingMinor = max(0, amountMinor - savedMinor)
    let progressPercent = Int((savedMinor * 100) / amountMinor)

    var daysLeft: Int? = nil
    if let due = dueDate {
        guard isValidDateString(due), let (dy, dm, dd) = parseYmd(due) else {
            throw FinanceError.invalidDate("dueDate must be a valid YYYY-MM-DD string")
        }
        let dueDays = daysSinceEpoch(year: dy, month: dm, day: dd)
        daysLeft = max(0, dueDays - todayDays + 1)
    }

    let status: String
    if savedMinor == amountMinor {
        status = "complete"
    } else if let due = dueDate, due < today {
        status = "overdue"
    } else if dueDate != nil {
        status = "active"
    } else {
        status = "no_deadline"
    }

    var requiredDailyMinor: Int64? = nil
    if status == "complete" {
        requiredDailyMinor = 0
    } else if dueDate == nil || status == "overdue" {
        requiredDailyMinor = nil
    } else if let dl = daysLeft, dl > 0 {
        let quotient = remainingMinor / Int64(dl)
        let remainder = remainingMinor % Int64(dl)
        requiredDailyMinor = remainder == 0 ? quotient : quotient + 1
    } else {
        requiredDailyMinor = remainingMinor
    }

    return GoalProgressResult(
        remainingMinor: remainingMinor,
        progressPercent: progressPercent,
        daysLeft: daysLeft,
        requiredDailyMinor: requiredDailyMinor,
        status: status
    )
}

// MARK: - Text Parsing

public func parseKzt(_ value: Any?) throws -> Int64 {
    let raw = "\(value ?? "")"
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    text = text.replacingOccurrences(of: "\u{00a0}", with: " ")
    text = text.replacingOccurrences(of: "\u{202f}", with: " ")

    let suffixes = ["тенге", "тг", "kzt", "₸"]
    for s in suffixes {
        if text.hasSuffix(s) {
            text = String(text.dropLast(s.count)).trimmingCharacters(in: .whitespaces)
        }
    }

    let pattern = "^(\\d[\\d ]*(?:[.,]\\d{1,2})?)?\\s*(тыс\\.?|тысяч[аи]?|миллион(?:а|ов)?|млн)?(?:\\s+(\\d[\\d ]*(?:[.,]\\d{1,2})?))?$"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        throw FinanceError.invalidAmount("Укажи сумму числом, например 2500 или 8,5 тыс.")
    }

    let nsText = text as NSString
    guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) else {
        throw FinanceError.invalidAmount("Укажи сумму числом, например 2500 или 8,5 тыс.")
    }

    let group1 = match.range(at: 1).location != NSNotFound ? nsText.substring(with: match.range(at: 1)) : nil
    let group2 = match.range(at: 2).location != NSNotFound ? nsText.substring(with: match.range(at: 2)) : nil
    let group3 = match.range(at: 3).location != NSNotFound ? nsText.substring(with: match.range(at: 3)) : nil

    if (group1 == nil && group2 == nil) || (group2 == nil && group3 != nil) {
        throw FinanceError.invalidAmount("Укажи сумму числом, например 2500 или 8,5 тыс.")
    }

    func parseMinor(_ s: String) throws -> Int64 {
        let trimmed = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.components(separatedBy: ".")
        let intPart = parts[0]
        if intPart.contains(" ") {
            let spaceRegex = try? NSRegularExpression(pattern: "^\\d{1,3}(?: \\d{3})+$")
            let hasMatch = spaceRegex?.firstMatch(in: intPart, range: NSRange(location: 0, length: (intPart as NSString).length)) != nil
            if !hasMatch {
                throw FinanceError.invalidAmount("Проверь пробелы в сумме.")
            }
        }
        let intVal = Int64(intPart.replacingOccurrences(of: " ", with: "")) ?? 0
        var fracStr = parts.count > 1 ? parts[1] : ""
        if fracStr.count > 2 {
            fracStr = String(fracStr.prefix(2))
        }
        while fracStr.count < 2 {
            fracStr.append("0")
        }
        let fracVal = Int64(fracStr) ?? 0
        return intVal * 100 + fracVal
    }

    let multiplier: Int64
    if let g2 = group2 {
        let isMln = g2.hasPrefix("млн") || g2.hasPrefix("миллион")
        multiplier = isMln ? 1_000_000 : 1_000
    } else {
        multiplier = 1
    }

    let baseMinor: Int64
    if let g1 = group1 {
        baseMinor = try parseMinor(g1)
    } else {
        baseMinor = 100
    }

    let additionMinor: Int64
    if let g3 = group3 {
        additionMinor = try parseMinor(g3)
    } else {
        additionMinor = 0
    }

    let result = baseMinor * multiplier + additionMinor
    if result < 0 || result > FinanceConstants.maxAmountMinor {
        throw FinanceError.invalidAmount("Сумма вне допустимого диапазона.")
    }

    return result
}

private func extractSingleMoney(_ text: String) -> (raw: String, value: Int64)? {
    let pattern = "(?:\\d{1,3}(?:[ \\u00a0]\\d{3})+|\\d+)(?:[.,]\\d{1,2})?(?:\\s*(?:тысяч[аи]?|тыс\\.?|миллион(?:а|ов)?|млн)(?:\\s+\\d{1,3}(?!\\d))?)?|миллион(?:а|ов)?"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }

    let nsText = text as NSString
    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
    if matches.count != 1 {
        return nil
    }

    let signRegex = try? NSRegularExpression(pattern: "(?:^|\\s)[-+]\\s*\\d")
    if signRegex?.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) != nil {
        return nil
    }

    let match = matches[0]
    let raw = nsText.substring(with: match.range)
    let rest = nsText.substring(to: match.range.location) + nsText.substring(from: match.range.location + match.range.length)

    let restRegex = try? NSRegularExpression(pattern: "[\\d]|тысяч|миллион|млн", options: [.caseInsensitive])
    if restRegex?.firstMatch(in: rest, options: [], range: NSRange(location: 0, length: (rest as NSString).length)) != nil {
        return nil
    }

    let afterStr = nsText.substring(from: match.range.location + match.range.length)
    let dotRegex = try? NSRegularExpression(pattern: "^[.,]\\d")
    if dotRegex?.firstMatch(in: afterStr, options: [], range: NSRange(location: 0, length: (afterStr as NSString).length)) != nil {
        return nil
    }

    do {
        let val = try parseKzt(raw)
        return (raw, val)
    } catch {
        return nil
    }
}

public func parseFinanceText(
    _ text: String,
    today: String,
    kindHint: String? = nil
) throws -> [FinanceDraft] {
    if text.count > 10000 || !isValidDateString(today) {
        throw FinanceError.invalidDraft("Проверь текст и дату.")
    }

    let splitPattern = "[;\\n]+|,\\s+а\\s+(?=(?:я )?(?:получ|потрат|заплат|у меня|хочу|кажд))"
    guard let splitRegex = try? NSRegularExpression(pattern: splitPattern, options: [.caseInsensitive]) else {
        return []
    }

    let nsText = text as NSString
    var clauses: [String] = []
    var lastIndex = 0

    let matches = splitRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
    for m in matches {
        let clause = nsText.substring(with: NSRange(location: lastIndex, length: m.range.location - lastIndex)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !clause.isEmpty {
            clauses.append(clause)
        }
        lastIndex = m.range.location + m.range.length
    }
    let tail = nsText.substring(from: lastIndex).trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty {
        clauses.append(tail)
    }

    let months = "января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря"

    func regexTest(_ pattern: String, in str: String) -> Bool {
        guard let reg = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return reg.firstMatch(in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length)) != nil
    }

    func regexMatches(_ pattern: String, in str: String) -> [String] {
        guard let reg = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = str as NSString
        let ms = reg.matches(in: str, options: [], range: NSRange(location: 0, length: ns.length))
        return ms.map { ns.substring(with: $0.range) }
    }

    var drafts: [FinanceDraft] = []

    for clause in clauses {
        let lower = clause.lowercased()

        let frequency: String?
        if regexTest("кажд(?:ый месяц|ого месяца)|ежемесячно", in: lower) {
            frequency = "monthly"
        } else if regexTest("каждую неделю|еженедельно", in: lower) {
            frequency = "weekly"
        } else {
            frequency = nil
        }

        var kind: String? = nil
        let spent = regexTest("потратил[аи]?|заплатил[аи]?|купил[аи]?|оплатил[аи]?", in: lower)
        let earned = regexTest("получил[аи]?|заработал[аи]?|пришло", in: lower)
        let snapshot = regexTest("остаток|осталось|всего сейчас|сейчас есть", in: lower)

        if regexTest("хочу накопить|цель|коплю на", in: lower) {
            kind = "goal"
        } else if frequency != nil {
            let incoming = regexTest("получаю|приходит|зарабатываю|доход|зарплата", in: lower)
            let outgoing = regexTest("плачу|оплачиваю|плат[её]ж|тариф|абонемент|подписка|расход", in: lower)
            if incoming != outgoing {
                kind = incoming ? "planned_income" : "obligation"
            }
        } else if (spent || earned) && !snapshot {
            if spent != earned {
                kind = spent ? "expense" : "income"
            }
        } else if !spent && !earned &&
                    !regexTest("долг|кредит|рассроч|будет|буду|получу|зарплат|расход|доход|плат[её]ж|заплатить|оплатить|потратить|накопить", in: lower) &&
                    (snapshot || regexTest("у меня\\s+(?:сейчас(?:\\s+есть)?|есть)\\s", in: lower)) {
            kind = "balance"
        }

        if let hint = kindHint {
            kind = hint
        }

        var date: String? = nil
        let explicit = regexMatches("\\d{4}-\\d{2}-\\d{2}|\\d{1,2}[./]\\d{1,2}[./]\\d{4}", in: lower)
        var iso: String? = nil
        if explicit.count == 1 {
            let exp = explicit[0]
            if exp.contains("-") {
                iso = exp
            } else {
                let parts = exp.split(whereSeparator: { $0 == "." || $0 == "/" }).map { String($0) }
                if parts.count == 3 {
                    let dStr = parts[0].count == 1 ? "0" + parts[0] : parts[0]
                    let mStr = parts[1].count == 1 ? "0" + parts[1] : parts[1]
                    iso = "\(parts[2])-\(mStr)-\(dStr)"
                }
            }
        }

        let relative = regexMatches("позавчера|вчера|сегодня", in: lower)
        let uncertainDate = explicit.count > 1 || relative.count > 1 ||
            regexTest("прошл|назад|раньше|позже|на той неделе|завтра|понедельник|вторник|сред[ау]|четверг|пятниц|суббот|воскресенье|январ|феврал|март|апрел|ма[йея]|июн|июл|август|сентябр|октябр|ноябр|декабр", in: lower)

        if let singleIso = iso, !uncertainDate {
            date = singleIso
        } else if uncertainDate {
            date = nil
        } else if regexTest("позавчера", in: lower) {
            if let (ty, tm, td) = parseYmd(today) {
                let dDays = daysSinceEpoch(year: ty, month: tm, day: td) - 2
                date = dateFromEpochDays(dDays)
            }
        } else if regexTest("вчера", in: lower) {
            if let (ty, tm, td) = parseYmd(today) {
                let dDays = daysSinceEpoch(year: ty, month: tm, day: td) - 1
                date = dateFromEpochDays(dDays)
            }
        } else if let k = kind, (k == "balance" || k == "income" || k == "expense") {
            date = today
        }

        var numericText = clause
        if let regDate = try? NSRegularExpression(pattern: "\\d{4}-\\d{2}-\\d{2}|\\d{1,2}[./]\\d{1,2}[./]\\d{4}", options: [.caseInsensitive]) {
            numericText = regDate.stringByReplacingMatches(in: numericText, options: [], range: NSRange(location: 0, length: (numericText as NSString).length), withTemplate: "")
        }
        if let regMonth = try? NSRegularExpression(pattern: "(?:до|к)?\\s*\\d{1,2}\\s+(?:\(months))(?:\\s+\\d{4})?", options: [.caseInsensitive]) {
            numericText = regMonth.stringByReplacingMatches(in: numericText, options: [], range: NSRange(location: 0, length: (numericText as NSString).length), withTemplate: "")
        }

        var savedPart: String? = nil
        var targetText = numericText
        if kind == "goal" {
            let goalSavedPattern = "(?:уже\\s+)?(?:отложено|накоплено|накопил[аи]?)\\s+(.+)$"
            if let regSaved = try? NSRegularExpression(pattern: goalSavedPattern, options: [.caseInsensitive]) {
                let ns = numericText as NSString
                if let match = regSaved.firstMatch(in: numericText, options: [], range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 {
                    savedPart = ns.substring(with: match.range(at: 1))
                }
            }

            let splitGoalPattern = "(?:уже\\s+)?(?:отложено|накоплено|накопил[аи]?)"
            if let regSplit = try? NSRegularExpression(pattern: splitGoalPattern, options: [.caseInsensitive]) {
                let ns = numericText as NSString
                if let match = regSplit.firstMatch(in: numericText, options: [], range: NSRange(location: 0, length: ns.length)) {
                    targetText = ns.substring(to: match.range.location)
                }
            }
        }

        let moneyMatch = extractSingleMoney(targetText)
        var titleStr = targetText
        if let mm = moneyMatch {
            titleStr = titleStr.replacingOccurrences(of: mm.raw, with: "")
        }

        let stopWords = "(?:каждый месяц|ежемесячно|каждую неделю|еженедельно|хочу накопить|цель накопить|цель|коплю|потратил[аи]?|заплатил[аи]?|купил[аи]?|оплатил[аи]?|получил[аи]?|заработал[аи]?|пришло|получаю|зарабатываю|плачу|оплачиваю|сегодня|позавчера|вчера|тенге|тг|kzt|₸)"
        if let regStop = try? NSRegularExpression(pattern: stopWords, options: [.caseInsensitive]) {
            titleStr = regStop.stringByReplacingMatches(in: titleStr, options: [], range: NSRange(location: 0, length: (titleStr as NSString).length), withTemplate: " ")
        }
        if let regPre = try? NSRegularExpression(pattern: "^\\s*(?:я\\s+)?(?:на|за|для)\\s+", options: [.caseInsensitive]) {
            titleStr = regPre.stringByReplacingMatches(in: titleStr, options: [], range: NSRange(location: 0, length: (titleStr as NSString).length), withTemplate: "")
        }
        if let regMonthEnd = try? NSRegularExpression(pattern: "(?:до|к)\\s*\\d{1,2}\\s*(?:\(months))(?:\\s*\\d{4})?", options: [.caseInsensitive]) {
            titleStr = regMonthEnd.stringByReplacingMatches(in: titleStr, options: [], range: NSRange(location: 0, length: (titleStr as NSString).length), withTemplate: "")
        }

        titleStr = titleStr.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        titleStr = titleStr.trimmingCharacters(in: CharacterSet(charactersIn: ", ."))

        if kind == "balance" {
            titleStr = "Остаток"
        }
        if kind == "goal" {
            if let regDueTrail = try? NSRegularExpression(pattern: "\\s+(?:до|к)\\s*$", options: [.caseInsensitive]) {
                titleStr = regDueTrail.stringByReplacingMatches(in: titleStr, options: [], range: NSRange(location: 0, length: (titleStr as NSString).length), withTemplate: "")
            }
            titleStr = titleStr.trimmingCharacters(in: .whitespaces)
        }

        var finalTitle: String? = titleStr
        if titleStr.isEmpty || regexTest("^(?:на|за|для|я)$", in: titleStr) {
            finalTitle = nil
        } else {
            let firstChar = titleStr.prefix(1).uppercased()
            finalTitle = firstChar + titleStr.dropFirst()
        }

        let category: String
        // The same names statements and limits use (MerchantCategories), so typed and imported spending add up.
        if regexTest("обед|ужин|завтрак|кафе|ресторан|кофе", in: lower) {
            category = "Кафе и рестораны"
        } else if regexTest("еда|продукт", in: lower) {
            category = "Продукты"
        } else if regexTest("такси|автобус|метро|транспорт|проезд", in: lower) {
            category = "Транспорт"
        } else if regexTest("тариф|телефон|интернет|связь", in: lower) {
            category = "Связь и интернет"
        } else {
            category = "Без категории"
        }

        let savedMinorVal: Int64?
        if let sp = savedPart, let sm = extractSingleMoney(sp) {
            savedMinorVal = sm.value
        } else {
            savedMinorVal = nil
        }

        let isDateExcludedKind = kind == "goal" || kind == "obligation" || kind == "planned_income"
        let finalDate = isDateExcludedKind ? nil : date
        let dueDateVal = (kind == "goal" && iso != nil) ? iso : nil
        let needsDueVal = (kind == "goal") && regexTest("(?:до|к)\\s+(?:\\d|следующ|конц)", in: clause)

        let draft = FinanceDraft(
            kind: kind,
            title: finalTitle,
            amountMinor: moneyMatch?.value,
            date: finalDate,
            category: category,
            obligationId: nil,
            frequency: frequency,
            savedMinor: savedMinorVal,
            dueDate: dueDateVal,
            needsDueDate: needsDueVal,
            recordId: nil,
            balanceRelation: nil
        )
        drafts.append(draft)
    }

    return drafts
}

public func dateFromEpochDays(_ days: Int) -> String {
    let z = days + 719468
    let era = (z >= 0 ? z : z - 146096) / 146097
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    let finalYear = m <= 2 ? y + 1 : y
    return String(format: "%04d-%02d-%02d", finalYear, m, d)
}
