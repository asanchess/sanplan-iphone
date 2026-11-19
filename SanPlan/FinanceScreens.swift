import SwiftUI
import UniformTypeIdentifiers

/// Деньги, round 6: a 1:1 port of docs/design/canvas-r5/Money.html. The header scrolls with the content;
/// the day limit and «Обзор / План / Операции» come first; the bottom bar «Кофе 1200 · Добавить» is the section's «+»
/// (voice or text), and what it adds lands in «Операции». Everything takes the section colour from `sectionAccent`.
public struct FinanceScreen: View {
    @Binding var showSettings: Bool
    @ObservedObject private var store: FinanceStore
    @ObservedObject private var inputs: InputDrafts
    @ObservedObject private var dictation: SpeechDictation
    /// The account's key session: the backup file is sealed with a key derived from its data key.
    @ObservedObject private var vault: VaultKeySession
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

    // Composer & stats
    @FocusState private var composerFocused: Bool
    @State private var horizonDays: Int = 30
    @State private var recordToDelete: FinanceRecord? = nil
    @State private var recordToEdit: FinanceRecord? = nil
    @State private var recordToCategorize: FinanceRecord? = nil

    // Tabs and the operations feed
    @State private var tab: FinanceTab = .overview
    /// «Траты по дням»: week or month; a deep link can ask for either.
    @State private var period: DeepLink.Period = .week
    @State private var showBreakdown = false
    @State private var showReconcile = false
    @State private var ledgerFilter = LedgerFilter(month: FinanceText.currentMonth())
    @State private var didApplyScreenshotRoute = false
    /// Read so «можно сегодня», the month and the week are drawn again when the day turns over.
    @Environment(\.dayKey) private var dayKey

    // Vault Import / Export
    @State private var showExportSheet: Bool = false
    @State private var showImportSheet: Bool = false
    /// What the single file importer is open for; SwiftUI presents only one importer per screen.
    @State private var importsStatement = false
    @State private var pickedStatement: URL?
    /// Only for opening an older backup protected by a password.
    @State private var vaultPasswordPrompt: String = ""
    @State private var isExporting: Bool = false
    @State private var isImporting: Bool = false
    @State private var pendingImportEnvelope: FinanceVaultEnvelope? = nil
    @State private var pendingImportState: FinanceState? = nil
    @State private var exportedDocument: EncryptedVaultDocument? = nil

    @Environment(\.sectionAccent) private var accent

    public init(store: FinanceStore, inputs: InputDrafts, dictation: SpeechDictation, vault: VaultKeySession, client: APIClient? = nil, showSettings: Binding<Bool>) {
        self.store = store
        self.inputs = inputs
        self.dictation = dictation
        self.vault = vault
        self.client = client
        self._showSettings = showSettings
    }

    /// Gregorian day in Qyzylorda whatever calendar the phone uses.
    private var todayString: String { FinanceText.today() }

    /// «НОЯБРЬ»: only the month; the net has its own large line «Чистыми за ноябрь» under the day limit.
    private var moneyKicker: String {
        FinanceText.monthName(currentMonthString)
    }

    /// «Чистыми за ноябрь +197 972 ₸» under «Можно потратить сегодня»; nil without a balance.
    private var monthNet: (month: String, minor: Int64)? {
        guard let clean = snapshot?.cleanMinor else { return nil }
        return (FinanceText.monthName(currentMonthString), clean)
    }

    /// Траты этого месяца и сумма лимитов в тенге, для «Можно потратить сегодня» по нажатию.
    private var monthSpending: (spent: Int64, limit: Int64)? {
        guard let limits = store.state.budget?.limits, !limits.isEmpty else { return nil }
        let byCategory = store.periodSummary(from: String(todayString.prefix(7)) + "-01", to: todayString).byCategory
        let spent = limits.keys.reduce(Int64(0)) { $0 + (byCategory[$1] ?? 0) }
        return (spent, limits.values.reduce(0, +) / FinanceBudgeting.oneTenge)
    }

