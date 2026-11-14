import XCTest
@testable import SanPlan

final class AlertSoundTests: XCTestCase {
    func testStoredRoundTrip() {
        for choice in [AlertSoundChoice.system, .builtin("arna-tone-01-pulse.caf"), .custom("custom-ab12.m4a")] {
            XCTAssertEqual(AlertSoundChoice(stored: choice.stored), choice)
        }
    }

    func testUnknownOrEmptyStoredIsSystem() {
        XCTAssertEqual(AlertSoundChoice(stored: nil), .system)
        XCTAssertEqual(AlertSoundChoice(stored: ""), .system)
        XCTAssertEqual(AlertSoundChoice(stored: "builtin:"), .system)
        XCTAssertEqual(AlertSoundChoice(stored: "weird"), .system)
    }

    func testMissingFileFallsBackToSystem() {
        let b = AlertSoundChoice.builtin("arna-tone-01-pulse.caf")
        XCTAssertEqual(b.resolved(builtinExists: { _ in false }, customExists: { _ in true }), .system)
        XCTAssertEqual(b.resolved(builtinExists: { _ in true }, customExists: { _ in false }), b)
        let c = AlertSoundChoice.custom("custom-1.mp3")
        XCTAssertEqual(c.resolved(builtinExists: { _ in true }, customExists: { _ in false }), .system)
        XCTAssertEqual(c.resolved(builtinExists: { _ in false }, customExists: { _ in true }), c)
        XCTAssertNil(AlertSoundChoice.system.fileName)
        XCTAssertEqual(c.fileName, "custom-1.mp3")
    }

    func testSyncNewestWins() {
        XCTAssertEqual(AlertSoundSync.decide(localStored: "system", localAt: 0, remoteStored: nil, remoteAt: 0), .none)
        XCTAssertEqual(AlertSoundSync.decide(localStored: "custom:a.mp3", localAt: 5, remoteStored: nil, remoteAt: 9), .push)
        XCTAssertEqual(AlertSoundSync.decide(localStored: "system", localAt: 5, remoteStored: "system", remoteAt: 9), .none)
        XCTAssertEqual(AlertSoundSync.decide(localStored: "system", localAt: 5, remoteStored: "builtin:x.caf", remoteAt: 9), .apply("builtin:x.caf"))
        XCTAssertEqual(AlertSoundSync.decide(localStored: "system", localAt: 9, remoteStored: "builtin:x.caf", remoteAt: 5), .push)
    }

    func testBuiltinNamesAndTitles() {
        let names = AlertSoundLibrary.builtinNames(in: ["arna-tone-02-morning-bell.caf", "other.caf", "arna-tone-01-pulse.wav", "arna-tone-03.txt", "arna-tone-03.m4a"])
        XCTAssertEqual(names, ["arna-tone-01-pulse.wav", "arna-tone-02-morning-bell.caf", "arna-tone-03.m4a"])
        XCTAssertEqual(AlertSoundLibrary.title(forBuiltin: "arna-tone-02-morning-bell.caf"), "Morning bell")
        XCTAssertEqual(AlertSoundLibrary.title(forBuiltin: "arna-tone-03.m4a"), "Тон 3")
    }

    func testImportPlanAndNames() {
        XCTAssertEqual(AlertSoundImport.plan(duration: 12), .copy)
        XCTAssertEqual(AlertSoundImport.plan(duration: 30), .copy)
        XCTAssertEqual(AlertSoundImport.plan(duration: 95), .trim)
        XCTAssertEqual(AlertSoundImport.storedName(id: "ab", original: "My Song.MP3", plan: .copy), "custom-ab.mp3")
        XCTAssertEqual(AlertSoundImport.storedName(id: "ab", original: "My Song.mp3", plan: .trim), "custom-ab.m4a")
        XCTAssertTrue(AlertSoundImport.isSupported("a.wav"))
        XCTAssertFalse(AlertSoundImport.isSupported("a.pdf"))
    }

