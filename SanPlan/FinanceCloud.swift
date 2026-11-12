import Foundation
import CryptoKit

// Деньги в зашифрованной коллекции `finance` (docs/contracts/FINANCE-MIGRATION.md).
// Состояние FinanceState раскладывается на записи коллекции и собирается обратно; формат тот же, что в вебе
// (src/finance-cloud.mjs). Чистая логика: ни сети, ни файлов.

extension FinanceRecord: @unchecked Sendable {}
extension FinanceImport: @unchecked Sendable {}
extension FinanceBudget: @unchecked Sendable {}

/// Открытый текст записи коллекции `finance`. `k`: rec | import | budget | rules | batches.
public struct FinancePayload: Codable, Equatable, Sendable {
    public var k: String
    /// Место записи в списке; дробное, чтобы вставка в середину не переписывала соседей.
    public var seq: Double?
    public var record: FinanceRecord?
    public var importItem: FinanceImport?
    public var budget: FinanceBudget?
    public var rules: [String: String]?
    public var batches: [String]?

    enum CodingKeys: String, CodingKey {
        case k, seq, record, importItem = "import", budget, rules, batches
    }

    public init(k: String, seq: Double? = nil, record: FinanceRecord? = nil, importItem: FinanceImport? = nil,
                budget: FinanceBudget? = nil, rules: [String: String]? = nil, batches: [String]? = nil) {
        self.k = k
        self.seq = seq
        self.record = record
        self.importItem = importItem
        self.budget = budget
        self.rules = rules
        self.batches = batches
    }
}

/// Что считается «тем же самым» до и после переноса.
public struct FinanceFingerprint: Equatable {
    public var records: Int
    public var operations: Int
    public var imports: Int
    /// «месяц|income|категория» → сумма в minor-единицах (операции, которые идут в итоги).
    public var byMonthCategory: [String: Int64]
    public var goalsSavedMinor: Int64
    public var balanceMinor: Int64
}

public enum FinanceCloud {
    public static let budgetID = "f-meta-budget"
    public static let rulesID = "f-meta-rules"
    public static let batchesID = "f-meta-batches"

