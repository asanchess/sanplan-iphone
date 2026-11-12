import SwiftUI
import UniformTypeIdentifiers

public struct FinanceScreen: View {
    @Binding var showSettings: Bool
    @ObservedObject private var store: FinanceStore
    @ObservedObject private var inputs: InputDrafts
    @ObservedObject private var dictation: SpeechDictation
    /// Reads phrases through the server's Gemini; nil keeps everything on the phone's own rules.
    private let client: APIClient?

    /// The composer text lives above the tabs, so it survives switching tabs during dictation.
    private var textInput: String { inputs.money }
    @State private var kindHint: String = ""
    @State private var drafts: [FinanceDraft] = []
    @State private var sourceText: String = ""
    @State private var sourceHint: String = ""
    @State private var draftEdited: Bool = false
    @State private var errorMessage: String? = nil
    @State private var statusMessage: String? = nil
    @State private var isParsing = false
    /// Only the answer to the latest request is shown.
    @State private var parseToken = UUID()
    /// How the last phrase was read, shown above the drafts.
    @State private var parseNote: String? = nil

    // Composer & stats visibility
    @State private var showComposer: Bool = false
    @State private var horizonDays: Int = 30
    @State private var recordToDelete: FinanceRecord? = nil
    @State private var recordToEdit: FinanceRecord? = nil
    @State private var recordToCategorize: FinanceRecord? = nil

    // Tabs, pinned header and the operations feed
    @State private var tab: FinanceTab = .overview
    @State private var showBreakdown = false
    @State private var showReconcile = false
    @State private var feedExpanded = false
    @State private var ledgerFilter = LedgerFilter(month: FinanceText.currentMonth())

    // Vault Import / Export
    @State private var showExportSheet: Bool = false
    @State private var showImportSheet: Bool = false
    /// What the single file importer is open for; SwiftUI presents only one importer per screen.
    @State private var importsStatement = false
    @State private var pickedStatement: URL?
    @State private var vaultPasswordPrompt: String = ""
    @State private var vaultPasswordConfirm: String = ""
    @State private var isExporting: Bool = false
    @State private var isImporting: Bool = false
    @State private var pendingImportEnvelope: FinanceVaultEnvelope? = nil
    @State private var pendingImportState: FinanceState? = nil
    @State private var exportedDocument: EncryptedVaultDocument? = nil

    public init(store: FinanceStore, inputs: InputDrafts, dictation: SpeechDictation, client: APIClient? = nil, showSettings: Binding<Bool>) {
        self.store = store
        self.inputs = inputs
        self.dictation = dictation
        self.client = client
        self._showSettings = showSettings
    }

    /// Gregorian day in Qyzylorda whatever calendar the phone uses.
    private var todayString: String { FinanceText.today() }

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

    private var snapshot: BudgetSnapshot? {
        guard !store.state.records.isEmpty else { return nil }
        return try? FinanceBudgeting.snapshot(store.state, today: todayString)
    }

    public var body: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()

            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    headerBar(proxy)
                        .padding(.horizontal, DS.Metrics.screenGutter)

