import Charts
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
    /// The PDF the owner picked in the Money screen's file importer.
    @Binding var pickedFile: URL?
    let onPick: () -> Void

    @State private var isReading = false
    @State private var pending: PendingStatement?
    @State private var suggestions: [StatementImport.MergeSuggestion] = []
    @State private var importToDelete: FinanceImport?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                SectionHeader("Выписки")
                Text("Kaspi Gold и Halyk в PDF. Файл читается на телефоне и никуда не отправляется.")
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)

                PillButton("Импорт выписки", icon: "doc.text.magnifyingglass", style: .secondary, isLoading: isReading) {
                    onPick()
                }
                .accessibilityIdentifier("statement-import")

                ForEach(suggestions) { suggestion in
                    mergeRow(suggestion)
                }

                ForEach(store.state.imports ?? []) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.bank) · \(MoneyFormat.operations(item.count))")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(periodText(item))
                                .font(.caption2)
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        Spacer()
                        Button("Удалить") { importToDelete = item }
                            .font(.caption)
                            .foregroundColor(DS.Colors.destructive)
                            .frame(minHeight: DS.Metrics.minHitTarget)
                    }
                }
            }
        }
        .onChange(of: pickedFile) { _, url in
            guard let url else { return }
            pickedFile = nil
            read(url)
        }
        .sheet(item: $pending) { pending in
            StatementPreviewSheet(pending: pending, onImport: { confirm(pending) }, onCancel: { self.pending = nil })
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
        .background(DS.Colors.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
    }

    private func read(_ url: URL) {
        isReading = true
        errorMessage = nil
        let rules = store.state.merchantCategories
        Task {
            let outcome: Result<PendingStatement, Error> = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let text = try BankStatementParser.text(ofPDFAt: url)
                    let statement = try BankStatementParser.parse(text)
                    let importId = "imp-" + UUID().uuidString.prefix(8).lowercased()
                    let preview = StatementImport.preview(statement, importId: importId, rules: rules)
                    return .success(PendingStatement(id: importId, fileName: url.lastPathComponent, preview: preview))
                } catch {
                    return .failure(error)
                }
            }.value
            isReading = false
            switch outcome {
            case .success(let statement): pending = statement
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    private func confirm(_ pending: PendingStatement) {
        do {
            let next = try StatementImport.apply(pending.preview, to: store.state, importId: pending.id, fileName: pending.fileName, today: today)
            try store.replaceState(with: next, today: today)
            suggestions = StatementImport.mergeSuggestions(in: store.state, importId: pending.id)
            let added = store.state.records.filter { $0.importId == pending.id }.count
            let skipped = pending.preview.records.count - added
            statusMessage = "Добавлено: \(MoneyFormat.operations(added))."
                + (skipped > 0 ? " Уже были загружены раньше: \(skipped)." : "")
        } catch {
            errorMessage = error.localizedDescription
        }
        self.pending = nil
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
            try store.replaceState(with: StatementImport.deleteImport(item.id, from: store.state), today: today)
            suggestions.removeAll { suggestion in !store.state.records.contains { $0.id == suggestion.importedId } }
            statusMessage = "Выписка удалена."
        } catch {
            errorMessage = error.localizedDescription
        }
        importToDelete = nil
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

// MARK: - Charts

struct MoneyChartsSection: View {
    let insights: FinanceInsights
    /// Opens the operations feed filtered by the tapped category; nil keeps the legend static.
    var onCategory: ((String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let palette: [Color] = [
        DS.Colors.accent, Color(red: 0.42, green: 0.31, blue: 0.85), Color(red: 0.95, green: 0.62, blue: 0.40),
        Color(red: 0.36, green: 0.72, blue: 0.62), Color(red: 0.90, green: 0.45, blue: 0.62), Color(red: 0.55, green: 0.60, blue: 0.70),
    ]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                SectionHeader("Расходы за месяц")
                if insights.categories.isEmpty {
                    Text("В этом месяце расходов нет.")
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                } else {
                    HStack(alignment: .center, spacing: DS.Metrics.spacing16) {
                        ring.frame(width: 140, height: 140)
                        legend
                    }
                }
                comparison
                if let forecast = insights.forecastExpenseMinor, insights.expenseMinor > 0 {
                    HStack {
                        Text("Прогноз к концу месяца")
                            .font(.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                        Spacer()
                        Text(MoneyFormat.kzt(forecast))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundColor(DS.Colors.textPrimary)
                            .contentTransition(.numericText())
                    }
                }
                if !insights.topMerchants.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                        Text("Где больше всего")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                        ForEach(insights.topMerchants) { merchant in
                            HStack {
                                Text(merchant.name).font(.subheadline).lineLimit(1)
                                Spacer()
                                Text(MoneyFormat.kzt(merchant.amountMinor))
                                    .font(.subheadline.monospacedDigit())
                            }
                            .foregroundColor(DS.Colors.textPrimary)
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: insights)
    }

    private var ring: some View {
        Chart(insights.categories) { slice in
            SectorMark(
                angle: .value("Сумма", slice.amountMinor),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(color(for: slice))
        }
        .chartLegend(.hidden)
        .chartBackground { _ in
            VStack(spacing: 0) {
                Text(MoneyFormat.kzt(insights.expenseMinor))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundColor(DS.Colors.textPrimary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("всего").font(.caption2).foregroundColor(DS.Colors.textSecondary)
            }
            .padding(24)
        }
        .accessibilityLabel("Расходы по категориям")
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(insights.categories) { slice in
                if let onCategory {
                    Button { onCategory(slice.name) } label: { legendRow(slice) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Показать операции категории")
                } else {
                    legendRow(slice)
                }
            }
        }
    }

    private func legendRow(_ slice: FinanceInsights.Slice) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color(for: slice)).frame(width: 8, height: 8)
            Text(slice.name).font(.caption).lineLimit(1)
            Spacer(minLength: 4)
            Text(percent(slice.amountMinor)).font(.caption.monospacedDigit())
        }
        .foregroundColor(DS.Colors.textPrimary)
        .frame(minHeight: onCategory == nil ? nil : 32)
        .contentShape(Rectangle())
    }

    private var comparison: some View {
        let rows = [
            FinanceInsights.Slice(name: "Этот месяц", amountMinor: insights.expenseMinor),
            FinanceInsights.Slice(name: "Прошлый месяц", amountMinor: insights.previousExpenseMinor),
        ]
        return VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
            Chart(rows) { row in
                BarMark(x: .value("Сумма", row.amountMinor), y: .value("Месяц", row.name))
                    .foregroundStyle(row.name == "Этот месяц" ? DS.Colors.accent : DS.Colors.textSecondary.opacity(0.35))
                    .cornerRadius(4)
                    .annotation(position: .trailing) {
                        Text(MoneyFormat.kzt(row.amountMinor)).font(.caption2.monospacedDigit()).foregroundColor(DS.Colors.textSecondary)
                    }
            }
            .chartXAxis(.hidden)
            .frame(height: 70)
            if insights.previousExpenseMinor > 0 {
                let delta = Double(insights.expenseMinor - insights.previousExpenseMinor) / Double(insights.previousExpenseMinor) * 100
                Text(delta >= 0 ? "На \(Int(delta.rounded())) % больше, чем в прошлом месяце" : "На \(Int((-delta).rounded())) % меньше, чем в прошлом месяце")
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    private func color(for slice: FinanceInsights.Slice) -> Color {
        let index = insights.categories.firstIndex(of: slice) ?? 0
        return palette[index % palette.count]
    }

    private func percent(_ minor: Int64) -> String {
        guard insights.expenseMinor > 0 else { return "" }
        return "\(Int((Double(minor) / Double(insights.expenseMinor) * 100).rounded())) %"
    }
}
