import SwiftUI
import UIKit
import XCTest
@testable import SanPlan

final class InkTests: XCTestCase {
    // MARK: - Размеры и состояния

    func testPosterSizeGrowsWithTypeButStopsAtOnePointThree() {
        XCTAssertEqual(Ink.posterSize(base: 56, scaled: 56), 56)
        XCTAssertEqual(Ink.posterSize(base: 56, scaled: 40), 56, "smaller sizes never shrink below the base")
        XCTAssertEqual(Ink.posterSize(base: 40, scaled: 48), 48)
        XCTAssertEqual(Ink.posterSize(base: 40, scaled: 90), 52, accuracy: 0.001)
    }

    func testMetricsFollowTheSpec() {
        XCTAssertEqual(Ink.Metrics.primaryHeight, 52)
        XCTAssertEqual(Ink.Metrics.secondaryHeight, 48)
        XCTAssertGreaterThanOrEqual(Ink.Metrics.minHit, 44)
        XCTAssertEqual(Ink.Metrics.frameLine, 3)
        XCTAssertEqual(Ink.Metrics.cellLine, 2)
        XCTAssertEqual(Ink.Metrics.ruleLine, 1.5)
        XCTAssertLessThanOrEqual(Ink.Metrics.starCount, 40)
    }

    func testSetStateIsNeverColourOnly() {
        XCTAssertEqual(InkSetState.state(done: true, isCurrent: true), .done)
        XCTAssertEqual(InkSetState.state(done: false, isCurrent: true), .now)
        XCTAssertEqual(InkSetState.state(done: false, isCurrent: false), .todo)
        XCTAssertEqual(InkSetState.now.word, "сейчас")
        XCTAssertEqual(InkSetState.done.word, "сделан")
        XCTAssertEqual(InkSetState.todo.word, "впереди")
        XCTAssertEqual(InkSetState.skipped.word, "пропущен")
    }

    func testStatTilesStackFromTheFirstAccessibilitySize() {
        XCTAssertFalse(InkStatLayout.isStacked(.large))
        XCTAssertFalse(InkStatLayout.isStacked(.xxxLarge))
        XCTAssertTrue(InkStatLayout.isStacked(.accessibility1))
        XCTAssertTrue(InkStatLayout.isStacked(.accessibility5))
    }

    // MARK: - Главная кнопка плана

    func testPrimaryWeekdayIsTodayOtherwiseTheFirstDayOfThePlan() {
        func day(_ weekday: Int) -> WorkoutDayPlan { WorkoutDayPlan(weekday: weekday, exercises: []) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let wednesday = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 11, day: 18, hour: 12))!
        XCTAssertEqual(WorkoutScreen.weekday(of: wednesday), 3)
        XCTAssertEqual(WorkoutScreen.primaryWeekday(in: [day(1), day(3), day(5)], today: wednesday), 3)
        XCTAssertEqual(WorkoutScreen.primaryWeekday(in: [day(2), day(5)], today: wednesday), 2, "a rest day: the first day in the list")
        XCTAssertEqual(WorkoutScreen.primaryWeekday(in: [day(1), day(2)], today: wednesday), 1)
        XCTAssertNil(WorkoutScreen.primaryWeekday(in: [], today: wednesday))
    }

    // MARK: - Шрифты и фон

    func testFontsFallBackToTheSystemWhenTheFilesAreNotBundled() {
        XCTAssertFalse(Ink.Font.available("NoSuchFont-Regular"))
        // Какой бы ни был результат, запрос шрифта не падает и даёт значение.
        _ = Ink.Font.poster(size: 56)
        _ = Ink.Font.text(.body, weight: .bold)
        XCTAssertEqual(Ink.Font.baseSize(.body), 16)
        XCTAssertEqual(Ink.Font.baseSize(.subheadline), 15)
        XCTAssertEqual(Ink.Font.baseSize(.headline), 17)
    }

    func testStarPositionsAreStableAndInsideTheScreen() {
        for index in 0..<Ink.Metrics.starCount {
            let x = InkStarBackground.unit(index, 12.9898)
            let y = InkStarBackground.unit(index, 78.233)
            XCTAssertTrue((0..<1).contains(x) && (0..<1).contains(y))
            XCTAssertEqual(x, InkStarBackground.unit(index, 12.9898), "the same star every redraw")
        }
    }

    // MARK: - Токены и контраст (раздел 2.2)

    private func rgb(_ color: Color, dark: Bool) -> (r: Double, g: Double, b: Double) {
        let trait = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: trait).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func luminance(_ color: Color, dark: Bool) -> Double {
        func channel(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let c = rgb(color, dark: dark)
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    private func contrast(_ a: Color, _ b: Color, dark: Bool) -> Double {
        let first = luminance(a, dark: dark), second = luminance(b, dark: dark)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    func testTokensResolveToTheSpecValuesInBothThemes() {
        func hex(_ color: Color, dark: Bool) -> UInt32 {
            let c = rgb(color, dark: dark)
            return (UInt32((c.r * 255).rounded()) << 16) | (UInt32((c.g * 255).rounded()) << 8) | UInt32((c.b * 255).rounded())
        }
        XCTAssertEqual(hex(Ink.Colors.bg, dark: false), 0xFBFAF5)
        XCTAssertEqual(hex(Ink.Colors.bg, dark: true), 0x0E0B16)
        XCTAssertEqual(hex(Ink.Colors.accent, dark: false), 0x4B2A8C)
        XCTAssertEqual(hex(Ink.Colors.accent, dark: true), 0x7C5CE6)
        XCTAssertEqual(hex(Ink.Colors.accentText, dark: true), 0xB9A2F5)
        XCTAssertEqual(hex(Ink.Colors.spark, dark: false), 0x8E6CF0)
    }

    func testTextPairsKeepTheContrastTheSpecPromises() {
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(contrast(Ink.Colors.fg, Ink.Colors.bg, dark: dark), 7, "fg/bg dark=\(dark)")
            XCTAssertGreaterThanOrEqual(contrast(Ink.Colors.muted, Ink.Colors.bg, dark: dark), 4.5, "muted/bg dark=\(dark)")
            XCTAssertGreaterThanOrEqual(contrast(Ink.Colors.muted, Ink.Colors.soft, dark: dark), 4.5, "muted/soft dark=\(dark)")
            XCTAssertGreaterThanOrEqual(contrast(Ink.Colors.accentText, Ink.Colors.bg, dark: dark), 4.5, "accentText/bg dark=\(dark)")
            XCTAssertGreaterThanOrEqual(contrast(Ink.Colors.accentText, Ink.Colors.soft, dark: dark), 4.5, "accentText/soft dark=\(dark)")
            XCTAssertGreaterThanOrEqual(contrast(Ink.Colors.onAccent, Ink.Colors.accent, dark: dark), 4.5, "onAccent/accent dark=\(dark)")
        }
        // «Космос»: акцент на фоне годится для заливок и границ (3:1), но не для текста.
        XCTAssertGreaterThanOrEqual(contrast(Ink.Colors.accent, Ink.Colors.bg, dark: true), 3)
    }
}
