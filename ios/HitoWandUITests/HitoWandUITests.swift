import XCTest

@MainActor
final class HitoWandUITests: XCTestCase {
    private func openFixtures(_ app: XCUIApplication) {
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let base = ProcessInfo.processInfo.environment["WAND_FIXTURE_URL"] ?? "https://localhost:18443/"
        let field = app.textFields["address-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(base + "bridge.html\n")
        XCTAssertTrue(pageText(app, "Wand hardware fixtures").waitForExistence(timeout: 30))
    }

    func testNativeHardwarePromptsAndRevocation() {
        let app = XCUIApplication()
        openFixtures(app)
        app.webViews.buttons["Choose Bluetooth device"].tap()
        XCTAssertTrue(app.navigationBars["Choose a device"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        let cancelled = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "NotFoundError")).firstMatch
        XCTAssertTrue(cancelled.waitForExistence(timeout: 10))
        app.webViews.buttons["Scan NFC"].tap()
        let permission = app.alerts["Allow NFC access?"]
        XCTAssertTrue(permission.waitForExistence(timeout: 10))
        permission.buttons["Allow"].tap()
        let unsupported = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "NFC is unavailable")).firstMatch
        XCTAssertTrue(unsupported.waitForExistence(timeout: 10))
        app.buttons["site-controls"].tap()
        let revoke = app.buttons["Revoke hardware access"]
        XCTAssertTrue(revoke.waitForExistence(timeout: 5))
        XCTAssertTrue(revoke.isEnabled)
        revoke.tap()
        XCTAssertFalse(revoke.isEnabled)
        app.buttons["Done"].tap()
    }

    func testHTTPSNavigationAndSameTabLinks() {
        let app = XCUIApplication()
        openFixtures(app)
        app.swipeUp()
        app.webViews.links["Open second page"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Second page"].waitForExistence(timeout: 10))
        app.buttons["Back"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Wand hardware fixtures"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Forward"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Second page"].waitForExistence(timeout: 10))
        app.buttons["Back"].tap()
        app.webViews.links["Open new-window link"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Second page"].waitForExistence(timeout: 10))
        app.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["The web, connected."].waitForExistence(timeout: 10))
    }

    private func pageText(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        // WebKit on iOS 27 exposes headings as Other rather than StaticText.
        app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    func testReleaseBrowserSmoke() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let base = ProcessInfo.processInfo.environment["WAND_FIXTURE_URL"] ?? "https://wand.hito.ai/fixtures/"
        app.launch()
        let field = app.textFields["address-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(base + "bridge.html\n")
        XCTAssertTrue(pageText(app, "Wand hardware fixtures").waitForExistence(timeout: 30))
        // Tapping the current URL must select it all: no delete/select-all workaround.
        field.tap()
        field.typeText(base + "second.html\n")
        XCTAssertTrue(pageText(app, "Second page").waitForExistence(timeout: 30))
        XCTAssertEqual(field.value as? String, base + "second.html")
        app.buttons["Back"].tap()
        XCTAssertTrue(pageText(app, "Wand hardware fixtures").waitForExistence(timeout: 15))
        app.buttons["Forward"].tap()
        XCTAssertTrue(pageText(app, "Second page").waitForExistence(timeout: 15))
        app.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Recent pages"].waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Recent pages"].waitForExistence(timeout: 10))
        let recent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", base + "bridge.html")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tap()
        XCTAssertTrue(pageText(app, "Wand hardware fixtures").waitForExistence(timeout: 30))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["site-controls"].waitForExistence(timeout: 10))
        app.buttons["site-controls"].tap()
        app.buttons["Clear website data"].tap()
        app.sheets.buttons["Clear website data"].tap()
        XCTAssertTrue(app.staticTexts["Recent pages"].waitForExistence(timeout: 10))
        app.buttons["Clear browsing history"].tap()
        app.buttons["Clear history"].tap()
        XCTAssertFalse(app.staticTexts["Recent pages"].exists)
    }

    func testBrowserFullscreenControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        openFixtures(app)
        app.buttons["site-controls"].tap()
        app.buttons["enter-fullscreen"].tap()
        let exit = app.buttons["exit-fullscreen"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["address-field"].exists)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: exit)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 8), .completed)
        app.webViews.textFields.firstMatch.twoFingerTap()
        XCTAssertTrue(exit.waitForExistence(timeout: 3))
        exit.tap()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 3))
        XCTAssertTrue(pageText(app, "Wand hardware fixtures").exists)
    }

    func testFullscreenPreservesPageAndRestoresAfterWebsiteFullscreen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        openFixtures(app)
        let field = app.webViews.textFields.firstMatch
        field.tap()
        field.typeText(" retained")
        let retainedValue = field.value as? String
        app.buttons["site-controls"].tap()
        app.buttons["enter-fullscreen"].tap()
        XCTAssertEqual(field.value as? String, retainedValue)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["exit-fullscreen"].waitForExistence(timeout: 5))
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "Fullscreen landscape"
        landscape.lifetime = .keepAlways
        add(landscape)
        XCUIDevice.shared.orientation = .portrait
        app.webViews.firstMatch.swipeDown()
        app.webViews.buttons["Enter fullscreen"].tap()
        XCTAssertTrue(app.webViews.buttons["Exit fullscreen"].waitForExistence(timeout: 10))
        app.webViews.buttons["Exit fullscreen"].tap()
        XCTAssertTrue(app.buttons["exit-fullscreen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["address-field"].exists)
        XCTAssertEqual(field.value as? String, retainedValue)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["exit-fullscreen"].waitForExistence(timeout: 5))
        app.webViews.buttons["Choose Bluetooth device"].tap()
        XCTAssertTrue(app.navigationBars["Choose a device"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["exit-fullscreen"].waitForExistence(timeout: 5))
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portrait.name = "Fullscreen portrait after prompt"
        portrait.lifetime = .keepAlways
        add(portrait)
        app.buttons["exit-fullscreen"].tap()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, retainedValue)
    }

    func testRememberedBrowserFullscreen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        openFixtures(app)
        // Make the test repeatable if a previous run saved this origin.
        if app.buttons["exit-fullscreen"].exists { app.buttons["exit-fullscreen"].tap() }
        app.buttons["site-controls"].tap()
        let preference = app.switches["always-fullscreen"]
        if preference.value as? String == "1" { preference.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        preference.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["exit-fullscreen"].waitForExistence(timeout: 5))
        app.buttons["exit-fullscreen"].tap()
        app.buttons["Reload"].tap()
        XCTAssertTrue(pageText(app, "Wand hardware fixtures").waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["address-field"].exists)
        app.terminate()
        openFixtures(app)
        XCTAssertTrue(app.buttons["exit-fullscreen"].waitForExistence(timeout: 5))
        app.buttons["exit-fullscreen"].tap()
        app.buttons["site-controls"].tap()
        app.switches["always-fullscreen"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["Done"].tap()
    }

    func testFullscreenFixture() {
        continueAfterFailure = false
        let app = XCUIApplication()
        openFixtures(app)
        app.webViews.buttons["Enter fullscreen"].tap()
        XCTAssertTrue(app.webViews.buttons["Exit fullscreen"].waitForExistence(timeout: 10))
        let entered = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Entered fullscreen")).firstMatch
        XCTAssertTrue(entered.waitForExistence(timeout: 10))
        app.webViews.buttons["Exit fullscreen"].tap()
        XCTAssertTrue(app.webViews.buttons["Enter fullscreen"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["address-field"].exists || app.textFields["address-field"].exists)
    }

    func testPrivacyPolicyAvailableOffline() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["site-controls"].tap()
        let policy = app.buttons["privacy-policy"]
        XCTAssertTrue(policy.waitForExistence(timeout: 5))
        policy.tap()
        XCTAssertTrue(app.webViews.staticTexts["Wand Browser Privacy Policy"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews.staticTexts["Effective date: October 20, 2026"].exists)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["privacy-policy"].waitForExistence(timeout: 5))
    }

    func testHomeAddressValidationAndSiteControls() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Wand Browser"].waitForExistence(timeout: 10))
        let field = app.textFields["address-field"]
        XCTAssertTrue(field.exists)
        field.tap()
        field.typeText("not a website\n")
        XCTAssertTrue(app.staticTexts["Couldn’t open this page"].waitForExistence(timeout: 5))
        app.buttons["Dismiss"].tap()
        app.buttons["site-controls"].tap()
        XCTAssertTrue(app.staticTexts["No devices allowed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["NFC idle"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["The web, connected."].exists)
    }
}
