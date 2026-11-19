#if DEBUG
import Foundation

/// Made-up money for the cloud screenshots (`--screenshot-demo-data`), so «Обзор», «План» and «Операции»
/// can be compared with the canvas. Nothing here is a real person's data and nothing is ever saved:
/// `FinanceStore.showScreenshotDemo` keeps it in memory with no owner.
enum MoneyDemo {
    static let importId = "demo-kaspi"

    /// Four weeks of spending across categories, one salary this month, three envelopes with history,
    /// two monthly payments, limits and one bank statement.
    static func state(today: String) -> FinanceState {
        let day = { (offset: Int) in MoneyDays.shift(today, by: -offset) }
        let tenge = { (value: Int64) in value * 100 }
        var records: [FinanceRecord] = []

        func record(_ id: String, _ kind: String, _ title: String, _ amount: Int64, date: String? = nil,
                    category: String? = nil, merchant: String? = nil, fromStatement: Bool = false) {
            var r = FinanceRecord(id: id, kind: kind, title: title, amountMinor: tenge(amount), date: date, category: category)
            r.merchant = merchant
            r.importId = fromStatement ? MoneyDemo.importId : nil
            records.append(r)
        }

        // Spending: (title, category, merchant, amount, every n days, first offset).
        let patterns: [(String, String, String, Int64, Int, Int)] = [
            ("Магнум", "Продукты", "MAGNUM CASH&CARRY", 8_400, 3, 1),
            ("Small", "Продукты", "SMALL", 2_900, 4, 2),
            ("Кофейня", "Кафе и рестораны", "COFFEE BOOM", 1_600, 2, 1),
            ("Обед", "Кафе и рестораны", "SALAM BRO", 3_800, 5, 3),
            ("Яндекс Go", "Транспорт", "YANDEX GO", 1_900, 3, 2),
            ("Онай", "Транспорт", "ONAY", 900, 6, 4),
            ("Технодом", "Покупки", "TECHNODOM", 14_500, 11, 6),
            ("Wildberries", "Покупки", "WILDBERRIES", 6_200, 9, 5),
            ("Кино", "Развлечения", "KINOPARK", 4_000, 10, 7),
        ]
        var n = 0
        for (title, category, merchant, amount, every, first) in patterns {
            var offset = first
            var step: Int64 = 0
            while offset <= 27 {
                n += 1
                // Small spread so bars differ; older operations come from the statement.
                let value = amount + (step % 3) * amount / 7
                record("demo-e\(n)", "expense", title, value, date: day(offset), category: category,
                       merchant: merchant, fromStatement: offset >= 7)
                offset += every
                step += 1
            }
        }
        // Today, as on the canvas: coffee and a taxi.
        record("demo-today-1", "expense", "Кофе", 1_200, date: today, category: "Кафе и рестораны")
        record("demo-today-2", "expense", "Такси", 2_300, date: today, category: "Транспорт")

        // One salary this month (yesterday, or today on the 1st), so «Отложить с дохода» shows.
        let incomeDay = today.hasSuffix("-01") ? today : day(1)
        record("demo-income", "income", "Зарплата", 450_000, date: incomeDay, category: "Зарплата")
        record("demo-balance", "balance", "Остаток на картах", 612_400, date: incomeDay)

        // Payments.
        var rent = FinanceRecord(id: "demo-rent", kind: "obligation", title: "Аренда", amountMinor: tenge(120_000), frequency: "monthly")
        rent.date = day(27)
        records.append(rent)
        var net = FinanceRecord(id: "demo-net", kind: "obligation", title: "Интернет", amountMinor: tenge(5_990), frequency: "monthly")
        net.date = day(27)
        records.append(net)

        // Envelopes with history.
        // «Отпуск» is behind its date, «Техника» is on track, «Подушка» has no date and grows for months.
        records.append(FinanceRecord(id: "demo-goal-cushion", kind: "goal", title: "Подушка", amountMinor: tenge(300_000), savedMinor: tenge(180_000)))
        var trip = FinanceRecord(id: "demo-goal-trip", kind: "goal", title: "Отпуск", amountMinor: tenge(200_000), savedMinor: tenge(45_000))
        trip.date = day(150)
        trip.dueDate = day(-120)
        records.append(trip)
        var tech = FinanceRecord(id: "demo-goal-tech", kind: "goal", title: "Техника", amountMinor: tenge(150_000), savedMinor: tenge(17_400))
        tech.date = day(40)
        tech.dueDate = day(-400)
        records.append(tech)
        let log = [
            EnvelopeLogEntry(id: "demo-log-old-1", goalId: "demo-goal-cushion", amountMinor: tenge(20_000), date: day(150)),
            EnvelopeLogEntry(id: "demo-log-old-2", goalId: "demo-goal-cushion", amountMinor: tenge(15_000), date: day(120)),
            EnvelopeLogEntry(id: "demo-log-old-3", goalId: "demo-goal-cushion", amountMinor: tenge(25_000), date: day(85)),
            EnvelopeLogEntry(id: "demo-log-1", goalId: "demo-goal-cushion", amountMinor: tenge(80_000), date: day(26)),
            EnvelopeLogEntry(id: "demo-log-2", goalId: "demo-goal-trip", amountMinor: tenge(45_000), date: day(20)),
            EnvelopeLogEntry(id: "demo-log-3", goalId: "demo-goal-tech", amountMinor: tenge(25_000), date: day(16)),
            EnvelopeLogEntry(id: "demo-log-4", goalId: "demo-goal-tech", amountMinor: -tenge(7_600), date: day(9)),
            EnvelopeLogEntry(id: "demo-log-5", goalId: "demo-goal-cushion", amountMinor: tenge(40_000), date: day(5)),
        ]

        let month = String(today.prefix(7))
        let budget = FinanceBudget(
            limits: [
                "Продукты": tenge(120_000), "Кафе и рестораны": tenge(45_000), "Транспорт": tenge(30_000),
                "Покупки": tenge(60_000), "Развлечения": tenge(20_000),
            ],
            savingsGoalId: "demo-goal-cushion",
            reviewedMonths: [FinanceInsights.previousMonth(month)],
            freeOfferMonths: [month],
            envelopeLog: log
        )
        let statement = FinanceImport(
            id: MoneyDemo.importId, bank: "Kaspi Gold", fileName: "kaspi-gold-demo.pdf",
            periodStart: day(27), periodEnd: day(7), importedAt: day(6),
            count: records.filter { $0.importId == MoneyDemo.importId }.count
        )
        let state = FinanceState(records: records, imports: [statement], budget: budget)
        return (try? validateFinance(state)) ?? state
    }
}
#endif
