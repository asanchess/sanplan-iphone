import XCTest

/// End-to-end UI tests for ARNA. The debug launch flags read in RootView.swift skip sign-in
/// (`--screenshot-signed-in`), pick the first tab (`--screenshot-tab N`) and seed a workout
/// (`--screenshot-active-workout <phase>`). They work in Debug builds only.
///
/// Data on the simulator survives between tests (money records, the workout program),
/// so every test accepts both a fresh install and the state an earlier test left behind.
final class ARNAUITests: XCTestCase {

    private var app: XCUIApplication!

    private enum Labels {
        static let moneyComposer = "Новая операция"
        static let plansComposer = "Что запланировать?"
        static let hideKeyboard = "Скрыть клавиатуру"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 1. Login

    @MainActor
    func test01_LoginScreenAppearsWithoutSignedInFixture() {
        launch(signedIn: false)

        // AuthService.loadStatus asks the server first; with no session cookie it ends signed out.
        let google = button("Войти через Google")
        XCTAssertTrue(google.waitForExistence(timeout: 30), "Login screen did not appear")
        XCTAssertTrue(text("A-san").exists, "A-san wordmark missing on the login screen")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Tabs must not show before sign-in")

        let owner = exactButton("Вход для владельца")
        XCTAssertTrue(owner.waitForExistence(timeout: 5))
        owner.tap()

        let password = app.secureTextFields.matching(NSPredicate(format: "label == %@ OR placeholderValue == %@", "Пароль владельца", "Пароль владельца")).firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5), "Owner password field missing")
        let passwordLogin = button("Войти по паролю")
        XCTAssertTrue(passwordLogin.waitForExistence(timeout: 5))
        XCTAssertFalse(passwordLogin.isEnabled, "Password sign-in must stay disabled while the field is empty")
    }

    // MARK: - 2. Tabs

    @MainActor
    func test02_EveryTabOpensFromTheTabBar() {
        launch()

        XCTAssertTrue(text("Сегодня").waitForExistence(timeout: 10), "Today heading missing")
        assertTodayVisible()

        openTab("Деньги")
        assertMoneyVisible()

        openTab("Планы")
        assertPlansVisible()

        openTab("Тренировка")
        assertWorkoutVisible()

        openTab("Заметки")
        XCTAssertTrue(button("Купить домой").waitForExistence(timeout: 5) || text("Купить домой").waitForExistence(timeout: 1), "Seeded note missing")

        openTab("Сегодня")
        assertTodayVisible()
    }

    // MARK: - 3. Money: both file importers present the system picker

    @MainActor
    func test03_MoneyStatementAndVaultImportersPresentDocumentPicker() {
        launch(tab: 1)
        assertMoneyVisible()
        XCTAssertFalse(isDocumentPickerVisible(), "A document picker is already showing before any tap")
        openMoneySection("Операции")

        let statement = app.buttons["statement-import"]
        scrollTo(statement)
        statement.tap()
        XCTAssertTrue(waitUntil(15) { self.isDocumentPickerVisible() },
                      "«Импорт выписки» did not present the document picker")
        dismissDocumentPicker()

        let restore = exactButton("Восстановить из копии")
        scrollTo(restore)
        restore.tap()
        XCTAssertTrue(waitUntil(15) { self.isDocumentPickerVisible() },
                      "«Восстановить из копии» did not present the document picker")
        dismissDocumentPicker()

        // The statement importer still works after the vault one was used.
        scrollTo(statement)
        statement.tap()
        XCTAssertTrue(waitUntil(15) { self.isDocumentPickerVisible() },
                      "«Импорт выписки» stopped presenting the picker after a vault restore attempt")
        dismissDocumentPicker()
    }

    // MARK: - 4. Money: typed expense is saved

    @MainActor
    func test04_MoneyTypedExpenseIsSavedAndSurvivesTabSwitch() {
        launch(tab: 1)
        assertMoneyVisible()
        let token = uniqueToken()

        let field = openMoneyComposer()
        scrollTo(field)
        typeInto(field, "потратил 2500 на обед \(token)")
        XCTAssertTrue(waitUntil(5) { self.value(of: field).contains(token) },
                      "Typed text did not reach the money field; value: \(value(of: field))")
        hideKeyboardIfNeeded()

        // «Добавить» in the bottom bar reads the phrase into drafts.
        let parse = app.buttons["money-add"]
        XCTAssertTrue(parse.waitForExistence(timeout: 5), "Money «Добавить» button missing")
        parse.tap()

        // Parsing may wait for the server before falling back to the phone's own rules.
        XCTAssertTrue(text("Проверь перед добавлением").waitForExistence(timeout: 15), "Review section did not appear after parsing")
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Подтвердить и добавить")).firstMatch
        scrollTo(confirm)
        XCTAssertTrue(confirm.isEnabled, "Confirm is disabled: the parsed draft still has open questions")
        confirm.tap()

        let added = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Добавлено.")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 10), "No success message after confirming")
        // Confirming opens «Операции», where «Добавлено вручную» lists the record before the feed is even opened.
        XCTAssertTrue(recordRow(token).waitForExistence(timeout: 5), "The new expense is not in «Добавлено вручную»")
        openMoneySection("Операции")
        expandOperationsFeed()
        // The feed row itself, not the «Добавлено вручную» card whose label also carries the token.
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND identifier != %@", token, "manual-entries")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5), "Saved expense is not in the operations feed")
        scrollTo(record)

        openTab("Планы")
        assertPlansVisible()
        openTab("Деньги")
        XCTAssertTrue(recordRow(token).waitForExistence(timeout: 5),
                      "Saved expense disappeared after switching tabs (the Операции tab and the open feed must stay)")
    }

    // MARK: - 5. Money: draft survives a tab switch

    @MainActor
    func test05_MoneyDraftSurvivesTabSwitch() {
        launch(tab: 1)
        assertMoneyVisible()
        let token = uniqueToken()

        let field = openMoneyComposer()
        scrollTo(field)
        typeInto(field, "черновик \(token)")
        XCTAssertTrue(waitUntil(5) { self.value(of: field).contains(token) }, "Typed text did not reach the money field")
        hideKeyboardIfNeeded()

        openTab("Сегодня")
        assertTodayVisible()
        openTab("Деньги")

        let again = openMoneyComposer()
        XCTAssertTrue(waitUntil(5) { self.value(of: again).contains(token) },
                      "Money draft was lost after switching tabs; value: \(value(of: again))")
    }

    // MARK: - 6. Plans: draft survives a tab switch

    @MainActor
    func test06_PlansDraftSurvivesTabSwitch() {
        launch(tab: 2)
        assertPlansVisible()
        let token = uniqueToken()

        let field = composerField(Labels.plansComposer)
        scrollTo(field)
        typeInto(field, "встреча \(token)")
        XCTAssertTrue(waitUntil(5) { self.value(of: field).contains(token) }, "Typed text did not reach the plans field")
        hideKeyboardIfNeeded()

        openTab("Тренировка")
        assertWorkoutVisible()
        openTab("Планы")

        let again = composerField(Labels.plansComposer)
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(5) { self.value(of: again).contains(token) },
                      "Plans draft was lost after switching tabs; value: \(value(of: again))")
    }

    // MARK: - 7. Workout

    @MainActor
    func test07_WorkoutRunFromProgramWithRestTimer() {
        launch(tab: 3)
        assertWorkoutVisible()
        endLeftoverWorkoutIfNeeded()

        // Build a one-exercise program when there is none yet.
        let start = button("Начать тренировку")
        if !start.waitForExistence(timeout: 2) {
            let add = button("Добавить упражнение")
            scrollTo(add)
            add.tap()
            let exercise = exactButton("Жим штанги лёжа")
            XCTAssertTrue(exercise.waitForExistence(timeout: 5), "Exercise library did not open")
            exercise.tap()
            let done = button("Готово")
            scrollTo(done)
            done.tap()
        }
        scrollTo(start)
        start.tap()

        // Preparing counts down by itself; skip it when it is still showing.
        let startNow = button("Начать сейчас")
        if startNow.waitForExistence(timeout: 3), startNow.isHittable {
            startNow.tap()
        }
        XCTAssertTrue(text("Рабочий подход").waitForExistence(timeout: 15), "Working set did not start")
        // Nothing is ticked yet, so the finish button on top closes without saving.
        XCTAssertEqual(workoutFinishButton().label, "Закрыть без сохранения", "Top finish button should close without saving before any set")

        let startRest = button("Подход сделан, отдых")
        if !startRest.waitForExistence(timeout: 3) {
            // A one-set exercise has no rest; add a set so one follows.
            let addSet = button("Добавить подход")
            scrollTo(addSet)
            addSet.tap()
            scrollTo(startRest)
        }
        XCTAssertTrue(startRest.waitForExistence(timeout: 5), "«Подход сделан, отдых» missing during a working set")
        startRest.tap()
        // AlarmKit asks on the first rest, sometimes several seconds late on CI; answer it whenever it comes.
        let restLabel = text("Отдых")
        let restStarted = waitUntil(20) {
            self.dismissSystemAlertIfPresent(timeout: 0.5)
            return restLabel.exists
        }
        XCTAssertTrue(restStarted, "Rest phase did not start")
        XCTAssertTrue(button("Пропустить отдых").exists, "Skip rest control missing")
        XCTAssertTrue(exactButton("Пауза").exists, "Pause control missing")
        XCTAssertTrue(exactButton("Добавить 60 секунд").exists, "+60 s control missing")
        let plus30 = exactButton("Добавить 30 секунд")
        XCTAssertTrue(plus30.exists, "+30 s control missing")

        scrollTo(plus30)
        let before = restSeconds()
        XCTAssertNotNil(before, "Rest timer (mm:ss) not found")
        plus30.tap()
        if let before {
            XCTAssertTrue(waitUntil(5) { (self.restSeconds() ?? 0) >= before + 20 },
                          "Rest timer did not grow after +30 s (was \(before), now \(restSeconds() ?? -1))")
        }

        exactButton("Пауза").tap()
        XCTAssertTrue(text("Отдых на паузе").waitForExistence(timeout: 5), "Pause did not take effect")
        XCTAssertTrue(exactButton("Пропустить отдых").exists, "Skip control missing while paused")
        let resume = button("Продолжить")
        XCTAssertTrue(resume.exists)
        resume.tap()
        XCTAssertTrue(text("Отдых").waitForExistence(timeout: 5), "Rest did not resume")

        button("Пропустить отдых").tap()
        XCTAssertTrue(text("Рабочий подход").waitForExistence(timeout: 5), "Skipping rest did not start the next set")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Подход 2 из")).firstMatch.exists,
                      "Set counter did not move to set 2")

        finishWorkoutEarly()
        XCTAssertTrue(text("Тренировка завершена").waitForExistence(timeout: 5), "Summary did not appear after finishing")
        // The first set was ticked by «Подход сделан, отдых», so the workout is kept and the summary closes with «Готово».
        let close = exactButton("Готово")
        scrollTo(close)
        close.tap()
        XCTAssertTrue(button("Начать тренировку").waitForExistence(timeout: 5), "Program overview did not return")
    }

    @MainActor
    func test08_SeededActiveWorkoutShowsControls() {
        launch(tab: 3, activeWorkout: "working")

        XCTAssertTrue(text("Рабочий подход").waitForExistence(timeout: 10), "Seeded working phase not shown")
        // Round 6: the name may sit inside a combined card label, so look for it in any element.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Жим лёжа")).firstMatch.waitForExistence(timeout: 5),
                      "Seeded exercise name missing")
        XCTAssertTrue(text("Подход 1 из 4").exists, "Set counter missing")
        XCTAssertTrue(text("Время подхода").exists, "Set stopwatch caption missing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "В прошлый раз")).firstMatch.exists,
                      "«В прошлый раз» missing")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Добавить подход")).firstMatch.exists, "Add-set control missing")
        XCTAssertTrue(button("Подход сделан, отдых").exists, "«Подход сделан, отдых» missing")

        // Nothing ticked: the top button closes without saving. Tick the set by starting the rest, then it finishes with a question.
        XCTAssertEqual(workoutFinishButton().label, "Закрыть без сохранения", "Top finish button should close without saving before any set")
        button("Подход сделан, отдых").tap()
        dismissSystemAlertIfPresent(timeout: 5) // AlarmKit asks on the first rest.
        XCTAssertTrue(text("Отдых").waitForExistence(timeout: 5), "Rest phase did not start")

        // The finish dialog opens and can be cancelled without changing the workout.
        let finish = workoutFinishButton()
        XCTAssertTrue(waitUntil(5) { finish.label == "Завершить" }, "Top finish button did not switch to «Завершить» after a set")
        finish.tap()
        let confirm = exactButton("Завершить и сохранить")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Finish confirmation did not appear")
        // iOS 26 shows the dialog as a popover without the cancel button; a tap outside cancels it.
        let keepGoing = exactButton("Продолжить тренировку")
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        if keepGoing.exists {
            keepGoing.tap()
        } else if dismissRegion.exists {
            dismissRegion.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)).tap()
        }
        XCTAssertTrue(waitUntil(5) { !self.exactButton("Завершить и сохранить").exists }, "The finish dialog did not close")
        XCTAssertTrue(text("Отдых").exists, "Cancelling the dialog changed the workout")
    }

    // MARK: - 8. Settings

    @MainActor
    func test09_SettingsOpenAndShowWorkoutDefaults() {
        launch(tab: 0)
        assertTodayVisible()

        let gear = exactButton("Профиль и настройки")
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()

        // Round 6: the profile lists settings by section; «Тренировка» holds the workout defaults.
        XCTAssertTrue(text("Электронная почта").waitForExistence(timeout: 10), "Profile sheet did not open")
        let workoutSettings = app.buttons["profile-settings-workout"]
        scrollTo(workoutSettings)
        workoutSettings.tap()

        let restBetweenExercises = text("Отдых между упражнениями")
        scrollTo(restBetweenExercises)
        XCTAssertTrue(text("Подходов").exists, "Default sets row missing")
        XCTAssertTrue(text("Отдых между подходами").exists, "Default rest row missing")
        XCTAssertTrue(exactButton("Больше: Подходов").exists)
        XCTAssertTrue(exactButton("Меньше: Подходов").exists)
        XCTAssertTrue(text("Применяется к новым упражнениям. Уже добавленные не меняются.").exists)

        let back = exactButton("Назад")
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        // The profile root stays in the hierarchy under a pushed page; wait for the pop to finish before closing.
        XCTAssertTrue(waitUntil(5) { !restBetweenExercises.exists }, "Workout settings did not close")

        let close = exactButton("Закрыть профиль")
        // The round-6 profile header scrolls with the list, so bring it back before closing.
        scrollTo(close)
        XCTAssertTrue(waitUntil(5) { close.isHittable }, "Profile close button not reachable")
        close.tap()
        XCTAssertTrue(waitUntil(5) { !self.text("Электронная почта").exists }, "Profile sheet did not close")
    }

    /// The profile closes from its header right after opening (the arc card's stripes once swallowed this tap).
    @MainActor
    func test11_ProfileClosesFromHeader() {
        launch(tab: 0)
        assertTodayVisible()
        let gear = exactButton("Профиль и настройки")
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()
        XCTAssertTrue(text("Электронная почта").waitForExistence(timeout: 10), "Profile sheet did not open")
        let close = exactButton("Закрыть профиль")
        XCTAssertTrue(waitUntil(5) { close.isHittable }, "Profile close button not reachable")
        close.tap()
        XCTAssertTrue(waitUntil(5) { !self.text("Электронная почта").exists }, "Profile sheet did not close from the header")
    }

    // MARK: - 10. Notes and the shared «+»

    @MainActor
    func test10_PlusSavesNoteAndHandsTextToPlans() {
        launch(tab: 0)
        assertTodayVisible()
        let token = uniqueToken()

        let plus = exactButton("Записать")
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "«+» missing on Today")
        plus.tap()
        let field = composerField("Мысль, список, план или трата")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Composer did not open")
        typeInto(field, "заметка \(token)")
        let save = exactButton("Сохранить заметку")
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(waitUntil(5) { !field.exists }, "Composer did not close after saving")

        openTab("Заметки")
        XCTAssertTrue(waitUntil(5) { self.button("заметка \(token)").exists || self.text("заметка \(token)").exists }, "Saved note not in the list")

        // Make a plan: the text lands in the Plans field, nothing is parsed on its own.
        exactButton("Записать").tap()
        let again = composerField("Мысль, список, план или трата")
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        typeInto(again, "созвон \(token) завтра в 10")
        hideKeyboardIfNeeded()
        let makePlan = button("Сделать планом")
        XCTAssertTrue(makePlan.waitForExistence(timeout: 5))
        makePlan.tap()
        assertPlansVisible()
        let plans = composerField(Labels.plansComposer)
        XCTAssertTrue(plans.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(5) { self.value(of: plans).contains("созвон \(token)") }, "Text did not reach the Plans field; value: \(value(of: plans))")
    }

    // MARK: - Launch

    @MainActor
    private func launch(signedIn: Bool = true, tab: Int? = nil, activeWorkout: String? = nil) {
        let app = XCUIApplication()
        var arguments: [String] = []
        if signedIn { arguments.append("--screenshot-signed-in") }
        arguments.append("--no-pet")
        if let tab { arguments += ["--screenshot-tab", String(tab)] }
        if let activeWorkout { arguments += ["--screenshot-active-workout", activeWorkout] }
        app.launchArguments += arguments

        addUIInterruptionMonitor(withDescription: "System permission alert") { alert in
            let deny = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@", "Don", "Не ")).firstMatch
            if deny.exists { deny.tap(); return true }
            if alert.buttons.count > 0 { alert.buttons.element(boundBy: 0).tap(); return true }
            return false
        }

        app.launch()
        self.app = app
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "App did not reach the foreground")
    }

    // MARK: - Screen checks

    @MainActor
    private func assertTodayVisible(file: StaticString = #filePath, line: UInt = #line) {
        let plansAction = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Добавить план", "Все планы")).firstMatch
        XCTAssertTrue(plansAction.waitForExistence(timeout: 10), "Today screen not shown", file: file, line: line)
        XCTAssertTrue(text("Сегодня").exists, "Today heading missing", file: file, line: line)
    }

    @MainActor
    private func assertMoneyVisible(file: StaticString = #filePath, line: UInt = #line) {
        let shown = waitUntil(10) {
            self.app.buttons["statement-import"].exists || self.app.buttons["can-spend-today"].exists
        }
        XCTAssertTrue(shown, "Money screen not shown (no statement import, no «Можно потратить сегодня»)", file: file, line: line)
        XCTAssertTrue(text("Деньги").exists, "Money heading missing", file: file, line: line)
        XCTAssertTrue(app.buttons["money-add"].exists, "Money «Добавить» (the section's «+») missing", file: file, line: line)
        if app.buttons["can-spend-today"].exists {
            for tab in ["Обзор", "План", "Операции"] {
                XCTAssertTrue(exactButton(tab).exists, "Money tab «\(tab)» missing", file: file, line: line)
            }
        }
    }

    @MainActor
    private func assertPlansVisible(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(composerField(Labels.plansComposer).waitForExistence(timeout: 10), "Plans composer not shown", file: file, line: line)
        XCTAssertTrue(exactButton("Профиль и настройки").exists, "Plans profile button missing", file: file, line: line)
        XCTAssertTrue(text("Планы").exists, "Plans heading missing", file: file, line: line)
    }

    @MainActor
    private func assertWorkoutVisible(file: StaticString = #filePath, line: UInt = #line) {
        let shown = waitUntil(10) {
            self.button("Добавить упражнение").exists
                || self.exactButton("Изменить").exists
                || self.app.buttons["workout-finish"].exists
                || self.text("Тренировка завершена").exists
        }
        XCTAssertTrue(shown, "Workout screen not shown (no builder, program, active or finished workout)", file: file, line: line)
        XCTAssertTrue(text("Тренировка").exists, "Workout heading missing", file: file, line: line)
    }

    // MARK: - Element lookup

    @MainActor
    private func button(_ fragment: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    @MainActor
    private func exactButton(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    private func text(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// ComposerField is a vertical-axis TextField; depending on the OS it surfaces as a text field or a text view.
    @MainActor
    private func composerField(_ label: String) -> XCUIElement {
        let types = [XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue].map { NSNumber(value: $0) }
        let predicate = NSPredicate(format: "elementType IN %@ AND (label == %@ OR placeholderValue == %@)", types, label, label)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func recordRow(_ token: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", token)).firstMatch
    }

    @MainActor
    private func value(of element: XCUIElement) -> String {
        (element.value as? String) ?? ""
    }

    /// Cyrillic letters only: no digits (the money parser rejects a second number), no autocorrect target
    /// in an English keyboard, and none of the parser's keywords can form from this alphabet.
    private func uniqueToken() -> String {
        let alphabet = Array("абвгдежзик")
        let stamp = Int(Date().timeIntervalSince1970 * 1000) % 1_000_000
        let digits = String(format: "%06ld", stamp)
        return String(digits.compactMap { $0.wholeNumberValue.map { alphabet[$0] } })
    }

    // MARK: - Interaction helpers

    private func tabIndex(_ title: String) -> Int {
        ["Сегодня": 0, "Деньги": 1, "Планы": 2, "Тренировка": 3, "Заметки": 4][title] ?? -1
    }

    @MainActor
    private func openTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        hideKeyboardIfNeeded()
        let tab = app.buttons["tab-\(tabIndex(title))"]
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
        } else {
            let fallback = exactButton(title)
            XCTAssertTrue(fallback.waitForExistence(timeout: 5), "Tab «\(title)» not found", file: file, line: line)
            fallback.tap()
        }
    }

    /// Picks a tab inside the Money screen; an empty money screen has no tabs and shows everything at once.
    @MainActor
    private func openMoneySection(_ title: String) {
        hideKeyboardIfNeeded()
        let segment = exactButton(title)
        if segment.waitForExistence(timeout: 3) { segment.tap() }
    }

    /// «История операций» starts folded under the statements: opens it (today's day is open) and waits for its search field.
    @MainActor
    private func expandOperationsFeed(file: StaticString = #filePath, line: UInt = #line) {
        let search = app.textFields["operations-search"]
        if !search.exists {
            let header = app.buttons["money-ops-history"]
            scrollTo(header, file: file, line: line)
            header.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5),
                      "Operations feed is not shown", file: file, line: line)
    }

    /// Round 6: the Money composer is the bottom bar «Новая операция», always on screen.
    @MainActor
    private func openMoneyComposer(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let field = composerField(Labels.moneyComposer)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Money composer field «Новая операция» missing", file: file, line: line)
        return field
    }

    @MainActor
    private func hideKeyboardIfNeeded() {
        // The keyboard bar's «Готово» (in the section's colour).
        let bar = app.buttons["kbd-done"]
        if bar.exists && bar.isHittable {
            bar.tap()
        } else if app.keyboards.firstMatch.exists {
            // Screens dismiss the keyboard when the content is dragged down.
            drag(from: 0.30, to: 0.60)
        }
        _ = waitUntil(3) { !self.app.keyboards.firstMatch.exists }
    }

    /// Scrolls with slow drags until the element is fully on screen, above the tab bar and keyboard.
    @MainActor
    private func scrollTo(_ element: XCUIElement, maxDrags: Int = 14, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Element not found: \(element)", file: file, line: line)
        var drags = 0
        while !isOnScreen(element) && drags < maxDrags {
            if element.frame.minY < visibleTop() {
                // Below a pinned header (Money keeps balance, «Можно потратить сегодня» and tabs on top, ~40% of the screen).
                drag(from: 0.50, to: 0.80)
            } else {
                drag(from: 0.80, to: 0.50)
            }
            drags += 1
        }
        XCTAssertTrue(isOnScreen(element), "Could not scroll to element: \(element)", file: file, line: line)
    }

    @MainActor
    private func drag(from startY: CGFloat, to endY: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func visibleTop() -> CGFloat {
        app.windows.firstMatch.frame.minY + 50
    }

    @MainActor
    private func isOnScreen(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard !frame.isEmpty else { return false }
        var bottom = app.windows.firstMatch.frame.maxY
        let tabBar = app.otherElements["arna-tab-bar"]
        if tabBar.exists, !tabBar.frame.isEmpty { bottom = min(bottom, tabBar.frame.minY) }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, !keyboard.frame.isEmpty { bottom = min(bottom, keyboard.frame.minY) }
        guard frame.minY >= visibleTop(), frame.maxY <= bottom - 2 else { return false }
        if element.elementType == .button || element.elementType == .textField || element.elementType == .textView {
            return element.isHittable
        }
        return true
    }

    @MainActor
    @discardableResult
    /// Taps a field until it holds the keyboard, then types; on a slow simulator the first tap can land before focus.
    private func typeInto(_ field: XCUIElement, _ text: String) {
        for _ in 0..<3 {
            field.tap()
            if waitUntil(3, { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }) { break }
        }
        field.typeText(text)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }

    // MARK: - Document picker

    @MainActor
    private func isDocumentPickerVisible() -> Bool {
        let candidates: [XCUIElement] = [
            app.buttons["Cancel"],
            app.navigationBars["Recents"],
            app.navigationBars["Browse"],
            app.buttons["Recents"],
            app.buttons["Browse"],
            app.staticTexts["Recents"],
            app.staticTexts["Browse"]
        ]
        return candidates.contains { $0.exists }
    }

    @MainActor
    private func dismissDocumentPicker(file: StaticString = #filePath, line: UInt = #line) {
        let cancel = app.buttons["Cancel"]
        let close = app.buttons["Close"]
        if cancel.exists {
            cancel.tap()
        } else if close.exists {
            close.tap()
        } else {
            drag(from: 0.12, to: 0.95)
        }
        XCTAssertTrue(waitUntil(10) { !self.isDocumentPickerVisible() }, "Document picker did not close", file: file, line: line)
        XCTAssertTrue(app.buttons["statement-import"].waitForExistence(timeout: 5), "Money screen not back after the picker", file: file, line: line)
    }

    // MARK: - Workout helpers

    @MainActor
    private func restSeconds() -> Int? {
        let timer = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]{2}:[0-9]{2}$")).firstMatch
        guard timer.waitForExistence(timeout: 3) else { return nil }
        let parts = timer.label.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    @MainActor
    private func finishWorkoutEarly() {
        let finish = workoutFinishButton()
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertEqual(finish.label, "Завершить", "A ticked set should make the top button «Завершить»")
        finish.tap()
        let confirm = exactButton("Завершить и сохранить")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Finish confirmation did not appear")
        confirm.tap()
    }

    /// «Завершить» on top of a running workout; «Закрыть без сохранения» until a set is ticked.
    @MainActor
    private func workoutFinishButton() -> XCUIElement {
        app.buttons["workout-finish"]
    }

    /// A workout left running by an earlier failed test would hide the program; end it first.
    @MainActor
    private func endLeftoverWorkoutIfNeeded() {
        let finish = workoutFinishButton()
        if finish.exists {
            if finish.label == "Закрыть без сохранения" {
                finish.tap()
                return
            }
            finishWorkoutEarly()
        }
        // A finished summary closes with «Готово», or «Закрыть без сохранения» when nothing was ticked.
        if text("Тренировка завершена").waitForExistence(timeout: 2) {
            let close = exactButton("Готово").exists ? exactButton("Готово") : exactButton("Закрыть без сохранения")
            scrollTo(close)
            close.tap()
        }
    }

    /// System alerts (AlarmKit permission) belong to SpringBoard; answer «Don't Allow» so no real alarm rings later.
    @MainActor
    private func dismissSystemAlertIfPresent(timeout: TimeInterval) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return }
        let deny = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@", "Don", "Не ")).firstMatch
        if deny.exists {
            deny.tap()
        } else if alert.buttons.count > 0 {
            alert.buttons.element(boundBy: 0).tap()
        }
        _ = waitUntil(5) { !alert.exists }
    }
}
