import SwiftUI

/// Home. Blocks in order: day review · plans · habits · goals · pinned notes · money · workout.
/// Each block is 1–2 lines and opens its section; habits, goals, notes and workout are hidden while empty (`TodaySummary`).
public struct TodayScreen: View {
    @ObservedObject var plans: PlanStore
    @ObservedObject var finance: FinanceStore
    @ObservedObject var workouts: WorkoutStore
    @Binding var selectedTab: MainTab
    @Binding var showSettings: Bool
    /// Notes feed the week summary and the streak; nil until the root view passes them.
    var notes: NotesStore? = nil
    /// The account's encrypted `reviews` collection; nil while the vault is locked (reviews then stay in a local file).
    var reviewsVault: VaultCollection<ReviewDayRecord>? = nil
    /// Voice input for the review line; nil: typing only.
    var inputs: InputDrafts? = nil
    /// The app-wide streak for a day; nil hides the line.
    var appStreak: ((String) -> StreakState)? = nil
    var dictation: SpeechDictation? = nil
    /// Opens Plans → «Цели»; nil: just switches to the Plans tab.
    var onOpenGoals: (() -> Void)? = nil
    /// Opens Plans → «Привычки»; nil: just switches to the Plans tab.
    var onOpenHabits: (() -> Void)? = nil
    /// Grows when the day-review reminder is tapped (ReviewNotifications); opens the day review.
    var reviewRequest: Int = 0
    /// Owned by AppModel so Plans (spheres) sees the same week ratings.
    @ObservedObject var review: ReviewStore
    @ObservedObject private var goals = GoalStore.shared
    @ObservedObject private var habitStore = HabitStore.shared
    @State private var reviewSheet: ReviewSheet?
    @State private var isShowingAlarms = false

