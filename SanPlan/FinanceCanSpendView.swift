import SwiftUI

/// «Можно потратить сегодня» и одна строка, почему такая сумма. Правило — в FinanceSummaries.canSpendToday.
/// Без лимитов вместо суммы подсказка задать их.
struct CanSpendTodayCard: View {
    let result: CanSpendToday?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Можно потратить сегодня").font(.subheadline).foregroundColor(DS.Colors.textSecondary)
                Spacer(minLength: 8)
                if let result {
                    Text(FinanceText.money(result.amount * 100))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundColor(DS.Colors.textPrimary)
                }
            }
            Text(result?.basis ?? "Задайте лимиты по категориям во вкладке «План»: тогда здесь появится сумма на день")
                .font(.caption)
                .foregroundColor(result == nil ? DS.Colors.warning : DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Metrics.spacing16)
        .padding(.vertical, DS.Metrics.spacing12)
        .background(DS.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("can-spend-today")
    }
}
