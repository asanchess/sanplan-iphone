import SwiftUI
import UniformTypeIdentifiers

public struct FinanceScreen: View {
    @Binding var showSettings: Bool
    @ObservedObject private var store: FinanceStore
    @ObservedObject private var inputs: InputDrafts
    @ObservedObject private var dictation: SpeechDictation

    /// The composer text lives above the tabs, so it survives switching tabs during dictation.
    private var textInput: String { inputs.money }
    @State private var kindHint: String = ""
    @State private var drafts: [FinanceDraft] = []
    @State private var sourceText: String = ""
    @State private var sourceHint: String = ""
    @State private var draftEdited: Bool = false
    @State private var errorMessage: String? = nil
    @State private var statusMessage: String? = nil

    // Composer & stats visibility
    @State private var showComposer: Bool = false
    @State private var selectedMonth: String = ""
    @State private var horizonDays: Int = 30
    @State private var recordToDelete: FinanceRecord? = nil

    // Vault Import / Export
    @State private var showExportSheet: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var vaultPasswordPrompt: String = ""
    @State private var vaultPasswordConfirm: String = ""
    @State private var isExporting: Bool = false
    @State private var isImporting: Bool = false
    @State private var pendingImportEnvelope: FinanceVaultEnvelope? = nil
    @State private var pendingImportState: FinanceState? = nil
    @State private var exportedDocument: EncryptedVaultDocument? = nil

    public init(store: FinanceStore, inputs: InputDrafts, dictation: SpeechDictation, showSettings: Binding<Bool>) {
        self.store = store
        self.inputs = inputs
        self.dictation = dictation
        self._showSettings = showSettings
    }

