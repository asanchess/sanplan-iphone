import SwiftUI

/// «Итоги», ported from docs/design/canvas-r5/Summary.html (round 6): one screen for the day and the week.
/// «Собрано само» is read from the sections (each row opens its exact place); the owner adds only a mark and a line.
/// Phone-5 functions stay on the same screen in the canvas style: move open tasks, the daily reminder, past reviews,
/// and in the week mode the 1–10 sphere ratings.
struct SummaryScreen: View {
    enum Mode: Hashable { case day, week }

    @ObservedObject var review: ReviewStore
    let day: String
    let sources: () -> ReviewSources
    /// Plans' `moveOpenToTomorrow`; nil hides the block.
    let moveOpen: (([String]) async -> Bool)?
    /// Voice input for the line of the day (InputDrafts.Target.review); nil: typing only.
    var inputs: InputDrafts? = nil
    var dictation: SpeechDictation? = nil
    /// Plans' spheres (GoalStore.spheres) for the week ratings.
    var spheres: [ReviewSphere] = []
    var initialMode: Mode = .day
    /// A row of «Собрано само» was tapped: the caller closes «Итоги» and opens the place.
    let onOpen: (DeepLink) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sectionAccent) private var accent
    @State private var mode: Mode = .day
    @State private var mood: Int?
    @State private var text = ""
    @State private var dayDigest = PeriodDigest()
    @State private var dayFacts: [SummaryFactRow] = []
    @State private var weekFacts: [SummaryFactRow] = []
    @State private var ratings: [String: Int] = [:]
    @State private var moveState: MoveState = .idle
    @State private var saved = false
    @State private var reminder = ReviewReminderSettings.standard
    @State private var reminderDenied = false
    @State private var historyOpen = false
    @State private var loaded = false
    @FocusState private var focused: Bool

    enum MoveState: Equatable { case idle, moving, moved(Int), failed }

    private var weekStart: String { ReviewCalendar.weekStart(day) }
    private var weekEnd: String { ReviewCalendar.addDays(weekStart, 6) }
    /// Screenshots never touch the owner's drafts: the demo line stays in this screen's memory.
    private var voiceInputs: InputDrafts? { ScreenshotRoute.demoData ? nil : inputs }

    var body: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    ArnaSegmented("Период", selection: $mode, options: [(value: Mode.day, label: "День"), (value: Mode.week, label: "Неделя")])
                    factsBlock(mode == .day ? dayFacts : weekFacts)
                    if mode == .day {
                        moodBlock
                        noteField
                        if moveOpen != nil && !dayDigest.plans.open.isEmpty { moveBlock }
                        reminderBlock
                    } else {
                        spheresBlock
                    }
                    if let error = review.errorMessage {
                        Text(error)
                            .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                            .foregroundColor(DS.Colors.destructive)
                    }
                    saveButton
                    if !review.reviewedDays.isEmpty {
                        Button { historyOpen = true } label: {
                            Text("Прошлые итоги")
                                .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                                .foregroundColor(accent)
                                .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DS.Metrics.screenGutter)
                .padding(.top, 18)
                .padding(.bottom, 32)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .keyboardDismissBar()
        .sensoryFeedback(.success, trigger: saved)
        .sheet(isPresented: $historyOpen) {
            ReviewHistorySheet(review: review).tint(accent)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            mode = initialMode
            load()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(DS.Colors.surface, in: Circle())
                    .overlay(Circle().strokeBorder(DS.Colors.hairline, lineWidth: 1.5))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Назад")
            VStack(alignment: .leading, spacing: 6) {
                SkewTag(mode == .day ? Self.dayTag(day) : Self.weekTag(from: weekStart, to: weekEnd), color: accent)
                Text("Итоги")
                    .font(DS.Fonts.display(28, relativeTo: .largeTitle))
                    .foregroundColor(DS.Colors.textPrimary)
                    .shadow(color: DS.Colors.ink, radius: 0, x: 3, y: 3)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Собрано само

    private func factsBlock(_ rows: [SummaryFactRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Собрано само")
            ForEach(rows) { row in
                Button { onOpen(row.link) } label: {
                    HStack(spacing: 14) {
                        Circle().fill(Self.color(row.kind)).frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .font(DS.Fonts.text(17, .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                            if !row.note.isEmpty {
                                Text(row.note)
                                    .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(row.value)
                            .font(DS.Fonts.text(18, .heavy).monospacedDigit())
                            .foregroundColor(DS.Colors.textPrimary)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([row.name, row.value, row.note].filter { !$0.isEmpty }.joined(separator: ", "))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onOpen(row.link) }
            }
        }
    }

    // MARK: Day

    private var moodBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Ваша оценка")
            HStack(spacing: 8) {
                ForEach(ReviewLimits.moodRange, id: \.self) { value in
                    let selected = mood == value
                    Button { mood = selected ? nil : value } label: {
                        Text("\(value)")
                            .font(DS.Fonts.text(20, .heavy).monospacedDigit())
                            .foregroundColor(selected ? DS.Colors.canvas : DS.Colors.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(selected ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(selected ? Color.clear : DS.Colors.hairline, lineWidth: 1.5)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel("\(value) из 5, \(ReviewMood.label(value))")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .sensoryFeedback(.selection, trigger: mood)
            Text(SummaryFacts.moodText(mood))
                .font(DS.Fonts.text(16, .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    @ViewBuilder
    private var noteField: some View {
        if let inputs = voiceInputs, let dictation {
            ReviewVoiceLine(text: $text, inputs: inputs, dictation: dictation)
        } else {
            TextField("Пара слов о дне (необязательно)", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .focused($focused)
                .font(DS.Fonts.text(17, .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.Colors.hairline, lineWidth: 1.5))
                .onChange(of: text) { _, value in
                    if value.count > ReviewLimits.maxTextLength { text = String(value.prefix(ReviewLimits.maxTextLength)) }
                }
        }
    }

    private var moveBlock: some View {
        let open = dayDigest.plans.open
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Незакрытое")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(open.prefix(5)), id: \.id) { plan in
                    Text("• \(plan.title)")
                        .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                }
                if open.count > 5 {
                    Text("…и ещё \(open.count - 5)")
                        .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            PillButton("Перенести незакрытое на завтра", icon: "arrow.right.circle", style: .secondary, isLoading: moveState == .moving) {
                guard let moveOpen else { return }
                moveState = .moving
                let ids = open.map(\.id)
                Task {
                    let ok = await moveOpen(ids)
                    moveState = ok ? .moved(ids.count) : .failed
                    loadDay(sources())
                }
            }
            switch moveState {
            case .moved(let count):
                Text("Перенесено на завтра: \(count)")
                    .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.textSecondary)
            case .failed:
                Text("Не удалось перенести. Задачи остались на сегодня.")
                    .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.destructive)
            default:
                EmptyView()
            }
        }
    }

    private var reminderBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Напоминание")
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Напоминать каждый день", isOn: Binding(get: { reminder.enabled }, set: { update(enabled: $0) }))
                    .font(DS.Fonts.text(17, .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .tint(accent)
                    .frame(minHeight: DS.Metrics.minHitTarget)
                if reminder.enabled {
                    DatePicker("Время", selection: Binding(get: { reminderDate }, set: { setTime($0) }), displayedComponents: .hourAndMinute)
                        .font(DS.Fonts.text(17, .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .tint(accent)
                        .frame(minHeight: DS.Metrics.minHitTarget)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if reminderDenied {
                Text("Уведомления выключены в настройках iPhone. Включите их для ARNA, чтобы напоминание приходило.")
                    .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.destructive)
            }
        }
    }

    // MARK: Week

    @ViewBuilder
    private var spheresBlock: some View {
        let previousWeek = review.previousWeek(before: day)
        let comparison = WeekComparison.make(
            current: WeekReview.make(containing: day, ratings: ratings, now: 0),
            previous: previousWeek)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Оценка сфер, 1–10")
            if spheres.isEmpty {
                Button { onOpen(.goals) } label: {
                    Text("Сферы задаются в разделе «Цели»")
                        .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                        .foregroundColor(accent)
                        .frame(minHeight: DS.Metrics.minHitTarget)
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    ForEach(spheres) { sphere in
                        ratingRow(sphere, delta: comparison.deltas[sphere.id])
                        if sphere.id != spheres.last?.id {
                            Rectangle().fill(DS.Colors.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(comparison.averageDelta.map { "Среднее к прошлой неделе: \(Self.signed($0))" }
                     ?? (previousWeek == nil ? "Прошлой недели для сравнения нет." : ""))
                    .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    private func ratingRow(_ sphere: ReviewSphere, delta: Int?) -> some View {
        let value = ratings[sphere.id]
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sphere.title)
                    .font(DS.Fonts.text(17, .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                if let delta, delta != 0 {
                    Text("\(delta > 0 ? "+" : "−")\(abs(delta)) к прошлой")
                        .font(DS.Fonts.text(13, .medium, relativeTo: .caption).monospacedDigit())
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            Spacer()
            stepButton("minus", label: "Уменьшить: \(sphere.title)", enabled: (value ?? 0) > ReviewLimits.ratingRange.lowerBound) {
                ratings[sphere.id] = max(ReviewLimits.ratingRange.lowerBound, (value ?? 6) - 1)
            }
            Text(value.map(String.init) ?? "—")
                .font(DS.Fonts.text(20, .heavy).monospacedDigit())
                .frame(minWidth: 32)
                .foregroundColor(DS.Colors.textPrimary)
                .accessibilityLabel(value.map { "\(sphere.title): \($0)" } ?? "\(sphere.title): нет оценки")
            stepButton("plus", label: "Увеличить: \(sphere.title)", enabled: (value ?? 0) < ReviewLimits.ratingRange.upperBound) {
                ratings[sphere.id] = min(ReviewLimits.ratingRange.upperBound, (value ?? 5) + 1)
            }
        }
        .frame(minHeight: 60)
        .sensoryFeedback(.selection, trigger: value)
    }

    private func stepButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                .overlay(Circle().strokeBorder(DS.Colors.hairline, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    // MARK: Save

    private var canSave: Bool {
        mode == .day ? ReviewEntry.make(day: day, mood: mood, text: text, now: 0) != nil : !ratings.isEmpty
    }

    private var saveButton: some View {
        Button(action: save) {
            Text(mode == .day ? "Сохранить итоги" : "Сохранить итоги недели")
                .font(DS.Fonts.text(18, .heavy))
                .foregroundColor(DS.Colors.canvas)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.45)
    }

    private func save() {
        switch mode {
        case .day:
            guard review.saveDay(day, mood: mood, text: text) else { return }
            if dictation?.isListening(to: .review) == true { dictation?.stop() }
            voiceInputs?.clear(.review)
        case .week:
            guard review.saveWeek(containing: day, ratings: ratings) else { return }
        }
        saved.toggle()
        dismiss()
    }

    // MARK: Reminder

    private var reminderDate: Date {
        var parts = DateComponents()
        parts.hour = reminder.hour
        parts.minute = reminder.minute
        return Calendar.current.date(from: parts) ?? Date()
    }

    private func setTime(_ date: Date) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        update(enabled: reminder.enabled, hour: parts.hour ?? 21, minute: parts.minute ?? 0)
    }

    private func update(enabled: Bool, hour: Int? = nil, minute: Int? = nil) {
        reminder = ReviewReminderSettings(enabled: enabled, hour: hour ?? reminder.hour, minute: minute ?? reminder.minute)
        review.setReminder(reminder)
        let settings = reminder
        Task { reminderDenied = !(await ReviewReminder.apply(settings)) }
    }

    // MARK: Load

    private func load() {
        let src = sources()
        loadDay(src)
        // The week so far against the same days of the previous week.
        let beforeStart = ReviewCalendar.addDays(weekStart, -7)
        let beforeEnd = ReviewCalendar.addDays(day, -7)
        weekFacts = SummaryFacts.week(
            current: ReviewSummaries.digest(src, from: weekStart, to: day),
            previous: ReviewSummaries.digest(src, from: beforeStart, to: beforeEnd),
            days: ReviewCalendar.days(from: weekStart, to: day),
            plans: src.plans, workouts: src.workouts, from: weekStart, to: day
        )
        ratings = review.week(containing: day)?.ratings ?? [:]
        reminder = review.reminder
        if let entry = review.day(day) {
            mood = entry.mood
            text = entry.text
        } else if ScreenshotRoute.demoData {
            // Made-up, in memory only: saved only if someone taps «Сохранить».
            mood = 4
            text = "Успел главное, вечером прогулка."
        }
        // A draft kept in InputDrafts (typed or dictated before the screen was closed) wins over the saved line.
        if let inputs = voiceInputs {
            if inputs.review.isEmpty { inputs.edit(text, for: .review) } else { text = inputs.review }
        }
    }

    private func loadDay(_ src: ReviewSources) {
        dayDigest = ReviewSummaries.digest(src, day: day)
        let habits = HabitStore.shared
        let habitsOpen = TodayHabitsSummary.make(habits: habits.habits, marks: habits.marks, day: day, context: habits.context, limit: Int.max)?
            .rows.filter { !$0.done }.map(\.title) ?? []
        dayFacts = SummaryFacts.day(
            dayDigest, day: day, workouts: src.workouts,
            dayLimit: FinanceSummaries.canSpendToday(src.finance, on: day)?.dayLimit,
            habitsOpen: habitsOpen
        )
    }

    // MARK: Format

    static func color(_ kind: SummaryFactRow.Kind) -> Color {
        switch kind {
        case .plans: return DS.Colors.plans
        case .workout: return DS.Colors.workout
        case .money: return DS.Colors.money
        case .habits: return DS.Colors.today
        case .notes: return DS.Colors.notes
        }
    }

    private static func parse(_ day: String) -> Date? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: day)
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// «Вторник, 17 ноября».
    static func dayTag(_ day: String) -> String {
        guard let date = parse(day) else { return day }
        let text = format(date, "EEEE, d MMMM")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// «16–22 ноября», or «27 октября – 2 ноября» across months.
    static func weekTag(from: String, to: String) -> String {
        guard let start = parse(from), let end = parse(to) else { return "\(from) – \(to)" }
        if format(start, "MM") == format(end, "MM") { return "\(format(start, "d"))–\(format(end, "d MMMM"))" }
        return "\(format(start, "d MMMM")) – \(format(end, "d MMMM"))"
    }

    static func signed(_ delta: Double) -> String {
        let rounded = (delta * 10).rounded() / 10
        if rounded == 0 { return "без изменений" }
        return "\(rounded > 0 ? "+" : "−")\(String(format: "%.1f", abs(rounded)))"
    }
}

/// The line of the day with a microphone: words stream into `InputDrafts.review`, nothing leaves the phone.
struct ReviewVoiceLine: View {
    @Binding var text: String
    @ObservedObject var inputs: InputDrafts
    @ObservedObject var dictation: SpeechDictation
    @Environment(\.sectionAccent) private var accent
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Пара слов о дне (необязательно)", text: Binding(
                    get: { inputs.review },
                    set: { inputs.edit(String($0.prefix(ReviewLimits.maxTextLength)), for: .review) }
                ), axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focused)
                    .font(DS.Fonts.text(17, .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Button {
                    if dictation.isListening(to: .review) { dictation.stop() }
                    else { Task { await dictation.start(into: .review) } }
                } label: {
                    Image(systemName: dictation.isListening(to: .review) ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(dictation.isListening(to: .review) ? accent : DS.Colors.textSecondary)
                        .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dictation.isListening(to: .review) ? "Остановить диктовку" : "Продиктовать строку о дне")
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.Colors.hairline, lineWidth: 1.5))
            if let error = dictation.errorMessage {
                Text(error)
                    .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.destructive)
            }
        }
        .onChange(of: inputs.review) { _, value in
            if text != value { text = value }
        }
    }
}

// MARK: - History

/// Past day reviews, newest first. Swipe to delete, with a tap to undo.
struct ReviewHistorySheet: View {
    @ObservedObject var review: ReviewStore
    @Environment(\.dismiss) private var dismiss
    @State private var removed: ReviewEntry?
    @State private var deleted = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(review.reviewedDays.reversed(), id: \.self) { day in
                    if let entry = review.day(day) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.title(day))
                                .font(DS.Fonts.text(17, .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                            if let mood = entry.mood {
                                Text("Оценка: \(mood) из 5")
                                    .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                                    .foregroundColor(DS.Colors.textSecondary)
                            }
                            if !entry.text.isEmpty {
                                Text(entry.text)
                                    .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(minHeight: DS.Metrics.minHitTarget, alignment: .leading)
                        .listRowBackground(DS.Colors.surface)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                removed = entry
                                review.deleteDay(day)
                                deleted.toggle()
                            } label: { Label("Удалить", systemImage: "trash") }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.canvas)
            .overlay {
                if review.reviewedDays.isEmpty {
                    EmptyState(title: "Итогов пока нет", message: "Они появятся здесь после первого вечера.", icon: "moon.stars")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let removed {
                    HStack {
                        Text("Итоги за \(Self.title(removed.day)) удалены")
                            .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                            .foregroundColor(DS.Colors.textPrimary)
                        Spacer()
                        Button("Вернуть") {
                            review.saveDay(removed.day, mood: removed.mood, text: removed.text)
                            self.removed = nil
                        }
                        .frame(minHeight: DS.Metrics.minHitTarget)
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .background(DS.Colors.surfaceRaised)
                }
            }
            .navigationTitle("Прошлые итоги")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: deleted)
    }

    static func title(_ day: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        parser.locale = Locale(identifier: "ru_RU")
        parser.dateFormat = "d MMMM, EEEE"
        return parser.string(from: date)
    }
}
