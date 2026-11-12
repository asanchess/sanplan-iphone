import SwiftUI

public struct PlanScreen: View {
    @ObservedObject public var store: PlanStore
    @ObservedObject public var recorder: VoiceRecorder
    @ObservedObject public var inputs: InputDrafts
    @ObservedObject public var dictation: SpeechDictation
    @ObservedObject public var workouts: WorkoutStore
    @Binding public var showSettings: Bool
    @ObservedObject private var habits = HabitStore.shared
    private let onOpenWorkout: () -> Void
    private let streakSources: [StreakEngine.ActivitySource]

    @State private var viewMode: ViewMode = .day
    @State private var isShowingAlarms: Bool = false
    @State private var isConfirmingDraftReset: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public enum ViewMode: String, CaseIterable, Identifiable {
        case day = "Сегодня"
        case week = "Неделя"
        case upcoming = "Все"
        case habits = "Привычки"
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
        streakSources: [StreakEngine.ActivitySource] = []
    ) {
        self.store = store
        self.recorder = recorder
        self.inputs = inputs
        self.dictation = dictation
        self.workouts = workouts
        self._showSettings = showSettings
        self.onOpenWorkout = onOpenWorkout
        self.streakSources = streakSources
    }

    public var body: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()

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
                    VStack(spacing: DS.Metrics.spacing16) {
                        if recorder.isRecordingOrPaused {
                            recorderSection
                        }

                        if store.isParsing {
                            parsingCard
                        }

                        if !store.draftPlans.isEmpty {
                            draftsSection
                        }

                        Picker("Вид", selection: $viewMode) {
                            ForEach(ViewMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch viewMode {
                        case .day:
                            weekStrip
                            agendaDayList
                        case .week:
                            weekView
                        case .upcoming:
                            upcomingList
                        case .habits:
                            HabitsSection(habits: habits, today: PlanDomain.today(timeZone: store.timeZone), streakSources: streakSources)
                        }
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.top, DS.Metrics.spacing16)
                    .padding(.bottom, DS.Metrics.spacing16)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await store.reload() }
                .safeAreaInset(edge: .bottom) {
                    if !recorder.isRecordingOrPaused {
                        composer
                    }
                }
            }
        }
        .task {
            await store.reload()
        }
        .onChange(of: store.selectedDate) { _, _ in
            Task { await store.ensureRangeLoaded() }
        }
        .sheet(isPresented: $isShowingAlarms) {
            AlarmsScreen(store: store)
        }
    }

    private var topBar: some View {
        ScreenHeader("Планы") {
            HeaderTextButton("Будильники", icon: "alarm") {
                isShowingAlarms = true
            }

            CircleIconButton(
                icon: "person.crop.circle",
                accessibilityLabel: "Открыть настройки"
            ) {
                showSettings = true
            }
        }
    }

    private var weekStrip: some View {
        let dates = currentWeekDays(for: store.selectedDate)
        let today = PlanDomain.today(timeZone: store.timeZone)
        return Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                HStack(spacing: DS.Metrics.spacing4) {
                    Text(weekTitle(for: store.selectedDate))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    if store.selectedDate != today {
                        Button("Сегодня") { store.selectedDate = today }
                            .font(.footnote.weight(.medium))
                            .foregroundColor(DS.Colors.accent)
                            .frame(minHeight: DS.Metrics.minHitTarget)
                    }
                    weekButton(icon: "chevron.left", label: "Предыдущая неделя", days: -7)
                    weekButton(icon: "chevron.right", label: "Следующая неделя", days: 7)
                }

                HStack(spacing: DS.Metrics.spacing4) {
                    ForEach(dates, id: \.self) { dateStr in
                        let isSelected = dateStr == store.selectedDate
                        Button(action: {
                            store.selectedDate = dateStr
                        }) {
                            VStack(spacing: 2) {
                                Text(weekdayShort(dateStr))
                                    .font(.caption2)
                                    .foregroundColor(isSelected ? DS.Colors.onAccent : DS.Colors.textSecondary)
                                Text(dayNumber(dateStr))
                                    .font(.callout.monospacedDigit().weight(.semibold))
                                    .foregroundColor(isSelected ? DS.Colors.onAccent : (dateStr == today ? DS.Colors.accent : DS.Colors.textPrimary))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(isSelected ? DS.Colors.accent : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                        }
                        .accessibilityLabel(formatLongDate(dateStr))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func weekButton(icon: String, label: String, days: Int) -> some View {
        Button {
            store.selectedDate = PlanDomain.addDays(dateStr: store.selectedDate, days: days)
        } label: {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
        }
        .accessibilityLabel(label)
    }

    private var agendaDayList: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            SectionHeader("Расписание дня")

            let items = store.dayAgenda
            if items.isEmpty {
                EmptyState(
                    title: "На этот день планов нет",
                    message: "Продиктуй план или введи его текстом.",
                    icon: "calendar"
                )
            } else {
                ForEach(items) { it in
                    agendaRow(it)
                }
            }
        }
    }

    private var upcomingList: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            SectionHeader("Предстоящие")

            let items = store.upcomingAgenda
            if items.isEmpty {
                EmptyState(
                    title: "Ближайших планов нет",
                    message: "Здесь появятся будущие встречи и невыполненные задачи.",
                    icon: "clock"
                )
            } else {
                ForEach(items) { it in
                    agendaRow(it)
                }
            }
        }
    }

    private func agendaRow(_ it: AgendaItem) -> some View {
        Card {
            HStack(alignment: .top, spacing: DS.Metrics.spacing12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.displayTime)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !it.displayDate.isEmpty && viewMode == .upcoming {
                        Text(formatShortDate(it.displayDate))
                            .font(.caption2)
                            .foregroundColor(DS.Colors.textSecondary)
                    }

                    Text(it.badge)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DS.Colors.surfaceRaised)
                        .clipShape(Capsule())
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(width: 92, alignment: .leading)

                VStack(alignment: .leading, spacing: DS.Metrics.spacing4) {
                    Text(it.item.title)
                        .font(.body.weight(.medium))
                        .foregroundColor(it.item.completed == true ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                        .strikethrough(it.item.completed == true)

                    if let desc = it.item.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(2)
                    }

                    if it.item.googleEventId == nil && it.badge == "ARNA" && it.item.date != nil && it.item.time != nil {
                        Button(action: {
                            Task {
                                await store.exportPlanToGoogle(it.item)
                            }
                        }) {
                            Text(store.googlePendingId == it.item.id ? "Отправка в Google…" : "В Google Календарь")
                                .font(.caption.weight(.medium))
                                .foregroundColor(DS.Colors.accent)
                                .frame(minHeight: DS.Metrics.minHitTarget, alignment: .leading)
                        }
                        .disabled(store.googlePendingId == it.item.id)
                    }
                }

                Spacer(minLength: 0)

                if it.item.kind == "task" && it.badge != "Черновик" {
                    let completed = it.item.completed == true
                    Button(action: {
                        Task {
                            await store.toggleTaskCompletion(id: it.item.id, completed: !completed)
                        }
                    }) {
                        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundColor(completed ? DS.Colors.positive : DS.Colors.textSecondary)
                    }
                    .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                    .disabled(store.pendingTaskIds.contains(it.item.id))
                    .accessibilityLabel(completed ? "Вернуть задачу: \(it.item.title)" : "Выполнить задачу: \(it.item.title)")
                }
            }
        }
    }

    private var parsingCard: some View {
        Card {
            HStack(spacing: DS.Metrics.spacing12) {
                ProgressView()
                    .tint(DS.Colors.accent)
                Text("Разбираю план…")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 0)
            }
        }
    }

    private var recorderSection: some View {
        Card {
            VStack(spacing: DS.Metrics.spacing12) {
                HStack {
                    Text(recorder.state == .paused ? "Запись на паузе" : "Идёт запись…")
                        .font(.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    Text(formatElapsed(recorder.elapsedTime))
                        .font(.headline.monospacedDigit())
                        .foregroundColor(DS.Colors.accent)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(DS.Colors.surfaceRaised)
                            .frame(height: 8)

                        let width = max(8, geo.size.width * CGFloat(reduceMotion ? 0.5 : recorder.normalizedLevel))
                        Capsule()
                            .fill(DS.Colors.accentGradient)
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
        }
    }

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
                SectionHeader("Черновики (\(store.draftPlans.count))")
                Spacer()
                Button("Сбросить все") {
                    isConfirmingDraftReset = true
                }
                .font(.footnote)
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
                Card {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                        Text("Есть пересечение по времени")
                            .font(.headline)
                            .foregroundColor(DS.Colors.warning)
                        Text("Измени время или сохрани, оставив пересечение.")
                            .font(.footnote)
                            .foregroundColor(DS.Colors.textSecondary)

                        PillButton("Сохранить с пересечением", style: .secondary) {
                            Task {
                                await store.saveDrafts(keepConflicts: true)
                            }
                        }
                    }
                }
            }

            ForEach($store.draftPlans) { $draft in
                draftEditor(draft: $draft)
            }

            PillButton(
                "Сохранить планы",
                icon: "checkmark",
                style: .primary,
                isLoading: store.isLoading
            ) {
                Task {
                    await store.saveDrafts(keepConflicts: false)
                }
            }
        }
    }

    private func draftEditor(draft: Binding<PlanItem>) -> some View {
        let isConflicted = store.conflictedDraftIds.contains(draft.wrappedValue.id)
        return Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                HStack {
                    Text(draft.wrappedValue.kind == "task" ? "Задача" : "Событие")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(isConflicted ? DS.Colors.warning : DS.Colors.accent)
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
                    .font(.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(DS.Metrics.spacing8)
                    .background(DS.Colors.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))

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
                    .font(.footnote)
                    .foregroundColor(DS.Colors.textPrimary)
                }

                ReminderOffsetsPicker(offsets: Binding(
                    get: { (try? PlanDomain.getReminderOffsets(plan: draft.wrappedValue)) ?? [] },
                    set: { draft.wrappedValue = PlanDomain.withReminderOffsets(draft.wrappedValue, offsets: $0) }
                ))
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
            .font(.subheadline)
            .foregroundColor(DS.Colors.textPrimary)
            .tint(DS.Colors.controlTint)
            .environment(\.timeZone, TimeZone(identifier: plan.timeZone) ?? .current)
            .environment(\.locale, Locale(identifier: "ru_RU"))

            if plan.kind == "task" {
                Button("Без даты") {
                    draft.wrappedValue.date = nil
                    draft.wrappedValue.time = nil
                    draft.wrappedValue = PlanDomain.withReminderOffsets(draft.wrappedValue, offsets: [])
                }
                .font(.footnote)
                .foregroundColor(DS.Colors.accent)
                .frame(minHeight: DS.Metrics.minHitTarget)
            }
        }
    }

    private var composer: some View {
        ComposerField(
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
        .padding(.horizontal, DS.Metrics.screenGutter)
        .padding(.top, DS.Metrics.spacing8)
        .padding(.bottom, DS.Metrics.spacing12)
        .background(DS.Colors.canvas.opacity(0.97))
    }

    private func toggleDictation() {
        if dictation.isListening(to: .plans) {
            dictation.stop()
            return
        }
        Task {
            if await dictation.start(into: .plans) { return }
            // Without Apple Speech the recording goes to the server as before.
            if !dictation.isSupported {
                dictation.errorMessage = nil
                await recorder.start()
            }
        }
    }

    private func parseComposer() {
        dictation.stop()
        let text = inputs.take(.plans)
        guard !text.isEmpty else { return }
        Task { await store.parseText(text) }
    }

    // MARK: - Week

    private var weekView: some View {
        let days = PlanWeek.days(containing: store.selectedDate, timeZone: store.timeZone)
        let training = Dictionary(
            PlanWeek.trainingRows(program: workouts.program, days: days, timeZone: store.timeZone).map { ($0.date, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let today = PlanDomain.today(timeZone: store.timeZone)
        return VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            HStack(spacing: DS.Metrics.spacing4) {
                Text(PlanWeek.title(of: days, timeZone: store.timeZone))
                    .font(.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                if !days.contains(today) {
                    Button("Сегодня") { store.selectedDate = today }
                        .font(.footnote.weight(.medium))
                        .foregroundColor(DS.Colors.accent)
                        .frame(minHeight: DS.Metrics.minHitTarget)
                }
                weekButton(icon: "chevron.left", label: "Предыдущая неделя", days: -7)
                weekButton(icon: "chevron.right", label: "Следующая неделя", days: 7)
            }
            ForEach(days, id: \.self) { date in
                weekDayBlock(date: date, training: training[date], isToday: date == today)
            }
        }
    }

    private func weekDayBlock(date: String, training: PlanWeek.TrainingRow?, isToday: Bool) -> some View {
        let items = store.agenda(for: date)
        return Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                HStack {
                    Text(formatLongDate(date).prefix(1).uppercased() + formatLongDate(date).dropFirst())
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(isToday ? DS.Colors.accent : DS.Colors.textPrimary)
                    Spacer()
                    if items.isEmpty && training == nil {
                        Text("Свободно")
                            .font(.caption)
                            .foregroundColor(DS.Colors.textSecondary)
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
                        .font(.footnote)
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, DS.Metrics.spacing8)
                        .frame(minHeight: 36)
                        .background(DS.Colors.accent.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
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
                            Text(it.displayTime)
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                                .frame(width: 76, alignment: .leading)
                            Text(it.item.title)
                                .font(.subheadline)
                                .foregroundColor(it.item.completed == true ? DS.Colors.textSecondary : DS.Colors.textPrimary)
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
        }
    }

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
