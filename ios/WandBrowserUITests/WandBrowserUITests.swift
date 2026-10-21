import XCTest

@MainActor
final class WandBrowserUITests: XCTestCase {
    private func scrollControls(_ web: XCUIElement, up: Bool) {
        // Stay inside the fixture's upper scroll panel rather than its console.
        let high = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let low = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        (up ? low : high).press(forDuration: 0.05, thenDragTo: up ? high : low)
    }
    private var fixtureBase: String {
        get throws {
            let value = ProcessInfo.processInfo.environment["WAND_FIXTURE_URL"] ?? "https://hito-dev.github.io/wand-browser/fixtures/"
            guard let url = URL(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw NSError(domain: "WandFixtureTests", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "WAND_FIXTURE_URL must be an HTTPS directory URL without credentials, query, or fragment."])
            }
            return value.hasSuffix("/") ? value : value + "/"
        }
    }
    private func openFixtures(_ app: XCUIApplication, preserveFullscreenPreference: Bool = false) throws {
        let base = try fixtureBase
        XCUIDevice.shared.orientation = .portrait
        // Keep unrelated tests independent of a preference left by an interrupted run.
        app.launchArguments = preserveFullscreenPreference ? [] : ["-browser.fullscreenOrigins.v1", "()"]
        app.launch()
        let field = app.textFields["address-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(base + "bridge.html\n")
        XCTAssertTrue(pageText(app, "Wand hardware fixtures").waitForExistence(timeout: 30),
                      "Could not open \(base)bridge.html. Check your internet connection and Pages deployment, or override WAND_FIXTURE_URL.")
    }

    // Run separately on iPhone 17 Pro; export attachments for the release handoff.
    func testCaptureReleaseScreenshots() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-browser.fullscreenOrigins.v1", "()", "-browser.history.v1", ""]
        app.launch()
        XCTAssertTrue(app.buttons["open-hardware-fixtures"].waitForExistence(timeout: 10))
        func capture(_ name: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = name
            image.lifetime = .keepAlways
            add(image)
        }
        capture("wand-home")
        let field = app.textFields["address-field"]
        field.tap()
        field.typeText(try fixtureBase + "bridge.html\n")
        XCTAssertTrue(pageText(app, "Wand hardware fixtures").waitForExistence(timeout: 30))
        XCTAssertTrue(app.webViews.staticTexts["Ready."].waitForExistence(timeout: 10))
        capture("wand-fixture")
        app.buttons["site-controls"].tap()
        XCTAssertTrue(app.buttons["Revoke hardware access"].waitForExistence(timeout: 5))
        capture("wand-site-controls")
    }

    func testHomeHardwareFixturesShortcut() {
        let app = XCUIApplication()
        app.launchArguments = ["-browser.fullscreenOrigins.v1", "()"]
        app.launch()
        let shortcut = app.buttons["open-hardware-fixtures"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        shortcut.tap()
        XCTAssertTrue(pageText(app, "Wand hardware fixtures").waitForExistence(timeout: 30))
        XCTAssertEqual(app.textFields["address-field"].value as? String,
                       "https://wand.hito.ai/fixtures/bridge.html")
        app.buttons["Home"].tap()
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
    }

    func testNativeHardwarePromptsAndRevocation() throws {
        let app = XCUIApplication()
        try openFixtures(app)
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

    func testHTTPSNavigationAndSameTabLinks() throws {
        let app = XCUIApplication()
        try openFixtures(app)
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

    func testReleaseBrowserSmoke() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let base = try fixtureBase
        app.launchArguments = ["-browser.fullscreenOrigins.v1", "()"]
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

    func testFullscreenAddressEditing() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        try openFixtures(app)
        if app.buttons["exit-fullscreen"].exists { app.buttons["exit-fullscreen"].tap() }
        app.buttons["site-controls"].tap()
        app.buttons["enter-fullscreen"].tap()
        let address = app.buttons["fullscreen-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "Fullscreen address bar"
        capture.lifetime = .keepAlways
        add(capture)
        address.tap()
        let field = app.textFields["address-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let base = try fixtureBase
        field.typeText(base + "second.html\n")
        XCTAssertTrue(pageText(app, "Second page").waitForExistence(timeout: 30))
        XCTAssertEqual(field.value as? String, base + "second.html")
        app.buttons["site-controls"].tap()
        app.buttons["enter-fullscreen"].tap()
        app.buttons["exit-fullscreen"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testBrowserFullscreenControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        try openFixtures(app)
        app.buttons["site-controls"].tap()
        app.buttons["enter-fullscreen"].tap()
        let exit = app.buttons["exit-fullscreen"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["address-field"].exists)
        scrollControls(app.webViews.firstMatch, up: true)
        scrollControls(app.webViews.firstMatch, up: false)
        XCTAssertFalse(app.textFields["address-field"].exists)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: exit)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 8), .completed)
        app.webViews.staticTexts["Wand hardware fixtures"].firstMatch.twoFingerTap()
        XCTAssertTrue(exit.waitForExistence(timeout: 3))
        exit.tap()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 3))
        XCTAssertTrue(pageText(app, "Wand hardware fixtures").exists)
    }

    func testFullscreenPreservesPageAcrossOrientationAndBackground() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        try openFixtures(app)
        scrollControls(app.webViews.firstMatch, up: true)
        let field = app.webViews.textFields["NFC text"]
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
        scrollControls(app.webViews.firstMatch, up: false)
        scrollControls(app.webViews.firstMatch, up: false)
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

    func testFixtureConsoleCanBeDraggedAndResetsOnReload() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        try openFixtures(app)
        let web = app.webViews.firstMatch
        let divider = web.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Resize console")).firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        let initial = divider.frame.midY
        let grip = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.1, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        XCTAssertLessThan(divider.frame.midY, initial - 60)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Fixture console expanded by dragging"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertGreaterThan(divider.frame.midY, initial)
        app.buttons["Reload"].tap()
        let reset = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(divider.frame.midY - initial) < 3 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reset], timeout: 10), .completed)
    }

    func testRememberedBrowserFullscreen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        try openFixtures(app)
        // Make the test repeatable if a previous run saved this origin.
        if app.buttons["exit-fullscreen"].exists { app.buttons["exit-fullscreen"].tap() }
        app.buttons["site-controls"].tap()
        let preference = app.switches["always-fullscreen"]
        XCTAssertTrue(preference.waitForExistence(timeout: 5))
        if preference.value as? String == "1" { preference.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        preference.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["exit-fullscreen"].waitForExistence(timeout: 5))
        app.buttons["exit-fullscreen"].tap()
        app.buttons["Reload"].tap()
        XCTAssertTrue(pageText(app, "Wand hardware fixtures").waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["address-field"].exists)
        app.terminate()
        try openFixtures(app, preserveFullscreenPreference: true)
        XCTAssertTrue(app.buttons["exit-fullscreen"].waitForExistence(timeout: 5))
        app.buttons["exit-fullscreen"].tap()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 5))
        app.buttons["site-controls"].tap()
        XCTAssertTrue(app.switches["always-fullscreen"].waitForExistence(timeout: 5))
        app.switches["always-fullscreen"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["Done"].tap()
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
