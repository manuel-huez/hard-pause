import XCTest

final class HardPauseUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testNavigationAndPlanCommitmentFlow() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 10))
        attachScreenshot("01-home")

        app.tabBars.buttons["Plans"].tap()
        XCTAssertTrue(element("plans.screen").waitForExistence(timeout: 5))
        attachScreenshot("02-plans")

        let newPlan = app.buttons["plans.new"]
        XCTAssertTrue(newPlan.waitForExistence(timeout: 5))
        newPlan.tap()
        XCTAssertTrue(element("editor.screen").waitForExistence(timeout: 5))
        attachScreenshot("03-create-plan-intention")

        let customIntention = app.buttons["editor.intention.custom"]
        XCTAssertTrue(customIntention.waitForExistence(timeout: 5))
        customIntention.tap()
        let intentionContinue = app.buttons["editor.continue"]
        XCTAssertTrue(intentionContinue.waitForExistence(timeout: 5))
        intentionContinue.tap()

        let planName = app.textFields["editor.name"]
        XCTAssertTrue(planName.waitForExistence(timeout: 5))
        planName.tap()
        planName.typeText("UI smoke plan")
        attachScreenshot("04-create-plan-boundaries")

        let boundariesContinue = app.buttons["editor.continue"]
        XCTAssertTrue(boundariesContinue.waitForExistence(timeout: 5))
        boundariesContinue.tap()

        let pauseMode = app.buttons["editor.mode.softLock"]
        let hardPauseMode = app.buttons["editor.mode.lockdown"]
        XCTAssertTrue(pauseMode.waitForExistence(timeout: 5))
        XCTAssertTrue(hardPauseMode.waitForExistence(timeout: 5))
        scrollUntilVisible(pauseMode)
        XCTAssertTrue(hardPauseMode.isHittable)
        XCTAssertTrue(element("editor.breakWait").exists)
        XCTAssertTrue(element("editor.breakLength").exists)
        XCTAssertTrue(element("editor.fixedDuration").exists)
        XCTAssertTrue(element("editor.fullUnlockWait").exists)
        attachScreenshot("05-pause-and-hard-pause-modes")

        hardPauseMode.tap()
        XCTAssertFalse(element("editor.breakWait").exists)
        XCTAssertFalse(element("editor.breakLength").exists)
        XCTAssertFalse(element("editor.fixedDuration").exists)
        XCTAssertTrue(element("editor.fullUnlockWait").exists)
        let waitingPeriods = app.staticTexts["editor.waitingPeriods"]
        XCTAssertTrue(waitingPeriods.waitForExistence(timeout: 5))
        scrollBySmallStep()
        attachScreenshot("06-hard-pause-waits")

        let deviceProtection = app.staticTexts["editor.deviceProtection"]
        XCTAssertTrue(deviceProtection.waitForExistence(timeout: 5))
        scrollUntilVisible(deviceProtection)
        XCTAssertFalse(app.switches["editor.preventAppRemoval"].exists)
        XCTAssertFalse(app.switches["editor.requireAutomaticTime"].exists)
        XCTAssertTrue(element("editor.permissionProtectionStatus").exists)
        XCTAssertTrue(staticText("Not verified by this iPhone app").exists)
        attachScreenshot("07-hard-pause-device-protection")

        scrollBackUntilVisible(pauseMode)
        pauseMode.tap()
        scrollUntilVisible(deviceProtection)
        XCTAssertTrue(app.switches["editor.preventAppRemoval"].exists)
        XCTAssertTrue(app.switches["editor.requireAutomaticTime"].exists)
        XCTAssertTrue(app.staticTexts["These choices become fixed when the plan starts."].exists)
        attachScreenshot("08-pause-device-protection")

        let cancel = app.buttons["editor.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(element("plans.screen").waitForExistence(timeout: 5))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(element("settings.screen").waitForExistence(timeout: 5))
        let passcode = app.staticTexts["settings.optionalPasscode"]
        XCTAssertTrue(passcode.waitForExistence(timeout: 5))
        let passcodeDescription = staticText(
            "On iOS 26.4 or later, iOS can require the passcode before Family Controls access is changed. Anyone who knows the passcode can still revoke access."
        )
        XCTAssertTrue(passcodeDescription.waitForExistence(timeout: 5))
        scrollUntilVisible(passcodeDescription)
        XCTAssertTrue(app.staticTexts["settings.optionalPasscode"].exists)
        XCTAssertTrue(passcodeDescription.exists)
        XCTAssertTrue(
            staticText(
                "It adds the most friction when a trusted person keeps the code. Hard Pause cannot set, read, or verify it."
            ).exists
        )
        attachScreenshot("09-settings-passcode")

        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 5))
        attachScreenshot("10-home-return")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func staticText(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func scrollUntilVisible(_ element: XCUIElement, maximumSwipes: Int = 6) {
        var remaining = maximumSwipes
        while !element.isHittable && remaining > 0 {
            app.swipeUp()
            remaining -= 1
        }
        XCTAssertTrue(element.isHittable, "Expected \(element.identifier) to become visible")
    }

    private func scrollBackUntilVisible(_ element: XCUIElement, maximumSwipes: Int = 6) {
        var remaining = maximumSwipes
        while !element.isHittable && remaining > 0 {
            app.swipeDown()
            remaining -= 1
        }
        XCTAssertTrue(element.isHittable, "Expected \(element.identifier) to become visible")
    }

    private func scrollBySmallStep() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
