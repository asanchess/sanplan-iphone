import SwiftUI

/// The «Планы» tab (canvas `docs/design/canvas-r5/Plans.html`): plans, habits and goals behind one switcher,
/// alarms behind the clock in the header, and one bottom field «Что запланировать?» for all three.
public struct PlanScreen: View {
    /// Read so the «сегодня» mark in the week strip moves at midnight even when another day is open.
    @Environment(\.dayKey) private var dayKey
    @ObservedObject public var store: PlanStore
    @ObservedObject public var recorder: VoiceRecorder
    @ObservedObject public var inputs: InputDrafts
    @ObservedObject public var dictation: SpeechDictation
    @ObservedObject public var workouts: WorkoutStore
    @Binding public var showSettings: Bool
    @ObservedObject private var habits = HabitStore.shared
    @ObservedObject private var goals = GoalStore.shared
    private let savingsOptions: [GoalSavingsOption]
    private let weekRatings: [WeekReview]
    private let onOpenWorkout: () -> Void
    private let streakSources: [StreakEngine.ActivitySource]
    /// Bumped by «Сегодня» to open the goals view.
    private let goalsRequest: Int
    /// Bumped by «Сегодня» to open the habits view.
    private let habitsRequest: Int

    @State private var viewMode: ViewMode = .day
    @State private var section: PlansSection = PlansSection.stored()
    @State private var isShowingAlarms: Bool = false
    @State private var isEditingSaved: Bool = false
    @State private var isConfirmingDraftReset: Bool = false
    /// What the bottom field understood in «Привычки» / «Цели»; nothing is saved until «Сохранить».
    @State private var habitPreview: Habit? = nil
    @State private var goalPreview: PlansQuickParse.GoalReading? = nil
    /// The words behind the preview, put back into the field on cancel.
    @State private var previewSource: String = ""
    @State private var parseNotice: String? = nil
    @State private var habitDraftRequest: Habit? = nil
    @State private var goalDraftRequest: Goal? = nil
    /// Device preference: also send saved plans with a date and time to Google Calendar.
    @AppStorage("arna.plans.toGoogle.v1") private var sendToGoogle: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let accent = DS.Colors.plans

    public enum ViewMode: String, CaseIterable, Identifiable {
        case day = "Сегодня"
        case week = "Неделя"
        case upcoming = "Все"
        case done = "Готово"
        public var id: String { rawValue }
    }

    public init(
        store: PlanStore,
        recorder: VoiceRecorder,
        inputs: InputDrafts,
        dictation: SpeechDictation,
        workouts: WorkoutStore,
        showSettings: Binding<Bool>,
        onOpenWorkout: @escaping () -> Void = {},
        streakSources: [StreakEngine.ActivitySource] = [],
        savingsOptions: [GoalSavingsOption] = [],
        weekRatings: [WeekReview] = [],
        goalsRequest: Int = 0,
        habitsRequest: Int = 0
    ) {
        self.store = store
        self.recorder = recorder
        self.inputs = inputs
        self.dictation = dictation
        self.workouts = workouts
        self._showSettings = showSettings
        self.onOpenWorkout = onOpenWorkout
        self.streakSources = streakSources
        self.savingsOptions = savingsOptions
        self.weekRatings = weekRatings
        self.goalsRequest = goalsRequest
        self.habitsRequest = habitsRequest
    }

    private var isDemo: Bool { ScreenshotRoute.demoData }
    private var today: String { PlanDomain.today(timeZone: store.timeZone) }

    public var body: some View {
        planBody
            .environment(\.sectionAccent, DS.Colors.plans)
            .tint(DS.Colors.plans)
            .onChange(of: goalsRequest) { _, _ in section = .goals }
            .onChange(of: habitsRequest) { _, _ in section = .habits }
            .onChange(of: section) { _, next in
                next.store()
                parseNotice = nil
            }
            .onReceive(DeepLinks.shared.$pending) { link in
                if let link { open(link) }
            }
    }

