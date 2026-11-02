import XCTest

final class LittleRouteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMapExpandsWithoutBlockingManualLibraryAccess() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--zones-fixture"]
        app.launch()
        let expand = app.buttons["expandContextMap"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        if !expand.isHittable { app.swipeUp() }
        expand.tap()
        XCTAssertTrue(app.navigationBars["Music Zones"].waitForExistence(timeout: 10))
        let status = app.staticTexts["contextStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let ready = NSPredicate(format: "label CONTAINS %@", "Parks")
        expectation(for: ready, evaluatedWith: status)
        waitForExpectations(timeout: 15)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Weighted context polygons"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].firstMatch.tap()
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.navigationBars["My Music"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testQueueHasAccessibleDismissal() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let queue = app.buttons["openQueue"]
        XCTAssertTrue(queue.waitForExistence(timeout: 10))
        if !queue.isHittable { app.swipeUp() }
        queue.tap()
        let close = app.buttons["Close queue"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertFalse(close.waitForExistence(timeout: 1))
    }

    @MainActor
    func testDegradedStoreDisablesImportAndExplainsRecovery() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--store-unavailable"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["libraryStoreWarning"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Import songs"].isEnabled)
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["libraryUnavailable"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing"]
            app.launch()
        }
    }
}