    /// «Чистыми X ₸» and why, under the day limit (was the pinned CleanHeader).
    private var cleanLine: (amount: String, note: String, warns: Bool)? {
        guard let s = snapshot else { return nil }
        guard let clean = s.cleanMinor else {
            return ("—", "Остаток не указан: напишите внизу «остаток 150000» или загрузите выписку", true)
        }
        let amount = FinanceText.money(clean)
        if clean < 0 { return (amount, "Не хватает \(FinanceText.money(-clean)) на план месяца", true) }
        if let asOf = s.asOf, s.isStale {
            return (amount, "остаток на \(FinanceText.dayMonth(asOf)) · пора загрузить свежую выписку", true)
        }
        if s.limits.isEmpty { return (amount, "Лимитов нет — на повседневные траты ничего не учтено", true) }
        guard let asOf = s.asOf else { return (amount, "на счетах", false) }
        return (amount, "на счетах на \(FinanceText.dayMonth(asOf))", false)
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

    private var snapshot: BudgetSnapshot? {
        guard !store.state.records.isEmpty else { return nil }
        return try? FinanceBudgeting.snapshot(store.state, today: todayString)
    }

    public var body: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()
            MoneyBackdrop(accent: accent)
                .ignoresSafeArea(edges: .top)

            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: MoneyStyle.blockGap) {
                            ScreenHeader("Деньги", kicker: moneyKicker) {}

                            // As on the canvas: the day's number first, then the section switcher.
                            if !store.state.records.isEmpty {
                                CanSpendTodayCard(
                                    result: store.canSpendToday(on: todayString),
                                    month: monthSpending,
                                    clean: cleanLine,
                                    net: monthNet,
                                    onBreakdown: { showBreakdown = true },
                                    onSetLimits: { tab = .plan }
                                )
                                .tourTarget("money.canSpend")
                                ArnaSegmented("Раздел денег", selection: $tab, options: FinanceTab.allCases.map { ($0, $0.title) })
                                    .tourTarget("money.sections")
                            }
                            messages

                            if !drafts.isEmpty {
                                reviewSection.id("review")
                            }

                            if store.state.records.isEmpty {
                                if drafts.isEmpty {
                                    emptyStateView
                                }
                                statementsSection
                                    .tourTarget("money.statements")
                                vaultActionsSection
                            } else {
                                tabContent
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 24)
                    }
                    .tourScrollHost()
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: drafts.isEmpty) { _, isEmpty in
                        guard !isEmpty else { return }
                        withAnimation { proxy.scrollTo("review", anchor: .top) }
                    }

                    composerBar
                }
            }
        }
        .onAppear {
            applyScreenshotRoute()
            store.refreshSummary(today: todayString, horizonDays: horizonDays)
        }
        .onChange(of: dayKey) { old, new in
            store.refreshSummary(today: todayString, horizonDays: horizonDays)
            // A new month: the ledger that showed «this month» shows the new one; a month picked on purpose stays.
            if let month = ledgerFilter.month {
                ledgerFilter.month = DayTurn.follow(selected: month, oldToday: String(old.prefix(7)), newToday: String(new.prefix(7)))
            }
        }
        .onReceive(DeepLinks.shared.$pending) { link in
            guard let link else { return }
            switch link {
            case .moneyOverview(let p):
                tab = .overview
                period = p
            case .moneyPlan:
                tab = .plan
            case .moneyOperations:
                tab = .operations
            default:
                return
            }
            DeepLinks.shared.consume()
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
                        let next = try removeFinanceRecord(state: store.state, id: rec.id)
                        try store.replaceStateUndoable(with: next, today: todayString, message: "Удалено: \(rec.title)")
                        statusMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    recordToDelete = nil
                }
            }
        } message: {
            Text("Статистика пересчитается. Сразу после удаления можно нажать «Отменить».")
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
            Group {
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
                                try store.replaceStateUndoable(with: StatementImport.edit(record.id, edit, in: store.state), today: todayString, message: "Запись обновлена")
                                statusMessage = nil
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
            .environment(\.sectionAccent, accent)
            .tint(accent)
        }
        .sheet(isPresented: $showBreakdown) {
            CleanBreakdownSheet(snapshot: snapshot, onSetLimits: {
                showBreakdown = false
                tab = .plan
            }) { showBreakdown = false }
            .environment(\.sectionAccent, accent)
        }
        .sheet(isPresented: $showReconcile) {
            ReconcileSheet(today: todayString, apply: financeApply) { showReconcile = false }
                .environment(\.sectionAccent, accent)
        }
        .onChange(of: store.state.records.isEmpty) { _, isEmpty in
            // Sign-out or a reset empties the state: nothing typed into the feed may outlive it.
            if isEmpty {
                ledgerFilter = LedgerFilter(month: currentMonthString)
                tab = .overview
                period = .week
            }
        }
    }

    /// Debug screenshots: made-up money in memory and the asked-for tab (money-overview / money-plan / money-ops).
    private func applyScreenshotRoute() {
        #if DEBUG
        guard !didApplyScreenshotRoute else { return }
        didApplyScreenshotRoute = true
        if ScreenshotRoute.demoData {
            store.showScreenshotDemo(MoneyDemo.state(today: todayString), today: todayString)
        }
        switch ScreenshotRoute.screen ?? "" {
        case "money-overview": tab = .overview
        case "money-plan": tab = .plan
        case "money-ops": tab = .operations
        default: break
        }
        #endif
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
                period: $period,
                onCategory: { category in
                    ledgerFilter = LedgerFilter(
                        month: currentMonthString,
                        kind: .expense,
                        category: category == "Остальное" ? nil : category
                    )
                    tab = .operations
                },
                onOpenPlan: { tab = .plan }
            )
        case .plan:
            FinancePlanTab(store: store, today: todayString, apply: financeApply)
        case .operations:
            // Top to bottom: «Выписки из банка» with the folded «История загрузок», then the folded «История операций».
            statementsSection
                .tourTarget("money.statements")
            OperationsFeed(
                store: store, filter: $ledgerFilter,
                onEdit: { recordToEdit = $0 },
                onDelete: { recordToDelete = $0 },
                onCategory: { recordToCategorize = $0 }
            )
            ManualEntriesCard(state: store.state) { recordToEdit = $0 }
            ReconcileCard(snapshot: snapshot) { showReconcile = true }
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
                    .font(DS.Fonts.text(15, .medium))
                    .foregroundColor(accent)
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
            let next = try change(store.state)
            if let message {
                try store.replaceStateUndoable(with: next, today: todayString, message: message)
            } else {
                try store.replaceState(with: next, today: todayString)
            }
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

    // MARK: - Bottom composer (the section's «+»)

    private var composerBar: some View {
        VStack(spacing: 0) {
            if let speechError = dictation.errorMessage {
                Text(speechError)
                    .font(DS.Fonts.text(13, .medium, relativeTo: .caption))
                    .foregroundColor(DS.Colors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }
            MoneyComposerBar(
                text: Binding(get: { inputs.money }, set: { inputs.edit($0, for: .money) }),
                focus: $composerFocused,
                isListening: dictation.isListening(to: .money),
                level: dictation.level,
                isBusy: isParsing,
                onMic: {
                    if dictation.isListening(to: .money) {
                        dictation.stop()
                    } else {
                        // Speech becomes text on the phone (Apple Speech); only the text is read by the server.
                        Task { await dictation.start(into: .money) }
                    }
                },
                onAdd: {
                    // Empty field: «Добавить» opens the keyboard; with text it reads the phrase into drafts.
                    if textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        composerFocused = true
                    } else {
                        dictation.stop()
                        composerFocused = false
                        parseEnteredText()
                    }
                },
                onClear: {
                    dictation.stop()
                    inputs.clear(.money)
                }
            )
        }
        .background(DS.Colors.canvas)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        Card {
            VStack(spacing: DS.Metrics.spacing16) {
                EmptyState(
                    title: "Сколько у вас денег сейчас?",
                    message: "Напишите внизу обычным текстом: «остаток 100000», «обед 2500», «зарплата 300000». Можно голосом.",
                    icon: "creditcard"
                )

                MoneyPrimaryButton("Добавить первую запись") {
                    composerFocused = true
                }
                .accessibilityIdentifier("money-first-record")
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Parsing

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
                        .font(DS.Fonts.text(13, .medium, relativeTo: .caption))
                        .foregroundColor(DS.Colors.textSecondary)
                }

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
                .tint(accent)

                if isDraftStale {
                    Text("Текст изменён после разбора.")
                        .font(DS.Fonts.text(13, .medium, relativeTo: .caption))
                        .foregroundColor(DS.Colors.warning)
                    MoneyOutlineButton("Разобрать заново", icon: "arrow.clockwise", isLoading: isParsing) {
                        dictation.stop()
                        parseEnteredText()
                    }
                }

                if let f = firstQuestion {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Уточни запись \(f.index + 1): \(f.question.label)")
                            .font(DS.Fonts.text(15, .semibold))
                            .foregroundColor(DS.Colors.warning)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Colors.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                ForEach(drafts.indices, id: \.self) { index in
                    draftCard(index: index)
                }

                MoneyPrimaryButton(
                    "Подтвердить и добавить (\(drafts.count))",
                    isEnabled: !drafts.isEmpty && missingQuestions.isEmpty && !isDraftStale
                ) {
                    confirmDrafts()
                }

                Text(client == nil
                     ? "Текст разбирается на устройстве."
                     : "Фразу читает Gemini (Google) через сервер ARNA. Сервер её не хранит, Google может хранить по своим правилам. Остатки и история остаются на телефоне.")
                    .font(DS.Fonts.text(12, .medium, relativeTo: .caption2))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    private func draftCard(index: Int) -> some View {
        let d = drafts[index]
        return VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
            HStack {
                Text("Запись \(index + 1)")
                    .font(DS.Fonts.text(13, .semibold, relativeTo: .caption))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Убрать") {
                    drafts.remove(at: index)
                    draftEdited = true
                }
                .font(DS.Fonts.text(13, .semibold, relativeTo: .caption))
                .foregroundColor(DS.Colors.destructive)
                .frame(minHeight: DS.Metrics.minHitTarget)
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
            .tint(accent)

            // Title field
            TextField(d.kind == "expense" ? "На что потрачено" : d.kind == "income" ? "Источник дохода" : "Название", text: Binding(
                get: { d.title ?? "" },
                set: { patchDraft(index: index, keyPath: \.title, value: $0.isEmpty ? nil : $0) }
            ))
            .moneyField()

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
            .moneyField()

            // Date field
            if d.kind == "balance" || d.kind == "income" || d.kind == "expense" {
                TextField("Дата (ГГГГ-ММ-ДД)", text: Binding(
                    get: { d.date ?? "" },
                    set: { patchDraft(index: index, keyPath: \.date, value: $0.isEmpty ? nil : $0) }
                ))
                .moneyField()
            }

            // Frequency field
            if d.kind == "obligation" || d.kind == "planned_income" {
                ArnaSegmented("Периодичность", selection: Binding(
                    get: { d.frequency ?? "" },
                    set: { patchDraft(index: index, keyPath: \.frequency, value: $0.isEmpty ? nil : $0) }
                ), options: [("monthly", "Каждый месяц"), ("weekly", "Каждую неделю")])
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
                .moneyField()

                TextField("Срок (ГГГГ-ММ-ДД) — необязательно", text: Binding(
                    get: { d.dueDate ?? "" },
                    set: { patchDraft(index: index, keyPath: \.dueDate, value: $0.isEmpty ? nil : $0) }
                ))
                .moneyField()
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
                .tint(accent)
            }
        }
        .padding(12)
        .background(DS.Colors.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            // What was just added shows in the feed and first in «Добавлено вручную» on the operations tab.
            self.tab = .operations
            inputs.clear(.money)
            self.sourceText = ""
            self.kindHint = ""
            self.sourceHint = ""
            self.draftEdited = false
            statusMessage = count == 1
                ? "Добавлено. Запись — в «Операциях» и первая в «Добавлено вручную», её можно изменить или удалить."
                : "Добавлено записей: \(count). Они в «Операциях» и первые в «Добавлено вручную», их можно изменить или удалить."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Vault Actions Section

    private var vaultActionsSection: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                SectionHeader("Сохранение и копия")

                Text(storageText + " " + backupText)
                    .font(.caption)
                    .foregroundColor(DS.Colors.textSecondary)

                VStack(spacing: DS.Metrics.spacing12) {
                    if !store.state.records.isEmpty {
                        PillButton(
                            "Сохранить копию в Файлы",
                            style: .secondary,
                            isEnabled: hasAccountKey
                        ) {
                            exportVault()
                        }
                    }

                    PillButton("Восстановить из копии", style: .secondary) {
                        importsStatement = false
                        showImportSheet = true
                    }
                }

                // An older copy protected by a password: ask for it as before.
                if let envelope = pendingImportEnvelope, pendingImportState == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Эта копия защищена паролем. Введите пароль, которым её сохранили.")
                            .font(.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)

                        SecureField("Пароль от копии", text: $vaultPasswordPrompt)
                            .moneyField()

                        HStack(spacing: DS.Metrics.spacing12) {
                            PillButton("Открыть копию", style: .secondary, isEnabled: vaultPasswordPrompt.count >= 8) {
                                openPasswordBackup(envelope)
                            }

                            PillButton("Отмена", style: .secondary) {
                                self.pendingImportEnvelope = nil
                                self.vaultPasswordPrompt = ""
                            }
                        }
                    }
                    .padding(12)
                    .background(DS.Colors.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
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

    /// The account's key is on this phone (signed in and loaded).
    private var hasAccountKey: Bool {
        vault.phase == .ready && vault.dataKey != nil
    }

    /// Where money lives now, from the store's storage state.
    private var storageText: String {
        switch store.storage {
        case .cloud: return "Данные хранятся в облаке в зашифрованном виде и на этом телефоне."
        case .migrating: return "Данные переносятся в облако в зашифрованном виде и пока хранятся на этом телефоне."
        case .local: return "Данные хранятся только на этом телефоне."
        }
    }

    private var backupText: String {
        if store.state.records.isEmpty {
            return "Если есть копия с другого устройства, её можно восстановить."
        }
        if hasAccountKey {
            return "Копия зашифрована ключом вашего аккаунта: открыть её можно, войдя в этот же аккаунт Google."
        }
        return "Сохранить копию можно после входа в аккаунт Google: она шифруется ключом аккаунта."
    }

    private func exportVault() {
        // No unencrypted fallback: without the account key there is no copy.
        guard hasAccountKey, let key = vault.dataKey else {
            errorMessage = "Сохранить копию можно после входа в аккаунт Google."
            return
        }
        do {
            let backup = try FinanceVault.sealAccountBackup(state: store.state, accountKey: key)
            let data = try JSONEncoder().encode(backup)
            self.exportedDocument = EncryptedVaultDocument(data: data)
            self.showExportSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openPasswordBackup(_ envelope: FinanceVaultEnvelope) {
        let password = vaultPasswordPrompt
        Task {
            do {
                let opened = try await FinanceVault.openFinance(envelope: envelope, password: password)
                self.pendingImportState = opened
                self.pendingImportEnvelope = nil
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
                self.pendingImportState = nil
                self.pendingImportEnvelope = nil
                self.vaultPasswordPrompt = ""
                switch try FinanceVault.backupKind(of: json) {
                case .accountKey:
                    let backup = try FinanceVault.readAccountBackup(from: json)
                    guard hasAccountKey, let key = vault.dataKey else {
                        throw FinanceVaultError.decryptionFailed(FinanceVault.accountKeyMissingMessage)
                    }
                    self.pendingImportState = try FinanceVault.openAccountBackup(backup, accountKey: key)
                case .password:
                    // An older copy: the password field appears in the section.
                    self.pendingImportEnvelope = try FinanceVault.readVaultEnvelope(from: json)
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
