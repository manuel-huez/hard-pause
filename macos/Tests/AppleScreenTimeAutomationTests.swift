import XCTest

final class AppleScreenTimeAutomationTests: XCTestCase {
    func testRecognizesDistinctCredentialStages() {
        XCTAssertEqual(ScreenTimeCodeStage.parse(labels: ["Screen Time", "Enter your passcode"]), .current)
        XCTAssertEqual(ScreenTimeCodeStage.parse(labels: ["Screen Time", "Enter a new passcode"]), .new)
        XCTAssertEqual(ScreenTimeCodeStage.parse(labels: ["Screen Time", "Re-enter your new passcode"]), .confirmation)
    }

    func testRejectsUnknownOrAmbiguousAuthenticationScreens() {
        XCTAssertNil(ScreenTimeCodeStage.parse(labels: ["Enter your Mac password"]))
        XCTAssertNil(ScreenTimeCodeStage.parse(labels: ["Screen Time", "Change Passcode"]))
        XCTAssertNil(
            ScreenTimeCodeStage.parse(labels: ["Screen Time", "Enter your current passcode to set a new passcode"]))
        XCTAssertNil(ScreenTimeCodeStage.parse(labels: ["Screen Time", "Enter your passcode", "Incorrect passcode"]))
    }
}
