import Foundation

// Учёт по счетам (docs/finance/ACCOUNTS-SPEC-2026-11-27.md): счета, переводы между ними, остатки.
// Сайт видит только обычные доходы и расходы; переводы там помечены `excluded`. Чистая логика.

/// One of the owner's cards, accounts, deposits, or cash.
public struct FinanceAccount: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// «Halyk», «Kaspi» or «Cash».
    public var bank: String
    /// card | account | deposit | cash
    public var kind: String
    public var name: String
    /// Every mask statements write it by: «card:0006», «kz:0004».
    public var identifiers: [String]
    /// What was on it at the end of `anchorDate`; the balance is counted from here both ways.
    public var anchorMinor: Int64?
    public var anchorDate: String?
    /// Bank closing balances the owner accepted; each keeps a «Корректировка» while operations are missing.
    public var accepted: [FinanceBankBalance]?
}

public struct FinanceBankBalance: Codable, Equatable, Sendable {
    public var date: String
    public var minor: Int64
}

/// The text of an imported statement, so a better parser can read it again.
public struct FinanceStatementSource: Codable, Equatable, Sendable {
    public var importId: String
    public var parserVersion: Int
    /// zlib: the server takes records of a limited size.
    public var text: Data
    /// The accounts the statement covers.
    public var accounts: [String]
}

/// The owner's answer about one operation, kept by its fingerprint so it outlives re-reading and web edits.
public struct FinanceDecision: Codable, Equatable, Sendable {
    /// True: a transfer, out of the totals. False: spending or income.
    public var excluded: Bool
    /// The fingerprint of the other side.
    public var other: String?
    /// The other account, when there is no other side.
    public var account: String?
    public var category: String?
}

public struct FinanceTransfer: Codable, Equatable, Sendable {
    public var from: String?
    public var to: String?
}

public struct FinanceLedgerState: Codable, Equatable, Sendable {
    public var accounts: [FinanceAccount] = []
    public var statements: [FinanceStatementSource] = []
    /// Fingerprints of operations deleted one by one: loading the statement again does not bring them back.
    public var removed: [String] = []
    /// Another person's name as statements write it (lowercased) → family | debt | gift | work | own.
    public var people: [String: String] = [:]
    /// The owner's names from statement headers, «first|surname», lowercased.
    public var owners: [String] = []
    public var decisions: [String: FinanceDecision] = [:]

    public init() {}
}

public enum FinanceLedger {
    /// Raise when a parser change should re-read stored statements.
    public static var parserVersion = 1
    /// Halyk's fee for a transfer to another bank, by the day it takes effect.
    public static var feeTable: [(from: String, minor: Int64)] = [("2000-01-01", 20_000), ("2026-11-27", 25_000)]
    static let feeCategory = "Комиссии"
    static let peopleCategory = "Люди"
    static let adjustmentTitle = "Корректировка"
    public static let people: [(rule: String, label: String)] = [("family", "Семья"), ("debt", "Долг"), ("gift", "Подарок"), ("work", "Работа")]
    public static let cashId = "acc-cash"

    static func fee(_ date: String) -> Int64 { feeTable.last { $0.from <= date }?.minor ?? 0 }

    // MARK: - What a line is

