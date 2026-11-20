import XCTest
@testable import SanPlan

final class NoteRichTextTests: XCTestCase {
    func testParsesAndWritesEveryMarkerBack() {
        let text = "# Покупки\n- [ ] хлеб\n- [x] молоко\n• сыр\n1. первое\n2. второе\nпросто текст\n2024. год"
        let lines = NoteLists.parse(text)
        XCTAssertEqual(lines.map(\.style), [.heading, .check(false), .check(true), .bullet, .number(1), .number(2), .plain, .plain])
        XCTAssertEqual(lines[1].body, "хлеб")
        XCTAssertEqual(NoteLists.text(lines), text, "plain text round-trips, so the web keeps reading «- [ ]»")
    }

    func testReturnContinuesNumbersFromTwo() {
        let lines = [NoteLine(.number(1), "хлеб")]
        let result = NoteLists.pressReturn(lines, at: NoteCursor(line: 0, column: 4))
        XCTAssertEqual(result.lines, [NoteLine(.number(1), "хлеб"), NoteLine(.number(2), "")])
        XCTAssertEqual(result.cursor, NoteCursor(line: 1, column: 0))
    }

    func testReturnContinuesChecklistUnticked() {
        let lines = [NoteLine(.check(true), "хлеб")]
        let result = NoteLists.pressReturn(lines, at: NoteCursor(line: 0, column: 4))
        XCTAssertEqual(result.lines[1], NoteLine(.check(false), ""))
    }

    func testReturnOnEmptyItemEndsTheList() {
        let lines = [NoteLine(.bullet, "сыр"), NoteLine(.bullet, "")]
        let result = NoteLists.pressReturn(lines, at: NoteCursor(line: 1, column: 0))
        XCTAssertEqual(result.lines, [NoteLine(.bullet, "сыр"), NoteLine(.plain, "")])
        XCTAssertEqual(result.cursor, NoteCursor(line: 1, column: 0))
    }

    func testReturnInTheMiddleSplitsAndRenumbers() {
        let lines = [NoteLine(.number(1), "хлебмолоко"), NoteLine(.number(2), "сыр")]
        let result = NoteLists.pressReturn(lines, at: NoteCursor(line: 0, column: 4))
        XCTAssertEqual(result.lines, [NoteLine(.number(1), "хлеб"), NoteLine(.number(2), "молоко"), NoteLine(.number(3), "сыр")])
    }

    func testReturnAfterHeadingIsPlainText() {
        let result = NoteLists.pressReturn([NoteLine(.heading, "План")], at: NoteCursor(line: 0, column: 4))
        XCTAssertEqual(result.lines[1].style, .plain)
    }

    func testReturnNeverSplitsAnEmoji() {
        let result = NoteLists.pressReturn([NoteLine(.bullet, "a👍b")], at: NoteCursor(line: 0, column: 2))
        XCTAssertEqual(result.lines.map(\.body), ["a", "👍b"])
    }

    func testToolSwitchesStyleOnAndOff() {
        let lines = [NoteLine(.plain, "хлеб"), NoteLine(.bullet, "сыр")]
        let checked = NoteLists.apply(.check, to: lines, range: 0...1)
        XCTAssertEqual(checked.map(\.style), [.check(false), .check(false)])
        let back = NoteLists.apply(.check, to: checked, range: 0...1)
        XCTAssertEqual(back.map(\.style), [.plain, .plain])
        let numbered = NoteLists.apply(.number, to: lines, range: 0...1)
        XCTAssertEqual(numbered.map(\.style), [.number(1), .number(2)])
    }

    func testCheckToolKeepsTicks() {
        let lines = [NoteLine(.check(true), "хлеб"), NoteLine(.plain, "сыр")]
        XCTAssertEqual(NoteLists.apply(.check, to: lines, range: 0...1).map(\.style), [.check(true), .check(false)])
    }

    func testNumberToolContinuesTheListAbove() {
        let lines = [NoteLine(.number(1), "хлеб"), NoteLine(.plain, "сыр")]
        XCTAssertEqual(NoteLists.apply(.number, to: lines, range: 1...1)[1].style, .number(2))
    }

    func testTitleDropsMarkers() {
        XCTAssertEqual(Note(text: "# Покупки\n• хлеб", createdAt: 1).title, "Покупки")
        XCTAssertEqual(Note(text: "# Покупки\n• хлеб", createdAt: 1).preview, "хлеб")
        XCTAssertEqual(Note(text: "- [ ] позвонить", createdAt: 1).title, "позвонить")
    }

    func testPhotoTokenParsing() {
        let id = "0f8fad5b-d9cb-469f-a165-70867728950e"
        XCTAssertEqual(NotePhotos.id(in: NotePhotos.token(id)), id)
        XCTAssertEqual(NotePhotos.id(in: "  [[photo:\(id)]] "), id)
        XCTAssertNil(NotePhotos.id(in: "смотри [[photo:\(id)]]"))
        XCTAssertNil(NotePhotos.id(in: "[[photo:]]"))
        XCTAssertNil(NotePhotos.id(in: "[[photo:../x]]"))
        XCTAssertEqual(NoteLists.plainLine(NotePhotos.token(id)), "Фото")
    }
}
