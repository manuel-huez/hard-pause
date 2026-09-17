import AppKit
import ApplicationServices
import Foundation

struct AppleScreenTimeInspection: Equatable {
    let hasPasscode: Bool
    let sharesAcrossDevices: Bool
    let adultFilterEnabled: Bool
}

enum AppleScreenTimeAutomationError: LocalizedError {
    case accessibilityRequired
    case unsupportedScreen
    case existingPasscodeRequired
    case recoveryRequired
    case verificationRequired

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            return "Allow Hard Pause in System Settings → Privacy & Security → Accessibility, then try again."
        case .unsupportedScreen:
            return
                "Screen Time could not be changed safely. Keep System Settings open and use English for this setup. Your saved code has been retained."
        case .existingPasscodeRequired:
            return "Enter the current Screen Time code to replace it. Hard Pause will not remove an unknown code."
        case .recoveryRequired:
            return
                "Finish Apple's passcode recovery step in System Settings, then choose Verify setup. The new code is saved securely."
        case .verificationRequired:
            return
                "The saved code could not be verified. Protection is not confirmed. Keep System Settings open and choose Verify setup."
        }
    }
}

enum ScreenTimeCodeStage: Equatable {
    case current, new, confirmation

    static func parse(labels: [String]) -> Self? {
        let text = labels.joined(separator: " ").lowercased()
        guard text.contains("screen time"),
            !text.contains("incorrect"), !text.contains("failed attempt")
        else { return nil }
        if text.contains("re-enter") || text.contains("confirm your") { return .confirmation }
        let newCode =
            text.contains("new passcode") || text.contains("create a passcode")
            || text.contains("enter a screen time passcode")
        let oldCode =
            text.contains("enter your") || text.contains("old passcode")
            || text.contains("current passcode")
        guard newCode != oldCode else { return nil }
        return newCode ? .new : .current
    }
}

/// No screenshots, clipboard, AppleScript, command arguments or logs carry credentials.
/// This adapter deliberately stops on unknown UI instead of guessing coordinates.
@MainActor
protocol AppleScreenTimeAutomating {
    func inspect() async throws -> AppleScreenTimeInspection
    func install(passcode: String, replacing existingPasscode: String?, enableAdultFilter: Bool) async throws
    func verify(passcode: String, requiresAdultFilter: Bool) async throws
    func release(passcode: String, restoreUnrestricted: Bool) async throws
}

@MainActor
final class AppleScreenTimeAutomation: AppleScreenTimeAutomating {
    private let worker = ScreenTimeAccessibilityWorker()

    func inspect() async throws -> AppleScreenTimeInspection {
        try await openScreenTime()
        return try await worker.inspect()
    }

    func install(passcode: String, replacing existingPasscode: String?, enableAdultFilter: Bool) async throws {
        try await openScreenTime()
        try await worker.install(passcode: passcode, replacing: existingPasscode, enableAdultFilter: enableAdultFilter)
    }

    func verify(passcode: String, requiresAdultFilter: Bool) async throws {
        try await openScreenTime()
        try await worker.verify(passcode: passcode, requiresAdultFilter: requiresAdultFilter)
    }

    func release(passcode: String, restoreUnrestricted: Bool) async throws {
        try await openScreenTime()
        try await worker.release(passcode: passcode, restoreUnrestricted: restoreUnrestricted)
    }

    private func openScreenTime() async throws {
        guard AXIsProcessTrusted() else { throw AppleScreenTimeAutomationError.accessibilityRequired }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension"),
            NSWorkspace.shared.open(url)
        else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        try await Task.sleep(for: .milliseconds(600))
    }
}