    /// The kind of money movement a statement line is, from its words; nil for an ordinary purchase or income.
    static func hint(_ t: ParsedStatement.Transaction, index: Int, statement: ParsedStatement) -> String? {
        let text = (t.operation + " " + t.details + " " + (t.bankCategory ?? "")).lowercased()
        func find(_ pattern: String) -> String? {
            text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
        }
        let report = statement.account == ParsedStatement.allAccounts
        if find("комиссия за перевод") != nil { return "fee" }
        if statement.bank == .halyk {
            if find("between own|между своими") != nil { return report ? "own-card" : "own" }
            if t.amountMinor < 0, let card = find(#"(transfer to card|перевод на карту) \*\d{4}"#) { return "card:" + card.suffix(4) }
            if let name = statement.counterparties[index] { return "name:" + name }
            if find(#"(via|payment) terminal|через терминал|\batm\b|снятие налич|банкомат|cash withdrawal"#) != nil { return "cash" }
            if BankStatementParser.halykTransferDetails.contains(t.details) || find("outgoing transfer|исходящий перевод") != nil { return "out" }
        } else {
            // Interest («Проценты по Kaspi Депозиту») is income, not the owner's money moving.
            if t.operation == "Вознаграждение" { return nil }
            if find("kaspi депозит|своего сч[её]та|на свой сч|на карту на kaspi|с kaspi gold|на kaspi gold") != nil { return "deposit" }
            if t.operation == "Снятие" || (t.operation == "Пополнение" && find("банкомат|терминал") != nil) { return "cash" }
            if find(#"другого банка|др\. банка"#) != nil { return "out" }
            if t.operation == "Перевод" || t.operation == "Пополнение" {
                let details = t.details.hasPrefix("Возврат ") ? String(t.details.dropFirst(8)) : t.details
                let parts = details.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if let name = parts.first, name.range(of: #"^\p{L}[\p{L}\-]* \p{L}\.$"#, options: .regularExpression) != nil {
                    return "name:" + name + (parts.count > 1 ? "|" + parts[1] : "")
                }
            }
        }
        if StatementImport.isOwnTransfer(t, ownerFirstName: statement.ownerFirstName) { return "own" }
        return report && t.operation == "Перевод" ? "unknown" : nil
    }

    /// Halyk writes its fee as one more outgoing transfer right after the transfer, the same day.
    static func markFees(_ records: inout [FinanceRecord]) {
        func sends(_ r: FinanceRecord) -> Bool { r.kind == "expense" && (r.hint == "out" || r.hint?.hasPrefix("card:") == true) }
        for i in records.indices where records[i].hint == "out" && records[i].kind == "expense" {
            let r = records[i]
            guard let date = r.date, r.amountMinor == fee(date),
                  records.contains(where: { sends($0) && $0.accountId == r.accountId && $0.date == date && $0.amountMinor != fee(date) }) else { continue }
            records[i].hint = "fee"
            records[i].category = feeCategory
        }
    }

    // MARK: - Accounts

    /// The account for a preview's «bank|kind|identifier», found by any of its masks or created.
    static func resolve(_ provisional: String, statement: ParsedStatement, in ledger: inout FinanceLedgerState) -> String {
        let parts = provisional.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return provisional }
        let (bank, kind) = (parts[0], parts[1])
        let masks = parts[2].isEmpty ? statement.identifiers : [parts[2]]
        let found = ledger.accounts.firstIndex { $0.bank == bank && !Set($0.identifiers).isDisjoint(with: masks) }
            // A deposit made up for a transfer has no mask yet; a statement without a number joins the bank's account.
            ?? ledger.accounts.firstIndex { $0.bank == bank && $0.kind == kind && (masks.isEmpty || (kind == "deposit" && $0.identifiers.isEmpty)) }
        if let found {
            ledger.accounts[found].identifiers += masks.filter { !ledger.accounts[found].identifiers.contains($0) }
            return ledger.accounts[found].id
        }
        return create(bank: bank, kind: kind, masks: masks, in: &ledger)
    }

    @discardableResult
    static func create(bank: String, kind: String, masks: [String], in ledger: inout FinanceLedgerState) -> String {
        let digits = masks.first.map { String($0.suffix(4)) }
        let base = (["acc", bank.lowercased(), kind] + (digits.map { [$0] } ?? [])).joined(separator: "-")
        var id = bank == "Cash" ? cashId : base
        var n = 2
        while ledger.accounts.contains(where: { $0.id == id }) { id = "\(base)-\(n)"; n += 1 }
        let name: String
        switch (bank, kind) {
        case ("Cash", _): name = "Наличные"
        case (_, "deposit"): name = "\(bank) Депозит"
        case ("Kaspi", _): name = "Kaspi Gold"
        case (_, "account"): name = "\(bank) счёт"
        default: name = bank
        }
        ledger.accounts.append(FinanceAccount(id: id, bank: bank, kind: kind, name: name + (digits.map { " *" + $0 } ?? ""), identifiers: masks))
        return id
    }

    private static func cashAccount(in ledger: inout FinanceLedgerState) -> String {
        if ledger.accounts.contains(where: { $0.id == cashId }) { return cashId }
        return create(bank: "Cash", kind: "cash", masks: [], in: &ledger)
    }

    /// Gives every record of a preview its account and fingerprint «account:date:signed amount:repeat within the day».
    static func assign(_ preview: StatementImport.Preview, in ledger: inout FinanceLedgerState) -> [FinanceRecord] {
        var resolved: [String: String] = [:]
        var repeats: [String: Int] = [:]
        return preview.records.map { record in
            var r = record
            if let provisional = r.accountId {
                if resolved[provisional] == nil { resolved[provisional] = resolve(provisional, statement: preview.statement, in: &ledger) }
                let id = resolved[provisional] ?? provisional
                r.accountId = id
                let key = "\(id):\(r.date ?? ""):\(signed(r))"
                repeats[key, default: 0] += 1
                r.fp = "\(key):\(repeats[key] ?? 1)"
            }
            return r
        }
    }

    static func signed(_ r: FinanceRecord) -> Int64 { r.kind == "income" ? r.amountMinor ?? 0 : -(r.amountMinor ?? 0) }

    /// The amount the statement wrote, from the fingerprint: a transfer's fee may have been split off it.
    static func wholeAmount(_ r: FinanceRecord) -> Int64? {
        guard let parts = r.fp?.split(separator: ":"), parts.count == 4, let whole = Int64(parts[2]) else { return nil }
        return abs(whole)
    }

    // MARK: - Linking

    /// «name|bank» of a «name:…» hint.
    private static func person(_ r: FinanceRecord) -> (name: String, bank: String?)? {
        guard let hint = r.hint, hint.hasPrefix("name:") else { return nil }
        let parts = hint.dropFirst(5).split(separator: "|", maxSplits: 1).map(String.init)
        guard let name = parts.first else { return nil }
        return (name, parts.count > 1 ? parts[1] : nil)
    }

    /// «TESTOV ARMAN», «Арман Тестов» or «АРМАН Т.» against the names statement headers gave.
    static func isOwner(_ name: String, owners: [String]) -> Bool {
        let words = name.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        guard words.count >= 2 else { return false }
        return owners.contains { owner in
            let parts = owner.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts[0].count > 1, let initial = parts[1].first else { return false }
            let (first, surname) = (parts[0], parts[1])
            return (words[0] == first && (words[1] == surname || words[1] == String(initial))) || (words[0] == surname && words[1] == first)
        }
    }

    private static func partnerBank(_ r: FinanceRecord) -> String? {
        guard let bank = person(r)?.bank?.lowercased() else { return nil }
        return bank.contains("halyk") ? "Halyk" : bank.contains("kaspi") ? "Kaspi" : bank
    }

    private static func days(_ a: FinanceRecord, _ b: FinanceRecord) -> Int {
        guard let x = StatementImport.dayNumber(a.date), let y = StatementImport.dayNumber(b.date) else { return .max }
        return abs(x - y)
    }

    /// Whether a statement of the account includes the day.
    static func covers(_ accountId: String, _ date: String, in state: FinanceState) -> Bool {
        (state.ledger?.statements ?? []).contains { source in
            source.accounts.contains(accountId) && (state.imports ?? []).contains {
                $0.id == source.importId && ($0.periodStart ?? "9") <= date && date <= ($0.periodEnd ?? "")
            }
        }
    }

    /// Works out every transfer again from the lines' hints and the owner's answers. Running it twice changes nothing.
    public static func link(_ state: inout FinanceState) {
        var ledger = state.ledger ?? FinanceLedgerState()
        let labels = Set(people.map { $0.label })
        // Fee rows split out of a transfer are made again.
        state.records.removeAll { $0.id.hasSuffix("-fee") && $0.importId != nil && $0.ownerEdited != true }
        var records = state.records
        for i in records.indices where records[i].hint != nil && records[i].hint != "fee" {
            records[i].excluded = nil
            records[i].pairedWith = nil
            records[i].transfer = nil
            records[i].status = nil
            if let note = records[i].note, note == StatementImport.ownTransferNote || labels.contains(note) { records[i].note = nil }
            // A transfer that had its fee split out gets its whole amount back.
            if records[i].hint?.hasPrefix("card:") == true || records[i].hint == "out", records[i].ownerEdited != true,
               let whole = wholeAmount(records[i]) {
                records[i].amountMinor = whole
            }
        }

        var done = Set<Int>()
        var derived: [FinanceRecord] = []
        func isFree(_ i: Int) -> Bool { !done.contains(i) }
        func pair(_ a: Int, _ b: Int) {
            let (e, n) = records[a].kind == "expense" ? (a, b) : (b, a)
            let transfer = FinanceTransfer(from: records[e].accountId, to: records[n].accountId)
            for (i, other) in [(e, n), (n, e)] {
                records[i].excluded = true
                records[i].pairedWith = records[other].id
                records[i].transfer = transfer
                records[i].status = nil
                if records[i].note == nil { records[i].note = StatementImport.ownTransferNote }
                done.insert(i)
            }
        }
        func oneSided(_ i: Int, _ other: String?) {
            let r = records[i]
            records[i].excluded = true
            records[i].transfer = r.kind == "expense" ? FinanceTransfer(from: r.accountId, to: other) : FinanceTransfer(from: other, to: r.accountId)
            records[i].status = nil
            // A line the words say nothing about, left out by hand, is not named a transfer.
            if records[i].note == nil, r.hint != nil { records[i].note = StatementImport.ownTransferNote }
            done.insert(i)
        }
        func review(_ i: Int) {
            records[i].status = "review"
            done.insert(i)
        }
        /// The sender keeps only what arrived; the rest is the bank's fee, a line of its own.
        func split(_ i: Int, received: Int64) {
            let r = records[i]
            guard let sent = r.amountMinor, sent > received, r.ownerEdited != true, let fp = r.fp,
                  !ledger.removed.contains(fp + ":fee") else { return }
            records[i].amountMinor = received
            let id = r.id + "-fee"
            guard !records.contains(where: { $0.id == id }) else { return }
            var row = FinanceRecord(id: id, kind: "expense", title: "Комиссия за перевод", amountMinor: sent - received,
                                    date: r.date, category: feeCategory)
            row.importId = r.importId
            row.accountId = r.accountId
            row.fp = fp + ":fee"
            row.hint = "fee"
            derived.append(row)
        }

        // 0. The owner's answers come first.
        var byFp: [String: Int] = [:]
        for (i, r) in records.enumerated() { if let fp = r.fp { byFp[fp] = i } }
        for (fp, decision) in ledger.decisions.sorted(by: { $0.key < $1.key }) {
            guard let i = byFp[fp], isFree(i) else { continue }
            if let category = decision.category { records[i].category = category }
            if !decision.excluded {
                records[i].excluded = nil
                records[i].pairedWith = nil
                records[i].transfer = nil
                records[i].status = nil
                done.insert(i)
            } else if let other = decision.other {
                // A partner that is gone leaves the line to the rules below.
                if let j = byFp[other], isFree(j) { pair(i, j) }
            } else {
                oneSided(i, decision.account)
            }
        }

        func openLines(_ matching: (FinanceRecord) -> Bool) -> [Int] {
            records.indices.filter { isFree($0) && matching(records[$0]) }.sorted { (records[$0].date ?? "") < (records[$1].date ?? "") }
        }

        // 1. Between the owner's cards inside one report: both sides are there.
        for e in openLines({ $0.hint == "own-card" && $0.kind == "expense" }) {
            let r = records[e]
            if let n = openLines({ $0.hint == "own-card" && $0.kind == "income" }).first(where: {
                records[$0].date == r.date && records[$0].amountMinor == r.amountMinor && records[$0].accountId != r.accountId
            }) { pair(e, n) }
        }
        for i in openLines({ $0.hint == "own-card" }) { oneSided(i, nil) }

        // 2. «Transfer to card *NNNN» of a known card of the owner.
        for e in openLines({ $0.hint?.hasPrefix("card:") == true }) {
            let r = records[e]
            let targets = ledger.accounts.filter { $0.identifiers.contains(r.hint ?? "") && $0.id != r.accountId }
            guard targets.count == 1, let sent = r.amountMinor else { review(e); continue }
            // The amount includes the fee. A known card is a strong sign: any difference up to 1 000 ₸.
            let candidates = openLines {
                $0.kind == "income" && $0.accountId == targets[0].id && ($0.amountMinor ?? 0) <= sent
                    && sent - ($0.amountMinor ?? 0) <= 100_000 && days($0, r) <= 1
            }
            func rank(_ i: Int) -> (Int64, Int) { (sent - (records[i].amountMinor ?? 0), days(records[i], r)) }
            let arrived = candidates.min { rank($0) < rank($1) }
            if let n = arrived {
                split(e, received: records[n].amountMinor ?? sent)
                pair(e, n)
            } else {
                oneSided(e, targets[0].id)
            }
        }

        // 3. Kaspi's own deposit: always the owner's money, with or without the deposit's statement.
        let isDeposit = { (id: String?) in ledger.accounts.contains { $0.id == id && $0.kind == "deposit" } }
        for gap in 0...1 {
            for e in openLines({ $0.hint == "deposit" && $0.kind == "expense" }) {
                let r = records[e]
                if let n = openLines({ $0.hint == "deposit" && $0.kind == "income" }).first(where: {
                    records[$0].amountMinor == r.amountMinor && days(records[$0], r) <= gap
                        && isDeposit(records[$0].accountId) != isDeposit(r.accountId)
                }) { pair(e, n) }
            }
        }
        for i in openLines({ $0.hint == "deposit" }) {
            if isDeposit(records[i].accountId) {
                let cards = ledger.accounts.filter { $0.bank == "Kaspi" && $0.kind == "card" }
                oneSided(i, cards.count == 1 ? cards[0].id : nil)
            } else {
                var deposit = ledger.accounts.first { $0.bank == "Kaspi" && $0.kind == "deposit" }?.id
                if deposit == nil { deposit = create(bank: "Kaspi", kind: "deposit", masks: [], in: &ledger) }
                oneSided(i, deposit)
            }
        }

        // 4. Cash taken out or put back in.
        for i in openLines({ $0.hint == "cash" }) { oneSided(i, cashAccount(in: &ledger)) }

        // 5. Between banks.
        let banks = Dictionary(ledger.accounts.map { ($0.id, $0.bank) }, uniquingKeysWith: { a, _ in a })
        let owners = ledger.owners
        func isCross(_ r: FinanceRecord) -> Bool {
            r.hint == "out" || r.hint == "own" || person(r).map { isOwner($0.name, owners: owners) } == true
        }
        func possible(_ e: FinanceRecord, _ n: FinanceRecord) -> Bool {
            guard e.kind == "expense", n.kind == "income", let a = banks[e.accountId ?? ""], let b = banks[n.accountId ?? ""] else { return false }
            // Inside one bank only a side naming the owner makes two accounts a pair.
            guard a != b || (e.accountId != n.accountId && [e, n].contains { person($0) != nil && isCross($0) }) else { return false }
            return (partnerBank(e) ?? b) == b && (partnerBank(n) ?? a) == a
        }
        func automatic(_ e: FinanceRecord, _ n: FinanceRecord) -> Bool {
            let (sent, got) = (e.amountMinor ?? 0, n.amountMinor ?? 0)
            return possible(e, n) && days(e, n) <= 1 && (sent == got || sent - got == fee(e.date ?? ""))
        }
        // Only a pair that is each other's single candidate is joined without asking.
        var joined = true
        while joined {
            joined = false
            let senders = openLines { isCross($0) && $0.kind == "expense" }
            let receivers = openLines { isCross($0) && $0.kind == "income" }
            for e in senders where isFree(e) {
                let found = receivers.filter { isFree($0) && automatic(records[e], records[$0]) }
                guard found.count == 1, senders.filter({ isFree($0) && automatic(records[$0], records[found[0]]) }).count == 1 else { continue }
                split(e, received: records[found[0]].amountMinor ?? 0)
                pair(e, found[0])
                joined = true
            }
        }
        let unpaired = openLines(isCross)
        var waiting: [Int] = [], unsure: [Int] = []
        for i in unpaired where records[i].hint == "out" {
            let r = records[i]
            let close = unpaired.contains { j in
                let (e, n) = r.kind == "expense" ? (r, records[j]) : (records[j], r)
                let (sent, got) = (e.amountMinor ?? 0, n.amountMinor ?? 0)
                return possible(e, n) && days(e, n) <= 3 && abs(sent - got) * 100 <= max(sent, got) * 3
            }
            // No statement of another bank for that day yet: the other side may still come.
            let otherBankSeen = ledger.statements.flatMap(\.accounts).contains {
                banks[$0] != banks[r.accountId ?? ""] && covers($0, r.date ?? "", in: state)
            }
            if close || otherBankSeen { unsure.append(i) } else { waiting.append(i) }
        }
        for i in unsure { review(i) }
        for i in waiting {
            records[i].status = "pendingPair"
            records[i].excluded = true
            done.insert(i)
        }
        for i in openLines(isCross) {
            let named = ledger.accounts.filter { $0.bank == partnerBank(records[i]) && $0.kind != "deposit" && $0.id != records[i].accountId }
            oneSided(i, named.count == 1 ? named[0].id : nil)
        }

        // 6. Transfers the words say nothing about, and other people.
        for i in openLines({ $0.hint == "unknown" }) { review(i) }
        for i in openLines({ person($0) != nil }) {
            let rule = ledger.people[person(records[i])?.name.lowercased() ?? ""]
            if rule == "own" { oneSided(i, nil); continue }
            if records[i].ownerEdited != true { records[i].category = peopleCategory }
            if let label = people.first(where: { $0.rule == rule })?.label {
                if records[i].note == nil { records[i].note = label }
            } else if records[i].ownerEdited != true {
                records[i].status = "review"
            }
        }

        state.records = records + derived
        state.ledger = ledger
        // The one checkpoint of earlier builds gives way to the accounts' own balances.
        if ledger.accounts.contains(where: { $0.anchorDate != nil }) {
            state.records.removeAll { $0.id == StatementImport.balanceRecordId }
        }
        settle(&state)
    }

    // MARK: - Balances

    /// What was on the account at the end of the day, counted from its anchor. Nil without an anchor.
    public static func balance(_ account: FinanceAccount, on date: String, in state: FinanceState) -> Int64? {
        guard let anchor = account.anchorMinor, let from = account.anchorDate else { return nil }
        let (low, high) = date >= from ? (from, date) : (date, from)
        var sum: Int64 = 0
        for r in state.records where r.kind == "income" || r.kind == "expense" {
            guard let day = r.date, day > low, day <= high else { continue }
            if r.accountId == account.id {
                sum += signed(r)
            } else if r.pairedWith == nil, let t = r.transfer, t.to == account.id || t.from == account.id, !covers(account.id, day, in: state) {
                // The other side of a transfer, while no statement of this account shows it itself.
                sum -= signed(r)
            }
        }
        return date >= from ? anchor + sum : anchor - sum
    }

    /// All accounts with a balance, plus what was entered by hand or came from Wallet since the newest anchor.
    /// Nil when no account has a balance, or a hand reconciliation is newer than every anchor.
    public static func total(on date: String, in state: FinanceState) -> Int64? {
        let accounts = state.ledger?.accounts ?? []
        guard let newest = accounts.compactMap(\.anchorDate).max(),
              !state.records.contains(where: { $0.kind == "balance" && ($0.date ?? "") >= newest && ($0.date ?? "") <= date }) else { return nil }
        var sum = accounts.compactMap { balance($0, on: date, in: state) }.reduce(Int64(0), +)
        for r in state.records where r.accountId == nil && r.excluded != true && (r.kind == "income" || r.kind == "expense") {
            if let day = r.date, day > newest, day <= date { sum += signed(r) }
        }
        return sum
    }

    public struct BalanceDiff: Equatable, Identifiable {
        public var id: String { accountId + date }
        public let accountId: String
        public let date: String
        public let bank: Int64
        public let ours: Int64
    }

    /// Statements of one account whose closing balance is not what the operations give.
    public static func diffs(in state: FinanceState) -> [BalanceDiff] {
        var result: [BalanceDiff] = []
        for source in state.ledger?.statements ?? [] where source.accounts.count == 1 {
            guard let item = state.imports?.first(where: { $0.id == source.importId }), let bank = item.closingMinor, let date = item.closingDate,
                  let account = state.ledger?.accounts.first(where: { $0.id == source.accounts[0] }),
                  let ours = balance(account, on: date, in: state), ours != bank,
                  !result.contains(where: { $0.accountId == account.id && $0.date == date }) else { continue }
            result.append(BalanceDiff(accountId: account.id, date: date, bank: bank, ours: ours))
        }
        return result.sorted { ($0.accountId, $0.date) < ($1.accountId, $1.date) }
    }

    /// The «Корректировка» rows are worked out from the accepted bank balances, so one goes when its operation arrives.
    private static func settle(_ state: inout FinanceState) {
        state.records.removeAll { $0.id.hasPrefix("adj-") }
        for index in state.ledger?.accounts.indices ?? (0..<0) {
            guard var account = state.ledger?.accounts[index], let accepted = account.accepted, var anchorDate = account.anchorDate else { continue }
            if let same = accepted.last(where: { $0.date == anchorDate }) {
                account.anchorMinor = same.minor
                account.accepted = accepted.filter { $0.date != anchorDate }
                state.ledger?.accounts[index] = account
            }
            anchorDate = account.anchorDate ?? anchorDate
            let rest = account.accepted ?? []
            let after = rest.filter { $0.date > anchorDate }.sorted { $0.date < $1.date }
            let before = rest.filter { $0.date < anchorDate }.sorted { $0.date > $1.date }
            for entry in after + before {
                guard let ours = balance(account, on: entry.date, in: state), ours != entry.minor else { continue }
                // Before the anchor the balance is counted backwards: the row goes the day after, with the opposite sign.
                let later = entry.date > anchorDate
                let amount = later ? entry.minor - ours : ours - entry.minor
                let day = later ? entry.date : StatementImport.dayNumber(entry.date).map { dateFromEpochDays($0 + 1) } ?? entry.date
                var row = FinanceRecord(id: "adj-\(account.id)-\(entry.date)", kind: amount > 0 ? "income" : "expense",
                                        title: adjustmentTitle, amountMinor: abs(amount), date: day, category: "Без категории")
                row.accountId = account.id
                row.excluded = true
                state.records.append(row)
            }
        }
    }

    // MARK: - The owner's answers

    public static func setAnchor(_ accountId: String, minor: Int64, date: String, in state: FinanceState) throws -> FinanceState {
        guard isValidDateString(date), abs(minor) <= FinanceConstants.maxAmountMinor else { throw FinanceError.invalidDraft("Неверный остаток") }
        return try change(state) { ledger, next in
            guard let i = ledger.accounts.firstIndex(where: { $0.id == accountId }) else { return }
            ledger.accounts[i].anchorMinor = minor
            ledger.accounts[i].anchorDate = date
            // A total entered by hand before gives way to the account's own balance.
            next.records.removeAll { $0.kind == "balance" && $0.title == FinanceBudgeting.reconcileTitle && ($0.date ?? "") >= date }
        }
    }

    /// «Принять остаток банка».
    public static func accept(_ diff: BalanceDiff, in state: FinanceState) throws -> FinanceState {
        try change(state) { ledger, _ in
            guard let i = ledger.accounts.firstIndex(where: { $0.id == diff.accountId }) else { return }
            ledger.accounts[i].accepted = (ledger.accounts[i].accepted ?? []).filter { $0.date != diff.date }
                + [FinanceBankBalance(date: diff.date, minor: diff.bank)]
        }
    }

    public enum Answer: Equatable {
        /// This and that line are one transfer.
        case pair(String)
        /// «Мой перевод → счёт»; nil: an account outside the app.
        case transfer(String?)
        /// «Трата → категория», remembered for the merchant.
        case expense(String)
        /// «Человек → правило», remembered for the person.
        case person(String)
    }

    public static func decide(_ recordId: String, _ answer: Answer, in state: FinanceState) throws -> FinanceState {
        guard let record = state.records.first(where: { $0.id == recordId }), let fp = record.fp else {
            throw FinanceError.invalidDraft("Запись не найдена")
        }
        return try change(state) { ledger, next in
            switch answer {
            case .pair(let otherId):
                guard let other = next.records.first(where: { $0.id == otherId })?.fp else { return }
                ledger.decisions[fp] = FinanceDecision(excluded: true, other: other)
                ledger.decisions[other] = FinanceDecision(excluded: true, other: fp)
            case .transfer(let accountId):
                ledger.decisions[fp] = FinanceDecision(excluded: true, account: accountId)
                // The card the line names is this account from now on.
                if let hint = record.hint, hint.hasPrefix("card:"), let i = ledger.accounts.firstIndex(where: { $0.id == accountId }),
                   !ledger.accounts[i].identifiers.contains(hint) {
                    ledger.accounts[i].identifiers.append(hint)
                }
            case .expense(let category):
                ledger.decisions[fp] = FinanceDecision(excluded: false, category: category)
                if let merchant = record.merchant {
                    var rules = next.merchantCategories ?? [:]
                    rules[MerchantCategories.key(merchant)] = category
                    next.merchantCategories = rules
                }
            case .person(let rule):
                guard let name = person(record)?.name else { return }
                ledger.people[name.lowercased()] = rule
                ledger.decisions[fp] = nil
            }
        }
    }

    /// Lines «Проверь» offers as the other side: another account, the opposite direction, ≤3 days and ≤3 %.
    public static func candidates(for record: FinanceRecord, in state: FinanceState) -> [FinanceRecord] {
        state.records.filter { other in
            guard other.id != record.id, other.fp != nil, other.accountId != record.accountId, other.pairedWith == nil,
                  other.status == "review" || other.status == "pendingPair", other.kind != record.kind else { return false }
            let (a, b) = (record.amountMinor ?? 0, other.amountMinor ?? 0)
            return days(record, other) <= 3 && abs(a - b) * 100 <= max(a, b) * 3
        }
    }

    /// Operations as statements and the owner count them: without the rows the app makes itself.
    static func operationCount(_ records: [FinanceRecord]) -> Int {
        records.filter { ($0.kind == "income" || $0.kind == "expense") && !$0.id.hasSuffix("-fee") && !$0.id.hasPrefix("adj-") }.count
    }

    /// Two masks are one account, e.g. «*0006» of a Halyk report is the Kaspi Gold.
    public static func glue(_ source: String, into target: String, in state: FinanceState) throws -> FinanceState {
        try change(state) { ledger, next in
            guard source != target, let from = ledger.accounts.first(where: { $0.id == source }),
                  let i = ledger.accounts.firstIndex(where: { $0.id == target }) else { return }
            ledger.accounts[i].identifiers += from.identifiers.filter { !ledger.accounts[i].identifiers.contains($0) }
            if ledger.accounts[i].anchorMinor == nil {
                ledger.accounts[i].anchorMinor = from.anchorMinor
                ledger.accounts[i].anchorDate = from.anchorDate
            }
            ledger.accounts.removeAll { $0.id == source }
            func moved(_ fp: String) -> String { fp.hasPrefix(source + ":") ? target + fp.dropFirst(source.count) : fp }
            for k in next.records.indices {
                if next.records[k].accountId == source { next.records[k].accountId = target }
                next.records[k].fp = next.records[k].fp.map(moved)
            }
            ledger.removed = ledger.removed.map(moved)
            ledger.decisions = Dictionary(ledger.decisions.map { fp, decision in
                var d = decision
                d.other = d.other.map(moved)
                if d.account == source { d.account = target }
                return (moved(fp), d)
            }, uniquingKeysWith: { a, _ in a })
            for k in ledger.statements.indices {
                ledger.statements[k].accounts = ledger.statements[k].accounts.map { $0 == source ? target : $0 }
            }
        }
    }

    private static func change(_ state: FinanceState, _ body: (inout FinanceLedgerState, inout FinanceState) -> Void) throws -> FinanceState {
        var next = try validateFinance(state)
        var ledger = next.ledger ?? FinanceLedgerState()
        body(&ledger, &next)
        next.ledger = ledger
        link(&next)
        return try validateFinance(next)
    }

    // MARK: - Reading stored statements again

    static func pack(_ text: String) -> Data {
        let raw = Data(text.utf8) as NSData
        return (try? raw.compressed(using: .zlib) as Data) ?? Data()
    }

    static func unpack(_ data: Data) -> String? {
        (try? (data as NSData).decompressed(using: .zlib) as Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Reads stored statements again where it is needed: the parser got better, or the website saved a record
    /// without its account fields. The owner's edits stay. Nil when nothing changed.
    public static func upkeep(_ state: FinanceState) -> FinanceState? {
        var next = state
        var changed = false
        for source in state.ledger?.statements ?? [] {
            let id = source.importId
            let stale = source.parserVersion < parserVersion
            let bare = next.records.contains { $0.importId == id && $0.fp == nil && !$0.id.hasSuffix("-fee") }
            guard stale || bare, var ledger = next.ledger, let text = unpack(source.text),
                  let statement = try? BankStatementParser.parse(text) else { continue }
            let preview = StatementImport.preview(statement, importId: id, rules: next.merchantCategories)
            let read = assign(preview, in: &ledger)
            next.ledger = ledger
            if stale {
                let old = Dictionary(next.records.filter { $0.importId == id }.compactMap { r in r.fp.map { ($0, r) } },
                                     uniquingKeysWith: { a, _ in a })
                var rest = next
                rest.records.removeAll { $0.importId == id }
                let fresh = StatementImport.newRecords(StatementImport.Preview(statement: statement, records: read, excludedCount: 0), in: rest)
                    .map { record -> FinanceRecord in
                        guard let kept = record.fp.flatMap({ old[$0] }) else { return record }
                        var r = record
                        r.category = kept.category
                        r.note = kept.note
                        if kept.ownerEdited == true {
                            r.title = kept.title
                            r.amountMinor = kept.amountMinor
                            r.date = kept.date
                            r.excluded = kept.excluded
                            r.ownerEdited = true
                        }
                        return r
                    }
                rest.records += fresh
                next = rest
                if let i = next.ledger?.statements.firstIndex(where: { $0.importId == id }) {
                    next.ledger?.statements[i].parserVersion = parserVersion
                }
            } else {
                let byId = Dictionary(read.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for i in next.records.indices where next.records[i].importId == id && next.records[i].fp == nil {
                    guard let r = byId[next.records[i].id] else { continue }
                    next.records[i].accountId = r.accountId
                    next.records[i].fp = r.fp
                    next.records[i].hint = r.hint
                    next.records[i].refund = r.refund
                }
            }
            changed = true
        }
        guard changed else { return nil }
        link(&next)
        guard let clean = try? validateFinance(next), clean != state else { return nil }
        return clean
    }

    // MARK: - Starting over

    /// «Очистить финансы»: envelopes with what is saved in them and the category rules stay, everything else goes.
    public static func cleared(_ state: FinanceState) throws -> FinanceState {
        let goals = state.records.filter { $0.kind == "goal" }
        let budget = state.budget.map { FinanceBudget(savingsGoalId: $0.savingsGoalId, envelopeLog: $0.envelopeLog) }
        return try validateFinance(FinanceState(records: goals, committedBatches: state.committedBatches,
                                                merchantCategories: state.merchantCategories, budget: budget))
    }

    // MARK: - Totals

    /// A refund is not income: it takes the money back out of its spending category.
    static func netted(_ r: FinanceRecord) -> FinanceRecord {
        guard r.refund == true, r.kind == "income" else { return r }
        var next = r
        next.kind = "expense"
        next.amountMinor = -(r.amountMinor ?? 0)
        return next
    }

    /// Stretches without a statement, per account, inside the span all statements cover together.
    public static func gaps(in state: FinanceState) -> [(account: FinanceAccount, from: String, to: String)] {
        let periods: [(accounts: [String], from: Int, to: Int)] = (state.ledger?.statements ?? []).compactMap { source in
            guard let item = state.imports?.first(where: { $0.id == source.importId }),
                  let from = StatementImport.dayNumber(item.periodStart), let to = StatementImport.dayNumber(item.periodEnd) else { return nil }
            return (source.accounts, from, to)
        }
        guard let first = periods.map(\.from).min(), let last = periods.map(\.to).max() else { return [] }
        var result: [(account: FinanceAccount, from: String, to: String)] = []
        for account in state.ledger?.accounts ?? [] {
            let own = periods.filter { $0.accounts.contains(account.id) }.sorted { $0.from < $1.from }
            guard !own.isEmpty else { continue }
            var next = first
            for period in own + [(accounts: [String](), from: last + 1, to: last + 1)] {
                if period.from > next { result.append((account: account, from: dateFromEpochDays(next), to: dateFromEpochDays(period.from - 1))) }
                next = max(next, period.to + 1)
            }
        }
        return result
    }
}

/// The summary after statements are loaded. It is read from the state each time it is shown, so answers given
/// in «Проверь» move the numbers.
public struct ImportReport: Equatable {
    public var periodStart: String?
    public var periodEnd: String?
    public var accounts: [String]
    /// Own transfers among the loaded lines; a pair counts once.
    public var transfers: Int
    /// Everything waiting for the owner, not only from this load.
    public var review: Int
    /// «Kaspi» → transfers waiting for its statement.
    public var waiting: [String: Int]

    public init(importIds: Set<String>, in state: FinanceState) {
        let ledger = state.ledger ?? FinanceLedgerState()
        let items = (state.imports ?? []).filter { importIds.contains($0.id) }
        periodStart = items.compactMap(\.periodStart).min()
        periodEnd = items.compactMap(\.periodEnd).max()
        let covered = Set(ledger.statements.filter { importIds.contains($0.importId) }.flatMap(\.accounts))
        accounts = ledger.accounts.filter { covered.contains($0.id) }.map(\.name)
        let own = state.records.filter { ($0.importId.map(importIds.contains) ?? false) && $0.transfer != nil }
        transfers = Set(own.map { r in r.pairedWith.map { min(r.id, $0) } ?? r.id }).count
        review = state.records.filter { $0.status == "review" }.count
        waiting = [:]
        for r in state.records where r.status == "pendingPair" {
            let bank = ledger.accounts.first { $0.id == r.accountId }?.bank
            waiting[bank == "Halyk" ? "Kaspi" : "Halyk", default: 0] += 1
        }
    }

    /// «Kaspi Gold: нет данных с 01.03 по 15.03»
    public static func gapText(_ name: String, from: String, to: String) -> String {
        func short(_ date: String) -> String { "\(date.suffix(2)).\(date.dropFirst(5).prefix(2))" }
        return "\(name): нет данных с \(short(from)) по \(short(to))"
    }
}
