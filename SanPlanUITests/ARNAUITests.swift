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
        static let moneyComposer = "Например: потратил 2500 на обед"
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
        XCTAssertTrue(text("ARNA").exists, "ARNA wordmark missing on the login screen")
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
        field.tap()
        field.typeText("потратил 2500 на обед \(token)")
        XCTAssertTrue(waitUntil(5) { self.value(of: field).contains(token) },
                      "Typed text did not reach the money field; value: \(value(of: field))")
        hideKeyboardIfNeeded()

        let parse = button("Разобрать")
        scrollTo(parse)
        parse.tap()

        XCTAssertTrue(text("Проверь перед добавлением").waitForExistence(timeout: 5), "Review section did not appear after parsing")
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
        field.tap()
        field.typeText("черновик \(token)")
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
        field.tap()
        field.typeText("встреча \(token)")
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
        XCTAssertTrue(exactButton("Завершить досрочно").exists)

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
        dismissSystemAlertIfPresent(timeout: 5) // AlarmKit asks on the first rest.

        XCTAssertTrue(text("Отдых").waitForExistence(timeout: 5), "Rest phase did not start")
        XCTAssertTrue(button("Пропустить отдых").exists, "Skip rest control missing")
        XCTAssertTrue(exactButton("Пауза").exists, "Pause control missing")
        XCTAssertTrue(exactButton("Добавить 60 секунд").exists, "+60 s control missing")
        let plus30 = exactButton("Добавить 30 секунд")
        XCTAssertTrue(plus30.exists, "+30 s control missing")

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
        XCTAssertTrue(text("Жим лёжа").exists, "Seeded exercise name missing")
        XCTAssertTrue(text("Подход 1 из 4").exists, "Set counter missing")
        XCTAssertTrue(text("Время подхода").exists, "Set stopwatch caption missing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "В прошлый раз")).firstMatch.exists,
                      "«В прошлый раз» missing")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Добавить подход")).firstMatch.exists, "Add-set control missing")
        XCTAssertTrue(button("Подход сделан, отдых").exists, "«Подход сделан, отдых» missing")

        // The finish dialog opens and can be cancelled without changing the workout.
        let finish = exactButton("Завершить досрочно")
        XCTAssertTrue(finish.exists)
        finish.tap()
        let confirm = exactButton("Завершить")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Finish confirmation did not appear")
        // iOS 26 shows the dialog as a popover without the cancel button; a tap outside cancels it.
        let keepGoing = exactButton("Продолжить тренировку")
        if keepGoing.exists {
            keepGoing.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        }
        XCTAssertTrue(waitUntil(5) { !self.exactButton("Завершить").exists }, "The finish dialog did not close")
        XCTAssertTrue(text("Рабочий подход").exists, "Cancelling the dialog changed the workout")
    }

    // MARK: - 8. Settings

    @MainActor
    func test09_SettingsOpenAndShowWorkoutDefaults() {
        launch(tab: 0)
        assertTodayVisible()

        let gear = exactButton("Настройки")
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()

        XCTAssertTrue(text("Учетная запись").waitForExistence(timeout: 5), "Settings sheet did not open")
        let restBetweenExercises = text("Отдых между упражнениями")
        scrollTo(restBetweenExercises)
        XCTAssertTrue(text("Подходов").exists, "Default sets row missing")
        XCTAssertTrue(text("Отдых между подходами").exists, "Default rest row missing")
        XCTAssertTrue(exactButton("Больше: Подходов").exists)
        XCTAssertTrue(exactButton("Меньше: Подходов").exists)
        XCTAssertTrue(text("Применяется к новым упражнениям. Уже добавленные не меняются.").exists)

        let close = exactButton("Закрыть настройки")
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(waitUntil(5) { !self.text("Учетная запись").exists }, "Settings sheet did not close")
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
        field.tap()
        field.typeText("заметка \(token)")
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
        again.tap()
        again.typeText("созвон \(token) завтра в 10")
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
            self.app.buttons["statement-import"].exists || self.app.buttons["clean-header"].exists
        }
        XCTAssertTrue(shown, "Money screen not shown (no statement import, no «Чистыми» header)", file: file, line: line)
        XCTAssertTrue(text("Деньги").exists, "Money heading missing", file: file, line: line)
        XCTAssertTrue(exactButton("Добавить запись").exists, "Money «+» button missing", file: file, line: line)
        if app.buttons["clean-header"].exists {
            for tab in ["Обзор", "План", "Операции"] {
                XCTAssertTrue(exactButton(tab).exists, "Money tab «\(tab)» missing", file: file, line: line)
            }
        }
    }

    @MainActor
    private func assertPlansVisible(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(composerField(Labels.plansComposer).waitForExistence(timeout: 10), "Plans composer not shown", file: file, line: line)
        XCTAssertTrue(exactButton("Открыть настройки").exists, "Plans settings button missing", file: file, line: line)
        XCTAssertTrue(text("Планы").exists, "Plans heading missing", file: file, line: line)
    }

    @MainActor
    private func assertWorkoutVisible(file: StaticString = #filePath, line: UInt = #line) {
        let shown = waitUntil(10) {
            self.button("Добавить упражнение").exists
                || self.exactButton("Изменить").exists
                || self.exactButton("Завершить досрочно").exists
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

    @MainActor
    private func openTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        hideKeyboardIfNeeded()
        let tab = app.tabBars.buttons[title]
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

    /// The operations feed is collapsed by default; opens it unless it is open already.
    @MainActor
    private func expandOperationsFeed(file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.buttons["operations-feed-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Operations feed row missing", file: file, line: line)
        if !app.textFields["operations-search"].exists {
            scrollTo(toggle, file: file, line: line)
            toggle.tap()
        }
        XCTAssertTrue(app.textFields["operations-search"].waitForExistence(timeout: 5),
                      "Operations feed did not open", file: file, line: line)
    }

    /// Opens the Money composer from the empty state, the «+» button or an unfinished draft.
    @MainActor
    private func openMoneyComposer(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let field = composerField(Labels.moneyComposer)
        if field.waitForExistence(timeout: 2) { return field }

        let first = button("Добавить первую запись")
        let another = exactButton("Добавить запись")
        let resume = button("Продолжить черновик")
        XCTAssertTrue(waitUntil(5) { first.exists || another.exists || resume.exists },
                      "No way to open the money composer", file: file, line: line)
        let opener = first.exists ? first : (another.exists ? another : resume)
        scrollTo(opener, file: file, line: line)
        opener.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Money composer field did not appear", file: file, line: line)
        return field
    }

    @MainActor
    private func hideKeyboardIfNeeded() {
        let bar = exactButton(Labels.hideKeyboard)
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
        let tabBar = app.tabBars.firstMatch
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
        let finishEarly = exactButton("Завершить досрочно")
        XCTAssertTrue(finishEarly.waitForExistence(timeout: 5))
        finishEarly.tap()
        let confirm = exactButton("Завершить")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Finish confirmation did not appear")
        confirm.tap()
    }

    /// A workout left running by an earlier failed test would hide the program; end it first.
    @MainActor
    private func endLeftoverWorkoutIfNeeded() {
        if exactButton("Завершить досрочно").exists {
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
