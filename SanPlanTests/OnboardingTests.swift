import XCTest
import CryptoKit
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
        XCTAssertEqual(tour.step, .spheres)
        tour.apply(.skip)
        XCTAssertTrue(tour.finished, "три шага: вкладки, напоминание, сферы")
        XCTAssertNil(tour.step)
        XCTAssertEqual(tour.results[.tabs], .done)
        XCTAssertEqual(tour.results[.spheres], .skipped)
        XCTAssertEqual(OnboardingStep.allCases.count, 3)

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

    private func settingsStore(_ server: MemoryVaultTransport, key: SymmetricKey, folder: String) -> (AppSettingsStore, VaultCollection<AppSettingsRecord>) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-settings-\(UUID().uuidString)").appendingPathComponent(folder)
        let c = VaultCollection<AppSettingsRecord>(collection: "settings", policy: .newest, idPrefix: "s", baseDirectory: base)
        c.syncDelay = .seconds(3600)
        c.attach(account: "acc1", key: key, transport: server)
        let store = AppSettingsStore()
        store.setCollection(c)
        return (store, c)
    }

    /// Флаг «тур пройден» общий для аккаунта: второе устройство тур не показывает и не мигает им, пока настройки не пришли.
    func testTourWaitsForTheAccountSettingsAndHonoursAnotherDevice() async {
        let server = MemoryVaultTransport(), key = SymmetricKey(size: .bits256)
        let (s1, c1) = settingsStore(server, key: key, folder: "one")
        let m1 = model()
        m1.attach(settings: s1)
        m1.accountChanged("a@example.com")
        XCTAssertFalse(m1.isPresented, "настройки аккаунта ещё не пришли")
        await c1.sync()
        m1.settingsChanged()
        XCTAssertTrue(m1.isPresented, "новый аккаунт видит тур")
        m1.complete()
        XCTAssertTrue(s1.onboardingDone)
        await c1.sync()
        XCTAssertNotNil(server.records[AppSettingsStore.recordID], "флаг ушёл в запись s-app-settings")

        let (s2, c2) = settingsStore(server, key: key, folder: "two")
        let m2 = model()
        m2.attach(settings: s2)
        m2.accountChanged("a@example.com")
        XCTAssertFalse(m2.isPresented)
        await c2.sync()
        m2.settingsChanged()
        XCTAssertFalse(m2.isPresented, "на другом устройстве тур уже пройден")
        XCTAssertTrue(m2.isDone(for: "a@example.com"))
    }

    func testTheDeviceFlagMovesIntoTheAccountOnce() async {
        let server = MemoryVaultTransport(), key = SymmetricKey(size: .bits256)
        let defaults = UserDefaults(suiteName: "onboarding-move-\(UUID().uuidString)")!
        let old = OnboardingModel(defaults: defaults)
        old.accountChanged("a@example.com")
        old.complete()

        let (settings, collection) = settingsStore(server, key: key, folder: "move")
        let m = OnboardingModel(defaults: defaults)
        m.attach(settings: settings)
        m.accountChanged("a@example.com")
        await collection.sync()
        m.settingsChanged()
        XCTAssertFalse(m.isPresented)
        XCTAssertTrue(settings.onboardingDone, "флаг устройства перенесён в аккаунт")
    }

    func testRequestTourDoesNotResetTheAccountFlag() async {
        let server = MemoryVaultTransport(), key = SymmetricKey(size: .bits256)
        let (settings, collection) = settingsStore(server, key: key, folder: "again")
        let m = model()
        m.attach(settings: settings)
        m.accountChanged("a@example.com")
        await collection.sync()
        m.settingsChanged()
        m.complete()
        m.requestTour()
        XCTAssertTrue(m.isPresented)
        XCTAssertTrue(settings.onboardingDone, "другие устройства тур снова не увидят")
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
