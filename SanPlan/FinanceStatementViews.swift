import SwiftUI
import UniformTypeIdentifiers

enum MoneyFormat {
    /// «1 операция», «3 операции», «5 операций».
    static func operations(_ count: Int) -> String {
        let tens = count % 100, ones = count % 10
        let word = (11...14).contains(tens) ? "операций" : ones == 1 ? "операция" : (2...4).contains(ones) ? "операции" : "операций"
        return "\(count) \(word)"
    }

    static func kzt(_ minor: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = minor % 100 == 0 ? 0 : 2
        formatter.minimumFractionDigits = minor % 100 == 0 ? 0 : 2
        let value = NSDecimalNumber(value: Double(minor) / 100)
        return (formatter.string(from: value) ?? "\(minor / 100)") + " ₸"
    }

    /// Строка легенды расходов: «20% · 48 000 ₸» (веб: legendShareText).
    static func legendShare(amountMinor: Int64, totalMinor: Int64) -> String {
        let percent = totalMinor > 0 ? Int((Double(amountMinor) / Double(totalMinor) * 100).rounded()) : 0
        return "\(percent)% · \(kzt(amountMinor))"
    }

    static func date(_ ymd: String?) -> String {
        guard let ymd, ymd.count == 10 else { return ymd ?? "" }
        let parts = ymd.split(separator: "-")
        return "\(parts[2]).\(parts[1]).\(parts[0])"
    }
}

/// A statement waiting for the owner's confirmation.
struct PendingStatement: Identifiable {
    let id: String
    let fileName: String
    let preview: StatementImport.Preview
}

// MARK: - Statements section

/// Import button, merge offers and the list of imports with delete.
struct StatementsSection: View {
    @ObservedObject var store: FinanceStore
    let today: String
    @Binding var errorMessage: String?
    @Binding var statusMessage: String?
    /// Reading and the offers to merge live in `StatementImportFlow`.
    let isReading: Bool
    @Binding var suggestions: [StatementImport.MergeSuggestion]
    let onPick: () -> Void

    @State private var importToDelete: FinanceImport?
    /// «История загрузок» starts folded; not kept between launches.
    @State private var showsImports = false
    @State private var showsAccounts = false
    @State private var showsReview = false

    @Environment(\.sectionAccent) private var accent

    private var imports: [FinanceImport] { store.state.imports ?? [] }

    /// Canvas: an outline link «Выписки из банка» (52 high, radius 18, hairline 1.5) on top of «Операции»,
    /// then the past imports folded behind «История загрузок · N».
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            MoneyOutlineButton("Загрузить выписку", icon: "doc.text.magnifyingglass", isLoading: isReading) {
                onPick()
            }
            .accessibilityIdentifier("statement-import")
            .accessibilityHint("Импорт PDF-выписки")
            Text("Kaspi Gold и Halyk в PDF. Файл читается на телефоне и никуда не отправляется.")
                .font(DS.Fonts.text(13, .medium, relativeTo: .caption))
                .foregroundColor(DS.Colors.textSecondary)

            let review = store.state.records.filter { $0.status == "review" }.count
            if review > 0 {
                MoneyOutlineButton("Проверь · \(review)", icon: "questionmark.circle", isLoading: false) {
                    showsReview = true
                }
            }
            if !(store.state.ledger?.accounts ?? []).isEmpty {
                MoneyOutlineButton("Счета и остатки", icon: "creditcard", isLoading: false) {
                    showsAccounts = true
                }
            }

            ForEach(suggestions) { suggestion in
                mergeRow(suggestion)
            }

            if !imports.isEmpty {
                MoneyFoldHeader("История загрузок", count: imports.count, isOpen: showsImports) {
                    withAnimation(.snappy) { showsImports.toggle() }
                }
                .accessibilityIdentifier("money-imports-history")
            }

