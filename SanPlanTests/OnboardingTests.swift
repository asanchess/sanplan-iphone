import XCTest
@testable import SanPlan

/// «Первый запуск»: модель шагов, выбор сфер и флаг «пройден» по аккаунту.
@MainActor
final class OnboardingTests: XCTestCase {
    private func model() -> OnboardingModel {
        OnboardingModel(defaults: UserDefaults(suiteName: "onboarding-tests-\(UUID().uuidString)")!)
    }

    func testFlagIsKeptPerAccount() {
        let m = model()
        m.accountChanged("a@example.com")
        XCTAssertTrue(m.isPresented)
        m.complete()
        XCTAssertFalse(m.isPresented)
        XCTAssertTrue(m.isDone(for: "A@Example.com "), "тот же аккаунт: регистр и пробелы не важны")

        m.accountChanged("b@example.com")
        XCTAssertTrue(m.isPresented, "новый аккаунт видит тур")
        m.complete()

        m.accountChanged("a@example.com")
        XCTAssertFalse(m.isPresented, "пройденный тур не показывается снова")
        m.accountChanged(nil)
        XCTAssertFalse(m.isPresented)
    }

    func testRequestTourResetsOnlyTheCurrentAccount() {
        let m = model()
        m.accountChanged("a@example.com"); m.complete()
        m.accountChanged("b@example.com"); m.complete()
        m.accountChanged("a@example.com")
        m.requestTour()
        XCTAssertTrue(m.isPresented)
        XCTAssertFalse(m.isDone(for: "a@example.com"))
        XCTAssertTrue(m.isDone(for: "b@example.com"))
    }

    func testEmailIsNotWrittenToDefaultsKeys() {
        let suite = "onboarding-keys-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let m = OnboardingModel(defaults: defaults)
        m.accountChanged("secret.person@example.com")
        m.complete()
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(OnboardingModel.keyPrefix) }
        XCTAssertEqual(keys.count, 1)
        XCTAssertFalse(keys.contains { $0.contains("secret") || $0.contains("example") })
    }

    func testEveryStepCanBeSkippedAndSkippingAllFinishes() {
        var tour = OnboardingTour()
        XCTAssertEqual(tour.step, .tabs)
        tour.apply(.next)
        XCTAssertEqual(tour.step, .reminder)
        tour.apply(.skip)
        tour.apply(.back)
        XCTAssertEqual(tour.step, .reminder)
        tour.apply(.skip)
        tour.apply(.skip)
        XCTAssertEqual(tour.step, .key)
        tour.apply(.skip)
        XCTAssertTrue(tour.finished)
        XCTAssertNil(tour.step)
        XCTAssertEqual(tour.results[.tabs], .done)
        XCTAssertEqual(tour.results[.key], .skipped)

        var quick = OnboardingTour()
        quick.apply(.finish)
        XCTAssertTrue(quick.finished)
        var first = OnboardingTour()
        first.apply(.back)
        XCTAssertEqual(first.step, .tabs)
    }

    func testOneLinePerTab() {
        XCTAssertEqual(OnboardingTabs.lines.map(\.tab.title), ["Сегодня", "Деньги", "Планы", "Тренировка", "Заметки"])
        for item in OnboardingTabs.lines {
            XCTAssertLessThan(item.line.count, 90)
            XCTAssertFalse(item.line.contains("!"))
        }
    }

    func testKeyStepFollowsTheExistingKeySession() {
        XCTAssertEqual(OnboardingKeyState.make(.ready), .ready)
        XCTAssertEqual(OnboardingKeyState.make(.needsSetup), .create)
        XCTAssertEqual(OnboardingKeyState.make(.needsRecovery), .enter)
        XCTAssertEqual(OnboardingKeyState.make(.checking), .pending)
        XCTAssertNil(OnboardingKeyState.ready.actionTitle)
        XCTAssertEqual(OnboardingKeyState.create.actionTitle, "Создать ключ")
    }

    func testTwoToThreeSpheresAreChosen() {
        var picked: [String] = []
        for id in ["health", "money", "work", "rest"] { picked = OnboardingSpheres.toggle(picked, id) }
        XCTAssertEqual(picked, ["health", "money", "work"])
        XCTAssertEqual(OnboardingSpheres.toggle(picked, "money"), ["health", "work"])
        XCTAssertFalse(OnboardingSpheres.isReady(["health"]))
        XCTAssertTrue(OnboardingSpheres.chosen(["health"]).isEmpty)
        XCTAssertEqual(OnboardingSpheres.chosen(["rest", "health"]).map(\.id), ["health", "rest"])
        XCTAssertTrue(OnboardingSpheres.hint(["health"]).contains("ещё 1"))
    }
}