    /// `f-<localId>`, если id подходит серверу и не совпадает со служебным; иначе `f-x` + 40 hex от SHA-256.
    public static func collectionID(forLocal id: String) -> String {
        let reserved = id.hasPrefix("meta-")
        let plain = "f-" + id
        let allowed = id.unicodeScalars.allSatisfy { ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
        if !reserved, allowed, plain.count >= 8, plain.count <= 64 { return plain }
        return hashedID(id)
    }

    static func importID(_ id: String) -> String { hashedID("import:" + id) }

    static func hashedID(_ id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return "f-x" + digest.prefix(20).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Состояние → записи

    /// Записи коллекции, которые надо создать или изменить, и те, что надо убрать, чтобы коллекция стала равна `state`.
    /// `existing` — текущее содержимое коллекции (id → payload); записи с тем же содержимым не трогаются.
    public static func plan(existing: [String: FinancePayload], state: FinanceState) -> (puts: [(id: String, data: FinancePayload)], removes: [String]) {
        var desired: [(id: String, data: FinancePayload)] = []

        let recordIDs = state.records.map { collectionID(forLocal: $0.id) }
        let recordSeqs = assignSeq(ids: recordIDs, existing: existing, kind: "rec")
        for (i, r) in state.records.enumerated() {
            desired.append((recordIDs[i], FinancePayload(k: "rec", seq: recordSeqs[i], record: r)))
        }
        let imports = state.imports ?? []
        let importIDs = imports.map { importID($0.id) }
        let importSeqs = assignSeq(ids: importIDs, existing: existing, kind: "import")
        for (i, item) in imports.enumerated() {
            desired.append((importIDs[i], FinancePayload(k: "import", seq: importSeqs[i], importItem: item)))
        }
        if let budget = state.budget { desired.append((budgetID, FinancePayload(k: "budget", budget: budget))) }
        if let rules = state.merchantCategories, !rules.isEmpty { desired.append((rulesID, FinancePayload(k: "rules", rules: rules))) }
        if !state.committedBatches.isEmpty { desired.append((batchesID, FinancePayload(k: "batches", batches: state.committedBatches))) }

        let wanted = Set(desired.map(\.id))
        let puts = desired.filter { existing[$0.id] != $0.data }
        let removes = existing.keys.filter { !wanted.contains($0) }.sorted()
        return (puts, removes)
    }

    /// Оставляет прежнее место записи, если порядок не нарушен; новую вставляет между соседями.
    static func assignSeq(ids: [String], existing: [String: FinancePayload], kind: String) -> [Double] {
        let known: [Double?] = ids.map { id in
            guard let p = existing[id], p.k == kind else { return nil }
            return p.seq
        }
        var out: [Double] = []
        var previous: Double = 0
        for (i, current) in known.enumerated() {
            if let s = current, s > previous {
                out.append(s)
                previous = s
                continue
            }
            let next = known[(i + 1)...].compactMap { $0 }.first { $0 > previous }
            let value = next.map { (previous + $0) / 2 } ?? previous + 1
            out.append(value)
            previous = value
        }
        return out
    }

    /// Все записи для первой выгрузки.
    public static func entries(_ state: FinanceState, updatedAt: Int64) -> [(id: String, data: FinancePayload, updatedAt: Int64)] {
        plan(existing: [:], state: state).puts.map { ($0.id, $0.data, updatedAt) }
    }

    // MARK: Записи → состояние

    public static func state(from items: [VaultItem<FinancePayload>]) -> FinanceState {
        let payloads = items.compactMap { item in item.data.map { (id: item.id, p: $0) } }
        func ordered(_ kind: String) -> [(id: String, p: FinancePayload)] {
            payloads.filter { $0.p.k == kind }.sorted {
                ($0.p.seq ?? 0) != ($1.p.seq ?? 0) ? ($0.p.seq ?? 0) < ($1.p.seq ?? 0) : $0.id < $1.id
            }
        }
        let records = ordered("rec").compactMap(\.p.record)
        let imports = ordered("import").compactMap(\.p.importItem)
        return FinanceState(
            version: 1,
            records: records,
            committedBatches: payloads.first { $0.p.k == "batches" }?.p.batches ?? [],
            imports: imports.isEmpty ? nil : imports,
            merchantCategories: payloads.first { $0.p.k == "rules" }?.p.rules,
            budget: payloads.first { $0.p.k == "budget" }?.p.budget
        )
    }

    /// Текущее содержимое коллекции в виде «id → payload» для `plan`.
    public static func existing(_ items: [VaultItem<FinancePayload>]) -> [String: FinancePayload] {
        var out: [String: FinancePayload] = [:]
        for item in items { if let d = item.data { out[item.id] = d } }
        return out
    }

    // MARK: Сверка

    public static func fingerprint(_ state: FinanceState) -> FinanceFingerprint {
        var by: [String: Int64] = [:]
        var operations = 0
        var saved: Int64 = 0
        var balance: Int64 = 0
        for r in state.records {
            switch r.kind {
            case "income", "expense":
                operations += 1
                guard r.excluded != true, let date = r.date else { continue }
                by["\(date.prefix(7))|\(r.kind)|\(r.category ?? "Без категории")", default: 0] += r.amountMinor ?? 0
            case "goal": saved += r.savedMinor ?? 0
            case "balance": balance += r.amountMinor ?? 0
            default: break
            }
        }
        return FinanceFingerprint(records: state.records.count, operations: operations, imports: state.imports?.count ?? 0,
                                  byMonthCategory: by, goalsSavedMinor: saved, balanceMinor: balance)
    }

    /// Выгрузка подтверждена, если каждая локальная запись есть в облаке; когда наборы записей одинаковы,
    /// отпечатки обязаны совпасть полностью. Только тогда локальную копию можно удалять.
    public static func isVerified(local: FinanceState, remote: FinanceState) -> Bool {
        let remoteIDs = Set(remote.records.map(\.id))
        guard local.records.allSatisfy({ remoteIDs.contains($0.id) }) else { return false }
        let remoteImports = Set((remote.imports ?? []).map(\.id))
        guard (local.imports ?? []).allSatisfy({ remoteImports.contains($0.id) }) else { return false }
        if remoteIDs == Set(local.records.map(\.id)) { return fingerprint(local) == fingerprint(remote) }
        return true
    }
}
