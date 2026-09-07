import XCTest

final class MobileUITests: XCTestCase {
    @MainActor
    func testNotificationDeliveryFromSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let send = app.buttons["Send a test notification"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alerts = app.switches["Quota alerts"]
        let alertsWereEnabled = alerts.value as? String == "1"
        defer {
            if !alertsWereEnabled && alerts.value as? String == "1" { alerts.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        }
        if !send.isEnabled {
            alerts.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            let allow = springboard.alerts.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "Notification permission must be enabled for the delivery check.")
        }
        send.tap()
        XCTAssertTrue(app.staticTexts["Test sent. Check your notification banner or Notification Center."].waitForExistence(timeout: 10))
        XCTAssertTrue(springboard.staticTexts["Costbar notifications are ready"].waitForExistence(timeout: 10), "The system should present the local notification banner.")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Delivered Costbar notification"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor
    func testHomeScreenWidget() throws {
        continueAfterFailure = false
        XCUIApplication().launch()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let widget = springboard.icons.matching(NSPredicate(format: "label == 'Costbar' AND value == 'Widget'")).firstMatch
        for _ in 0..<5 {
            if widget.exists && widget.isHittable { break }
            springboard.swipeLeft()
        }
        XCTAssertTrue(widget.exists && widget.isHittable, "Install a Costbar Home Screen widget before running this live-data check.")
        XCTAssertTrue(widget.staticTexts["Costbar"].exists)
        XCTAssertFalse(widget.staticTexts["Open Costbar to sync usage"].exists, "Sync the simulator with a publishing Mac first.")
        XCTAssertGreaterThan(widget.staticTexts.count, 2, "The widget should display synced usage and its age.")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Costbar Home Screen widget"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
