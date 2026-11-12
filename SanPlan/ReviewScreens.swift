import SwiftUI

// Итоги дня и недели. Экран дня проходится меньше чем за 30 секунд:
// сводка уже посчитана, остаётся нажать настроение, написать строку и сохранить.

/// The card on «Сегодня»: one way into the day's review and one into the week's.
struct ReviewCard: View {
    @ObservedObject var review: ReviewStore
    let today: String
    let onDay: () -> Void
    let onWeek: () -> Void
    let onHistory: () -> Void

    var body: some View {
        let entry = review.day(today)
        Card {
            SectionHeader("Итоги дня")
            if let entry {
                if let mood = entry.mood {
                    Text("Настроение: \(mood) из 5 · \(ReviewMood.label(mood))")
                        .font(.body)
                        .foregroundColor(DS.Colors.textPrimary)
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(3)
                }
            } else {
                Text("Сводка дня готова: настроение, одна строка, незакрытое на завтра.")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            PillButton(entry == nil ? "Подвести итоги" : "Изменить итоги", icon: "moon.stars", style: entry == nil ? .primary : .secondary, action: onDay)
            HStack(spacing: DS.Metrics.spacing12) {
                PillButton("Итоги недели", style: .secondary, action: onWeek)
                if !review.reviewedDays.isEmpty {
                    PillButton("Прошлые", style: .secondary, action: onHistory)
                }
            }
        }
    }
}

// MARK: - Day

struct DayReviewSheet: View {
    @ObservedObject var review: ReviewStore
    let day: String
    let sources: () -> ReviewSources
    /// TEMP: Plans' `moveOpenToTomorrow`; nil hides the button.
    let moveOpen: (([String]) async -> Bool)?

    @Environment(\.dismiss) private var dismiss
    @State private var mood: Int?
    @State private var text = ""
    @State private var digest = PeriodDigest()
    @State private var moveState: MoveState = .idle
    @State private var saved = false
    @State private var reminder = ReviewReminderSettings.standard
    @State private var reminderDenied = false
    @FocusState private var focused: Bool

    enum MoveState: Equatable { case idle, moving, moved(Int), failed }

