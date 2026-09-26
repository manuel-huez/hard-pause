import XCTest

final class ScreenTimeUIStringsTests: XCTestCase {
    func testAmbiguousSystemTranslationNeedsTheExpectedStep() {
        // Apple uses the same Russian title for these two non-adjacent steps.
        let title = "Введите код‑пароль Экранного времени"
        let strings = ScreenTimeUIStrings(values: [
            "Enter Screen Time Passcode": [title],
            "Re-enter new Screen Time passcode": [title],
            "Enter new Screen Time passcode": ["Введите новый код"],
        ])

        XCTAssertNil(strings.passcodeStage(labels: [title]))
        XCTAssertEqual(strings.passcodeStage(labels: [title], expected: .authenticate), .authenticate)
        XCTAssertEqual(strings.passcodeStage(labels: [title], expected: .confirm), .confirm)
        XCTAssertNil(strings.passcodeStage(labels: [title], expected: .create))
        XCTAssertNil(strings.passcodeStage(labels: [title, "Введите новый код"], expected: .create))
    }

    func testPasscodeStepsUseLocalizedSystemMeaning() {
        let strings = ScreenTimeUIStrings(values: [
            "AuthenticateToUpdatePasscodeHelpText": ["Saisissez l’ancien code"],
            "UpdatePasscodeHelpText": ["Saisissez le nouveau code"],
            "VerifyUpdatePasscodeHelpText": ["Confirmez le nouveau code"],
            "RecoveryAppleIDAlertTitle": ["Récupération du code"],
        ])

        XCTAssertEqual(strings.passcodeStage(labels: ["Saisissez l’ancien code", "Annuler"]), .authenticateChange)
        XCTAssertEqual(strings.passcodeStage(labels: ["Saisissez le nouveau code"]), .create)
        XCTAssertEqual(strings.passcodeStage(labels: ["Confirmez le nouveau code"]), .confirm)
        XCTAssertEqual(strings.passcodeStage(labels: ["Récupération du code"]), .recovery)
        XCTAssertNil(strings.passcodeStage(labels: ["Le code est incorrect", "Annuler"]))
        XCTAssertNil(strings.passcodeStage(labels: ["Saisissez le nouveau code", "Confirmez le nouveau code"]))
    }

    func testWebPoliciesDoNotDependOnMenuOrderOrLanguage() {
        let strings = ScreenTimeUIStrings(values: [
            "UnrestrictedAccessSpecifierName": ["Sans restriction", "制限なし"],
            "LimitAdultWebsitesSpecifierName": ["Limiter les sites pour adultes", "成人向けWebサイトを制限"],
            "AllowedWebsitesSpecifierName": ["Sites autorisés uniquement", "許可されたWebサイトのみ"],
        ])

        XCTAssertEqual(strings.webFilterLevel("Sites autorisés uniquement"), 2)
        XCTAssertEqual(strings.webFilterLevel("制限なし"), 0)
        XCTAssertEqual(strings.webFilterLevel("Limiter les sites pour adultes"), 1)
        XCTAssertNil(strings.webFilterLevel("Unknown policy"))
        XCTAssertFalse(strings.matches("", keys: ["Missing key"]))
    }

    func testConflictingPolicyTranslationsFailSafely() {
        let strings = ScreenTimeUIStrings(values: [
            "Unrestricted": ["Same label"],
            "Approved Websites Only": ["Same label"],
        ])

        XCTAssertNil(strings.webFilterLevel("Same label"))
    }
}