    private enum ReviewSheet: String, Identifiable {
        case day, week, history
        var id: String { rawValue }
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                        ScreenHeader("Сегодня", kicker: Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "ru_RU")))) {
                        }
                        if let line = StreakLine.text(appStreak?(reviewDay)) {
                            Text(line)
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.textSecondary)
                                .accessibilityLabel(line)
                        }
                        reviewCard
                        plansCard
                        habitsCard
                            .petTip("Нажмите кружок — привычка отмечена. Ошиблись — «Отменить» внизу.")
                        goalsCard
                        pinnedNotesCard
                        moneyCard
                            .petTip("Столько можно потратить сегодня, чтобы уложиться в месяц.")
                        workoutCard
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.vertical, DS.Metrics.spacing16)
                }
                .refreshable { await plans.reload() }
            }
            .shellCaptureButton()
            .toolbar(.hidden, for: .navigationBar)
        }
        .onChange(of: reviewRequest) { _, _ in reviewSheet = .day }
        .sheet(isPresented: $isShowingAlarms) {
            AlarmsScreen(store: plans)
        }
        .sheet(item: $reviewSheet) { sheet in
            switch sheet {
            case .day:
                DayReviewSheet(review: review, day: reviewDay, sources: reviewSources, moveOpen: { await moveOpenToTomorrow($0) }, inputs: inputs, dictation: dictation)
            case .week:
                WeekReviewSheet(review: review, day: reviewDay, sources: reviewSources, spheres: goals.spheres.map { ReviewSphere(id: $0.id, title: $0.title) })
            case .history:
                ReviewHistorySheet(review: review)
            }
        }
        .task {
            syncReviewOwner()
            review.setCollection(reviewsVault)
            finance.refreshSummary(today: PlanDomain.today())
            await plans.reload()
        }
        // Reviews follow the signed-in account: money switches owner on sign-in and sign-out.
        .onChange(of: finance.state) { _, _ in syncReviewOwner() }
        .onChange(of: reviewsVault?.isAvailable) { _, _ in review.setCollection(reviewsVault) }
    }

    /// Habits due today; the check button goes through `HabitStore.tap`, the same path as Plans → «Привычки».
    @ViewBuilder
    private var habitsCard: some View {
        if let block = TodayHabitsSummary.make(habits: habitStore.habits, marks: habitStore.marks, day: reviewDay, context: habitStore.context) {
            Card {
                SectionHeader("Привычки")
                ForEach(block.rows) { row in
                    HStack(spacing: DS.Metrics.spacing12) {
                        Button {
                            if let habit = habitStore.habits.first(where: { $0.id == row.id }) { habitStore.tapUndoable(habit, on: reviewDay) }
                        } label: {
                            Image(systemName: row.done ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundColor(row.done ? DS.Colors.accent : DS.Colors.textSecondary)
                                .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                        }
                        .buttonStyle(.plain)
                        .disabled(row.auto)
                        .accessibilityLabel(row.title)
                        .accessibilityValue(row.done ? "выполнено" : "не выполнено")
                        .accessibilityHint(row.auto ? "Отмечается автоматически" : "Отметить")
                        Button { openHabits() } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.body)
                                    .foregroundColor(row.done ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                                    .strikethrough(row.done)
                                let caption = [row.detail, row.auto ? "авто" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
                                if !caption.isEmpty {
                                    Text(caption).font(.footnote).foregroundColor(DS.Colors.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: DS.Metrics.minHitTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Открыть привычки")
                    }
                }
                let more = TodaySummary.moreText(block.more)
                PillButton(more.isEmpty ? "\(block.done) из \(block.total)" : "\(block.done) из \(block.total) · \(more)", style: .secondary) { openHabits() }
            }
        }
    }

    /// Two or three active goals; the week goal comes first (it replaces the old stand-alone «Цель недели» row).
    @ViewBuilder
    private var goalsCard: some View {
        let weekId = goals.weekGoal(today: reviewDay)?.goal.id
        if let block = GoalsSummary.make(goals: goals.goals, weekGoalId: weekId, progressOf: { goals.progress(for: $0, today: reviewDay) }) {
            Card {
                SectionHeader("Цели")
                ForEach(block.rows) { row in
                    Button { openGoals() } label: {
                        VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                            Text(row.isWeek ? "Цель недели · \(row.title)" : row.title)
                                .font(.body)
                                .foregroundColor(DS.Colors.textPrimary)
                            if !row.text.isEmpty {
                                Text(row.text).font(.footnote).foregroundColor(DS.Colors.textSecondary)
                            }
                            if let fraction = row.fraction {
                                ProgressView(value: fraction).accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: DS.Metrics.minHitTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.isWeek ? "Цель недели: " : "")\(row.title). \(row.text)")
                    .accessibilityHint("Открыть цели")
                }
                if block.more > 0 {
                    Text(TodaySummary.moreText(block.more)).font(.footnote).foregroundColor(DS.Colors.textSecondary)
                }
            }
        }
    }

    /// Pinned notes are the favourites: no separate star. Tapping leads to the notes tab.
    @ViewBuilder
    private var pinnedNotesCard: some View {
        if let block = PinnedNotesSummary.make(notes: notes?.notes ?? []) {
            Card {
                SectionHeader("Закреплённые заметки")
                ForEach(block.rows) { row in
                    Button { selectedTab = .notes } label: {
                        Text(row.title)
                            .font(.body)
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: DS.Metrics.minHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Открыть заметки")
                }
                if block.more > 0 {
                    Text(TodaySummary.moreText(block.more)).font(.footnote).foregroundColor(DS.Colors.textSecondary)
                }
            }
        }
    }

    private func openGoals() {
        if let onOpenGoals { onOpenGoals() } else { selectedTab = .plans }
    }

    private func openHabits() {
        if let onOpenHabits { onOpenHabits() } else { selectedTab = .plans }
    }

    private var reviewDay: String { PlanDomain.today(timeZone: plans.timeZone) }

    private var reviewCard: some View {
        ReviewCard(review: review, today: reviewDay,
                   onDay: { reviewSheet = .day }, onWeek: { reviewSheet = .week }, onHistory: { reviewSheet = .history })
    }

    private func reviewSources() -> ReviewSources {
        ReviewSources.current(plans: plans, finance: finance, workouts: workouts, notes: notes)
    }

    private func syncReviewOwner() {
        let before = review.owner
        review.switchOwner(to: finance.owner)
        guard review.owner != before else { return }
        if review.owner == .none {
            ReviewReminder.cancel()
        } else {
            let settings = review.reminder
            Task { await ReviewReminder.apply(settings) }
        }
    }

    private func moveOpenToTomorrow(_ ids: [String]) async -> Bool {
        await plans.moveOpenToTomorrow(ids)
    }

    private var plansCard: some View {
        let items = plans.upcomingAgenda.prefix(3)
        return Card {
            SectionHeader("Планы")
            if items.isEmpty {
                Text("Ближайших планов нет.")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            } else {
                ForEach(items) { agenda in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agenda.item.title)
                            .font(.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(Self.when(agenda))
                            .font(.footnote.monospacedDigit())
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: DS.Metrics.spacing12) {
                PillButton(items.isEmpty ? "Добавить план" : "Все планы", style: .secondary) { selectedTab = .plans }
                PillButton("Будильники", icon: "alarm", style: .secondary) { isShowingAlarms = true }
            }
        }
    }

    private var moneyCard: some View {
        Card {
            SectionHeader("Деньги")
            if let spendable = finance.summary?.spendableMinor ?? finance.summary?.balanceMinor {
                Text(Self.kzt(spendable))
                    .font(.system(.largeTitle, design: .default).weight(.light).monospacedDigit())
                    .foregroundColor(DS.Colors.textPrimary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(finance.summary?.spendableMinor != nil ? "Можно потратить" : "Баланс")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            } else {
                Text("Баланс пока не указан.")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            switch CanSpendLine.make(spend: finance.canSpendToday(on: reviewDay), gap: finance.canSpendGap(on: reviewDay), hasData: !finance.state.records.isEmpty) {
            case .amount(let amount, let basis):
                VStack(alignment: .leading, spacing: 2) {
                    Text(CanSpendLine.title(amount: amount))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(basis)
                        .font(.footnote)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .accessibilityElement(children: .combine)
            case .gap(let text):
                VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                    Text(text)
                        .font(.footnote)
                        .foregroundColor(DS.Colors.textSecondary)
                    PillButton("Открыть деньги", style: .secondary) { selectedTab = .money }
                }
            case nil:
                EmptyView()
            }
            PillButton((finance.summary?.spendableMinor ?? finance.summary?.balanceMinor) == nil ? "Добавить первую запись" : "Открыть деньги", style: .secondary) { selectedTab = .money }
        }
    }

    /// The running session, else today's day of the program, else the nearest next one; hidden with no program and no session.
    @ViewBuilder
    private var workoutCard: some View {
        let session = workouts.activeSession.flatMap { $0.phase != .complete ? $0 : nil }
        let name = session.map { $0.exercises.indices.contains($0.exerciseIndex) ? $0.exercises[$0.exerciseIndex].name : "" } ?? ""
        let weekday = WorkoutProgram.weekday(of: Date(), timeZone: TimeZone(identifier: plans.timeZone) ?? .current)
        if let line = TodayWorkoutSummary.make(active: session != nil, currentName: name, days: workouts.training?.days ?? [], weekday: weekday) {
            Card {
                SectionHeader("Тренировка")
                Button { selectedTab = .workout } label: {
                    HStack {
                        Text(line.title).font(.body).foregroundColor(DS.Colors.textPrimary)
                        Spacer()
                        Text(line.when).font(.footnote).foregroundColor(DS.Colors.textSecondary)
                    }
                    .frame(minHeight: DS.Metrics.minHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(line.title), \(line.when)")
                .accessibilityHint("Открыть тренировку")
                switch line.kind {
                case .active:
                    PillButton("Вернуться к тренировке", icon: "play.fill") { selectedTab = .workout }
                case .today:
                    PillButton("Начать тренировку", style: .secondary) { selectedTab = .workout }
                case .next:
                    EmptyView()
                }
            }
        }
    }

    /// "Сегодня, 10:00–11:00", or the short date for later days.
    static func when(_ agenda: AgendaItem) -> String {
        guard !agenda.displayDate.isEmpty else { return agenda.displayTime }
        if agenda.displayDate == PlanDomain.today() { return "Сегодня, \(agenda.displayTime)" }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: PlanDomain.defaultTimeZone)
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: agenda.displayDate) else { return agenda.displayTime }
        parser.locale = Locale(identifier: "ru_RU")
        parser.dateFormat = "d MMMM"
        return "\(parser.string(from: date)), \(agenda.displayTime)"
    }

    /// Amounts are stored in tiyn; whole tenge are enough for a summary.
    static func kzt(_ minor: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.maximumFractionDigits = 0
        let value = formatter.string(from: NSNumber(value: Double(minor) / 100)) ?? "\(minor / 100)"
        return "\(value) ₸"
    }
}