    var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                        summaryCard
                        moodCard
                        lineCard
                        if !digest.plans.open.isEmpty { moveCard }
                        reminderCard
                        PillButton("Сохранить", isEnabled: ReviewEntry.make(day: day, mood: mood, text: text, now: 0) != nil) { save() }
                    }
                    .padding(DS.Metrics.screenGutter)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Итоги дня")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .sensoryFeedback(.success, trigger: saved)
        .onAppear(perform: load)
    }

    private var summaryCard: some View {
        Card {
            SectionHeader("За день")
            summaryRow("Задачи", digest.plans.total == 0 ? "нет" : "\(digest.plans.done) из \(digest.plans.total)")
            summaryRow("Потрачено", digest.money.count == 0 ? "ничего" : ReviewFormat.tenge(digest.money.spentMinor))
            summaryRow("Тренировки", digest.training.completed == 0 ? "нет" : "\(digest.training.completed)")
            if let habits = digest.habits { summaryRow("Привычки", "\(habits.done) из \(habits.total)") }
            if digest.notes > 0 { summaryRow("Заметки", "\(digest.notes)") }
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.body).foregroundColor(DS.Colors.textSecondary)
            Spacer()
            Text(value).font(.body.monospacedDigit()).foregroundColor(DS.Colors.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private var moodCard: some View {
        Card {
            SectionHeader("Настроение")
            HStack(spacing: DS.Metrics.spacing8) {
                ForEach(ReviewLimits.moodRange, id: \.self) { value in
                    Button { mood = (mood == value) ? nil : value } label: {
                        Text("\(value)")
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundColor(mood == value ? DS.Colors.onAccent : DS.Colors.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(mood == value ? DS.Colors.accent : DS.Colors.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                            .overlay(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius).stroke(DS.Colors.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(value) из 5, \(ReviewMood.label(value))")
                    .accessibilityAddTraits(mood == value ? .isSelected : [])
                }
            }
            .sensoryFeedback(.selection, trigger: mood)
            Text(mood.map(ReviewMood.label) ?? "Можно пропустить")
                .font(.footnote)
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    private var lineCard: some View {
        Card {
            SectionHeader("Одна строка о дне")
            TextField("Что запомнилось", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .focused($focused)
                .submitLabel(.done)
                .font(.body)
                .padding(DS.Metrics.spacing12)
                .frame(minHeight: DS.Metrics.minHitTarget)
                .background(DS.Colors.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                .onChange(of: text) { _, value in
                    if value.count > ReviewLimits.maxTextLength { text = String(value.prefix(ReviewLimits.maxTextLength)) }
                }
            Text("Голосом — кнопкой с микрофоном на клавиатуре.")
                .font(.footnote)
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    @ViewBuilder
    private var moveCard: some View {
        if let moveOpen {
            Card {
                SectionHeader("Незакрытое")
                ForEach(digest.plans.open.prefix(5), id: \.id) { plan in
                    Text("• \(plan.title)").font(.subheadline).foregroundColor(DS.Colors.textPrimary).lineLimit(2)
                }
                if digest.plans.open.count > 5 {
                    Text("…и ещё \(digest.plans.open.count - 5)").font(.footnote).foregroundColor(DS.Colors.textSecondary)
                }
                PillButton("Перенести незакрытое на завтра", icon: "arrow.right.circle", style: .secondary, isLoading: moveState == .moving) {
                    moveState = .moving
                    let ids = digest.plans.open.map(\.id)
                    Task {
                        let ok = await moveOpen(ids)
                        moveState = ok ? .moved(ids.count) : .failed
                        digest = ReviewSummaries.digest(sources(), day: day)
                    }
                }
                switch moveState {
                case .moved(let count):
                    Text("Перенесено на завтра: \(count)").font(.footnote).foregroundColor(DS.Colors.textSecondary)
                case .failed:
                    Text("Не удалось перенести. Задачи остались на сегодня.").font(.footnote).foregroundColor(DS.Colors.destructive)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var reminderCard: some View {
        Card {
            SectionHeader("Напоминание")
            Toggle("Напоминать каждый день", isOn: Binding(get: { reminder.enabled }, set: { update(enabled: $0) }))
            if reminder.enabled {
                DatePicker("Время", selection: Binding(get: { reminderDate }, set: { setTime($0) }), displayedComponents: .hourAndMinute)
            }
            if reminderDenied {
                Text("Уведомления выключены в настройках iPhone. Включи их для ARNA, чтобы напоминание приходило.")
                    .font(.footnote)
                    .foregroundColor(DS.Colors.destructive)
            }
        }
    }

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
        Task { reminderDenied = !(await ReviewReminder.apply(reminder)) }
    }

    private func load() {
        digest = ReviewSummaries.digest(sources(), day: day)
        if let entry = review.day(day) { mood = entry.mood; text = entry.text }
        reminder = review.reminder
    }

    private func save() {
        guard review.saveDay(day, mood: mood, text: text) else { return }
        saved.toggle()
        dismiss()
    }
}

// MARK: - Week

struct WeekReviewSheet: View {
    @ObservedObject var review: ReviewStore
    let day: String
    let sources: () -> ReviewSources
    let spheres: [ReviewSphere]

    @Environment(\.dismiss) private var dismiss
    @State private var ratings: [String: Int] = [:]
    @State private var current = PeriodDigest()
    @State private var previous = PeriodDigest()
    @State private var saved = false

    private var weekStart: String { ReviewCalendar.weekStart(day) }

    var body: some View {
        let comparison = WeekComparison.make(
            current: WeekReview.make(containing: day, ratings: ratings, now: 0),
            previous: review.previousWeek(before: day))
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                        figuresCard
                        Card {
                            SectionHeader("Оценка сфер, 1–10")
                            ForEach(spheres) { sphere in
                                ratingRow(sphere, delta: comparison.deltas[sphere.id])
                            }
                            if let delta = comparison.averageDelta {
                                Text("Среднее к прошлой неделе: \(Self.signed(delta))")
                                    .font(.footnote)
                                    .foregroundColor(DS.Colors.textSecondary)
                            } else if review.previousWeek(before: day) == nil {
                                Text("Прошлой недели для сравнения нет.")
                                    .font(.footnote)
                                    .foregroundColor(DS.Colors.textSecondary)
                            }
                        }
                        PillButton("Сохранить", isEnabled: !ratings.isEmpty) {
                            guard review.saveWeek(containing: day, ratings: ratings) else { return }
                            saved.toggle()
                            dismiss()
                        }
                    }
                    .padding(DS.Metrics.screenGutter)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Итоги недели")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
        .presentationDetents([.large])
        .sensoryFeedback(.success, trigger: saved)
        .onAppear {
            let src = sources()
            current = ReviewSummaries.digest(src, from: weekStart, to: ReviewCalendar.addDays(weekStart, 6))
            let before = ReviewCalendar.addDays(weekStart, -7)
            previous = ReviewSummaries.digest(src, from: before, to: ReviewCalendar.addDays(before, 6))
            ratings = review.week(containing: day)?.ratings ?? [:]
        }
    }

    private var figuresCard: some View {
        Card {
            SectionHeader("Неделя с \(weekStart.suffix(5))")
            ForEach(ReviewWeekFigures.make(current: current, previous: previous), id: \.title) { figure in
                HStack {
                    Text(figure.title).font(.body).foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(figure.isMoney ? ReviewFormat.tenge(figure.current) : "\(figure.current)")
                            .font(.body.monospacedDigit())
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(Self.deltaText(figure))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func ratingRow(_ sphere: ReviewSphere, delta: Int?) -> some View {
        let value = ratings[sphere.id]
        return HStack(spacing: DS.Metrics.spacing8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sphere.title).font(.body).foregroundColor(DS.Colors.textPrimary)
                if let delta, delta != 0 {
                    Text("\(delta > 0 ? "+" : "−")\(abs(delta)) к прошлой")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            Spacer()
            stepButton("minus", label: "Уменьшить: \(sphere.title)", enabled: (value ?? 0) > ReviewLimits.ratingRange.lowerBound) {
                ratings[sphere.id] = max(ReviewLimits.ratingRange.lowerBound, (value ?? 6) - 1)
            }
            Text(value.map(String.init) ?? "—")
                .font(.title3.weight(.semibold).monospacedDigit())
                .frame(minWidth: 32)
                .foregroundColor(DS.Colors.textPrimary)
            stepButton("plus", label: "Увеличить: \(sphere.title)", enabled: (value ?? 0) < ReviewLimits.ratingRange.upperBound) {
                ratings[sphere.id] = min(ReviewLimits.ratingRange.upperBound, (value ?? 5) + 1)
            }
        }
        .sensoryFeedback(.selection, trigger: value)
    }

    private func stepButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                .background(DS.Colors.surfaceRaised)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    static func signed(_ delta: Double) -> String {
        let rounded = (delta * 10).rounded() / 10
        if rounded == 0 { return "без изменений" }
        return "\(rounded > 0 ? "+" : "−")\(String(format: "%.1f", abs(rounded)))"
    }

    static func deltaText(_ figure: WeekFigure) -> String {
        if figure.delta == 0 { return "как на прошлой" }
        let size = figure.isMoney ? ReviewFormat.tenge(abs(figure.delta)) : "\(abs(figure.delta))"
        return "\(figure.delta > 0 ? "+" : "−")\(size) к прошлой"
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
                            Text(Self.title(day)).font(.body.weight(.semibold)).foregroundColor(DS.Colors.textPrimary)
                            if let mood = entry.mood {
                                Text("Настроение: \(mood) из 5").font(.subheadline).foregroundColor(DS.Colors.textSecondary)
                            }
                            if !entry.text.isEmpty {
                                Text(entry.text).font(.subheadline).foregroundColor(DS.Colors.textSecondary).lineLimit(2)
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
                        Text("Итоги за \(Self.title(removed.day)) удалены").font(.footnote).foregroundColor(DS.Colors.textPrimary)
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
