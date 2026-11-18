import SwiftUI

/// Home, ported 1:1 from docs/design/canvas-r5/Main.html (round 6):
/// header · «Главное сейчас» · three rings · «Дальше сегодня» · habits · goals · pinned notes · «Прогресс недели» · «Итоги дня».
/// Habits, goals and notes are not on the canvas; they keep their phone-5 function in the same style and hide while empty.
/// Every card that points into another section opens the exact place through `DeepLinks`.
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
    /// Kept for RootView's call; round 6 opens goals and habits through `DeepLinks` (`.goals`, `.habits`).
    var onOpenGoals: (() -> Void)? = nil
    var onOpenHabits: (() -> Void)? = nil
    /// Grows when the day-review reminder is tapped (ReviewNotifications); opens «Итоги» on the day.
    var reviewRequest: Int = 0
    /// Owned by AppModel so Plans (spheres) sees the same week ratings.
    @ObservedObject var review: ReviewStore
    @ObservedObject private var goals = GoalStore.shared
    @ObservedObject private var habitStore = HabitStore.shared
    @Environment(\.headerShortcuts) private var shortcuts
    @State private var summaryOpen = false
    @State private var summaryMode: SummaryScreen.Mode = .day

    public var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                TodayBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ScreenHeader("Сегодня", kicker: Self.dateLine(Date())) {}
                        heroCard
                        ringsRow
                            .petTip("Три круга: планы, привычки и сколько можно потратить.")
                        nextSection
                        habitsSection
                            .petTip("Нажмите строку — привычка отмечена. Ошиблись — «Отменить» внизу.")
                        goalsSection
                        pinnedNotesSection
                        progressCard
                            .petTip("Неделя коротко. Нажмите — откроется весь прогресс.")
                        reviewButton
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                }
                .refreshable { await plans.reload() }
            }
            .shellCaptureButton()
            .toolbar(.hidden, for: .navigationBar)
        }
        .onChange(of: reviewRequest) { _, _ in openSummary(.day) }
        .fullScreenCover(isPresented: $summaryOpen) {
            SummaryScreen(
                review: review,
                day: reviewDay,
                sources: reviewSources,
                moveOpen: { await moveOpenToTomorrow($0) },
                inputs: inputs,
                dictation: dictation,
                spheres: goals.spheres.map { ReviewSphere(id: $0.id, title: $0.title) },
                initialMode: summaryMode,
                onOpen: { link in
                    summaryOpen = false
                    DeepLinks.shared.open(link)
                }
            )
            .environment(\.sectionAccent, DS.Colors.today)
        }
        // A place asked for elsewhere (Progress, the mascot) must not stay hidden under «Итоги».
        .onReceive(DeepLinks.shared.$pending) { link in
            if link != nil, summaryOpen { summaryOpen = false }
        }
        .task {
            syncReviewOwner()
            review.setCollection(reviewsVault)
            finance.refreshSummary(today: PlanDomain.today())
            if ScreenshotRoute.is("summary") { openSummary(.day) }
            if ScreenshotRoute.demoData {
                seedScreenshotDemo()
            } else {
                await plans.reload()
            }
        }
        // Reviews follow the signed-in account: money switches owner on sign-in and sign-out.
        .onChange(of: finance.state) { _, _ in syncReviewOwner() }
        .onChange(of: reviewsVault?.isAvailable) { _, _ in review.setCollection(reviewsVault) }
    }

    /// Debug screenshots: «Сегодня» opens first, before Plans and Money seed themselves, so it puts the same
    /// made-up plans and money in memory. Nothing is written: plans skip disk/alarm sync, money has no owner.
    private func seedScreenshotDemo() {
        #if DEBUG
        let today = PlanDomain.today(timeZone: plans.timeZone)
        if plans.plans.isEmpty {
            plans.plans = PlansDemo.plans(today: today, timeZone: plans.timeZone)
            plans.selectedDate = today
        }
        let moneyDay = FinanceText.today()
        finance.showScreenshotDemo(MoneyDemo.state(today: moneyDay), today: moneyDay)
        #endif
    }

    private func openSummary(_ mode: SummaryScreen.Mode) {
        summaryMode = mode
        summaryOpen = true
    }

    private func open(_ link: DeepLink) { DeepLinks.shared.open(link) }

    private var reviewDay: String { PlanDomain.today(timeZone: plans.timeZone) }

    // MARK: Главное сейчас

    private var activeSession: WorkoutSessionState? {
        workouts.activeSession.flatMap { $0.phase != .complete ? $0 : nil }
    }

    private var weekday: Int {
        WorkoutProgram.weekday(of: Date(), timeZone: TimeZone(identifier: plans.timeZone) ?? .current)
    }

    /// Today's day of the program, else the nearest next one (the same rule as `TodayWorkoutSummary`).
    private func programDay(today: Bool) -> WorkoutDayPlan? {
        let days = (workouts.training?.days ?? []).filter { (1...7).contains($0.weekday) }
        if today { return days.first { $0.weekday == weekday } }
        return days.min { ($0.weekday - weekday + 7) % 7 < ($1.weekday - weekday + 7) % 7 }
    }

    /// Saved, unfinished plans of today that are still ahead, by time.
    private var openToday: [AgendaItem] {
        let saved = Set(plans.plans.map(\.id))
        return plans.upcomingAgenda.filter { $0.displayDate == reviewDay && (saved.contains($0.id) || $0.item.kind == "event") }
    }

    private var hero: TodayHero {
        let session = activeSession
        let name = session.map { $0.exercises.indices.contains($0.exerciseIndex) ? $0.exercises[$0.exerciseIndex].name : "" } ?? ""
        let line = TodayWorkoutSummary.make(active: session != nil, currentName: name, days: workouts.training?.days ?? [], weekday: weekday)
        var detail = ""
        if let session {
            detail = session.exercises.isEmpty ? "" : "Упражнение \(min(session.exerciseIndex + 1, session.exercises.count)) из \(session.exercises.count)"
        } else if let line, let day = programDay(today: line.kind == .today) {
            detail = TodayWorkoutSummary.estimate(day)
        }
        let next = openToday.first.map { (title: $0.item.title, time: $0.startMin.map(TodayFormat.clock) ?? "") }
        return TodayHeroSummary.make(
            workout: line, workoutDetail: detail,
            workoutDoneToday: workouts.daySummary(for: reviewDay).completed,
            nextPlan: next, openPlans: openToday.count
        )
    }

    private var heroCard: some View {
        let hero = self.hero
        return TodayHeroCard(hero: hero, open: { heroOpen(hero) }, primary: { heroPrimary(hero) })
            .petTip(hero.kind == .workout ? "Главное на сейчас. «Начать» сразу запускает тренировку." : "Главное на сейчас.")
    }

    private func heroOpen(_ hero: TodayHero) {
        switch hero.kind {
        case .activeWorkout, .workout, .nextWorkout: selectedTab = .workout
        case .plan, .empty: open(.plansAll)
        }
    }

    private func heroPrimary(_ hero: TodayHero) {
        if hero.kind == .workout, activeSession == nil, let day = programDay(today: true) {
            workouts.startWorkout(day: day)
        }
        heroOpen(hero)
    }

    // MARK: Три круга

    private var ringsRow: some View {
        let planDay = plans.daySummary(for: reviewDay)
        let habitDay = habitStore.daySummary(for: reviewDay)
        return HStack(spacing: 10) {
            TodayRing(
                name: "Планы",
                value: planDay.total > 0 ? "\(planDay.done)/\(planDay.total)" : "—",
                fraction: planDay.total > 0 ? Double(planDay.done) / Double(planDay.total) : 0,
                color: DS.Colors.plans,
                spoken: planDay.total > 0 ? "Планы: \(planDay.done) из \(planDay.total)" : "Задач на сегодня нет",
                action: { open(.plansAll) }
            )
            TodayRing(
                name: "Привычки",
                value: habitDay.total > 0 ? "\(habitDay.done)/\(habitDay.total)" : "—",
                fraction: habitDay.total > 0 ? Double(habitDay.done) / Double(habitDay.total) : 0,
                color: DS.Colors.today,
                spoken: habitDay.total > 0 ? "Привычки: \(habitDay.done) из \(habitDay.total)" : "Привычек на сегодня нет",
                action: { open(.habits) }
            )
            moneyRing
        }
    }

    /// «Можно потратить сегодня» against the day's share of the limits; without limits, the balance; else a dash.
    private var moneyRing: some View {
        let spend = finance.canSpendToday(on: reviewDay)
        let fallback = finance.summary?.spendableMinor ?? finance.summary?.balanceMinor
        let value: String
        let fraction: Double
        let name: String
        let spoken: String
        if let spend {
            value = TodayFormat.short(spend.amount)
            let limit = spend.dayLimit ?? 0
            fraction = limit > 0 ? min(max(Double(spend.amount) / Double(limit), 0), 1) : 0
            name = "Осталось, ₸"
            spoken = "\(CanSpendLine.title(amount: spend.amount)). \(spend.basis)"
        } else if let fallback {
            value = TodayFormat.short(fallback / 100)
            fraction = 0
            name = "Баланс, ₸"
            spoken = "Баланс \(ReviewFormat.tenge(fallback)). \(finance.canSpendGap(on: reviewDay) ?? "")"
        } else {
            value = "—"
            fraction = 0
            name = "Осталось, ₸"
            spoken = "Учёт денег не начат"
        }
        return TodayRing(name: name, value: value, fraction: fraction, color: DS.Colors.money, spoken: spoken,
                         action: { open(.moneyOverview(.week)) })
    }

    // MARK: Дальше сегодня

    /// Today's plans (done ones stay, struck through); drafts that were never saved are not shown.
    private var todayItems: [AgendaItem] {
        let saved = Set(plans.plans.map(\.id))
        let drafts = Set(plans.draftPlans.map(\.id))
        return plans.agenda(for: reviewDay).filter { agenda in
            if drafts.contains(agenda.id) && !saved.contains(agenda.id) { return false }
            return agenda.item.date == reviewDay || agenda.item.completed != true
        }
    }

    private var nextSection: some View {
        let items = todayItems
        let shown = Array(items.prefix(4))
        let later = items.isEmpty ? Array(plans.upcomingAgenda.filter { $0.displayDate != reviewDay }.prefix(3)) : []
        let saved = Set(plans.plans.map(\.id))
        return VStack(alignment: .leading, spacing: 10) {
            TodaySectionTitle(
                title: items.isEmpty && !later.isEmpty ? "Дальше" : "Дальше сегодня",
                link: "Все планы",
                linkAction: { open(.plansAll) },
                icon: (name: "alarm", label: "Будильники", action: { open(.alarms) })
            )
            ForEach(shown) { agenda in
                let checkable = agenda.item.kind == "task" && saved.contains(agenda.id)
                let done = agenda.item.completed == true
                TodayCheckRow(
                    title: agenda.item.title,
                    trailing: agenda.startMin.map(TodayFormat.clock) ?? agenda.displayTime,
                    done: done,
                    checkable: checkable,
                    busy: plans.pendingTaskIds.contains(agenda.id)
                ) {
                    if checkable {
                        Task { await plans.toggleTaskCompletion(id: agenda.id, completed: !done) }
                    } else {
                        open(.plansAll)
                    }
                }
            }
            TodayMoreLine(count: items.count - shown.count)
            ForEach(later) { agenda in
                TodayCheckRow(title: agenda.item.title, trailing: Self.when(agenda), done: false, checkable: false) {
                    open(.plansAll)
                }
            }
            if items.isEmpty && later.isEmpty {
                TodayInfoRow(title: "Ближайших планов нет", caption: "Добавить план — в разделе «Планы»", icon: "plus",
                             iconColor: DS.Colors.plans, hint: "Открыть планы") { open(.plansAll) }
                    .accessibilityLabel("Добавить план")
            }
        }
    }

    // MARK: Привычки · цели · заметки (phone-5, в стиле холста)

    @ViewBuilder
    private var habitsSection: some View {
        if let block = TodayHabitsSummary.make(habits: habitStore.habits, marks: habitStore.marks, day: reviewDay, context: habitStore.context) {
            VStack(alignment: .leading, spacing: 10) {
                TodaySectionTitle(title: "Привычки · \(block.done) из \(block.total)", link: "Все привычки", linkAction: { open(.habits) })
                ForEach(block.rows) { row in
                    TodayCheckRow(
                        title: row.title,
                        trailing: row.auto ? "авто" : "",
                        done: row.done,
                        checkable: !row.auto,
                        caption: row.detail
                    ) {
                        if row.auto {
                            open(.habits)
                        } else if let habit = habitStore.habits.first(where: { $0.id == row.id }) {
                            habitStore.tapUndoable(habit, on: reviewDay)
                        }
                    }
                }
                TodayMoreLine(count: block.more)
            }
        }
    }

    /// Two or three active goals; the week goal comes first.
    @ViewBuilder
    private var goalsSection: some View {
        let weekId = goals.weekGoal(today: reviewDay)?.goal.id
        if let block = GoalsSummary.make(goals: goals.goals, weekGoalId: weekId, progressOf: { goals.progress(for: $0, today: reviewDay) }) {
            VStack(alignment: .leading, spacing: 10) {
                TodaySectionTitle(title: "Цели", link: "Все цели", linkAction: { open(.goals) })
                ForEach(block.rows) { row in
                    TodayInfoRow(
                        title: row.isWeek ? "Цель недели · \(row.title)" : row.title,
                        caption: row.text,
                        fraction: row.fraction,
                        hint: "Открыть цели"
                    ) { open(.goals) }
                }
                TodayMoreLine(count: block.more)
            }
        }
    }

    /// Pinned notes are the favourites: no separate star.
    @ViewBuilder
    private var pinnedNotesSection: some View {
        if let block = PinnedNotesSummary.make(notes: notes?.notes ?? []) {
            VStack(alignment: .leading, spacing: 10) {
                TodaySectionTitle(title: "Закреплённые заметки", link: "Все заметки", linkAction: { open(.notes) })
                ForEach(block.rows) { row in
                    TodayInfoRow(title: row.title, icon: "pin.fill", iconColor: DS.Colors.notes, hint: "Открыть заметки") { open(.notes) }
                }
                TodayMoreLine(count: block.more)
            }
        }
    }

    // MARK: Прогресс недели

    private var weekMarks: [TodayWeekStrip.Mark] {
        let start = ReviewCalendar.weekStart(reviewDay)
        let end = ReviewCalendar.addDays(start, 6)
        var active = Set<String>()
        active.formUnion(plans.activityDays(from: start, to: end))
        active.formUnion(finance.activityDays(from: start, to: end))
        active.formUnion(workouts.activityDays(from: start, to: end))
        active.formUnion(notes?.activityDays(from: start, to: end) ?? [])
        active.formUnion(habitStore.activityDays(from: start, to: end))
        active.formUnion(review.activityDays(from: start, to: end))
        return ReviewCalendar.weekDays(startingAt: start).map { day in
            if day == reviewDay { return active.contains(day) ? .todayActive : .today }
            return day < reviewDay && active.contains(day) ? .active : .idle
        }
    }

    /// This week up to today against the same days of the previous week.
    private var weekSentence: String {
        let start = ReviewCalendar.weekStart(reviewDay)
        let beforeStart = ReviewCalendar.addDays(start, -7)
        let beforeEnd = ReviewCalendar.addDays(reviewDay, -7)
        return TodayWeekBrief.sentence(
            spentNow: ReviewSummaries.financePeriod(finance.state, from: start, to: reviewDay).spentMinor,
            spentBefore: ReviewSummaries.financePeriod(finance.state, from: beforeStart, to: beforeEnd).spentMinor,
            workoutsNow: workouts.periodSummary(from: start, to: reviewDay).completed,
            workoutsBefore: workouts.periodSummary(from: beforeStart, to: beforeEnd).completed
        )
    }

    private var progressCard: some View {
        let sentence = weekSentence
        let streak = StreakLine.text(appStreak?(reviewDay))
        return Button { shortcuts?.openProgress() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader("Прогресс недели")
                    Text("Открыть")
                        .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                        .foregroundColor(DS.Colors.today)
                }
                Text(sentence)
                    .font(DS.Fonts.text(17, .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let streak {
                    Text(streak)
                        .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                TodayWeekStrip(marks: weekMarks)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["Прогресс недели", sentence, streak ?? ""].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Открыть прогресс")
        .accessibilityAction { shortcuts?.openProgress() }
    }

    // MARK: Итоги дня

    private var reviewButton: some View {
        let entry = review.day(reviewDay)
        return Button { openSummary(.day) } label: {
            HStack(spacing: 8) {
                Text("Итоги дня")
                if entry != nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(DS.Colors.today)
                }
            }
            .font(DS.Fonts.text(17, .bold))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.Colors.hairline, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityValue(entry == nil ? "" : "сохранены")
        .accessibilityHint("День и неделя: сводка, оценка, заметка")
    }

    // MARK: Helpers

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

    /// «вторник, 17 ноября» for the skewed tag.
    static func dateLine(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "ru_RU")))
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
