import SwiftUI

/// «Можно потратить сегодня» и одна строка, почему такая сумма. Правило — в FinanceSummaries.canSpendToday.
/// Без лимитов вместо суммы подсказка задать их.
struct CanSpendTodayCard: View {
    let result: CanSpendToday?
    /// Траты месяца и сумма лимитов (тенге): показываются по нажатию.
    var month: (spent: Int64, limit: Int64)? = nil
    @State private var showMonth = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { showMonth.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("МОЖНО ПОТРАТИТЬ СЕГОДНЯ")
                    .font(DS.Fonts.label)
                    .tracking(0.8)
                    .foregroundColor(DS.Colors.textSecondary)
                if let result {
                    Text(FinanceText.money(result.amount * 100))
                        .font(DS.Fonts.display(44, relativeTo: .largeTitle))
                        .foregroundColor(DS.Colors.money)
                        .shadow(color: DS.Colors.ink, radius: 0, x: 4, y: 4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if let limit = result.dayLimit, limit > 0 {
                        Text("Потрачено сегодня \(FinanceText.money(result.spentToday * 100)) из \(FinanceText.money(limit * 100))")
                            .font(DS.Fonts.text(16, .medium, relativeTo: .callout))
                            .foregroundColor(DS.Colors.textSecondary)
                        bar(Double(result.spentToday) / Double(limit))
                            .padding(.top, 6)
                    }
                    if showMonth {
                        VStack(alignment: .leading, spacing: 6) {
                            if let month, month.limit > 0 {
                                Text("Месяц по лимитам: \(FinanceText.money(month.spent * 100)) из \(FinanceText.money(month.limit * 100))")
                                    .font(DS.Fonts.text(16, .semibold, relativeTo: .callout))
                                    .foregroundColor(DS.Colors.textPrimary)
                                bar(Double(month.spent) / Double(month.limit))
                            }
                            Text(result.basis)
                                .font(DS.Fonts.text(14, relativeTo: .footnote))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 8)
                        .transition(.opacity)
                    }
                } else {
                    Text("Задайте лимиты по категориям во вкладке «План»: тогда здесь появится сумма на день")
                        .font(DS.Fonts.text(15, relativeTo: .subheadline))
                        .foregroundColor(DS.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(result == nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(showMonth ? "Скрыть месяц" : "Показать месяц")
        .accessibilityIdentifier("can-spend-today")
    }

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Colors.hairline)
                Capsule().fill(fraction > 1 ? DS.Colors.destructive : DS.Colors.money)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}