    private var planBody: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()
            PlansBackdrop()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.top, DS.Metrics.spacing8)

                if let err = store.errorMessage {
                    ErrorBanner(message: err) {
                        store.errorMessage = nil
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.top, DS.Metrics.spacing8)
                }

                if let recErr = recorder.errorMessage {
                    ErrorBanner(message: recErr)
                        .padding(.horizontal, DS.Metrics.screenGutter)
                        .padding(.top, DS.Metrics.spacing8)
                }

                if let speechErr = dictation.errorMessage {
                    ErrorBanner(message: speechErr) {
                        dictation.errorMessage = nil
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.top, DS.Metrics.spacing8)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                        ArnaSegmented("Раздел планов", selection: $section, options: PlansSection.allCases.map { ($0, $0.rawValue) })
                            .tourTarget("plans.sections")

                        if recorder.isRecordingOrPaused {
                            recorderSection
                        }

                        if let parseNotice {
                            noticeLine(parseNotice)
                        }

                        switch section {
                        case .plans:
                            plansTab
                        case .habits:
                            habitsTab
                        case .goals:
                            goalsTab
                        }
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.top, DS.Metrics.spacing16)
                    .padding(.bottom, DS.Metrics.spacing16)
                }
                .tourScrollHost()
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    if !isDemo { await store.reload() }
                }
                .safeAreaInset(edge: .bottom) {
                    if !recorder.isRecordingOrPaused {
                        composer
                    }
                }
            }
        }
        .task { await start() }
        .onChange(of: store.selectedDate) { _, _ in
            if !isDemo { Task { await store.ensureRangeLoaded() } }
        }
        .onChange(of: store.plans.isEmpty) { _, empty in
            // A reload elsewhere must not wipe the screenshot data.
            if empty && isDemo { seedDemo() }
        }
        .sheet(isPresented: $isEditingSaved) {
            NavigationStack {
                ScrollView {
                    if store.draftPlans.isEmpty {
                        EmptyState(title: "Сохранено", message: "Изменения записаны.", icon: "checkmark.circle")
                    } else {
                        draftsSection
                            .padding(.vertical, DS.Metrics.spacing16)
                    }
                }
                .padding(.horizontal, DS.Metrics.screenGutter)
                .background(DS.Colors.canvas.ignoresSafeArea())
                .navigationTitle("Изменить план")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть") { isEditingSaved = false }
                    }
                }
            }
            .environment(\.sectionAccent, DS.Colors.plans)
            .tint(DS.Colors.plans)
            .onChange(of: store.draftPlans.isEmpty) { _, empty in
                if empty { isEditingSaved = false }
            }
        }
        .sheet(isPresented: $isShowingAlarms) {
            AlarmsScreen(store: store)
        }
    }

    // MARK: - Start, deep links, screenshots

    private func start() async {
        switch ScreenshotRoute.screen ?? "" {
        case "plans-plans":
            section = .plans
            viewMode = .day
        case "plans-habits":
            section = .habits
        case "plans-goals":
            section = .goals
        case "plans-alarms":
            isShowingAlarms = true
        default:
            break
        }
        if isDemo {
            seedDemo()
        } else {
            await store.reload()
        }
    }

    /// Screenshot plans go straight into memory: `plans` is not written to disk and no alarm sync runs for it.
    private func seedDemo() {
        guard isDemo, store.plans.isEmpty else { return }
        store.plans = PlansDemo.plans(today: today, timeZone: store.timeZone)
        store.selectedDate = today
    }

    private func open(_ link: DeepLink) {
        switch link {
        case .plansAll:
            section = .plans
            viewMode = .upcoming
        case .habits:
            section = .habits
        case .goals:
            section = .goals
        case .alarms:
            isEditingSaved = false
            isShowingAlarms = true
        default:
            return
        }
        DeepLinks.shared.consume()
    }

    // MARK: - Header

    /// «5 ДЕЛ · 4 ПРИВЫЧКИ · 2 ЦЕЛИ» from the canvas: tasks for today, active habits and goals.
    private var plansKicker: String {
        let tasks = store.daySummary(for: today).total
        let habitCount = isDemo ? PlansDemo.habits.count : habits.activeHabits.count
        let goalCount = isDemo ? PlansDemo.goals.count : goals.activeGoals.count
        // Zero counts say nothing and push the tag past the header buttons, so only non-zero parts are shown.
        let parts: [String] = [
            (tasks, ReviewFormat.plural(tasks, "дело", "дела", "дел")),
            (habitCount, ReviewFormat.plural(habitCount, "привычка", "привычки", "привычек")),
            (goalCount, ReviewFormat.plural(goalCount, "цель", "цели", "целей"))
        ].filter { $0.0 > 0 }.map { $0.1 }
        return parts.isEmpty ? ReviewFormat.plural(0, "дело", "дела", "дел") : parts.joined(separator: " · ")
    }

    private var topBar: some View {
        ScreenHeader("Планы", kicker: plansKicker) {
            CircleIconButton(icon: "alarm", accessibilityLabel: "Будильники") {
                isShowingAlarms = true
            }
            .tourTarget("plans.alarms")
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var plansTab: some View {
        if store.isParsing {
            parsingCard
        }
        if !store.draftPlans.isEmpty {
            draftsSection
        }

        PlansFilterChips(selection: $viewMode, options: ViewMode.allCases.map { ($0, $0.rawValue) })
            .tourTarget("plans.modes")

        switch viewMode {
        case .day:
            let days = currentWeekDays(for: store.selectedDate)
            VStack(alignment: .leading, spacing: 10) {
                weekHeader(title: weekTitle(for: store.selectedDate), showToday: store.selectedDate != today)
                PlansDayStrip(
                    days: days,
                    selected: store.selectedDate,
                    today: today,
                    weekday: { weekdayShort($0) },
                    number: { dayNumber($0) },
                    spoken: { formatLongDate($0) },
                    onPick: { store.selectedDate = $0 }
                )
                .tourTarget("plans.days")
            }
            agendaTimeline(
                store.dayAgenda,
                showDate: false,
                emptyTitle: "На этот день планов нет",
                emptyMessage: "Напишите или продиктуйте внизу.",
                icon: "calendar"
            )
        case .week:
            weekView
        case .upcoming:
            agendaTimeline(
                store.upcomingAgenda,
                showDate: true,
                emptyTitle: "Ближайших планов нет",
                emptyMessage: "Здесь появятся будущие встречи и невыполненные задачи.",
                icon: "clock"
            )
        case .done:
            agendaTimeline(
                Array(store.completedAgenda.prefix(200)),
                showDate: true,
                emptyTitle: "Пока пусто",
                emptyMessage: "Здесь появятся выполненные задачи и прошедшие события.",
                icon: "checkmark.circle"
            )
        }

        alarmsLink
    }

    @ViewBuilder
    private var habitsTab: some View {
        if let habit = habitPreview {
            habitPreviewCard(habit)
        }
        draftsLink
        HabitsSection(
            habits: habits,
            today: today,
            streakSources: streakSources,
            demo: isDemo ? PlansDemo.habits : nil,
            draftRequest: $habitDraftRequest
        )
    }

    @ViewBuilder
    private var goalsTab: some View {
        if let reading = goalPreview {
            goalPreviewCard(reading)
        }
        draftsLink
        GoalsSection(
            goals: goals,
            habits: habits,
            today: today,
            savings: savingsOptions,
            weekRatings: weekRatings,
            demo: isDemo ? PlansDemo.goals : nil,
            draftRequest: $goalDraftRequest
        )
    }

    /// Plan drafts are edited in «Планы»; the other tabs only point there.
    @ViewBuilder
    private var draftsLink: some View {
        if !store.draftPlans.isEmpty || store.isParsing {
            Button {
                section = .plans
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                    Text(store.isParsing ? "Разбираю план…" : "Черновики планов: \(store.draftPlans.count)")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                .foregroundColor(accent)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    private var alarmsLink: some View {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let count = AlarmRows.build(plans: store.plans, nowMs: nowMs, showAll: false).filter { $0.nextSignal != nil }.count
        let title = count == 0 ? "Будильники" : "Будильники · \(ReviewFormat.plural(count, "включён", "включены", "включено"))"
        return PlansOutlineLink(title: title, icon: "alarm") {
            isShowingAlarms = true
        }
    }

    private func noticeLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.circle")
                .foregroundColor(DS.Colors.warning)
            Text(text)
                .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                parseNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Скрыть")
        }
        .padding(14)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Timeline

    private func weekHeader(title: String, showToday: Bool) -> some View {
        HStack(spacing: DS.Metrics.spacing4) {
            Text(title)
                .font(DS.Fonts.text(16, .bold, relativeTo: .headline))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer(minLength: 0)
            if showToday {
                Button("Сегодня") { store.selectedDate = today }
                    .font(DS.Fonts.text(14, .bold, relativeTo: .footnote))
                    .foregroundColor(accent)
                    .frame(minHeight: DS.Metrics.minHitTarget)
            }
            weekButton(icon: "chevron.left", label: "Предыдущая неделя", days: -7)
            weekButton(icon: "chevron.right", label: "Следующая неделя", days: 7)
        }
    }

    private func weekButton(icon: String, label: String, days: Int) -> some View {
        Button {
            store.selectedDate = PlanDomain.addDays(dateStr: store.selectedDate, days: days)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
        }
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func agendaTimeline(_ items: [AgendaItem], showDate: Bool, emptyTitle: String, emptyMessage: String, icon: String) -> some View {
        if items.isEmpty {
            EmptyState(title: emptyTitle, message: emptyMessage, icon: icon)
        } else {
            PlansTimeline {
                ForEach(items) { it in
                    timelineRow(it, showDate: showDate)
                }
            }
        }
    }

    /// Saved ARNA plans open for editing on tap; Google calendar events and drafts don't.
    private func isEditable(_ it: AgendaItem) -> Bool {
        it.item.savedAt != nil && it.item.source != "google" && !isDemo
    }

    private func canSendToGoogle(_ it: AgendaItem) -> Bool {
        it.item.googleEventId == nil && it.badge == "ARNA" && it.item.date != nil && it.item.time != nil && !isDemo
    }

    private func isCheckable(_ it: AgendaItem) -> Bool {
        it.item.kind == "task" && it.badge != "Черновик"
    }

    private func openEditor(_ it: AgendaItem) {
        guard isEditable(it) else { return }
        store.beginEdit(it.item)
        isEditingSaved = true
    }

    private func timelineRow(_ it: AgendaItem, showDate: Bool) -> some View {
        PlansTimelineRow(
            time: timeLabel(it),
            title: it.item.title,
            note: note(for: it, showDate: showDate),
            done: it.item.completed == true,
            canCheck: isCheckable(it),
            isPending: store.pendingTaskIds.contains(it.item.id),
            onToggle: { toggle(it.item) },
            onOpen: isEditable(it) ? { openEditor(it) } : nil
        )
        .contextMenu {
            if isEditable(it) {
                Button("Изменить", systemImage: "pencil") { openEditor(it) }
            }
            if canSendToGoogle(it) {
                Button("В Google Календарь", systemImage: "calendar.badge.plus") {
                    Task { await store.exportPlanToGoogle(it.item) }
                }
            }
            if isCheckable(it) {
                Button(it.item.completed == true ? "Вернуть" : "Выполнено",
                       systemImage: it.item.completed == true ? "arrow.uturn.backward" : "checkmark") {
                    toggle(it.item)
                }
            }
        }
        .accessibilityAction(named: "В Google Календарь") {
            if canSendToGoogle(it) { Task { await store.exportPlanToGoogle(it.item) } }
        }
    }

    /// «09:00» for the time column; plans without a clock time get a dash and say why in the note.
    private func timeLabel(_ it: AgendaItem) -> String {
        let head = String(it.displayTime.prefix(5))
        let isClock = head.count == 5 && head.dropFirst(2).first == ":" && head.filter(\.isNumber).count == 4
        if isClock { return head }
        return it.displayTime == "Весь день" ? "день" : "—"
    }

    private func note(for it: AgendaItem, showDate: Bool) -> String? {
        var parts: [String] = []
        if showDate && !it.displayDate.isEmpty { parts.append(formatShortDate(it.displayDate)) }
        if it.displayTime.count > 5 && it.displayTime != "Весь день" { parts.append(it.displayTime) }
        if store.googlePendingId == it.item.id {
            parts.append("Отправка в Google…")
        } else if it.badge != "ARNA" {
            parts.append(it.badge)
        }
        if let desc = it.item.description, !desc.isEmpty { parts.append(desc) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func toggle(_ item: PlanItem) {
        let id = item.id
        let title = item.title
        let completed = item.completed == true
        if isDemo {
            // Screenshot data stays in memory.
            if let index = store.plans.firstIndex(where: { $0.id == id }) { store.plans[index].completed = !completed }
            return
        }
        Task {
            await store.toggleTaskCompletion(id: id, completed: !completed)
            UndoCenter.shared.show(completed ? "Снова открыто: \(title)" : "Сделано: \(title)") {
                Task { await store.toggleTaskCompletion(id: id, completed: completed) }
            }
        }
    }

    // MARK: - Parsing and recording

    private var parsingCard: some View {
        HStack(spacing: DS.Metrics.spacing12) {
            ProgressView()
                .tint(accent)
            Text("Разбираю план…")
                .font(DS.Fonts.text(16, .semibold, relativeTo: .body))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var recorderSection: some View {
        VStack(spacing: DS.Metrics.spacing12) {
            HStack {
                Text(recorder.state == .paused ? "Запись на паузе" : "Идёт запись…")
                    .font(DS.Fonts.text(17, .bold, relativeTo: .headline))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text(formatElapsed(recorder.elapsedTime))
                    .font(DS.Fonts.text(17, .heavy, relativeTo: .headline))
                    .monospacedDigit()
                    .foregroundColor(accent)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DS.Colors.surfaceRaised)
                        .frame(height: 8)

                    let width = max(8, geo.size.width * CGFloat(reduceMotion ? 0.5 : recorder.normalizedLevel))
                    Capsule()
                        .fill(accent)
                        .frame(width: width, height: 8)
                        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: recorder.normalizedLevel)
                }
            }
            .frame(height: 8)

            HStack(spacing: DS.Metrics.spacing12) {
                PillButton(
                    recorder.state == .paused ? "Продолжить" : "Пауза",
                    icon: recorder.state == .paused ? "play.fill" : "pause.fill",
                    style: .secondary
                ) {
                    if recorder.state == .paused {
                        recorder.resume()
                    } else {
                        recorder.pause()
                    }
                }

                PillButton("Разобрать", icon: "sparkles", style: .primary) {
                    guard let result = recorder.finish() else { return }
                    Task {
                        await store.transcribe(audio: result.data, mimeType: result.mimeType)
                    }
                }

                CircleIconButton(icon: "xmark", accessibilityLabel: "Отменить запись") {
                    recorder.cancel()
                }
            }
        }
        .padding(16)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .inked(cornerRadius: 20, shadow: 4)
    }

    // MARK: - «Понял так»: plan drafts

    /// Overlaps the local list can see, plus the ones only the server could (Google events).
    private var draftsHaveConflict: Bool {
        if !store.conflictedDraftIds.isEmpty { return true }
        let draftIds = Set(store.draftPlans.map(\.id))
        return PlanDomain.getConflicts(plans: store.draftPlans + store.plans)
            .contains { $0.ids.contains(where: draftIds.contains) }
    }

    private var draftsSection: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            HStack {
                SkewTag("Понял так · \(store.draftPlans.count)", color: accent)
                Spacer()
                Button("Сбросить все") {
                    isConfirmingDraftReset = true
                }
                .font(DS.Fonts.text(14, .semibold, relativeTo: .footnote))
                .foregroundColor(DS.Colors.destructive)
                .frame(minHeight: DS.Metrics.minHitTarget)
                .confirmationDialog(
                    "Удалить все черновики (\(store.draftPlans.count))?",
                    isPresented: $isConfirmingDraftReset,
                    titleVisibility: .visible
                ) {
                    Button("Удалить черновики", role: .destructive) { store.clearAllDrafts() }
                    Button("Отмена", role: .cancel) {}
                } message: {
                    Text("Несохранённые планы будут потеряны.")
                }
            }

            if draftsHaveConflict {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                    Text("Есть пересечение по времени")
                        .font(DS.Fonts.text(17, .bold, relativeTo: .headline))
                        .foregroundColor(DS.Colors.warning)
                    Text("Измени время или сохрани, оставив пересечение.")
                        .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                        .foregroundColor(DS.Colors.textSecondary)

                    PillButton("Сохранить с пересечением", style: .secondary) {
                        saveDrafts(keepConflicts: true)
                    }
                }
                .padding(16)
                .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.Colors.warning.opacity(0.6), lineWidth: 1.5))
            }

            ForEach($store.draftPlans) { $draft in
                draftEditor(draft: $draft)
            }

            googleToggle

            PillButton(
                "Сохранить планы",
                icon: "checkmark",
                style: .primary,
                isLoading: store.isLoading
            ) {
                saveDrafts(keepConflicts: false)
            }
        }
    }

    private var googleToggle: some View {
        Toggle(isOn: $sendToGoogle) {
            VStack(alignment: .leading, spacing: 2) {
                Text("В Google Календарь")
                    .font(DS.Fonts.text(16, .bold, relativeTo: .body))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Планы с датой и временем")
                    .font(DS.Fonts.text(13, .medium, relativeTo: .caption))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .tint(accent)
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Saves the drafts, then sends the newly saved ones with a date and time to Google when the toggle is on.
    private func saveDrafts(keepConflicts: Bool) {
        let candidates = store.draftPlans
            .filter { $0.date != nil && $0.time != nil && $0.googleEventId == nil }
            .map(\.id)
        let toGoogle = sendToGoogle && !isDemo
        Task {
            let saved = await store.saveDrafts(keepConflicts: keepConflicts)
            guard saved, toGoogle else { return }
            let stillDrafts = Set(store.draftPlans.map(\.id))
            for id in candidates where !stillDrafts.contains(id) {
                if let plan = store.plans.first(where: { $0.id == id }), plan.googleEventId == nil {
                    await store.exportPlanToGoogle(plan)
                }
            }
        }
    }

    private func draftEditor(draft: Binding<PlanItem>) -> some View {
        let isConflicted = store.conflictedDraftIds.contains(draft.wrappedValue.id)
        return VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            HStack {
                Text((draft.wrappedValue.kind == "task" ? "Задача" : "Событие").uppercased())
                    .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                    .tracking(0.8)
                    .foregroundColor(isConflicted ? DS.Colors.warning : accent)
                Spacer()
                Button(action: {
                    store.removeDraft(id: draft.wrappedValue.id)
                }) {
                    Image(systemName: "trash")
                        .font(.footnote)
                        .foregroundColor(DS.Colors.destructive)
                        .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                }
                .accessibilityLabel("Удалить черновик: \(draft.wrappedValue.title)")
            }

            TextField("Название", text: draft.title)
                .font(DS.Fonts.text(17, .bold, relativeTo: .headline))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Picker("Тип", selection: draft.kind) {
                Text("Событие").tag("event")
                Text("Задача").tag("task")
            }
            .pickerStyle(.segmented)

            scheduleFields(draft: draft)

            if draft.wrappedValue.kind == "event" {
                Stepper(
                    "Длительность: \(draft.wrappedValue.durationMinutes ?? 60) мин",
                    value: Binding(
                        get: { draft.wrappedValue.durationMinutes ?? 60 },
                        set: { draft.wrappedValue.durationMinutes = $0 }
                    ),
                    in: 5...1440,
                    step: 5
                )
                .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                .foregroundColor(DS.Colors.textPrimary)
            }

            ReminderOffsetsPicker(offsets: Binding(
                get: { (try? PlanDomain.getReminderOffsets(plan: draft.wrappedValue)) ?? [] },
                set: { draft.wrappedValue = PlanDomain.withReminderOffsets(draft.wrappedValue, offsets: $0) }
            ))
        }
        .padding(16)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if isConflicted {
                RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(DS.Colors.warning.opacity(0.6), lineWidth: 1.5)
            }
        }
    }

    @ViewBuilder
    private func scheduleFields(draft: Binding<PlanItem>) -> some View {
        let plan = draft.wrappedValue
        if plan.date == nil || plan.date?.isEmpty == true {
            PillButton("Указать дату и время", icon: "calendar", style: .secondary) {
                let parts = PlanDateTime.parts(
                    PlanDateTime.date(date: store.selectedDate, time: plan.time, timeZone: plan.timeZone),
                    timeZone: plan.timeZone
                )
                draft.wrappedValue.date = parts.date
                draft.wrappedValue.time = parts.time
            }
        } else {
            DatePicker(
                "Когда",
                selection: Binding(
                    get: { PlanDateTime.date(date: draft.wrappedValue.date, time: draft.wrappedValue.time, timeZone: draft.wrappedValue.timeZone) },
                    set: { value in
                        let parts = PlanDateTime.parts(value, timeZone: draft.wrappedValue.timeZone)
                        draft.wrappedValue.date = parts.date
                        draft.wrappedValue.time = parts.time
                    }
                )
            )
            .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
            .foregroundColor(DS.Colors.textPrimary)
            .tint(accent)
            .environment(\.timeZone, TimeZone(identifier: plan.timeZone) ?? .current)
            .environment(\.locale, Locale(identifier: "ru_RU"))

            if plan.kind == "task" {
                Button("Без даты") {
                    draft.wrappedValue.date = nil
                    draft.wrappedValue.time = nil
                    draft.wrappedValue = PlanDomain.withReminderOffsets(draft.wrappedValue, offsets: [])
                }
                .font(DS.Fonts.text(14, .semibold, relativeTo: .footnote))
                .foregroundColor(accent)
                .frame(minHeight: DS.Metrics.minHitTarget)
            }
        }
    }

    // MARK: - «Понял так»: habit and goal

    private func habitPreviewCard(_ habit: Habit) -> some View {
        let unit = habit.target.unit
        let norm = habit.target.amount > 1
            ? (unit.isEmpty ? HabitText.times(habit.target.amount) : "\(habit.target.amount) \(unit)")
            : "Один раз"
        return PlansUnderstoodCard(title: "Понял так: привычка", onCancel: cancelPreview) {
            PlansFactLine(label: "Название", value: habit.title)
            PlansFactLine(label: "Когда", value: HabitText.schedule(habit.schedule))
            PlansFactLine(label: "Норма за день", value: norm)
            previewButtons(canSave: habits.owner != .none && !isDemo) {
                habits.add(habit)
                clearPreview()
            } onAdjust: {
                habitDraftRequest = habit
                clearPreview()
            }
        }
    }

    private func goalPreviewCard(_ reading: PlansQuickParse.GoalReading) -> some View {
        PlansUnderstoodCard(title: "Понял так: цель", onCancel: cancelPreview) {
            PlansFactLine(label: "Цель", value: reading.goal.title)
            PlansFactLine(label: "Как измерять", value: reading.measure)
            PlansFactLine(label: "Срок", value: reading.goal.dueDay.map { GoalText.dateLabel($0) } ?? "Без срока")
            if let sphere = goals.sphereTitle(reading.goal.sphereId) {
                PlansFactLine(label: "Сфера", value: sphere)
            }
            previewButtons(canSave: goals.owner != .none && !isDemo) {
                goals.add(reading.goal)
                clearPreview()
            } onAdjust: {
                goalDraftRequest = reading.goal
                clearPreview()
            }
        }
    }

    private func previewButtons(canSave: Bool, onSave: @escaping () -> Void, onAdjust: @escaping () -> Void) -> some View {
        HStack(spacing: DS.Metrics.spacing12) {
            PillButton("Сохранить", icon: "checkmark", style: .primary, isEnabled: canSave, action: onSave)
            PillButton("Настроить", icon: "slider.horizontal.3", style: .secondary, isEnabled: !isDemo, action: onAdjust)
        }
        .padding(.top, 4)
    }

    private func clearPreview() {
        habitPreview = nil
        goalPreview = nil
        previewSource = ""
    }

    /// «×» on the card: nothing is saved and the words go back into the field.
    private func cancelPreview() {
        if !previewSource.isEmpty && inputs.plans.isEmpty {
            inputs.edit(previewSource, for: .plans)
        }
        clearPreview()
    }

    // MARK: - Bottom field

    private var composer: some View {
        PlansComposerBar(
            placeholder: "Что запланировать?",
            text: Binding(get: { inputs.plans }, set: { inputs.edit($0, for: .plans) }),
            isListening: dictation.isListening(to: .plans),
            level: dictation.level,
            isBusy: store.isParsing,
            onMic: toggleDictation,
            onParse: parseComposer,
            onClear: {
                dictation.stop()
                inputs.clear(.plans)
            }
        )
        .background(DS.Colors.canvas.opacity(0.97))
    }

    private func toggleDictation() {
        if dictation.isListening(to: .plans) {
            dictation.stop()
            return
        }
        Task {
            if await dictation.start(into: .plans) { return }
            // Without Apple Speech the recording goes to the server as before (plans only parse it).
            if !dictation.isSupported {
                dictation.errorMessage = nil
                section = .plans
                await recorder.start()
            }
        }
    }

    /// «Разобрать»: a plan goes to the AI parse; a habit or a goal is read on the phone and shown before saving.
    private func parseComposer() {
        dictation.stop()
        parseNotice = nil
        let text = inputs.take(.plans)
        guard !text.isEmpty else { return }
        switch section {
        case .plans:
            Task { await store.parseText(text) }
        case .habits:
            if let habit = PlansQuickParse.habit(from: text, today: today) {
                goalPreview = nil
                habitPreview = habit
                previewSource = text
            } else {
                inputs.edit(text, for: .plans)
                parseNotice = "Не понял привычку. Например: «вода 8 стаканов в день»."
            }
        case .goals:
            let sphereIds = Set(goals.spheres.map(\.id))
            if let reading = PlansQuickParse.goal(from: text, today: today, sphereIds: sphereIds) {
                habitPreview = nil
                goalPreview = reading
                previewSource = text
            } else {
                inputs.edit(text, for: .plans)
                parseNotice = "Не понял цель. Например: «накопить 500 000 ₸ к июню»."
            }
        }
    }

    // MARK: - Week

    private var weekView: some View {
        let days = PlanWeek.days(containing: store.selectedDate, timeZone: store.timeZone)
        let training = Dictionary(
            PlanWeek.trainingRows(program: workouts.program, days: days, timeZone: store.timeZone).map { ($0.date, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let todayDate = today
        return VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            weekHeader(title: PlanWeek.title(of: days, timeZone: store.timeZone), showToday: !days.contains(todayDate))
            ForEach(days, id: \.self) { date in
                weekDayBlock(date: date, training: training[date], isToday: date == todayDate)
            }
        }
    }

    private func weekDayBlock(date: String, training: PlanWeek.TrainingRow?, isToday: Bool) -> some View {
        let items = store.agenda(for: date)
        let longDate = formatLongDate(date)
        return VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
            HStack {
                Text(longDate.prefix(1).uppercased() + longDate.dropFirst())
                    .font(DS.Fonts.text(16, .bold, relativeTo: .subheadline))
                    .foregroundColor(isToday ? accent : DS.Colors.textPrimary)
                Spacer()
                if items.isEmpty && training == nil {
                    Text("Свободно")
                        .font(DS.Fonts.text(13, .medium, relativeTo: .caption))
                        .foregroundColor(DS.Colors.textMuted)
                }
            }
            if let training {
                Button(action: onOpenWorkout) {
                    HStack(spacing: DS.Metrics.spacing8) {
                        Image(systemName: "figure.strengthtraining.traditional")
                        Text("\(training.title) · \(PlanWeek.exercisesLabel(training.exerciseCount))")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(DS.Fonts.text(14, .semibold, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, DS.Metrics.spacing8)
                    .frame(minHeight: 36)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Тренировка: \(training.title). Открыть раздел Тренировка")
            }
            ForEach(items) { it in
                Button {
                    store.selectedDate = date
                    viewMode = .day
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Metrics.spacing8) {
                        Text(timeLabel(it))
                            .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                            .monospacedDigit()
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 44, alignment: .leading)
                        Text(it.item.title)
                            .font(DS.Fonts.text(15, .semibold, relativeTo: .subheadline))
                            .foregroundColor(it.item.completed == true ? DS.Colors.textMuted : DS.Colors.textPrimary)
                            .strikethrough(it.item.completed == true)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(accent.opacity(0.5), lineWidth: 1.5)
            }
        }
    }

    // MARK: - Dates

    private func formatElapsed(_ t: TimeInterval) -> String {
        let secs = Int(t)
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    private func currentWeekDays(for dateStr: String) -> [String] {
        guard let tz = TimeZone(identifier: store.timeZone) else { return [dateStr] }
        let formatter = PlanDateTime.formatter("yyyy-MM-dd", timeZone: store.timeZone)
        guard let cur = formatter.date(from: dateStr) else { return [dateStr] }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        cal.firstWeekday = 2 // Monday
        guard let weekInterval = cal.dateInterval(of: .weekOfYear, for: cur) else { return [dateStr] }

        var res: [String] = []
        for i in 0..<7 {
            if let d = cal.date(byAdding: .day, value: i, to: weekInterval.start) {
                res.append(formatter.string(from: d))
            }
        }
        return res
    }

    private func reformat(_ dateStr: String, as format: String) -> String? {
        guard let cur = PlanDateTime.formatter("yyyy-MM-dd", timeZone: store.timeZone).date(from: dateStr) else { return nil }
        return PlanDateTime.formatter(format, timeZone: store.timeZone, locale: "ru_RU").string(from: cur)
    }

    private func weekTitle(for dateStr: String) -> String {
        reformat(dateStr, as: "LLLL yyyy")?.capitalized ?? dateStr
    }

    private func weekdayShort(_ dateStr: String) -> String {
        reformat(dateStr, as: "EE")?.capitalized ?? ""
    }

    private func dayNumber(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        return parts.count == 3 ? String(Int(parts[2]) ?? 0) : ""
    }

    private func formatShortDate(_ dateStr: String) -> String {
        reformat(dateStr, as: "d MMM") ?? dateStr
    }

    private func formatLongDate(_ dateStr: String) -> String {
        reformat(dateStr, as: "EEEE, d MMMM") ?? dateStr
    }
}
