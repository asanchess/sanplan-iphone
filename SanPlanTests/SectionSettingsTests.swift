import XCTest
@testable import SanPlan

/// «Что ведём?» and the section switches: per account, «Сегодня» always on, the choice survives a relaunch.
@MainActor
final class SectionSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "SectionSettingsTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testFirstSignInAsksOnceAndKeepsTheAnswer() {
        let settings = SectionSettings(defaults: defaults)
        settings.attach(email: "a@example.com")
        XCTAssertTrue(settings.needsChoice)
        XCTAssertEqual(settings.visibleTabs, MainTab.ordered, "everything is on until the person answers")

        settings.choose(keep: [.plans, .notes])
        XCTAssertFalse(settings.needsChoice)
        XCTAssertEqual(settings.visibleTabs, [.today, .plans, .notes])

        // The next launch: no question, the same tabs.
        let again = SectionSettings(defaults: defaults)
        again.attach(email: "A@example.com ")
        XCTAssertFalse(again.needsChoice)
        XCTAssertEqual(again.hidden, [.money, .workout])
    }

    func testAnotherAccountHasItsOwnChoice() {
        let settings = SectionSettings(defaults: defaults)
        settings.attach(email: "a@example.com")
        settings.choose(keep: [])
        settings.detach()
        XCTAssertTrue(settings.hidden.isEmpty, "sign-out forgets the loaded choice")

        settings.attach(email: "b@example.com")
        XCTAssertTrue(settings.needsChoice)
        XCTAssertTrue(settings.hidden.isEmpty)
    }

    func testTodayCannotBeTurnedOffAndSwitchesAreSaved() {
        let settings = SectionSettings(defaults: defaults)
        settings.attach(email: "a@example.com")
        settings.choose(keep: Set(SectionSettings.optional))
        settings.set(.today, on: false)
        XCTAssertTrue(settings.isOn(.today))

        settings.set(.money, on: false)
        XCTAssertFalse(settings.isOn(.money))
        settings.set(.money, on: true)
        settings.set(.workout, on: false)

        let again = SectionSettings(defaults: defaults)
        again.attach(email: "a@example.com")
        XCTAssertEqual(again.hidden, [.workout])
    }

    func testUITestSignInDoesNotAsk() {
        let settings = SectionSettings(defaults: defaults)
        settings.attach(email: "a@example.com", ask: false)
        XCTAssertFalse(settings.needsChoice)
    }

    func testLaunchArgumentsStayInMemory() {
        let settings = SectionSettings(defaults: defaults)
        settings.applyLaunchArguments(["app", "--screenshot-sections", "plans,notes", "--sections-choice"])
        XCTAssertEqual(settings.hidden, [.money, .workout])
        XCTAssertTrue(settings.needsChoice)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?.keys.first { $0.hasPrefix("asan.sections") })
    }

    func testStoredByNameNotByTabNumber() {
        XCTAssertEqual(SectionSettings.encode([.notes, .money]), "money,notes")
        XCTAssertEqual(SectionSettings.decode("money,notes,bogus,today"), [.money, .notes])
        XCTAssertEqual(SectionSettings.decode(nil), [])
    }

    func testMascotSaysNothingAboutAHiddenSection() {
        var input = MascotReminderInput()
        input.canSpend = "5 000 ₸"
        input.pinnedNote = "Список покупок"
        let all = MascotReminders.lines(input, focus: .today)
        XCTAssertTrue(all.contains { $0.contains("потратить") })
        let lines = MascotReminders.lines(input, focus: .today, hidden: [.money, .workout, .plans])
        XCTAssertEqual(lines, ["Заметка закреплена: «Список покупок»."])
    }
}
