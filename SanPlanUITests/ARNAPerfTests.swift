import XCTest

/// Performance numbers for the perf pass: launch time, scroll hitches per screen and tab switching.
/// Demo data lives in memory only, so these runs leave nothing behind for ARNAUITests.
/// The mascot stays on: its motion is part of what the owner feels on the phone.
final class ARNAPerfTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func makeApp(tab: Int, screen: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--screenshot-signed-in", "--screenshot-demo-data", "--screenshot-tab", String(tab)]
        if let screen { app.launchArguments += ["--screenshot-screen", screen] }
        return app
    }

    @MainActor
    func testPerf01_Launch() {
        let app = makeApp(tab: 0)
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            app.launch()
        }
    }

    @MainActor
    private func measureScroll(tab: Int, screen: String? = nil) {
        let app = makeApp(tab: tab, screen: screen)
        app.launch()
        let list = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15), "No scrollable list on tab \(tab)")
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            list.swipeUp(velocity: .fast)
            stopMeasuring()
            list.swipeDown(velocity: .fast)
        }
    }

    @MainActor func testPerf02_ScrollToday() { measureScroll(tab: 0) }
    @MainActor func testPerf03_ScrollMoneyOperations() { measureScroll(tab: 1, screen: "money-ops") }
    @MainActor func testPerf04_ScrollPlans() { measureScroll(tab: 2) }
    @MainActor func testPerf05_ScrollWorkoutHistory() { measureScroll(tab: 3, screen: "workout-history") }
    @MainActor func testPerf06_ScrollNotes() { measureScroll(tab: 4) }

    @MainActor
    func testPerf07_TabSwitching() {
        let app = makeApp(tab: 0)
        app.launch()
        XCTAssertTrue(app.buttons["tab-0"].waitForExistence(timeout: 15), "Tab bar missing")
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)]) {
            for index in [1, 2, 3, 4, 0] {
                let tab = app.buttons["tab-\(index)"]
                XCTAssertTrue(tab.waitForExistence(timeout: 5), "Tab \(index) missing")
                tab.tap()
            }
        }
    }
}