    func testSettingsKeepsChoiceAndFallsBackWhenFileMissing() async {
        let defaults = UserDefaults(suiteName: "alert-sound-test-\(UUID().uuidString)")!
        XCTAssertNil(AlertSoundSettings.restAlarmSoundName(defaults: defaults))
        defaults.set("custom:missing-file.mp3", forKey: AlertSoundSettings.restKey)
        XCTAssertNil(AlertSoundSettings.restAlarmSoundName(defaults: defaults))
        let settings = await AlertSoundSettings(defaults: defaults, now: { 42 })
        await settings.setRest(.builtin("arna-tone-01-pulse.caf"))
        let stored = defaults.string(forKey: AlertSoundSettings.restKey)
        XCTAssertEqual(stored, "builtin:arna-tone-01-pulse.caf")
    }

    func testVolumeStepsPickFileWithFallbackToFullFile() {
        XCTAssertEqual(AlertSoundVolume.normalized(nil), 100)
        XCTAssertEqual(AlertSoundVolume.normalized(0), 100)
        XCTAssertEqual(AlertSoundVolume.normalized(50), 60)
        XCTAssertEqual(AlertSoundVolume.normalized(10), 20)
        XCTAssertEqual(AlertSoundVolume.candidates(base: "arna-tone-01-kalimba.m4a", percent: 100), ["arna-tone-01-kalimba.m4a"])
        XCTAssertEqual(AlertSoundVolume.candidates(base: "arna-tone-01-kalimba.m4a", percent: 35), ["arna-tone-01-kalimba-v35.m4a", "arna-tone-01-kalimba.m4a"])
        XCTAssertEqual(AlertSoundVolume.candidates(base: "custom-ab.mp3", percent: 60), ["custom-ab-v60.mp3", "custom-ab-v60.m4a", "custom-ab.mp3"])
        let all: Set<String> = ["a.m4a", "a-v60.m4a"]
        XCTAssertEqual(AlertSoundVolume.fileName(base: "a.m4a", percent: 60, exists: all.contains), "a-v60.m4a")
        XCTAssertEqual(AlertSoundVolume.fileName(base: "a.m4a", percent: 20, exists: all.contains), "a.m4a")
        XCTAssertNil(AlertSoundVolume.fileName(base: "b.m4a", percent: 20, exists: all.contains))
    }

    func testVariantsAreNotListedAndTitlesAreRussian() {
        let files = ["arna-tone-01-kalimba.m4a", "arna-tone-01-kalimba-v60.m4a", "arna-tone-01-kalimba-v35.m4a", "arna-tone-01-kalimba-v20.m4a", "arna-tone-02-piano.m4a", "arna-tone-02-piano-v20.m4a", "arna-tone-03-savepoint.m4a"]
        XCTAssertEqual(AlertSoundLibrary.builtinNames(in: files), ["arna-tone-01-kalimba.m4a", "arna-tone-02-piano.m4a", "arna-tone-03-savepoint.m4a"])
        XCTAssertEqual(AlertSoundLibrary.title(forBuiltin: "arna-tone-01-kalimba.m4a"), "Калимба")
        XCTAssertEqual(AlertSoundLibrary.title(forBuiltin: "arna-tone-02-piano.m4a"), "Фортепиано")
        XCTAssertEqual(AlertSoundLibrary.title(forBuiltin: "arna-tone-03-savepoint.m4a"), "Точка сохранения")
    }

    func testVolumeSyncNewestWins() {
        XCTAssertEqual(AlertSoundVolume.decide(localPercent: 100, localAt: 0, remotePercent: nil, remoteAt: 0), .none)
        XCTAssertEqual(AlertSoundVolume.decide(localPercent: 35, localAt: 5, remotePercent: nil, remoteAt: 9), .push)
        XCTAssertEqual(AlertSoundVolume.decide(localPercent: 100, localAt: 5, remotePercent: 60, remoteAt: 9), .apply("60"))
        XCTAssertEqual(AlertSoundVolume.decide(localPercent: 100, localAt: 9, remotePercent: 60, remoteAt: 5), .push)
    }
}