            if showsImports {
                ForEach(imports) { item in
                    importRow(item)
                }
            }
        }
        .sheet(isPresented: $showsAccounts) {
            AccountsSheet(store: store, today: today) { showsAccounts = false }
        }
        .sheet(isPresented: $showsReview) {
            AccountReviewSheet(store: store, today: today) { showsReview = false }
        }
        .confirmationDialog(
            "Удалить выписку и все её операции?",
            isPresented: Binding(get: { importToDelete != nil }, set: { if !$0 { importToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let item = importToDelete { delete(item) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Записи, добавленные вручную, останутся.")
        }
    }

    /// One past import: bank, operations, period, and «Удалить».
    private func importRow(_ item: FinanceImport) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.bank) · \(MoneyFormat.operations(item.count))")
                    .font(DS.Fonts.text(16, .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(periodText(item))
                    .font(DS.Fonts.text(13, .medium, relativeTo: .caption))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Spacer()
            Button("Удалить") { importToDelete = item }
                .font(DS.Fonts.text(14, .semibold, relativeTo: .caption))
                .foregroundColor(DS.Colors.destructive)
                .frame(minHeight: DS.Metrics.minHitTarget)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func periodText(_ item: FinanceImport) -> String {
        if let start = item.periodStart, let end = item.periodEnd {
            return "\(MoneyFormat.date(start)) – \(MoneyFormat.date(end))"
        }
        return item.fileName
    }

    private func mergeRow(_ suggestion: StatementImport.MergeSuggestion) -> some View {
        let manual = store.state.records.first { $0.id == suggestion.manualId }
        return VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
            Text("Похоже на одну операцию: «\(manual?.title ?? "")» \(MoneyFormat.kzt(manual?.amountMinor ?? 0)), \(MoneyFormat.date(manual?.date))")
                .font(.footnote)
                .foregroundColor(DS.Colors.textPrimary)
            HStack(spacing: DS.Metrics.spacing8) {
                PillButton("Объединить", style: .primary) { merge(suggestion) }
                PillButton("Оставить обе", style: .secondary) {
                    suggestions.removeAll { $0 == suggestion }
                }
            }
        }
        .padding(DS.Metrics.spacing12)
        .background(accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func merge(_ suggestion: StatementImport.MergeSuggestion) {
        do {
            try store.replaceState(with: StatementImport.merge(suggestion, in: store.state), today: today)
            suggestions.removeAll { $0 == suggestion }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ item: FinanceImport) {
        do {
            try store.replaceStateUndoable(with: StatementImport.deleteImport(item.id, from: store.state), today: today, message: "Выписка удалена")
            suggestions.removeAll { suggestion in !store.state.records.contains { $0.id == suggestion.importedId } }
            statusMessage = "Выписка удалена."
        } catch {
            errorMessage = error.localizedDescription
        }
        importToDelete = nil
    }
}

/// Statements picked or shared: one preview after another, then the report. It sits on the root of the Money
/// screen, which stays when the first import swaps the empty screen for the tabs.
struct StatementImportFlow: ViewModifier {
    @ObservedObject var store: FinanceStore
    let today: String
    @Binding var pickedFiles: [URL]
    @Binding var isReading: Bool
    @Binding var suggestions: [StatementImport.MergeSuggestion]
    @Binding var errorMessage: String?

    @State private var pending: PendingStatement?
    /// More statements of the picked files, shown one after another.
    @State private var queued: [PendingStatement] = []
    @State private var batch = ImportBatch()
    @State private var report: ImportBatch?
    @ObservedObject private var inbox = StatementInbox.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: pickedFiles) { _, urls in
                guard !urls.isEmpty else { return }
                pickedFiles = []
                read(urls)
            }
            // A PDF shared from the bank app («Поделиться → A-san») waits in the inbox until this screen is shown.
            .onReceive(inbox.$files) { _ in showNext() }
            .sheet(item: $pending, onDismiss: showNext) { pending in
                StatementPreviewSheet(pending: pending, onImport: { confirm(pending) }, onCancel: { self.pending = nil })
            }
            .sheet(item: $report, onDismiss: showNext) { batch in
                ImportReportSheet(store: store, today: today, batch: batch) { report = nil }
            }
    }

    private func read(_ urls: [URL]) {
        isReading = true
        errorMessage = nil
        let rules = store.state.merchantCategories
        Task {
            let outcomes = await Task.detached(priority: .userInitiated) { () -> [(URL, Result<[PendingStatement], Error>)] in
                urls.map { url -> (URL, Result<[PendingStatement], Error>) in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return (url, Result<[PendingStatement], Error> {
                        let text = try BankStatementParser.text(ofPDFAt: url)
                        // One file can hold several accounts; each becomes its own import.
                        return try BankStatementParser.parseAll(text).map { statement in
                            let importId = "imp-" + UUID().uuidString.prefix(8).lowercased()
                            let preview = StatementImport.preview(statement, importId: importId, rules: rules)
                            return PendingStatement(id: importId, fileName: url.lastPathComponent, preview: preview)
                        }
                    })
                }
            }.value
            var failures: [String] = []
            for (url, outcome) in outcomes {
                inbox.discard(url)
                switch outcome {
                case .success(let statements): queued.append(contentsOf: statements)
                case .failure(let error):
                    failures.append(urls.count > 1 ? "\(url.lastPathComponent): \(error.localizedDescription)" : error.localizedDescription)
                }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
            isReading = false
            showNext()
        }
    }

    /// The next statement of the picked files, then the next shared file, then what all of them brought.
    private func showNext() {
        guard !isReading, pending == nil, report == nil else { return }
        if !queued.isEmpty {
            pending = queued.removeFirst()
        } else if let url = inbox.next() {
            read([url])
        } else if !batch.isEmpty {
            report = batch
            batch = ImportBatch()
        }
    }

    private func confirm(_ pending: PendingStatement) {
        let before = FinanceLedger.operationCount(store.state.records)
        let lines = FinanceLedger.operationCount(pending.preview.records)
        do {
            let next = try StatementImport.apply(pending.preview, to: store.state, importId: pending.id, fileName: pending.fileName, today: today)
            let importId = pending.id
            try store.replaceState(with: next, today: today)
            let added = max(0, FinanceLedger.operationCount(store.state.records) - before)
            batch.importIds.insert(importId)
            batch.added += added
            batch.already += max(0, lines - added)
            suggestions += StatementImport.mergeSuggestions(in: store.state, importId: importId)
            UndoCenter.shared.show("Выписка загружена: \(MoneyFormat.operations(added))") { [store, today] in
                try? store.replaceState(with: StatementImport.deleteImport(importId, from: store.state), today: today)
            }
        } catch StatementError.alreadyImported {
            batch.already += lines
        } catch {
            errorMessage = error.localizedDescription
        }
        self.pending = nil
    }
}

struct StatementPreviewSheet: View {
    let pending: PendingStatement
    let onImport: () -> Void
    let onCancel: () -> Void

    private var statement: ParsedStatement { pending.preview.statement }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Банк", value: statement.bank.rawValue)
                    if let start = statement.periodStart, let end = statement.periodEnd {
                        LabeledContent("Период", value: "\(MoneyFormat.date(start)) – \(MoneyFormat.date(end))")
                    }
                    if let closing = statement.closingBalance {
                        LabeledContent("Остаток на \(MoneyFormat.date(closing.date))", value: MoneyFormat.kzt(closing.amountMinor))
                    }
                    LabeledContent("Операций", value: "\(statement.transactions.count)")
                    if pending.preview.excludedCount > 0 {
                        LabeledContent("Переводы между своими счетами", value: "\(pending.preview.excludedCount), не учитываются")
                    }
                }
                Section("Операции") {
                    ForEach(pending.preview.records.filter { $0.kind != "balance" }) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.title).font(.subheadline).lineLimit(1)
                                Text("\(MoneyFormat.date(record.date)) · \(record.category ?? "")")
                                    .font(.caption2)
                                    .foregroundColor(DS.Colors.textSecondary)
                            }
                            Spacer()
                            Text((record.kind == "income" ? "+" : "−") + MoneyFormat.kzt(record.amountMinor ?? 0))
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(record.excluded == true ? DS.Colors.textSecondary : (record.kind == "income" ? DS.Colors.positive : DS.Colors.textPrimary))
                                .strikethrough(record.excluded == true)
                        }
                    }
                }
            }
            .navigationTitle("Выписка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Импортировать", action: onImport).bold() }
            }
        }
    }
}

