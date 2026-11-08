import XCTest
@testable import SanPlan

/// After a pause Apple Speech may begin a fresh transcript. The words said before the pause must stay in the field.
@MainActor
final class DictationContinuityTests: XCTestCase {
    func testTextBeforePauseStaysWhenRecogniserStartsOver() {
        let drafts = InputDrafts()
        drafts.beginDictation(into: .plans)
        drafts.applySpeech("купить", to: .plans)
        drafts.applySpeech("купить хлеб", to: .plans)
        // Pause: the recogniser's next transcript holds only the new words.
        drafts.applySpeech("молоко", to: .plans)
        drafts.applySpeech("молоко и сыр", to: .plans)
        XCTAssertEqual(drafts.plans, "купить хлеб молоко и сыр")
    }

    func testSeveralPausesKeepEverything() {
        let drafts = InputDrafts()
        drafts.edit("Завтра", for: .plans)
        drafts.beginDictation(into: .plans)
        drafts.applySpeech("встреча в 10", to: .plans)
        drafts.applySpeech("позвонить маме", to: .plans)
        drafts.applySpeech("спорт", to: .plans)
        XCTAssertEqual(drafts.plans, "Завтра встреча в 10 позвонить маме спорт")
    }

    func testCorrectionsAreNotTreatedAsNewStart() {
        let drafts = InputDrafts()
        drafts.beginDictation(into: .plans)
        drafts.applySpeech("в пятницу спорт зал", to: .plans)
        drafts.applySpeech("в пятницу спортзал", to: .plans)
        XCTAssertEqual(drafts.plans, "в пятницу спортзал")
    }

    func testStartsOverRules() {
        XCTAssertTrue(InputDrafts.startsOver(previous: "купить хлеб", next: "молоко"))
        XCTAssertFalse(InputDrafts.startsOver(previous: "при", next: "привет"), "Longer text extends")
        XCTAssertFalse(InputDrafts.startsOver(previous: "привет как", next: "привет"), "Same opening word, small drop")
        XCTAssertFalse(InputDrafts.startsOver(previous: "спорт зал завтра", next: "спортзал завтра"))
        XCTAssertFalse(InputDrafts.startsOver(previous: "потратил две тысячи", next: "потратил 2000"))
        XCTAssertTrue(InputDrafts.startsOver(previous: "встреча с аскаром в офисе", next: "встреча"),
                      "The same first word again after a long phrase is a new phrase")
        XCTAssertTrue(InputDrafts.startsOver(previous: "купить", next: "молоко и хлеб"), "A longer new phrase also starts over")
        XCTAssertTrue(InputDrafts.startsOver(previous: "встреча в 10", next: "позвонить маме"))
        XCTAssertFalse(InputDrafts.startsOver(previous: "тут", next: "тот хлеб"), "One similar word is a correction")
        XCTAssertFalse(InputDrafts.startsOver(previous: "", next: "молоко"))
        XCTAssertFalse(InputDrafts.startsOver(previous: "молоко", next: ""))
    }

    func testNewDictationDoesNotReuseOldTranscript() {
        let drafts = InputDrafts()
        drafts.beginDictation(into: .plans)
        drafts.applySpeech("купить хлеб", to: .plans)
        drafts.endDictation(into: .plans)
        drafts.beginDictation(into: .plans)
        drafts.applySpeech("молоко", to: .plans)
        XCTAssertEqual(drafts.plans, "купить хлеб молоко")
        drafts.applySpeech("молоко и сыр", to: .plans)
        XCTAssertEqual(drafts.plans, "купить хлеб молоко и сыр", "Base is the field text at start, not doubled")
    }

    func testResultAfterStopIsIgnored() {
        let drafts = InputDrafts()
        drafts.beginDictation(into: .plans)
        drafts.applySpeech("купить хлеб", to: .plans)
        drafts.endDictation(into: .plans)
        drafts.applySpeech("молоко", to: .plans)
        XCTAssertEqual(drafts.plans, "купить хлеб")
    }
}
