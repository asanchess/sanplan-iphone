import SwiftUI

/// Home: one card each for money, plans and workout, each with a direct way in.
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
    var dictation: SpeechDictation? = nil
    /// Grows when the day-review reminder is tapped (ReviewNotifications); opens the day review.
    var reviewRequest: Int = 0
    @StateObject private var review = ReviewStore()
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
                        ScreenHeader("Сегодня") {
                            CircleIconButton(icon: "person.crop.circle", accessibilityLabel: "Настройки") {
                                showSettings = true
                            }
                        }
                        reviewCard
                        workoutCard
                        plansCard
                        moneyCard
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.vertical, DS.Metrics.spacing16)
                }
                .refreshable { await plans.reload() }
            }
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
                WeekReviewSheet(review: review, day: reviewDay, sources: reviewSources, spheres: ReviewSphere.defaults)
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
                    Text("Можно потратить сегодня: (ReviewFormat.tenge(amount * 100))")
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

    private var workoutCard: some View {
        Card {
            SectionHeader("Тренировка")
            if let session = workouts.activeSession, session.phase != .complete {
                Text(session.exercises[session.exerciseIndex].name)
                    .font(.body)
                    .foregroundColor(DS.Colors.textPrimary)
                PillButton("Вернуться к тренировке", icon: "play.fill") { selectedTab = .workout }
            } else {
                Text(workouts.training?.days.isEmpty == false ? "Программа готова." : "Программа не задана.")
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
                PillButton(workouts.training?.days.isEmpty == false ? "Начать тренировку" : "Задать программу", style: .secondary) { selectedTab = .workout }
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