/// AX calls can wait on another process; keep them off the app's main thread.
private actor ScreenTimeAccessibilityWorker {
    private var application: AXUIElement {
        get throws {
            guard
                let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                    .first
            else { throw AppleScreenTimeAutomationError.unsupportedScreen }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 2)
            return element
        }
    }

    func inspect() async throws -> AppleScreenTimeInspection {
        let root = try application
        let lock = try unique(root, matching: isPasscodeSwitch)
        let hasPasscode = try boolValue(lock)
        let sharing = try unique(root) { text($0, kAXIdentifierAttribute) == "Share across devices" }
        let shares = try boolValue(sharing)
        guard try await openWebSettings() else {
            try await goBack()
            return AppleScreenTimeInspection(
                hasPasscode: hasPasscode, sharesAcrossDevices: shares, adultFilterEnabled: false)
        }
        let filter = try webFilter()
        let filtered =
            text(filter, kAXValueAttribute) != "Unrestricted Access"
            && text(filter, kAXValueAttribute) != "Unrestricted"
        // Only accept known values; a missing/inaccessible value is not proof of protection.
        guard
            [
                "Unrestricted Access", "Unrestricted", "Limit Adult Websites", "Allowed Websites Only",
                "Only Allowed Websites",
            ]
            .contains(text(filter, kAXValueAttribute))
        else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        try await closeWebSettings()
        return AppleScreenTimeInspection(
            hasPasscode: hasPasscode, sharesAcrossDevices: shares, adultFilterEnabled: filtered)
    }

    func install(passcode: String, replacing old: String?, enableAdultFilter: Bool) async throws {
        guard validCode(passcode) else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        if enableAdultFilter {
            _ = try await openWebSettings(enableContentRestrictions: true)
            let current = text(try webFilter(), kAXValueAttribute)
            if ["Unrestricted Access", "Unrestricted"].contains(current) {
                try await selectWebFilter("Limit Adult Websites")
            } else {
                guard ["Limit Adult Websites", "Allowed Websites Only", "Only Allowed Websites"].contains(current)
                else { throw AppleScreenTimeAutomationError.unsupportedScreen }
            }
            try await closeWebSettings()
        }
        let lock = try unique(try application, matching: isPasscodeSwitch)
        if try boolValue(lock) {
            guard let old, validCode(old) else { throw AppleScreenTimeAutomationError.existingPasscodeRequired }
            try await openChangePasscode()
            try await enterCode(old, stage: .current)
        } else {
            try press(lock)
            try await settle()
        }
        try await enterCode(passcode, stage: .new)
        try await enterCode(passcode, stage: .confirmation)
        if try hasRecoveryPrompt() { throw AppleScreenTimeAutomationError.recoveryRequired }
        // Code acceptance must be proved by a separate native authentication, not a toggle alone.
    }

    func verify(passcode: String, requiresAdultFilter: Bool) async throws {
        let inspection = try await inspect()
        guard inspection.hasPasscode, !requiresAdultFilter || inspection.adultFilterEnabled
        else { throw AppleScreenTimeAutomationError.verificationRequired }
        try await openChangePasscode()
        try await enterCode(passcode, stage: .current)
        guard try promptStage() == .new else { throw AppleScreenTimeAutomationError.verificationRequired }
        // Authentication succeeded. Never enter another code during verification.
        try press(try unique(try application) { role($0) == kAXButtonRole && text($0, kAXTitleAttribute) == "Cancel" })
        try await settle()
        guard try boolValue(unique(try application, matching: isPasscodeSwitch)) else {
            throw AppleScreenTimeAutomationError.verificationRequired
        }
    }

    func release(passcode: String, restoreUnrestricted: Bool) async throws {
        // Caller obtains this credential only after the protected service authorizes full release.
        if restoreUnrestricted {
            let hasContentRestrictions = try await openWebSettings()
            if hasContentRestrictions {
                if try promptStage() == .current { try await enterCode(passcode, stage: .current) }
                let current = text(try webFilter(), kAXValueAttribute)
                if current == "Limit Adult Websites" {
                    try await selectWebFilter("Unrestricted Access", alternate: "Unrestricted")
                } else if !["Unrestricted Access", "Unrestricted"].contains(current) {
                    // Never weaken a stricter allow-only policy added after setup.
                    throw AppleScreenTimeAutomationError.verificationRequired
                }
                try await closeWebSettings()
            } else {
                try await goBack()
            }
        }
        let lock = try unique(try application, matching: isPasscodeSwitch)
        if try boolValue(lock) {
            try press(lock)
            try await settle()
            try await enterCode(passcode, stage: .current)
        }
        guard try !boolValue(unique(try application, matching: isPasscodeSwitch)) else {
            throw AppleScreenTimeAutomationError.verificationRequired
        }
    }

    private func openChangePasscode() async throws {
        try press(
            try unique(try application) {
                role($0) == kAXButtonRole
                    && ["Change Passcode…", "Change Passcode"].contains(text($0, kAXTitleAttribute))
            })
        try await settle()
        let choices = try nodes(application).filter {
            role($0) == kAXMenuItemRole
                && ["Change Passcode…", "Change Screen Time Passcode"].contains(text($0, kAXTitleAttribute))
        }
        if choices.count == 1 {
            try press(choices[0])
            try await settle()
        }
    }

    private func credentialPrompt() throws -> AXUIElement? {
        let all = nodes(try application)
        let sheets = all.filter { role($0) == kAXSheetRole }
        if sheets.count == 1 { return sheets[0] }
        guard sheets.isEmpty else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        let dialogs = all.filter { text($0, kAXSubroleAttribute) == kAXDialogSubrole }
        guard dialogs.count <= 1 else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        return dialogs.first
    }

    private func promptStage() throws -> ScreenTimeCodeStage? {
        guard let prompt = try credentialPrompt() else { return nil }
        let labels = nodes(prompt).filter { role($0) == kAXStaticTextRole }
            .map { text($0, kAXValueAttribute) + " " + text($0, kAXTitleAttribute) }
        return ScreenTimeCodeStage.parse(labels: labels)
    }

    private func hasRecoveryPrompt() throws -> Bool {
        try nodes(application).contains {
            role($0) == kAXStaticTextRole
                && (text($0, kAXValueAttribute) + text($0, kAXTitleAttribute)).contains("Passcode Recovery")
        }
    }

    private func enterCode(_ code: String, stage: ScreenTimeCodeStage) async throws {
        if try hasRecoveryPrompt() { throw AppleScreenTimeAutomationError.recoveryRequired }
        guard validCode(code), try promptStage() == stage else {
            if try hasRecoveryPrompt() { throw AppleScreenTimeAutomationError.recoveryRequired }
            throw AppleScreenTimeAutomationError.verificationRequired
        }
        guard let prompt = try credentialPrompt() else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        let secureFields = nodes(prompt).filter {
            role($0) == "AXSecureTextField" || text($0, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
        }
        guard secureFields.count == 1 || secureFields.count == 4 else {
            throw AppleScreenTimeAutomationError.unsupportedScreen
        }
        for (index, field) in secureFields.enumerated() {
            let value = secureFields.count == 1 ? code : String(Array(code)[index])
            guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString) == .success
            else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        }
        // Some native code controls advance automatically; never press a second page's button.
        try await settle()
        if try promptStage() == stage {
            guard let currentPrompt = try credentialPrompt() else {
                throw AppleScreenTimeAutomationError.unsupportedScreen
            }
            let buttons = nodes(currentPrompt).filter {
                role($0) == kAXButtonRole && ["Continue", "Next", "OK", "Done"].contains(text($0, kAXTitleAttribute))
                    && enabled($0)
            }
            guard buttons.count == 1 else { throw AppleScreenTimeAutomationError.unsupportedScreen }
            try press(buttons[0])
            try await settle()
        }
        guard try promptStage() != stage else { throw AppleScreenTimeAutomationError.verificationRequired }
    }

    private func openWebSettings(enableContentRestrictions: Bool = false) async throws -> Bool {
        let root = try application
        try press(try unique(root) { role($0) == kAXButtonRole && text($0, kAXTitleAttribute) == "Content & Privacy" })
        try await settle()
        let toggle = try unique(try application) {
            text($0, kAXDescriptionAttribute)
                == "Restrict explicit content, purchases, downloads, and privacy settings."
        }
        if try !boolValue(toggle) {
            guard enableContentRestrictions else { return false }
            try press(toggle)
            try await settle()
        }
        try press(
            try unique(try application) {
                role($0) == kAXButtonRole
                    && ["App Store, Media, Web, & Games", "App Store, Media, Web & Games"].contains(
                        text($0, kAXTitleAttribute))
            })
        try await settle()
        return true
    }

    private func closeWebSettings() async throws {
        try press(try unique(try application) { role($0) == kAXButtonRole && text($0, kAXTitleAttribute) == "Done" })
        try await settle()
        try await goBack()
    }

    private func goBack() async throws {
        try press(try unique(try application) { text($0, kAXIdentifierAttribute) == "go back" })
        try await settle()
    }

    private func webFilter() throws -> AXUIElement {
        try unique(try application) {
            role($0) == kAXPopUpButtonRole
                && [text($0, kAXTitleAttribute), text($0, kAXDescriptionAttribute)].contains("Access to Web Content")
        }
    }

    private func selectWebFilter(_ choice: String, alternate: String? = nil) async throws {
        try press(try webFilter())
        try await settle()
        try press(
            try unique(try application) {
                role($0) == kAXMenuItemRole
                    && [choice, alternate].compactMap { $0 }.contains(text($0, kAXTitleAttribute))
            })
        try await settle()
        guard [choice, alternate].compactMap({ $0 }).contains(text(try webFilter(), kAXValueAttribute)) else {
            throw AppleScreenTimeAutomationError.verificationRequired
        }
    }

    private func isPasscodeSwitch(_ node: AXUIElement) -> Bool {
        text(node, kAXDescriptionAttribute) == "Use a passcode to secure Screen Time settings."
            || text(node, kAXTitleAttribute) == "Lock Screen Time Settings"
    }

    private func validCode(_ value: String) -> Bool {
        value.utf8.count == 4 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }

    private func press(_ node: AXUIElement) throws {
        guard enabled(node), AXUIElementPerformAction(node, kAXPressAction as CFString) == .success else {
            throw AppleScreenTimeAutomationError.unsupportedScreen
        }
    }

    private func unique(_ root: AXUIElement, matching predicate: (AXUIElement) -> Bool) throws -> AXUIElement {
        let matches = nodes(root).filter(predicate)
        guard matches.count == 1 else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        return matches[0]
    }

    private func nodes(_ root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var pending = [(root, 0)]
        while let (node, depth) = pending.popLast(), result.count < 1_500 {
            result.append(node)
            if depth < 20, let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        return result
    }

    private func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }
        return value
    }

    private func text(_ node: AXUIElement, _ key: String) -> String { attribute(node, key) as? String ?? "" }
    private func role(_ node: AXUIElement) -> String { text(node, kAXRoleAttribute) }
    private func enabled(_ node: AXUIElement) -> Bool {
        (attribute(node, kAXEnabledAttribute) as? NSNumber)?.boolValue == true
    }
    private func boolValue(_ node: AXUIElement) throws -> Bool {
        guard let value = attribute(node, kAXValueAttribute) as? NSNumber else {
            throw AppleScreenTimeAutomationError.unsupportedScreen
        }
        return value.boolValue
    }
}