                    if !store.state.records.isEmpty {
                        VStack(spacing: DS.Metrics.spacing12) {
                            CleanHeader(snapshot: snapshot) { showBreakdown = true }
                            CanSpendTodayCard(result: store.canSpendToday(on: todayString))
                            Picker("Раздел", selection: $tab) {
                                ForEach(FinanceTab.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.horizontal, DS.Metrics.screenGutter)
                        .padding(.bottom, DS.Metrics.spacing12)
                    }

                    ScrollView {
                        VStack(spacing: DS.Metrics.spacing24) {
                            messages

                            if showComposer || !drafts.isEmpty {
                                composerSection.id("composer")
                            }
                            if !drafts.isEmpty {
                                reviewSection
                            }

                            if store.state.records.isEmpty {
                                if !showComposer && drafts.isEmpty {
                                    emptyStateView
                                }
                                statementsSection
                                vaultActionsSection
                            } else {
                                tabContent
                            }
                        }
                        .padding(.horizontal, DS.Metrics.screenGutter)
                        .padding(.top, DS.Metrics.spacing4)
                        .padding(.bottom, DS.Metrics.spacing32)
                    }
                }
            }
        }
        .onAppear {
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
            allowedContentTypes: importsStatement ? [.pdf] : [.json],
            allowsMultipleSelection: false
        ) { result in
            if importsStatement {
                importsStatement = false
                switch result {
                case .success(let urls): pickedStatement = urls.first
                case .failure(let error): errorMessage = error.localizedDescription
                }
            } else {
                handleImportResult(result)
            }
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
        .confirmationDialog(
            "Категория операции",
            isPresented: Binding(get: { recordToCategorize != nil }, set: { if !$0 { recordToCategorize = nil } }),
            titleVisibility: .visible,
            presenting: recordToCategorize
        ) { record in
            ForEach(MerchantCategories.all, id: \.self) { category in
                Button(category) { setCategory(category, for: record) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { record in
            Text(record.title)
        }
        .sheet(item: $recordToEdit) { record in
            if record.importId == nil {
                ManualEditSheet(
                    record: record,
                    onSave: { edit in
                        let failure = applyChange("Запись обновлена.") { try FinanceBudgeting.editManual($0, id: record.id, edit) }
                        if failure == nil { recordToEdit = nil }
                        return failure
                    },
                    onDelete: {
                        recordToEdit = nil
                        recordToDelete = record
                    },
                    onCancel: { recordToEdit = nil }
                )
            } else {
            RecordEditSheet(
                record: record,
                onSave: { edit in
                    do {
                        try store.replaceState(with: StatementImport.edit(record.id, edit, in: store.state), today: todayString)
                        statusMessage = "Запись обновлена."
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    recordToEdit = nil
                },
                onDelete: {
                    recordToEdit = nil
                    recordToDelete = record
                },
                onCancel: { recordToEdit = nil }
            )
            }
        }
        .sheet(isPresented: $showBreakdown) {
            CleanBreakdownSheet(snapshot: snapshot, onSetLimits: {
                showBreakdown = false
                tab = .plan
            }) { showBreakdown = false }
        }
        .sheet(isPresented: $showReconcile) {
            ReconcileSheet(today: todayString, apply: financeApply) { showReconcile = false }
        }
        .onChange(of: store.state.records.isEmpty) { _, isEmpty in
            // Sign-out or a reset empties the state: nothing typed into the feed may outlive it.
            if isEmpty {
                ledgerFilter = LedgerFilter(month: currentMonthString)
                feedExpanded = false
                tab = .overview
            }
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .overview:
            FinanceOverviewTab(
                store: store,
                today: todayString,
                apply: financeApply,
                onCategory: { category in
                    ledgerFilter = LedgerFilter(
                        month: currentMonthString,
                        kind: .expense,
                        category: category == "Остальное" ? nil : category
                    )
                    feedExpanded = true
                    tab = .operations
                },
                onOpenPlan: { tab = .plan }
            )
        case .plan:
            FinancePlanTab(store: store, today: todayString, apply: financeApply)
        case .operations:
            ManualEntriesCard(state: store.state) { recordToEdit = $0 }
            OperationsFeed(
                store: store, filter: $ledgerFilter, expanded: $feedExpanded,
                onEdit: { recordToEdit = $0 },
                onDelete: { recordToDelete = $0 },
                onCategory: { recordToCategorize = $0 }
            )
            ReconcileCard(snapshot: snapshot) { showReconcile = true }
            statementsSection
            vaultActionsSection
        }
    }

    @ViewBuilder
    private var messages: some View {
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
    }

    private var statementsSection: some View {
        StatementsSection(
            store: store,
            today: todayString,
            errorMessage: $errorMessage,
            statusMessage: $statusMessage,
            pickedFile: $pickedStatement,
            onPick: {
                importsStatement = true
                showImportSheet = true
            }
        )
    }

    /// Every budget change goes through here: one pure function on the state, then the encrypted save.
    /// Nil when the change is saved, else the reason, so a sheet can stay open and show it.
    private func applyChange(_ message: String?, _ change: (FinanceState) throws -> FinanceState) -> String? {
        errorMessage = nil
        do {
            try store.replaceState(with: change(store.state), today: todayString)
            statusMessage = message
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    private var financeApply: FinanceApply { FinanceApply(run: applyChange) }

    private func setCategory(_ category: String, for record: FinanceRecord) {
        recordToCategorize = nil
        if applyChange("Категория: \(category).", { try StatementImport.recategorize(record.id, to: category, in: $0) }) == nil {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    // MARK: - Header Bar

    private func headerBar(_ proxy: ScrollViewProxy) -> some View {
        ScreenHeader("Деньги") {
            CircleIconButton(
                icon: "plus",
                accessibilityLabel: "Добавить запись"
            ) {
                showComposer = true
                // The composer sits above the tab content; bring it into view from any scroll position.
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo("composer", anchor: .top) }
                }
            }
            CircleIconButton(
                icon: "person.crop.circle",
                accessibilityLabel: "Настройки"
            ) {
                showSettings = true
            }
        }
        .padding(.top, DS.Metrics.spacing16)
        .padding(.bottom, DS.Metrics.spacing12)
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
                        Button("Скрыть") {
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
                    isBusy: isParsing,
                    parseTitle: isParsing ? "Разбираю…" : "Разобрать",
                    onMic: {
                        if dictation.isListening(to: .money) {
                            dictation.stop()
                        } else {
                            // Speech becomes text on the phone (Apple Speech); only the text is read by the server.
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

                Text(client == nil
                     ? "Текст разбирается на устройстве."
                     : "Фразу читает Gemini (Google) через сервер ARNA. Сервер её не хранит, Google может хранить по своим правилам. Остатки и история остаются на телефоне.")
                    .font(.caption2)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    /// Gemini reads the phrase first, like in plans; without the network or quota the phone's own rules do.
    private func parseEnteredText() {
        errorMessage = nil
        statusMessage = nil
        let text = textInput
        let hint = kindHint
        let today = todayString
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Расскажи хотя бы об одной сумме."
            return
        }
        guard !isParsing else { return }
        isParsing = true
        // Old drafts go away while the new phrase is read, so nothing stale can be confirmed meanwhile.
        drafts = []
        parseNote = nil
        let token = UUID()
        parseToken = token
        Task { @MainActor in
            defer { if parseToken == token { isParsing = false } }
            var result: [FinanceDraft] = []
            var note: String? = nil
            if let client {
                do {
                    result = try await FinanceAPI.parse(client: client, text: text, today: today, kindHint: hint.isEmpty ? nil : hint)
                    if result.isEmpty { note = "Gemini не нашёл сумм, разобрано по правилам на телефоне." }
                } catch {
                    note = "Gemini недоступен, разобрано по правилам на телефоне. Проверь поля."
                }
            }
            // The phrase changed or was confirmed while Gemini was answering: drop the answer.
            guard parseToken == token, textInput == text else { return }
            if result.isEmpty {
                do {
                    result = try parseFinanceText(text, today: today, kindHint: hint.isEmpty ? nil : hint)
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
            guard !result.isEmpty else {
                errorMessage = "Не нашёл суммы. Напиши, например: «потратил 2500 на обед»."
                return
            }
            guard result.count <= 50 else {
                errorMessage = "Добавляй не больше 50 записей за один раз."
                return
            }
            self.drafts = result
            self.sourceText = text
            self.sourceHint = hint
            self.draftEdited = false
            self.parseNote = note
        }
    }

    // MARK: - Review Section

    private var reviewSection: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                SectionHeader("Проверь перед добавлением")

                if let parseNote {
                    Text(parseNote)
                        .font(.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                }

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
            let count = drafts.count
            try store.commit(drafts: drafts, today: todayString)
            self.drafts = []
            self.parseNote = nil
            // What was just added shows first in «Добавлено вручную» on the operations tab.
            self.tab = .operations
            inputs.clear(.money)
            self.sourceText = ""
            self.kindHint = ""
            self.sourceHint = ""
            self.draftEdited = false
            self.showComposer = false
            statusMessage = count == 1
                ? "Добавлено. Запись — первая в «Добавлено вручную», её можно изменить или удалить."
                : "Добавлено записей: \(count). Они первые в «Добавлено вручную», их можно изменить или удалить."
        } catch {
            errorMessage = error.localizedDescription
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
                        importsStatement = false
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
