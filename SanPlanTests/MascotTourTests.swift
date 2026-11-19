import XCTest
@testable import SanPlan

final class MascotTourTests: XCTestCase {
    // MARK: Step lists

    func testEverySectionHasFourToEightStepsInTheFullTour() {
        for section in TourSection.allCases {
            let steps = TourPlan.steps(for: section)
            XCTAssertFalse(steps.isEmpty, "\(section) has no steps")
            XCTAssertTrue((4...8).contains(steps.count), "\(section): \(steps.count) steps")
            XCTAssertTrue(steps.allSatisfy { $0.section == section })
            XCTAssertTrue(steps.allSatisfy { !$0.text.isEmpty })
        }
    }

    func testFullTourIsEverySectionInTabOrder() {
        let full = TourPlan.steps(.full)
        XCTAssertEqual(full.count, TourPlan.all.count)
        let order = full.map(\.section).reduce(into: [TourSection]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(order, TourSection.allCases)
    }

    func testShortTourHasExactlyOneStepPerSection() {
        let short = TourPlan.steps(.short)
        XCTAssertEqual(short.count, TourSection.allCases.count)
        XCTAssertEqual(short.map(\.section), TourSection.allCases)
        XCTAssertTrue(short.allSatisfy(\.isKey))
    }

    func testSectionTourHasOnlyThatSection() {
        XCTAssertEqual(TourPlan.steps(.section(.money)), TourPlan.steps(for: .money))
    }

    func testStepIdsAreUniqueAndEachSectionStartsAtTheHeaderOrAKeyStep() {
        let ids = TourPlan.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for section in TourSection.allCases where section != .general {
            XCTAssertEqual(TourPlan.steps(for: section).first?.target, "header.title")
        }
    }

    func testSectionMapsToItsTab() {
        XCTAssertEqual(TourSection(tab: .money), .money)
        XCTAssertEqual(TourSection.general.tab, .today)
        XCTAssertEqual(TourSection.workout.tab, .workout)
    }

    // MARK: Run

    private func steps(_ count: Int) -> [TourStep] {
        (0..<count).map { TourStep("s\($0)", .today, target: "t\($0)", "Шаг \($0)") }
    }

    func testRunGoesForwardAndBackAndEnds() {
        var run = TourRun(kind: .full, steps: steps(3))
        XCTAssertTrue(run.isFirst)
        XCTAssertEqual(run.position, "1 из 3")
        XCTAssertTrue(run.next())
        XCTAssertTrue(run.next())
        XCTAssertTrue(run.isLast)
        XCTAssertFalse(run.next(), "past the last step the run is over")
        run.back()
        XCTAssertEqual(run.step?.id, "s1")
        run.back()
        run.back()
        XCTAssertEqual(run.step?.id, "s0")
    }

    func testMissingTargetIsPassedInTheDirectionOfTravel() {
        var run = TourRun(kind: .full, steps: steps(4))
        XCTAssertTrue(run.next())
        XCTAssertTrue(run.passMissing())
        XCTAssertEqual(run.step?.id, "s2")
        run.back()
        XCTAssertTrue(run.passMissing())
        XCTAssertEqual(run.step?.id, "s0")
        XCTAssertTrue(run.passesMissingTargets)
        XCTAssertFalse(TourRun(kind: .short, steps: steps(2)).passesMissingTargets)
    }

    // MARK: Launch flag

    private func freshDefaults() -> UserDefaults {
        let name = "MascotTourTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testFullTourShowsOncePerDevice() {
        let defaults = freshDefaults()
        XCTAssertEqual(TourLaunch.decide(arguments: ["app"], environment: [:], defaults: defaults),
                       TourLaunch.Decision(kind: .full, forced: false))
        TourLaunch.markDone(defaults)
        XCTAssertTrue(defaults.bool(forKey: "asan.tour.full.v2.done"))
        XCTAssertNil(TourLaunch.decide(arguments: ["app"], environment: [:], defaults: defaults))
    }

    func testOldFlagDoesNotHideTheNewTour() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "asan.tour.full.v1.done")
        XCTAssertNotNil(TourLaunch.decide(arguments: ["app"], environment: [:], defaults: defaults))
    }

    func testTestRunsNeverShowTheTourUnlessAsked() {
        let defaults = freshDefaults()
        XCTAssertNil(TourLaunch.decide(arguments: ["app", "--screenshot-signed-in"], environment: [:], defaults: defaults))
        XCTAssertNil(TourLaunch.decide(arguments: ["app", "--no-pet"], environment: [:], defaults: defaults))
        XCTAssertNil(TourLaunch.decide(arguments: ["app"], environment: ["XCTestConfigurationFilePath": "x"], defaults: defaults))

        TourLaunch.markDone(defaults)
        XCTAssertEqual(TourLaunch.decide(arguments: ["app", "--no-pet", "--mascot-tour", "short"], environment: [:], defaults: defaults),
                       TourLaunch.Decision(kind: .short, forced: true))
        XCTAssertEqual(TourLaunch.decide(arguments: ["app", "--mascot-tour", "money"], environment: [:], defaults: defaults)?.kind,
                       .section(.money))
        XCTAssertEqual(TourLaunch.decide(arguments: ["app", "--mascot-tour"], environment: [:], defaults: defaults)?.kind, .full)
    }

    // MARK: Reminders

    private func input(total: Int = 0, done: Int = 0, next: String? = nil) -> MascotReminderInput {
        var input = MascotReminderInput()
        input.plansTotal = total
        input.plansDone = done
        input.nextPlanTitle = next
        return input
    }

    func testPlanLinesFromData() {
        XCTAssertEqual(MascotReminders.lines(input(), focus: .plans).first, "На сегодня планов нет.")
        XCTAssertEqual(MascotReminders.lines(input(total: 3, done: 3), focus: .plans).first, "Все планы на сегодня выполнены.")
        XCTAssertEqual(MascotReminders.lines(input(total: 3, done: 1, next: "Стоматолог"), focus: .plans).first,
                       "На сегодня осталось 2 плана. Ближайший: «Стоматолог».")
        XCTAssertEqual(MascotReminders.lines(input(total: 5, done: 0), focus: .plans).first, "На сегодня осталось 5 планов.")
    }

    func testCurrentSectionLineComesFirstAndEmptyOnesAreLeftOut() {
        var data = input(total: 2, done: 1)
        data.canSpend = "4 500 ₸"
        data.pinnedNote = "Код от подъезда"
        data.workoutPlanned = true

        let money = MascotReminders.lines(data, focus: .money)
        XCTAssertEqual(money.first, "Сегодня можно потратить 4 500 ₸.")
        XCTAssertEqual(money.count, 4)

        let notes = MascotReminders.lines(data, focus: .notes)
        XCTAssertEqual(notes.first, "Заметка закреплена: «Код от подъезда».")

        let workout = MascotReminders.lines(data, focus: .workout)
        XCTAssertEqual(workout.first, "Сегодня тренировка по программе, ещё не начата.")

        let bare = MascotReminders.lines(input(), focus: .money)
        XCTAssertEqual(bare, ["На сегодня планов нет.", "Сегодня ещё без тренировки."])
    }

    func testWorkoutLinePrefersTheRunningWorkout() {
        var data = input()
        data.workoutDone = true
        XCTAssertEqual(MascotReminders.lines(data, focus: .workout).first, "Тренировка сегодня уже есть.")
        data.workoutActive = true
        XCTAssertEqual(MascotReminders.lines(data, focus: .workout).first, "Идёт тренировка: таймер на вкладке «Тренировка».")
    }

    func testLongTitlesAreCut() {
        let long = String(repeating: "а", count: 60)
        let cut = MascotReminders.short(long)
        XCTAssertEqual(cut.count, 32)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertEqual(MascotReminders.short("  Хлеб "), "Хлеб")
    }

    // MARK: Reactions

    func testPlanReactionOnlyForOneMoreDone() {
        let before = PlanDaySummary(done: 1, total: 3, open: [PlanOpenItem(id: "a", title: "Хлеб"), PlanOpenItem(id: "b", title: "Почта")])
        let after = PlanDaySummary(done: 2, total: 3, open: [PlanOpenItem(id: "b", title: "Почта")])
        XCTAssertEqual(MascotReactions.plan(old: before, new: after), "Готово: «Хлеб». Осталось 1 план.")

        let last = PlanDaySummary(done: 3, total: 3, open: [])
        XCTAssertEqual(MascotReactions.plan(old: after, new: last), "Готово: «Почта». На сегодня всё.")

        let added = PlanDaySummary(done: 2, total: 4, open: [])
        XCTAssertNil(MascotReactions.plan(old: before, new: added), "a new plan or a reload is not an event")
        XCTAssertNil(MascotReactions.plan(old: after, new: before), "an undone plan is not cheered")
    }

    func testWorkoutReactionOnlyWhenARunningWorkoutCompletes() {
        XCTAssertNotNil(MascotReactions.workout(old: .working, new: .complete))
        XCTAssertNil(MascotReactions.workout(old: nil, new: .complete), "a restored finished workout is not an event")
        XCTAssertNil(MascotReactions.workout(old: .complete, new: .complete))
        XCTAssertNil(MascotReactions.workout(old: .working, new: nil))
    }

    func testExpenseReactionOnlyForOneHandEnteredExpense() {
        let old = [FinanceRecord(id: "a", kind: "expense", title: "Кофе", amountMinor: 1_200_00)]
        let coffee = FinanceRecord(id: "b", kind: "expense", title: "Обед", amountMinor: 3_500_00)
        let line = MascotReactions.expense(old: old, new: old + [coffee])
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.hasPrefix("Трата записана: «Обед»") == true)

        let income = FinanceRecord(id: "c", kind: "income", title: "Зарплата", amountMinor: 1)
        XCTAssertNil(MascotReactions.expense(old: old, new: old + [income]))

        var imported = coffee
        imported.importId = "statement-1"
        XCTAssertNil(MascotReactions.expense(old: old, new: old + [imported]))
        XCTAssertNil(MascotReactions.expense(old: [], new: old + [coffee]), "a statement or a sync adds many at once")
    }
}
