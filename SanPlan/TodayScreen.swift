import SwiftUI

/// Home: one card each for money, plans and workout, each with a direct way in.
public struct TodayScreen: View {
    @ObservedObject var plans: PlanStore
    @ObservedObject var finance: FinanceStore
    @ObservedObject var workouts: WorkoutStore
    @Binding var selectedTab: MainTab
    @Binding var showSettings: Bool

    public var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                        workoutCard
                        plansCard
                        moneyCard
                    }
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.vertical, DS.Metrics.spacing16)
                }
                .refreshable { await plans.reload() }
            }
            .navigationTitle("Сегодня")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CircleIconButton(icon: "person.crop.circle", accessibilityLabel: "Настройки") {
                        showSettings = true
                    }
                }
            }
        }
        .task {
            finance.refreshSummary(today: PlanDomain.today())
            await plans.reload()
        }
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
            PillButton("Открыть планы", style: .secondary) { selectedTab = .plans }
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
            PillButton("Открыть деньги", style: .secondary) { selectedTab = .money }
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
                PillButton("Открыть тренировку", style: .secondary) { selectedTab = .workout }
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
