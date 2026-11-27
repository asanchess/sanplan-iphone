import SwiftUI

// Экраны учёта по счетам (docs/finance/ACCOUNTS-SPEC-2026-11-27.md §4, §7, §8): отчёт после загрузки,
// «Проверь», счета с остатками, мастер после очистки.

extension FinanceStore {
    /// One change by the owner, with «Отменить». Returns why it was not saved.
    func applyLedger(_ message: String, today: String, _ change: (FinanceState) throws -> FinanceState) -> String? {
        do {
            try replaceStateUndoable(with: change(state), today: today, message: message)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private extension FinanceState {
    var accountList: [FinanceAccount] { ledger?.accounts ?? [] }
    func accountName(_ id: String?) -> String { accountList.first { $0.id == id }?.name ?? "" }
}

// MARK: - Report

/// What the loaded statements brought, in one card.
struct ImportBatch: Identifiable {
    let id = UUID()
    var importIds: Set<String> = []
    var added = 0
    var already = 0

    var isEmpty: Bool { importIds.isEmpty && already == 0 }
}

struct ImportReportSheet: View {
    @ObservedObject var store: FinanceStore
    let today: String
    let batch: ImportBatch
    let onClose: () -> Void

    @State private var showsAccounts = false
    @State private var showsReview = false

    var body: some View {
        let report = ImportReport(importIds: batch.importIds, in: store.state)
        let unanchored = store.state.accountList.filter { $0.anchorDate == nil }.map(\.name)
        let gaps = FinanceLedger.gaps(in: store.state)
        FinanceSheet(title: "Загрузка", onClose: onClose) {
            Card {
                if let from = report.periodStart, let to = report.periodEnd {
                    MoneyRow(label: "Период", value: "\(MoneyFormat.date(from)) – \(MoneyFormat.date(to))")
                }
                if !report.accounts.isEmpty {
                    Text(report.accounts.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.textPrimary)
                }
                MoneyRow(label: "Добавлено", value: MoneyFormat.operations(batch.added), emphasized: true)
                MoneyRow(label: "Уже были", value: "\(batch.already)")
                MoneyRow(label: "Свои переводы", value: "\(report.transfers)")
                MoneyRow(label: "На проверку", value: "\(report.review)")
                ForEach(report.waiting.keys.sorted(), id: \.self) { bank in
                    MoneyRow(label: "Ждут выписку \(bank)", value: "\(report.waiting[bank] ?? 0)")
                }
            }

            BalanceNotes(store: store, today: today)

            if !unanchored.isEmpty {
                Text("Без остатка: \(unanchored.joined(separator: ", ")). Введи, сколько на счёте.")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.warning)
            }
            ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                Text(ImportReport.gapText(gap.account.name, from: gap.from, to: gap.to))
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            if report.review > 0 {
                PillButton("Проверь · \(report.review)", style: .primary) { showsReview = true }
            }
            if !store.state.accountList.isEmpty {
                PillButton("Счета и остатки", style: .secondary) { showsAccounts = true }
            }
        }
        .sheet(isPresented: $showsAccounts) {
            AccountsSheet(store: store, today: today) { showsAccounts = false }
        }
        .sheet(isPresented: $showsReview) {
            AccountReviewSheet(store: store, today: today) { showsReview = false }
        }
    }
}

/// The alarm of a negative total and the statements whose closing balance differs from ours.
struct BalanceNotes: View {
    @ObservedObject var store: FinanceStore
    let today: String
    @State private var error: String?

    var body: some View {
        if (FinanceLedger.total(on: today, in: store.state) ?? 0) < 0 {
            Text("Сумма на счетах меньше нуля. Проверь введённые остатки.")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DS.Colors.destructive)
        }
        ForEach(FinanceLedger.diffs(in: store.state)) { diff in
            Card {
                Text("\(store.state.accountName(diff.accountId)) на \(MoneyFormat.date(diff.date)): банк \(FinanceText.money(diff.bank)), у нас \(FinanceText.money(diff.ours)), разница \(FinanceText.money(abs(diff.bank - diff.ours)))")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textPrimary)
                PillButton("Принять остаток банка", style: .secondary) {
                    error = store.applyLedger("Остаток банка принят: на счёте строка «Корректировка».", today: today) {
                        try FinanceLedger.accept(diff, in: $0)
                    }
                }
            }
        }
        if let error {
            Text(error).font(.caption).foregroundColor(DS.Colors.destructive)
        }
    }
}

// MARK: - Accounts

