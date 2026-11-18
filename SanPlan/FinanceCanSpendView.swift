import SwiftUI

/// «Можно потратить сегодня» и одна строка, почему такая сумма. Правило — в FinanceSummaries.canSpendToday.
/// Без лимитов вместо суммы подсказка задать их.
/// Canvas: label 13/700, number Dela 44 in the accent with a 4,4 ink shadow, «Потрачено сегодня … из …» 16/500,
/// a 10-pt bar on #33295A. A tap opens the month and the «Чистыми» breakdown.
struct CanSpendTodayCard: View {
    let result: CanSpendToday?
    /// Траты месяца и сумма лимитов (тенге): показываются по нажатию.
    var month: (spent: Int64, limit: Int64)? = nil
    /// «Чистыми X ₸» with its note; nil hides the breakdown link.
    var clean: (amount: String, note: String, warns: Bool)? = nil
    /// «Чистыми за ноябрь»: the month name («ноябрь») and the net in minor units; nil hides the line.
    var net: (month: String, minor: Int64)? = nil
    var onBreakdown: (() -> Void)? = nil
    var onSetLimits: (() -> Void)? = nil
    @State private var showMonth = false
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            mainButton
            if let net {
                netLine(net)
            }
            if showMonth || result == nil {
                details
                    .transition(.opacity)
            }
        }
    }

    private var mainButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { showMonth.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("МОЖНО ПОТРАТИТЬ СЕГОДНЯ")
                    .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                    .tracking(0.8)
                    .foregroundColor(DS.Colors.textSecondary)
                if let result {
                    Text(FinanceText.money(result.amount * 100))
                        .font(DS.Fonts.display(44, relativeTo: .largeTitle))
                        .foregroundColor(accent)
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

    /// The breakdown link and, without limits, «Задать лимиты».
    @ViewBuilder
    private var details: some View {
        if let clean, let onBreakdown {
            Button(action: onBreakdown) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // The net itself is the big line above; here only the way into its breakdown.
                        Text(net == nil ? "Чистыми \(clean.amount)" : "Из чего складываются чистыми")
                            .font(DS.Fonts.text(16, .bold))
                            .foregroundColor(DS.Colors.textPrimary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(accent)
                    }
                    Text(clean.note)
                        .font(DS.Fonts.text(13, .medium, relativeTo: .caption))
                        .foregroundColor(clean.warns ? DS.Colors.warning : DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Показать, из чего складывается сумма")
            .accessibilityIdentifier("clean-header")
        }
        if result == nil, let onSetLimits {
            MoneyTextButton("Задать лимиты", action: onSetLimits)
        }
    }

    /// «ЧИСТЫМИ ЗА НОЯБРЬ» and «+197 972 ₸» in large heavy type: the accent while it holds, red below zero.
    private func netLine(_ net: (month: String, minor: Int64)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ЧИСТЫМИ ЗА \(net.month.uppercased())")
                .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                .tracking(0.8)
                .foregroundColor(DS.Colors.textSecondary)
            Text(FinanceText.signed(net.minor))
                .font(DS.Fonts.text(32, .heavy, relativeTo: .title))
                .monospacedDigit()
                .foregroundColor(net.minor < 0 ? DS.Colors.destructive : accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Чистыми за \(net.month): \(Self.spoken(net.minor))")
        .accessibilityIdentifier("money-net-month")
    }

    /// «плюс 197 972 тенге», «минус 3 400 тенге», «0 тенге».
    private static func spoken(_ minor: Int64) -> String {
        let sign = minor > 0 ? "плюс " : (minor < 0 ? "минус " : "")
        return sign + FinanceText.money(abs(minor)).replacingOccurrences(of: "₸", with: "тенге")
    }

    private func bar(_ fraction: Double) -> some View {
        MoneyBar(fraction: fraction, height: 10, color: fraction > 1 ? DS.Colors.destructive : accent)
            .accessibilityHidden(true)
    }
}
