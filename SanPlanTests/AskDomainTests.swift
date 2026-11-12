import XCTest
@testable import SanPlan

/// The questions «+» can answer without a model, and the wording they are recognised by.
final class AskDomainTests: XCTestCase {
    private let today = "2026-11-12" // Thursday

    private func noon(_ day: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: day + "T07:00:00Z")!.timeIntervalSince1970 * 1000)
    }

    private func expense(_ id: String, _ day: String, _ tenge: Int64, _ category: String) -> FinanceRecord {
        FinanceRecord(id: id, kind: "expense", title: id, amountMinor: tenge * 100, date: day, category: category)
    }

    private func data() -> AskData {
        AskData(
            today: today,
            plans: [
                PlanItem(id: "p1", kind: "event", title: "Стоматолог", date: "2026-11-13", time: "10:00"),
                PlanItem(id: "p2", kind: "task", title: "Купить билеты", date: "2026-11-13"),
                PlanItem(id: "p3", kind: "event", title: "Сегодняшнее", date: today, time: "09:00")
            ],
            finance: [
                expense("a", "2026-11-03", 12_000, "Продукты"), expense("b", "2026-11-09", 3_000, "Кафе и рестораны"),
                expense("c", "2026-11-05", 4_000, "Транспорт"), expense("old", "2026-10-30", 9_999, "Продукты")
            ],
            workouts: [
                WorkoutRecord(id: "w1", startedAt: noon("2026-11-10"), endedAt: noon("2026-11-10") + 3_000_000, title: "Верх",
                              exercises: [WorkoutRecordExercise(name: "Жим", sets: [WorkoutRecordSet(done: true, weightKg: 50, reps: 8)])]),
                WorkoutRecord(id: "w2", startedAt: noon("2026-11-11"), endedAt: noon("2026-11-11") + 3_000_000, title: "Ноги",
                              exercises: [WorkoutRecordExercise(name: "Присед", sets: [WorkoutRecordSet(done: true, weightKg: 80, reps: 5)])]),
                WorkoutRecord(id: "w0", startedAt: noon("2026-11-02"), endedAt: noon("2026-11-02") + 3_000_000, title: "Прошлая",
                              exercises: [WorkoutRecordExercise(name: "Жим", sets: [WorkoutRecordSet(done: true, weightKg: 50, reps: 8)])])
            ],
            dailyMinor: 1_250_000)
    }

    // MARK: Parsing — the supported set

    func testSupportedPhrasings() {
        let food = AskParser.categoryGroups[0].category
        let cases: [(String, AskQuery)] = [
            ("Сколько я потратил на еду в этом месяце?", .spent(.thisMonth, food)),
            ("сколько потратил на продукты за месяц", .spent(.thisMonth, food)),
            ("Сколько я потратил на питание на этой неделе", .spent(.thisWeek, food)),
            ("Сколько я потратил сегодня?", .spent(.today, nil)),
            ("Сколько я потратил в прошлом месяце", .spent(.lastMonth, nil)),
            ("Сколько тренировок на этой неделе?", .trainings(.thisWeek)),
            ("сколько тренировок в этом месяце", .trainings(.thisMonth)),
            ("Сколько тренировок было на прошлой неделе?", .trainings(.lastWeek)),
            ("Сколько тренировок", .trainings(.thisWeek)),
            ("Что у меня завтра?", .agenda(.tomorrow)),
            ("что у меня сегодня", .agenda(.today)),
            ("Что было вчера?", .agenda(.yesterday)),
            ("Планы на завтра", .agenda(.tomorrow)),
            ("Сколько можно потратить сегодня?", .canSpendToday),
            ("сколько я могу потратить", .canSpendToday)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(AskParser.parse(text), expected, text)
        }
    }

    func testWhatDidISpendIsNotTakenForAgenda() {
        XCTAssertEqual(AskParser.parse("Что я потратил сегодня?"), .spent(.today, nil))
    }

    func testUnsupportedQuestionsAreNotGuessed() {
        for text in ["", "   ", "Купить молоко", "Какая погода завтра?", "Что у меня послезавтра?", "Сколько звёзд на небе"] {
            XCTAssertNil(AskParser.parse(text), text)
        }
    }

    func testOnlyAnswerableQuestionsGetAnOffer() {
        XCTAssertTrue(AskParser.looksLikeQuestion("Что у меня завтра?"))
        XCTAssertFalse(AskParser.looksLikeQuestion("Позвонить маме завтра"))
        XCTAssertFalse(AskParser.looksLikeQuestion("Список\nсколько тренировок"))
        XCTAssertFalse(AskParser.looksLikeQuestion(String(repeating: "сколько тренировок ", count: 20)))
    }

    func testPeriodRanges() {
        XCTAssertEqual(AskPeriod.thisWeek.range(today: today).from, "2026-11-09")
        XCTAssertEqual(AskPeriod.thisWeek.range(today: today).to, "2026-11-15")
        XCTAssertEqual(AskPeriod.lastWeek.range(today: today).from, "2026-11-02")
        XCTAssertEqual(AskPeriod.thisMonth.range(today: today).to, "2026-11-30")
        XCTAssertEqual(AskPeriod.lastMonth.range(today: today).from, "2026-10-01")
        XCTAssertEqual(AskPeriod.lastMonth.range(today: "2026-01-15").to, "2025-12-31")
        XCTAssertEqual(AskPeriod.tomorrow.range(today: "2026-11-30").from, "2026-12-01")
    }

    // MARK: Answers computed from the data

    func testSpendingOnFoodThisMonthSumsFoodCategoriesOnly() {
        let answer = AskEngine.answer("Сколько я потратил на еду в этом месяце?", data: data())
        XCTAssertTrue(answer.isUnderstood)
        XCTAssertTrue(answer.text.contains("15"), answer.text) // 12 000 + 3 000
        XCTAssertTrue(answer.text.contains("2 траты"), answer.text)
        XCTAssertTrue(answer.text.contains("₸"))
    }

    func testSpendingWithoutCategoryListsTopCategories() {
        let answer = AskEngine.answer("Сколько я потратил в этом месяце", data: data())
        XCTAssertTrue(answer.text.contains("3 траты"), answer.text)
        XCTAssertEqual(answer.lines.count, 3)
        XCTAssertTrue(answer.lines[0].hasPrefix("Продукты"))
    }

    func testNoSpendingSaysSo() {
        let answer = AskEngine.answer("Сколько я потратил на еду вчера", data: data())
        XCTAssertEqual(answer.text, "Трат на еду вчера нет.")
    }

    func testTrainingsThisWeek() {
        let answer = AskEngine.answer("Сколько тренировок на этой неделе?", data: data())
        XCTAssertEqual(answer.text, "Тренировок на этой неделе: 2.")
        XCTAssertEqual(answer.lines, ["Верх", "Ноги"])
        XCTAssertEqual(AskEngine.answer("Сколько тренировок на прошлой неделе?", data: data()).text, "Тренировок на прошлой неделе: 1.")
    }

    func testNoTrainings() {
        var empty = data()
        empty.workouts = []
        XCTAssertEqual(AskEngine.answer("Сколько тренировок на этой неделе?", data: empty).text, "Тренировок на этой неделе нет.")
    }

    func testAgendaForTomorrowListsTimedItemsFirst() {
        let answer = AskEngine.answer("Что у меня завтра?", data: data())
        XCTAssertEqual(answer.text, "Завтра: 2 дела.")
        XCTAssertEqual(answer.lines.count, 2)
        XCTAssertTrue(answer.lines.contains { $0.contains("Стоматолог") && $0.contains("10:00") })
        XCTAssertTrue(answer.lines.contains { $0.contains("Купить билеты") })
    }

    func testEmptyAgenda() {
        XCTAssertEqual(AskEngine.answer("Что у меня вчера", data: data()).text, "На вчера планов нет.")
    }

    func testCanSpendToday() {
        XCTAssertTrue(AskEngine.answer("Сколько можно потратить сегодня?", data: data()).text.contains("12"))
        var noMoney = data()
        noMoney.dailyMinor = nil
        XCTAssertTrue(AskEngine.answer("Сколько можно потратить сегодня?", data: noMoney).text.hasPrefix("Не хватает данных"))
    }

    func testUnknownQuestionExplainsWhatCanBeAsked() {
        let answer = AskEngine.answer("Какая завтра погода", data: data())
        XCTAssertFalse(answer.isUnderstood)
        XCTAssertEqual(answer.lines, AskParser.examples)
    }

    /// Every example shown to the person must be answerable by the engine itself.
    func testEveryExampleIsUnderstood() {
        for example in AskParser.examples {
            XCTAssertTrue(AskEngine.answer(example, data: data()).isUnderstood, example)
        }
    }
}