// MARK: - Record editing

struct RecordEditSheet: View {
    let record: FinanceRecord
    let onSave: (StatementImport.RecordEdit) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var title: String = ""
    @State private var amount: String = ""
    @State private var date: Date = Date()
    @State private var category: String = ""
    @State private var note: String = ""
    @State private var excluded: Bool = false
    @State private var applyToMerchant: Bool = false
    @State private var amountError: String?

    private var hasCategory: Bool { record.kind == "income" || record.kind == "expense" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Описание", text: $title)
                    TextField("Сумма, ₸", text: $amount)
                        .keyboardType(.decimalPad)
                    if let amountError {
                        Text(amountError).font(.caption).foregroundColor(DS.Colors.destructive)
                    }
                    DatePicker("Дата", selection: $date, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "ru_RU"))
                }
                if hasCategory {
                    Section("Категория") {
                        Picker("Категория", selection: $category) {
                            ForEach(categoryOptions, id: \.self) { Text($0).tag($0) }
                        }
                        if let merchant = record.merchant {
                            Toggle("Для всех операций «\(merchant)»", isOn: $applyToMerchant)
                        }
                    }
                }
                Section {
                    TextField("Заметка", text: $note, axis: .vertical)
                    if hasCategory {
                        Toggle("Не учитывать в итогах", isOn: $excluded)
                    }
                }
                Section {
                    Button("Удалить запись", role: .destructive, action: onDelete)
                }
            }
            .navigationTitle("Запись")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save).bold() }
            }
            .onAppear(perform: load)
        }
    }

    private var categoryOptions: [String] {
        var options = MerchantCategories.all
        if let current = record.category, !options.contains(current) { options.insert(current, at: 0) }
        return options
    }

    private func load() {
        title = record.title
        amount = record.amountMinor.map { String(format: "%.2f", Double($0) / 100).replacingOccurrences(of: ".00", with: "") } ?? ""
        if let ymd = record.date, let parsed = PlanDateTime.formatter("yyyy-MM-dd", timeZone: "Asia/Qyzylorda").date(from: ymd) {
            date = parsed
        }
        category = record.category ?? "Без категории"
        note = record.note ?? ""
        excluded = record.excluded == true
    }

    private func save() {
        guard let minor = try? parseKzt(amount.replacingOccurrences(of: ",", with: ".")) else {
            amountError = "Введите сумму числом"
            return
        }
        let ymd = PlanDateTime.formatter("yyyy-MM-dd", timeZone: "Asia/Qyzylorda").string(from: date)
        onSave(.init(title: title, amountMinor: minor, date: ymd, category: category, note: note, excluded: excluded, applyCategoryToMerchant: applyToMerchant))
    }
}