struct AccountsSheet: View {
    @ObservedObject var store: FinanceStore
    let today: String
    let onClose: () -> Void

    @State private var editing: FinanceAccount?
    @State private var gluing: (source: FinanceAccount, target: FinanceAccount)?
    @State private var error: String?

    var body: some View {
        let accounts = store.state.accountList
        FinanceSheet(title: "Счета и остатки", onClose: onClose) {
            if let total = FinanceLedger.total(on: today, in: store.state) {
                MoneyRow(label: "Всего на счетах", value: FinanceText.money(total), emphasized: true)
            }
            BalanceNotes(store: store, today: today)
            ForEach(accounts) { account in
                row(account, others: accounts.filter { $0.id != account.id })
            }
            if let error {
                Text(error).font(.caption).foregroundColor(DS.Colors.destructive)
            }
        }
        .sheet(item: $editing) { account in
            AnchorSheet(store: store, account: account, today: today) { editing = nil }
        }
        .alert("Это один счёт?", isPresented: Binding(get: { gluing != nil }, set: { if !$0 { gluing = nil } }), presenting: gluing) { pair in
            Button("Объединить") {
                error = store.applyLedger("Счета объединены.", today: today) {
                    try FinanceLedger.glue(pair.source.id, into: pair.target.id, in: $0)
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: { pair in
            Text("Операции «\(pair.source.name)» перейдут на «\(pair.target.name)», и следующие выписки тоже.")
        }
    }

    private func row(_ account: FinanceAccount, others: [FinanceAccount]) -> some View {
        Card {
            if let balance = FinanceLedger.balance(account, on: today, in: store.state) {
                MoneyRow(label: account.name, value: FinanceText.money(balance), emphasized: true)
                if let minor = account.anchorMinor, let date = account.anchorDate {
                    Text("Считается от остатка \(FinanceText.money(minor)) на \(MoneyFormat.date(date)).")
                        .font(.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            } else {
                MoneyRow(label: account.name, value: "остаток не указан", emphasized: true)
            }
            PillButton(account.anchorDate == nil ? "Указать остаток" : "Изменить остаток", style: .secondary) {
                editing = account
            }
            if !others.isEmpty {
                Menu("Объединить с…") {
                    ForEach(others) { target in
                        Button(target.name) { gluing = (account, target) }
                    }
                }
                .font(.subheadline)
                .frame(minHeight: DS.Metrics.minHitTarget)
            }
        }
    }
}

struct AnchorSheet: View {
    @ObservedObject var store: FinanceStore
    let account: FinanceAccount
    let today: String
    let onClose: () -> Void

    @State private var amount = ""
    @State private var date = Date()
    @State private var error: String?

    private var format: DateFormatter { PlanDateTime.formatter("yyyy-MM-dd", timeZone: "Asia/Qyzylorda") }

    var body: some View {
        FinanceSheet(title: account.name, onClose: onClose) {
            Text("Сколько было на счёте в конце дня. Долг по кредитной карте — со знаком минус.")
                .font(.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
            TextField("Сумма, ₸", text: $amount)
                .keyboardType(.numbersAndPunctuation)
                .moneyField()
                .accessibilityLabel("Остаток, тенге")
            DatePicker("Дата", selection: $date, in: ...Date(), displayedComponents: .date)
                .environment(\.locale, Locale(identifier: "ru_RU"))
            if let error {
                Text(error).font(.caption).foregroundColor(DS.Colors.destructive)
            }
            PillButton("Сохранить", style: .primary, isEnabled: !amount.isEmpty) { save() }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard let minor = Self.minor(amount) else {
            error = "Введи сумму числом."
            return
        }
        let day = min(format.string(from: date), today)
        error = store.applyLedger("Остаток сохранён.", today: today) {
            try FinanceLedger.setAnchor(account.id, minor: minor, date: day, in: $0)
        }
        if error == nil { onClose() }
    }

    /// «152 300,50» or «−5000»; zero is a balance too.
    static func minor(_ raw: String) -> Int64? {
        var text = raw.replacingOccurrences(of: ",", with: ".").filter { !$0.isWhitespace }
        let negative = text.hasPrefix("-") || text.hasPrefix("−")
        if negative { text.removeFirst() }
        guard let value = try? parseKzt(text) else { return nil }
        return negative ? -value : value
    }
}

// MARK: - «Проверь»

/// Transfers the rules are not sure about, one tap each.
struct AccountReviewSheet: View {
    @ObservedObject var store: FinanceStore
    let today: String
    let onClose: () -> Void
    @State private var error: String?

    var body: some View {
        let waiting = store.state.records.filter { $0.status == "review" }.sorted { ($0.date ?? "") > ($1.date ?? "") }
        FinanceSheet(title: "Проверь", onClose: onClose) {
            if let error {
                Text(error).font(.caption).foregroundColor(DS.Colors.destructive)
            }
            if waiting.isEmpty {
                Text("Проверять нечего.")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            // shortcut: a long first load draws every card inside a ScrollView; page the list if it stutters.
            LazyVStack(spacing: DS.Metrics.spacing12) {
                ForEach(waiting) { record in row(record) }
            }
        }
    }

    private func row(_ record: FinanceRecord) -> some View {
        let incoming = record.kind == "income"
        return Card {
            MoneyRow(label: record.title,
                     value: FinanceText.signed(incoming ? record.amountMinor ?? 0 : -(record.amountMinor ?? 0)), emphasized: true)
            Text("\(MoneyFormat.date(record.date)) · \(store.state.accountName(record.accountId))")
                .font(.caption)
                .foregroundColor(DS.Colors.textSecondary)
            HStack(spacing: DS.Metrics.spacing12) {
                Menu("Мой перевод") {
                    ForEach(FinanceLedger.candidates(for: record, in: store.state)) { other in
                        Button("Пара: \(MoneyFormat.date(other.date)) · \(store.state.accountName(other.accountId)) · \(MoneyFormat.kzt(other.amountMinor ?? 0))") {
                            answer(record, .pair(other.id))
                        }
                    }
                    ForEach(store.state.accountList.filter { $0.id != record.accountId }) { account in
                        Button("\(incoming ? "Со счёта" : "На счёт") «\(account.name)»") { answer(record, .transfer(account.id)) }
                    }
                    Button("Счёт вне приложения") { answer(record, .transfer(nil)) }
                }
                Menu(incoming ? "Доход" : "Трата") {
                    ForEach(MerchantCategories.all, id: \.self) { category in
                        Button(category) { answer(record, .expense(category)) }
                    }
                }
                if record.hint?.hasPrefix("name:") == true {
                    Menu("Человек") {
                        ForEach(FinanceLedger.people, id: \.rule) { person in
                            Button(person.label) { answer(record, .person(person.rule)) }
                        }
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: DS.Metrics.minHitTarget)
        }
    }

    private func answer(_ record: FinanceRecord, _ answer: FinanceLedger.Answer) {
        error = store.applyLedger("Решение запомнено.", today: today) {
            try FinanceLedger.decide(record.id, answer, in: $0)
        }
    }
}

// MARK: - «Очистить финансы»

/// The confirmation that lists what goes, then the steps of starting over.
struct ClearFinancesFlow: ViewModifier {
    @Binding var isAsking: Bool
    /// False when nothing was cleared.
    let clear: () -> Bool
    let pick: () -> Void

    @State private var showsWizard = false
    /// The file importer opens only after the wizard is closed.
    @State private var wantsFiles = false

    func body(content: Content) -> some View {
        content
            .alert("Очистить финансы?", isPresented: $isAsking) {
                Button("Очистить", role: .destructive) { showsWizard = clear() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Удалятся все операции, выписки, счета и остатки, платежи плана, лимиты, плановые доходы и покупки из Wallet. Останутся конверты с отложенными суммами и правила категорий. Отменить нельзя.")
            }
            .sheet(isPresented: $showsWizard, onDismiss: {
                guard wantsFiles else { return }
                wantsFiles = false
                pick()
            }) {
                ClearWizardSheet(onPick: {
                    wantsFiles = true
                    showsWizard = false
                }, onClose: { showsWizard = false })
            }
    }
}

struct ClearWizardSheet: View {
    let onPick: () -> Void
    let onClose: () -> Void

    var body: some View {
        FinanceSheet(title: "Начать заново", onClose: onClose) {
            Group {
                Text("1. Выбери выписки за год: Kaspi Gold, Kaspi Депозит и отчёт Halyk по всем счетам. Можно сразу несколько файлов.")
                Text("2. Счета появятся из выписок сами.")
                Text("3. Введи, сколько сейчас на каждом счёте.")
                Text("4. Посмотри отчёт и «Проверь».")
            }
            .font(.subheadline)
            .foregroundColor(DS.Colors.textPrimary)
            PillButton("Выбрать выписки", style: .primary, action: onPick)
        }
        .presentationDetents([.medium, .large])
    }
}