    private var todayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Qyzylorda") ?? TimeZone(secondsFromGMT: 5 * 3600)!
        return formatter.string(from: Date())
    }

    private var currentMonthString: String {
        String(todayString.prefix(7))
    }

    private var missingQuestions: [(draft: FinanceDraft, question: FinanceQuestion, index: Int)] {
        drafts.enumerated().flatMap { index, d in
            financeQuestions(d, drafts: drafts).map { (draft: d, question: $0, index: index) }
        }
    }

    private var firstQuestion: (draft: FinanceDraft, question: FinanceQuestion, index: Int)? {
        missingQuestions.first
    }

    private var isDraftStale: Bool {
        !drafts.isEmpty && (textInput != sourceText || kindHint != sourceHint)
    }

    public var body: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: DS.Metrics.spacing24) {
                    headerBar

                    if let notice = store.notice {
                        ErrorBanner(message: notice) {
                            store.notice = nil
                        }
                    }

                    if let err = errorMessage {
                        ErrorBanner(message: err) {
                            errorMessage = nil
                        }
                    }

                    if let stat = statusMessage {
                        Card {
                            Text(stat)
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.positive)
                        }
                    }

                    if store.state.records.isEmpty && drafts.isEmpty && !showComposer {
                        emptyStateView
                    } else {
                        if showComposer || !drafts.isEmpty {
                            composerSection
                        } else {
                            Button(action: {
                                showComposer = true
                            }) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text(drafts.isEmpty ? "Добавить запись" : "Продолжить черновик")
                                }
                                .font(.body.weight(.semibold))
                                .foregroundColor(DS.Colors.onAccent)
                                .frame(maxWidth: .infinity)
                                .frame(height: DS.Metrics.pillHeight)
                                .background(DS.Colors.accent)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.pillHeight / 2))
                            }
                        }

                        if !drafts.isEmpty {
                            reviewSection
                        }

                        if !store.state.records.isEmpty && !showComposer {
                            summarySection
                            goalsSection
                            recordsListSection
                        }
                    }

                    vaultActionsSection
                }
                .padding(.horizontal, DS.Metrics.screenGutter)
                .padding(.bottom, DS.Metrics.spacing32)
            }
        }
        .onAppear {
            if selectedMonth.isEmpty {
                selectedMonth = currentMonthString
            }
            store.refreshSummary(today: todayString, horizonDays: horizonDays)
        }
        .fileExporter(
            isPresented: $showExportSheet,
            document: exportedDocument,
            contentType: .json,
            defaultFilename: "ARNA-финансы-\(todayString).json"
        ) { result in
            switch result {
            case .success:
                statusMessage = "Зашифрованная копия сохранена."
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showImportSheet,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .alert("Удалить запись?", isPresented: Binding(
            get: { recordToDelete != nil },
            set: { if !$0 { recordToDelete = nil } }
        )) {
            Button("Отмена", role: .cancel) { recordToDelete = nil }
            Button("Удалить", role: .destructive) {
                if let rec = recordToDelete {
                    do {
                        try store.remove(recordId: rec.id, today: todayString)
                        statusMessage = "Запись удалена."
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    recordToDelete = nil
                }
            }
        } message: {
            Text("Запись будет удалена, а статистика пересчитана.")
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        ScreenHeader("Деньги") {
            CircleIconButton(
                icon: "person.crop.circle",
                accessibilityLabel: "Настройки"
            ) {
                showSettings = true
            }
        }
        .padding(.top, DS.Metrics.spacing16)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        Card {
            VStack(spacing: DS.Metrics.spacing16) {
                EmptyState(
                    title: "Финансовый учёт пуст",
                    message: "Записывай остатки, доходы, расходы и регулярные платежи обычным текстом на русском языке.",
                    icon: "creditcard"
                )

                PillButton("Добавить первую запись") {
                    showComposer = true
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Composer Section

    private var composerSection: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                HStack {
                    SectionHeader(store.state.records.isEmpty ? "Сколько у тебя денег сейчас?" : "Новая запись")

                    if !store.state.records.isEmpty {
                        Button("К сводке") {
                            showComposer = false
                        }
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.accent)
                    }
                }

                Text("Например: «У меня сейчас 100 тысяч тенге» или «Вчера потратил 2500 на обед; получил 20000 за работу».")
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)

                Picker("Определить по фразе", selection: $kindHint) {
                    Text("Определить по фразе").tag("")
                    Text("Остаток сейчас").tag("balance")
                    Text("Полученный доход").tag("income")
                    Text("Расход").tag("expense")
                    Text("Регулярный платёж").tag("obligation")
                    Text("Цель накопления").tag("goal")
                    Text("Ожидаемый доход").tag("planned_income")
                }
                .pickerStyle(.menu)
                .accentColor(DS.Colors.accent)
                .padding(.vertical, 4)

                ComposerField(
                    placeholder: "Например: потратил 2500 на обед",
                    text: Binding(get: { inputs.money }, set: { inputs.edit($0, for: .money) }),
                    isListening: dictation.isListening(to: .money),
                    level: dictation.level,
                    onMic: {
                        if dictation.isListening(to: .money) {
                            dictation.stop()
                        } else {
                            // Money never goes to the server: without Apple Speech there is no dictation here.
                            Task { await dictation.start(into: .money) }
                        }
                    },
                    onParse: {
                        dictation.stop()
                        parseEnteredText()
                    },
                    onClear: {
                        dictation.stop()
                        inputs.clear(.money)
                    }
                )

                if let speechError = dictation.errorMessage {
                    Text(speechError)
                        .font(.caption)
                        .foregroundColor(DS.Colors.warning)
                }

                Text("Текст разбирается на устройстве. Финансовые данные не передаются на сервер.")
                    .font(.caption2)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    private func parseEnteredText() {
        errorMessage = nil
        do {
            let result = try parseFinanceText(textInput, today: todayString, kindHint: kindHint.isEmpty ? nil : kindHint)
            guard !result.isEmpty else {
                throw FinanceError.invalidDraft("Расскажи хотя бы об одной сумме.")
            }
            if result.count > 50 {
                throw FinanceError.invalidDraft("Добавляй не больше 50 записей за один раз.")
            }
            self.drafts = result
            self.sourceText = textInput
            self.sourceHint = kindHint
            self.draftEdited = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Review Section

    private var reviewSection: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                SectionHeader("Проверь перед добавлением")

                if isDraftStale {
                    Text("Текст изменён после разбора. Нажми «Разобрать» заново.")
                        .font(.caption)
                        .foregroundColor(DS.Colors.warning)
                }

                if let f = firstQuestion {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Уточни запись \(f.index + 1): \(f.question.label)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(DS.Colors.warning)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Colors.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                }

                ForEach(drafts.indices, id: \.self) { index in
                    draftCard(index: index)
                }

                PillButton(
                    "Подтвердить и добавить (\(drafts.count))",
                    style: .primary,
                    isEnabled: !drafts.isEmpty && missingQuestions.isEmpty && !isDraftStale
                ) {
                    confirmDrafts()
                }
            }
        }
    }

    private func draftCard(index: Int) -> some View {
        let d = drafts[index]
        return VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
            HStack {
                Text("Запись \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Убрать") {
                    drafts.remove(at: index)
                    draftEdited = true
                }
                .font(.caption)
                .foregroundColor(DS.Colors.destructive)
            }

            // Kind selector
            Picker("Тип записи", selection: Binding(
                get: { d.kind ?? "" },
                set: { patchDraft(index: index, keyPath: \.kind, value: $0.isEmpty ? nil : $0) }
            )) {
                Text("Что означает сумма?").tag("")
                Text("Остаток сейчас").tag("balance")
                Text("Полученный доход").tag("income")
                Text("Расход").tag("expense")
                Text("Регулярный платёж").tag("obligation")
                Text("Цель накопления").tag("goal")
                Text("Ожидаемый доход").tag("planned_income")
            }
            .pickerStyle(.menu)

            // Title field
            TextField(d.kind == "expense" ? "На что потрачено" : d.kind == "income" ? "Источник дохода" : "Название", text: Binding(
                get: { d.title ?? "" },
                set: { patchDraft(index: index, keyPath: \.title, value: $0.isEmpty ? nil : $0) }
            ))
            .textFieldStyle(.roundedBorder)

            // Amount field
            TextField("Сумма в ₸", text: Binding(
                get: { d.amountMinor != nil ? String(format: "%.2f", Double(d.amountMinor!) / 100.0) : "" },
                set: { raw in
                    if let minor = try? parseKzt(raw) {
                        patchDraft(index: index, keyPath: \.amountMinor, value: minor)
                    } else if raw.isEmpty {
                        patchDraft(index: index, keyPath: \.amountMinor, value: nil)
                    }
                }
            ))
            .keyboardType(.numbersAndPunctuation)
            .textFieldStyle(.roundedBorder)

            // Date field
            if d.kind == "balance" || d.kind == "income" || d.kind == "expense" {
                TextField("Дата (ГГГГ-ММ-ДД)", text: Binding(
                    get: { d.date ?? "" },
                    set: { patchDraft(index: index, keyPath: \.date, value: $0.isEmpty ? nil : $0) }
                ))
                .textFieldStyle(.roundedBorder)
            }

            // Frequency field
            if d.kind == "obligation" || d.kind == "planned_income" {
                Picker("Периодичность", selection: Binding(
                    get: { d.frequency ?? "" },
                    set: { patchDraft(index: index, keyPath: \.frequency, value: $0.isEmpty ? nil : $0) }
                )) {
                    Text("Как часто?").tag("")
                    Text("Каждый месяц").tag("monthly")
                    Text("Каждую неделю").tag("weekly")
                }
                .pickerStyle(.segmented)
            }

            // Goal fields
            if d.kind == "goal" {
                TextField("Сколько уже отложено, ₸", text: Binding(
                    get: { d.savedMinor != nil ? String(format: "%.2f", Double(d.savedMinor!) / 100.0) : "" },
                    set: { raw in
                        if let minor = try? parseKzt(raw) {
                            patchDraft(index: index, keyPath: \.savedMinor, value: minor)
                        } else if raw.isEmpty {
                            patchDraft(index: index, keyPath: \.savedMinor, value: nil)
                        }
                    }
                ))
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)

                TextField("Срок (ГГГГ-ММ-ДД) — необязательно", text: Binding(
                    get: { d.dueDate ?? "" },
                    set: { patchDraft(index: index, keyPath: \.dueDate, value: $0.isEmpty ? nil : $0) }
                ))
                .textFieldStyle(.roundedBorder)
            }

            // Balance relation
            if balanceRelationNeeded(d, drafts: drafts) {
                Picker("Операция уже учтена в остатке?", selection: Binding(
                    get: { d.balanceRelation ?? "" },
                    set: { patchDraft(index: index, keyPath: \.balanceRelation, value: $0.isEmpty ? nil : $0) }
                )) {
                    Text("Уточни связь с остатком").tag("")
                    Text("Да, входит в остаток").tag("included")
                    Text("Нет, после остатка").tag("after")
                }
                .pickerStyle(.menu)
            }
        }
        .padding(12)
        .background(DS.Colors.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
    }

    private func patchDraft<T>(index: Int, keyPath: WritableKeyPath<FinanceDraft, T>, value: T) {
        draftEdited = true
        drafts[index][keyPath: keyPath] = value
    }

    private func confirmDrafts() {
        errorMessage = nil
        do {
            try store.commit(drafts: drafts, today: todayString)
            self.drafts = []
            inputs.clear(.money)
            self.sourceText = ""
            self.kindHint = ""
            self.sourceHint = ""
            self.draftEdited = false
            self.showComposer = false
            statusMessage = "Записи успешно добавлены."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        Group {
            if let sum = store.summary {
                Card {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                        SectionHeader("Сводка")

                        HStack(spacing: DS.Metrics.spacing16) {
                            statBox(title: "Доход за месяц", amount: sum.incomeMinor, color: DS.Colors.positive)
                            statBox(title: "Расход за месяц", amount: sum.expenseMinor, color: DS.Colors.textPrimary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Остаток сейчас")
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.textSecondary)

                            if let bal = sum.balanceMinor {
                                Text(formatKzt(bal))
                                    .font(.title2.weight(.semibold).monospacedDigit())
                                    .foregroundColor(DS.Colors.textPrimary)
                            } else {
                                Text("—")
                                    .font(.title2.weight(.semibold))
                                    .foregroundColor(DS.Colors.textSecondary)
                                Text("Общий остаток ещё не указан.")
                                    .font(.caption)
                                    .foregroundColor(DS.Colors.textSecondary)
                            }
                        }
                        .padding(.top, 4)

                        Divider().background(DS.Colors.hairline)

                        HStack {
                            Text("Отложено на цели")
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.textSecondary)
                            Spacer()
                            Text(formatKzt(sum.reservedGoalMinor))
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(DS.Colors.textPrimary)
                        }

                        HStack {
                            Text("Платежи месяца")
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.textSecondary)
                            Spacer()
                            Text(formatKzt(sum.obligationsMinor))
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(DS.Colors.textPrimary)
                        }

                        HStack {
                            Text("Свободно")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Spacer()
                            Text(sum.spendableMinor != nil ? formatKzt(sum.spendableMinor!) : "—")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundColor(DS.Colors.accent)
                        }

                        if let deficit = sum.deficitMinor, deficit > 0 {
                            Text("На указанные резервы и платежи не хватает \(formatKzt(deficit)).")
                                .font(.caption)
                                .foregroundColor(DS.Colors.destructive)
                        }

                        if let daily = sum.dailyMinor {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ориентир на день · \(horizonDays) дн.")
                                    .font(.caption)
                                    .foregroundColor(DS.Colors.textSecondary)
                                Text(formatKzt(daily))
                                    .font(.headline.weight(.semibold).monospacedDigit())
                                    .foregroundColor(DS.Colors.textPrimary)
                            }
                            .padding(.top, 4)
                        }

                        if !sum.byCategory.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Расходы по категориям")
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(DS.Colors.textSecondary)

                                ForEach(sum.byCategory, id: \.name) { cat in
                                    HStack {
                                        Text(cat.name)
                                            .font(.caption)
                                            .foregroundColor(DS.Colors.textPrimary)
                                        Spacer()
                                        Text(formatKzt(cat.amountMinor))
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(DS.Colors.textSecondary)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
        }
    }

    private func statBox(title: String, amount: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(DS.Colors.textSecondary)
            Text(formatKzt(amount))
                .font(.headline.weight(.semibold).monospacedDigit())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(DS.Colors.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
    }

    // MARK: - Goals Section

    private var goalsSection: some View {
        let goals = store.state.records.filter { $0.kind == "goal" }
        return Group {
            if !goals.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                        SectionHeader("Накопления")

                        ForEach(goals) { g in
                            let prog = (try? goalProgress(
                                amountMinor: g.amountMinor ?? 1,
                                savedMinor: g.savedMinor ?? 0,
                                dueDate: g.dueDate,
                                today: todayString
                            ))

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(g.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(DS.Colors.textPrimary)
                                    Spacer()
                                    if let p = prog {
                                        Text("\(p.progressPercent)%")
                                            .font(.caption.weight(.medium).monospacedDigit())
                                            .foregroundColor(DS.Colors.accent)
                                    }
                                }

                                Text("\(formatKzt(g.savedMinor ?? 0)) из \(formatKzt(g.amountMinor ?? 0))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(DS.Colors.textSecondary)

                                ProgressView(value: Double(prog?.progressPercent ?? 0), total: 100)
                                    .accentColor(DS.Colors.accent)

                                if let p = prog {
                                    Text("Осталось \(formatKzt(p.remainingMinor))")
                                        .font(.caption2)
                                        .foregroundColor(DS.Colors.textSecondary)

                                    if let dailyReq = p.requiredDailyMinor, dailyReq > 0 {
                                        Text("\(formatKzt(dailyReq)) в день до срока")
                                            .font(.caption2)
                                            .foregroundColor(DS.Colors.textSecondary)
                                    }
                                }
                            }
                            .padding(12)
                            .background(DS.Colors.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Records List Section

    private var recordsListSection: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                SectionHeader("История записей")

                ForEach(store.state.records.reversed().prefix(50)) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(kindLabel(r.kind) + (r.date != nil ? " · \(r.date!)" : ""))
                                .font(.caption2)
                                .foregroundColor(DS.Colors.textSecondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            if let amt = r.amountMinor {
                                Text(formatKzt(amt))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundColor(DS.Colors.textPrimary)
                            }

                            Button("Удалить") {
                                recordToDelete = r
                            }
                            .font(.caption2)
                            .foregroundColor(DS.Colors.destructive)
                        }
                    }
                    Divider().background(DS.Colors.hairline)
                }
            }
        }
    }

    // MARK: - Vault Actions Section

    private var vaultActionsSection: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                SectionHeader("Сохранение и копия")

                Text(store.state.records.isEmpty
                     ? "Данные хранятся только на этом телефоне. Если есть копия с другого устройства, её можно восстановить."
                     : "Данные хранятся только на этом телефоне. Копия — файл, защищённый вашим паролем; без пароля его не открыть.")
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)

                VStack(spacing: DS.Metrics.spacing12) {
                    if !store.state.records.isEmpty {
                        SecureField("Пароль для копии", text: $vaultPasswordPrompt)
                            .textFieldStyle(.roundedBorder)

                        PillButton(
                            "Сохранить копию в Файлы",
                            style: .secondary,
                            isEnabled: vaultPasswordPrompt.count >= 8
                        ) {
                            exportVault()
                        }

                        if vaultPasswordPrompt.count < 8 {
                            Text("Пароль — не короче 8 символов.")
                                .font(.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    PillButton("Восстановить из копии", style: .secondary) {
                        showImportSheet = true
                    }
                }

                if let pendingState = pendingImportState {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("В выбранной копии \(pendingState.records.count) записей. Текущие данные будут заменены.")
                            .font(.subheadline)
                            .foregroundColor(DS.Colors.warning)

                        HStack(spacing: DS.Metrics.spacing12) {
                            PillButton("Заменить записи", style: .destructive) {
                                do {
                                    try store.replaceState(with: pendingState, today: todayString)
                                    self.pendingImportState = nil
                                    self.pendingImportEnvelope = nil
                                    statusMessage = "Данные восстановлены из резервной копии."
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }

                            PillButton("Отмена", style: .secondary) {
                                self.pendingImportState = nil
                                self.pendingImportEnvelope = nil
                            }
                        }
                    }
                    .padding(12)
                    .background(DS.Colors.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                }
            }
        }
    }

    private func exportVault() {
        Task {
            do {
                let envelope = try await FinanceVault.sealFinance(state: store.state, password: vaultPasswordPrompt)
                let data = try JSONEncoder().encode(envelope)
                self.exportedDocument = EncryptedVaultDocument(data: data)
                self.showExportSheet = true
                self.vaultPasswordPrompt = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Нет доступа к файлу."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                guard let json = String(data: data, encoding: .utf8) else {
                    throw FinanceVaultError.invalidEnvelope("Некорректный файл финансов.")
                }
                let envelope = try FinanceVault.readVaultEnvelope(from: json)
                self.pendingImportEnvelope = envelope

                // Prompt user to open envelope with password
                Task {
                    do {
                        let opened = try await FinanceVault.openFinance(envelope: envelope, password: vaultPasswordPrompt)
                        self.pendingImportState = opened
                        self.vaultPasswordPrompt = ""
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }

        case .failure(let err):
            errorMessage = err.localizedDescription
        }
    }

    // MARK: - Helpers

    private func formatKzt(_ amountMinor: Int64) -> String {
        let whole = amountMinor / 100
        let frac = abs(amountMinor % 100)
        let numFormatter = NumberFormatter()
        numFormatter.numberStyle = .decimal
        numFormatter.groupingSeparator = " "
        let formattedWhole = numFormatter.string(from: NSNumber(value: whole)) ?? "\(whole)"
        if frac == 0 {
            return "\(formattedWhole) ₸"
        } else {
            return String(format: "%@,%02d ₸", formattedWhole, frac)
        }
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "balance": return "Остаток"
        case "income": return "Доход"
        case "expense": return "Расход"
        case "obligation": return "Регулярный платёж"
        case "goal": return "Цель"
        case "planned_income": return "Ожидаемый доход"
        default: return kind
        }
    }
}

// MARK: - File Document for Export

public struct EncryptedVaultDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.json] }
    public var data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