// MARK: - Month insights (was MoneyChartsSection on «Обзор»)

/// Comparison with last month, the forecast and the top merchants. «Обзор» now shows the canvas blocks
/// («Траты по дням», «Куда уходит»), so these numbers live in «Итоги месяца».
struct MonthInsightsCard: View {
    let insights: FinanceInsights
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                SectionHeader("Расходы за месяц")
                comparisonRow("Этот месяц", insights.expenseMinor, color: accent)
                comparisonRow("Прошлый месяц", insights.previousExpenseMinor, color: DS.Colors.textMuted)
                if insights.previousExpenseMinor > 0 {
                    let delta = Double(insights.expenseMinor - insights.previousExpenseMinor) / Double(insights.previousExpenseMinor) * 100
                    Text(delta >= 0 ? "На \(Int(delta.rounded())) % больше, чем в прошлом месяце" : "На \(Int((-delta).rounded())) % меньше, чем в прошлом месяце")
                        .font(DS.Fonts.text(14, .medium, relativeTo: .caption))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                if let forecast = insights.forecastExpenseMinor, insights.expenseMinor > 0 {
                    MoneyRow(label: "Прогноз к концу месяца", value: MoneyFormat.kzt(forecast), emphasized: true)
                }
                if !insights.topMerchants.isEmpty {
                    Text("Где больше всего")
                        .font(DS.Fonts.text(14, .semibold, relativeTo: .footnote))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.top, DS.Metrics.spacing4)
                    ForEach(insights.topMerchants) { merchant in
                        MoneyRow(label: merchant.name, value: MoneyFormat.kzt(merchant.amountMinor))
                    }
                }
            }
        }
    }

    private func comparisonRow(_ title: String, _ minor: Int64, color: Color) -> some View {
        let top = max(insights.expenseMinor, insights.previousExpenseMinor, 1)
        return VStack(alignment: .leading, spacing: 6) {
            MoneyRow(label: title, value: MoneyFormat.kzt(minor))
            MoneyBar(fraction: Double(minor) / Double(top), height: 8, color: color)
        }
    }
}
