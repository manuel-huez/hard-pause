import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AppleScreenTimeInspection: Equatable {
    let hasPasscode: Bool
    let adultFilterEnabled: Bool
}

struct AppleScreenTimeWebsites: Equatable {
    let restricted: Set<String>
    let allowed: Set<String>
    let restrictedEntries: [String]
    let allowedEntries: [String]
}

enum AppleScreenTimeAutomationError: LocalizedError {
    case accessibilityRequired
    case unsupportedScreen
    case unsupportedPasscodeFlow
    case existingPasscodeRequired
    case recoveryRequired
    case verificationRequired
    case websiteSyncUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            return "Allow Hard Pause in System Settings → Privacy & Security → Accessibility, then try again."
        case .unsupportedScreen:
            return
                "Screen Time controls were not recognized. Keep System Settings open and try again. Any saved code is retained."
        case .unsupportedPasscodeFlow:
            return
                "Hard Pause cannot find a usable Screen Time passcode control on this macOS version. Automatic setup is unavailable here. Your plans stay active."
        case .existingPasscodeRequired:
            return "Enter the current Screen Time code to replace it. Hard Pause will not remove an unknown code."
        case .recoveryRequired:
            return
                "Finish Apple's passcode recovery step in System Settings, then choose Verify setup. The new code is saved securely."
        case .verificationRequired:
            return
                "The saved code could not be verified. Protection is not confirmed. Keep System Settings open and choose Verify setup."
        case .websiteSyncUnavailable:
            return
                "Screen Time website sync could not be verified. Check Content & Privacy in System Settings, then retry."
        }
    }
}

/// No screenshots, clipboard, AppleScript, command arguments or logs carry credentials.
/// This adapter deliberately stops on unknown UI instead of guessing coordinates or localized labels.
@MainActor
protocol AppleScreenTimeAutomating {
    func inspectCode() async throws -> Bool
    func inspect(checkAdultFilter: Bool, passcode: String?) async throws -> AppleScreenTimeInspection
    func install(passcode: String, replacing existingPasscode: String?, enableAdultFilter: Bool) async throws
    func verify(passcode: String, requiresAdultFilter: Bool) async throws
    func release(passcode: String, restoreUnrestricted: Bool) async throws
    func inspectWebsites(passcode: String) async throws -> AppleScreenTimeWebsites
    func updateWebsites(
        passcode: String, addRestricted: [String], removeRestricted: [String],
        addAllowed: [String], removeAllowed: [String]
    ) async throws -> AppleScreenTimeWebsites
}

extension AppleScreenTimeAutomating {
    func inspectWebsites(passcode: String) async throws -> AppleScreenTimeWebsites {
        throw AppleScreenTimeAutomationError.websiteSyncUnavailable
    }

    func updateWebsites(
        passcode: String, addRestricted: [String], removeRestricted: [String],
        addAllowed: [String], removeAllowed: [String]
    ) async throws -> AppleScreenTimeWebsites {
        throw AppleScreenTimeAutomationError.websiteSyncUnavailable
    }
}

@MainActor
final class AppleScreenTimeAutomation: AppleScreenTimeAutomating {
    private let worker = ScreenTimeAccessibilityWorker()

    func inspectCode() async throws -> Bool {
        try await openScreenTime()
        return try await worker.inspectCode()
    }

    func inspect(checkAdultFilter: Bool, passcode: String?) async throws -> AppleScreenTimeInspection {
        try await openScreenTime()
        return try await worker.inspect(checkAdultFilter: checkAdultFilter, passcode: passcode)
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

    func inspectWebsites(passcode: String) async throws -> AppleScreenTimeWebsites {
        try await openScreenTime()
        return try await worker.inspectWebsites(passcode: passcode)
    }

    func updateWebsites(
        passcode: String, addRestricted: [String], removeRestricted: [String],
        addAllowed: [String], removeAllowed: [String]
    ) async throws -> AppleScreenTimeWebsites {
        try await worker.updateWebsites(
            passcode: passcode, addRestricted: addRestricted, removeRestricted: removeRestricted,
            addAllowed: addAllowed, removeAllowed: removeAllowed)
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

    func inspectCode() async throws -> Bool {
        let root = try await screenTimeRoot()
        return try boolValue(passcodeSwitch(in: root))
    }

    func inspect(checkAdultFilter: Bool, passcode: String?) async throws -> AppleScreenTimeInspection {
        let root = try await screenTimeRoot()
        let lock = try passcodeSwitch(in: root)
        let hasPasscode = try boolValue(lock)
        guard checkAdultFilter else {
            return AppleScreenTimeInspection(hasPasscode: hasPasscode, adultFilterEnabled: false)
        }
        if hasPasscode && passcode == nil { throw AppleScreenTimeAutomationError.existingPasscodeRequired }
        guard try await openWebSettings(passcode: passcode) else {
            try await goBack()
            return AppleScreenTimeInspection(hasPasscode: hasPasscode, adultFilterEnabled: false)
        }
        let filtered = try await webFilterLevel() != 0
        try await closeWebSettings()
        return AppleScreenTimeInspection(hasPasscode: hasPasscode, adultFilterEnabled: filtered)
    }

    func install(passcode: String, replacing old: String?, enableAdultFilter: Bool) async throws {
        guard validCode(passcode) else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        if enableAdultFilter {
            _ = try await openWebSettings(enableContentRestrictions: true, passcode: old)
            if try await webFilterLevel() == 0 { try await selectWebFilter(1, passcode: old) }
            try await closeWebSettings()
        }
        let lock = try passcodeSwitch(in: application)
        if try boolValue(lock) {
            guard let old, validCode(old) else { throw AppleScreenTimeAutomationError.existingPasscodeRequired }
            try await openChangePasscode()
            try await enterCode(old, expecting: .nextPrompt)
        } else {
            try press(lock)
            try await settle()
        }
        try await enterCode(passcode, expecting: .nextPrompt)
        try await enterCode(passcode, expecting: .closed)
        guard try credentialPrompt() == nil else { throw AppleScreenTimeAutomationError.recoveryRequired }
        // Code acceptance must be proved by a separate native authentication, not a toggle alone.
    }

    func verify(passcode: String, requiresAdultFilter: Bool) async throws {
        let inspection = try await inspect(checkAdultFilter: requiresAdultFilter, passcode: passcode)
        guard inspection.hasPasscode, !requiresAdultFilter || inspection.adultFilterEnabled
        else { throw AppleScreenTimeAutomationError.verificationRequired }
        try await openChangePasscode()
        try await enterCode(passcode, expecting: .nextPrompt)
        // Authentication succeeded. Never enter another code during verification.
        try cancelCodePrompt()
        try await settle()
        guard try credentialPrompt() == nil else { throw AppleScreenTimeAutomationError.verificationRequired }
        guard try boolValue(passcodeSwitch(in: application)) else {
            throw AppleScreenTimeAutomationError.verificationRequired
        }
    }

    func release(passcode: String, restoreUnrestricted: Bool) async throws {
        // Caller obtains this credential only after the protected service authorizes full release.
        if restoreUnrestricted {
            let hasContentRestrictions = try await openWebSettings(passcode: passcode)
            if hasContentRestrictions {
                if try credentialPrompt() != nil { try await enterCode(passcode, expecting: .closed) }
                let current = try await webFilterLevel()
                if current == 1 {
                    try await selectWebFilter(0, passcode: passcode)
                } else if current != 0 {
                    // Never weaken a stricter allow-only policy added after setup.
                    throw AppleScreenTimeAutomationError.verificationRequired
                }
                try await closeWebSettings()
            } else {
                try await goBack()
            }
        }
        let lock = try passcodeSwitch(in: application)
        if try boolValue(lock) {
            try press(lock)
            try await settle()
            try await enterCode(passcode, expecting: .closed)
        }
        guard try !boolValue(passcodeSwitch(in: application)) else {
            throw AppleScreenTimeAutomationError.verificationRequired
        }
    }

    func inspectWebsites(passcode: String) async throws -> AppleScreenTimeWebsites {
        try await openWebsiteList(passcode: passcode)
        let websites = try websiteLists().websites
        try await closeWebsiteList()
        try await closeWebSettings()
        return websites
    }

    func updateWebsites(
        passcode: String, addRestricted: [String], removeRestricted: [String],
        addAllowed: [String], removeAllowed: [String]
    ) async throws -> AppleScreenTimeWebsites {
        try await openWebsiteList(passcode: passcode)
        for raw in removeAllowed { try await removeWebsite(raw, from: .allowed, passcode: passcode) }
        for raw in removeRestricted { try await removeWebsite(raw, from: .restricted, passcode: passcode) }
        for domain in addRestricted { try await addWebsite(domain, to: .restricted, passcode: passcode) }
        for domain in addAllowed { try await addWebsite(domain, to: .allowed, passcode: passcode) }
        let final = try websiteLists().websites
        try await closeWebsiteList()
        try await closeWebSettings()
        return final
    }

    private func closeWebsiteList() async throws {
        guard let sheet = try credentialPrompt(),
            let done = nodes(sheet).last(where: { role($0) == kAXButtonRole && enabled($0) })
        else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
        try press(done)
        try await settle()
    }

    private enum WebsiteKind { case allowed, restricted }

    private func addWebsite(_ domain: String, to kind: WebsiteKind, passcode: String) async throws {
        let list = try websiteLists()
        if (kind == .allowed ? list.websites.allowed : list.websites.restricted).contains(domain) { return }
        try press(kind == .allowed ? list.allowedAdd : list.restrictedAdd)
        try await settle()
        if (try? codePrompt()) != nil {
            try await authorizeWebsiteChange(passcode: passcode)
            if (try? websiteEntrySheet()) == nil {
                let current = try websiteLists()
                try press(kind == .allowed ? current.allowedAdd : current.restrictedAdd)
                try await settle()
            }
        }
        let sheet = try websiteEntrySheet()
        let field = try unique(sheet) { role($0) == kAXTextFieldRole }
        guard
            AXUIElementSetAttributeValue(
                field, kAXValueAttribute as CFString, "https://\(domain)" as CFString
            ) == .success
        else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
        guard
            let done = element(sheet, kAXDefaultButtonAttribute)
                ?? nodes(sheet).last(where: { role($0) == kAXButtonRole && enabled($0) })
        else {
            throw AppleScreenTimeAutomationError.websiteSyncUnavailable
        }
        try press(done)
        try await settle()
        let updated = try websiteLists().websites
        guard (kind == .allowed ? updated.allowed : updated.restricted).contains(domain) else {
            throw AppleScreenTimeAutomationError.websiteSyncUnavailable
        }
    }

    private func removeWebsite(_ raw: String, from kind: WebsiteKind, passcode: String) async throws {
        for attempt in 0..<2 {
            let list = try websiteLists()
            let rows = kind == .allowed ? list.allowedRows : list.restrictedRows
            let matches = rows.filter { $0.raw == raw }
            guard matches.count <= 1 else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
            guard let row = matches.first else { return }
            let selected =
                AXUIElementSetAttributeValue(
                    row.element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
            if !selected { try press(row.element) }
            let current = try websiteLists()
            try press(kind == .allowed ? current.allowedRemove : current.restrictedRemove)
            try await settle()
            if (try? codePrompt()) != nil {
                try await authorizeWebsiteChange(passcode: passcode)
            } else if attempt == 1 {
                break
            }
        }
        let remaining = try websiteLists().websites
        guard !(kind == .allowed ? remaining.allowedEntries : remaining.restrictedEntries).contains(raw) else {
            throw AppleScreenTimeAutomationError.websiteSyncUnavailable
        }
    }

    private struct WebsiteRow {
        let element: AXUIElement
        let raw: String
        let domain: String?
    }

    private struct WebsiteLists {
        let websites: AppleScreenTimeWebsites
        let allowedRows: [WebsiteRow]
        let restrictedRows: [WebsiteRow]
        let allowedAdd: AXUIElement
        let allowedRemove: AXUIElement
        let restrictedAdd: AXUIElement
        let restrictedRemove: AXUIElement
    }

    private func websiteEntrySheet() throws -> AXUIElement {
        guard let sheet = try credentialPrompt(),
            (try? unique(sheet) { role($0) == kAXTextFieldRole }) != nil
        else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
        return sheet
    }

    private func openWebsiteList(passcode: String) async throws {
        if (try? websiteLists()) != nil { return }
        if (try? webFilter()) == nil {
            guard try await openWebSettings(passcode: passcode) else {
                throw AppleScreenTimeAutomationError.websiteSyncUnavailable
            }
        }
        let customize = try unique(try application) { node in
            guard role(node) == kAXButtonRole, enabled(node), let container = parent(of: node) else {
                return false
            }
            return nodes(container).contains { role($0) == kAXPopUpButtonRole }
        }
        try press(customize)
        try await settle()
        try await authorizeWebsiteChange(passcode: passcode)
        _ = try websiteLists()
    }

    private func authorizeWebsiteChange(passcode: String) async throws {
        if (try? codePrompt()) != nil {
            try await enterCode(passcode, expecting: .closed)
        }
    }

    private func websiteLists() throws -> WebsiteLists {
        guard let sheet = try credentialPrompt() else {
            throw AppleScreenTimeAutomationError.websiteSyncUnavailable
        }
        let headings = nodes(sheet).filter { role($0) == "AXHeading" }
        let sections = headings.compactMap { try? websiteSection(after: $0) }
        guard headings.count == 2, sections.count == 2,
            let bundle = Bundle(path: "/System/Library/PrivateFrameworks/ScreenTimeUI.framework")
        else {
            throw AppleScreenTimeAutomationError.websiteSyncUnavailable
        }
        let restrictedTitle = bundle.localizedString(forKey: "RestrictedTitle", value: nil, table: "Localizable")
        guard restrictedTitle != "RestrictedTitle",
            [kAXValueAttribute, kAXTitleAttribute].contains(where: {
                text(headings[1], $0) == restrictedTitle
            })
        else {
            throw AppleScreenTimeAutomationError.websiteSyncUnavailable
        }
        let allowedSection = sections[0]
        let restrictedSection = sections[1]
        let restrictedRows = try websiteRows(in: restrictedSection)
        let allowedRows = try websiteRows(in: allowedSection)
        let allowedButtons = nodes(allowedSection).filter { role($0) == kAXButtonRole }
        let restrictedButtons = nodes(restrictedSection).filter { role($0) == kAXButtonRole }
        guard allowedButtons.count >= 2, restrictedButtons.count >= 2 else {
            throw AppleScreenTimeAutomationError.websiteSyncUnavailable
        }
        return WebsiteLists(
            websites: AppleScreenTimeWebsites(
                restricted: Set(restrictedRows.compactMap(\.domain)),
                allowed: Set(allowedRows.compactMap(\.domain)),
                restrictedEntries: restrictedRows.map(\.raw),
                allowedEntries: allowedRows.map(\.raw)),
            allowedRows: allowedRows,
            restrictedRows: restrictedRows,
            allowedAdd: allowedButtons[0], allowedRemove: allowedButtons[1],
            restrictedAdd: restrictedButtons[0], restrictedRemove: restrictedButtons[1]
        )
    }

    private func websiteSection(after heading: AXUIElement) throws -> AXUIElement {
        guard let parent = parent(of: heading),
            let siblings = attribute(parent, kAXChildrenAttribute) as? [AXUIElement],
            let index = siblings.firstIndex(where: { CFEqual($0, heading) }),
            siblings.indices.contains(index + 1), role(siblings[index + 1]) == kAXGroupRole
        else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
        return siblings[index + 1]
    }

    private func websiteRows(in section: AXUIElement) throws -> [WebsiteRow] {
        let list = try unique(section) { role($0) == kAXListRole }
        return try nodes(list).filter { role($0) == kAXRowRole }.map { row in
            let value =
                [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
                .map { text(row, $0) }.first { !$0.isEmpty }
                ?? nodes(row).filter { role($0) == kAXStaticTextRole }
                .map { text($0, kAXValueAttribute) }.first { !$0.isEmpty }
            guard let value else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
            if let components = URLComponents(string: value),
                ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                let host = components.host, let domain = DomainRule.normalize(host)
            {
                let whole =
                    components.port == nil
                    && ["", "/"].contains(components.path)
                    && components.query == nil && components.fragment == nil
                return WebsiteRow(element: row, raw: value, domain: whole ? domain : nil)
            }
            guard let domain = DomainRule.normalize(value) else {
                throw AppleScreenTimeAutomationError.websiteSyncUnavailable
            }
            return WebsiteRow(element: row, raw: value, domain: domain)
        }
    }

    private func openChangePasscode() async throws {
        let lock = try passcodeSwitch(in: application)
        guard let group = parent(of: lock) else {
            throw AppleScreenTimeAutomationError.unsupportedScreen
        }
        try press(try unique(group) { role($0) == kAXButtonRole })
        try await settle()
        _ = try codePrompt()
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

    private enum CodeTransition: Equatable { case nextPrompt, closed }

    private struct CodePrompt {
        let heading: String
        let fields: [AXUIElement]
        let focusedField: AXUIElement?
        let processID: pid_t
        let hasRecoveryOption: Bool
    }

    private func codePrompt() throws -> CodePrompt {
        guard let prompt = try credentialPrompt() else {
            throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow
        }
        let children = nodes(prompt)
        let fields = children.filter {
            enabled($0)
                && (role($0) == "AXSecureTextField"
                    || ["AXPasscodeBox", kAXSecureTextFieldSubrole].contains(text($0, kAXSubroleAttribute)))
        }
        let heading = children.filter { role($0) == kAXStaticTextRole }
            .map { text($0, kAXValueAttribute) }.first { !$0.isEmpty }
        guard !fields.isEmpty, let heading else {
            throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow
        }
        let focused = fields.first { (attribute($0, kAXFocusedAttribute) as? NSNumber)?.boolValue == true }
        var processID: pid_t = 0
        guard AXUIElementGetPid(focused ?? fields[0], &processID) == .success, processID > 0 else {
            throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow
        }
        return CodePrompt(
            heading: heading, fields: fields, focusedField: focused, processID: processID,
            hasRecoveryOption: children.filter { role($0) == kAXButtonRole }.count > 1)
    }

    private func cancelCodePrompt() throws {
        if let prompt = try credentialPrompt(),
            let cancel = element(prompt, kAXCancelButtonAttribute)
        {
            try press(cancel)
            return
        }
        // Some Settings views do not publish AXCancelButton. Escape cancels the native sheet.
        try postKey(53, character: nil, into: try codePrompt().processID)
    }

    private func enterCode(_ code: String, expecting transition: CodeTransition) async throws {
        guard validCode(code) else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        let start = try codePrompt()
        if start.fields.allSatisfy({ isSettable($0, kAXValueAttribute) }) {
            guard start.fields.count == 1 || start.fields.count == code.utf8.count else {
                throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow
            }
            for (field, value) in zip(start.fields, start.fields.count == 1 ? [code] : code.map(String.init)) {
                guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString) == .success
                else { throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow }
            }
        } else {
            guard start.focusedField != nil else { throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow }
            for digit in code.utf8 {
                let current = try codePrompt()
                guard current.heading == start.heading, current.focusedField != nil,
                    current.processID == start.processID
                else { throw AppleScreenTimeAutomationError.verificationRequired }
                try typeDigit(digit, into: current.processID)
                try await Task.sleep(for: .milliseconds(90))
            }
        }
        var closedSamples = 0
        for sample in 0..<25 {
            try await Task.sleep(for: .milliseconds(100))
            guard let prompt = try credentialPrompt() else {
                closedSamples += 1
                if transition == .closed, closedSamples >= 5 { return }
                continue
            }
            closedSamples = 0
            if transition == .closed, (try? codePrompt()) == nil { return }
            if transition == .nextPrompt, let next = try? codePrompt(),
                next.heading != start.heading,
                !start.hasRecoveryOption || !next.hasRecoveryOption
            {
                return
            }
            if sample == 6,
                let button = element(prompt, kAXDefaultButtonAttribute)
            {
                let cancel = element(prompt, kAXCancelButtonAttribute)
                if cancel.map({ !CFEqual(button, $0) }) ?? true { try press(button) }
            }
        }
        throw AppleScreenTimeAutomationError.verificationRequired
    }

    private func typeDigit(_ digit: UInt8, into processID: pid_t) throws {
        guard let key = Self.keypadCode(for: digit) else {
            throw AppleScreenTimeAutomationError.unsupportedScreen
        }
        try postKey(key, character: UniChar(digit), into: processID)
    }

    private func postKey(_ key: CGKeyCode, character: UniChar?, into processID: pid_t) throws {
        guard let source = CGEventSource(stateID: .privateState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow }
        for event in [down, up] {
            if let character {
                var unicode = [character]
                event.flags = .maskNumericPad
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode)
            }
            event.postToPid(processID)
        }
    }

    private static func keypadCode(for digit: UInt8) -> CGKeyCode? {
        guard (48...57).contains(digit) else { return nil }
        // ANSI keypad virtual key codes, independent of the selected keyboard layout.
        let codes: [CGKeyCode] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        return codes[Int(digit - 48)]
    }

    private func openWebSettings(
        enableContentRestrictions: Bool = false, passcode: String? = nil
    ) async throws -> Bool {
        let root = try application
        let sectionButtons = nodes(root).filter { role($0) == "AXHeading" }
            .compactMap { heading -> AXUIElement? in
                guard let parent = parent(of: heading),
                    let siblings = attribute(parent, kAXChildrenAttribute) as? [AXUIElement],
                    let index = siblings.firstIndex(where: { CFEqual($0, heading) }),
                    siblings.indices.contains(index + 1), role(siblings[index + 1]) == kAXButtonRole
                else { return nil }
                return siblings[index + 1]
            }
        guard sectionButtons.count == 1 else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        try press(sectionButtons[0])
        try await settle()
        if let passcode { try await authorizeWebsiteChange(passcode: passcode) }
        let toggle = try unique(try application) { role($0) == kAXCheckBoxRole }
        if try !boolValue(toggle) {
            guard enableContentRestrictions else { return false }
            try press(toggle)
            try await settle()
            if let passcode { try await authorizeWebsiteChange(passcode: passcode) }
            guard try boolValue(toggle) else { throw AppleScreenTimeAutomationError.verificationRequired }
        }
        guard let parent = parent(of: toggle),
            let first = nodes(parent).first(where: { role($0) == kAXButtonRole && enabled($0) })
        else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        try press(first)
        try await settle()
        return true
    }

    private func closeWebSettings() async throws {
        guard let sheet = try credentialPrompt(),
            let done = nodes(sheet).last(where: { role($0) == kAXButtonRole && enabled($0) })
        else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        try press(done)
        try await settle()
        try await goBack()
    }

    private func goBack() async throws {
        let toolbar = try unique(try application) { role($0) == kAXToolbarRole }
        let buttons = nodes(toolbar).filter { [kAXButtonRole, kAXMenuButtonRole].contains(role($0)) }
        guard let back = buttons.first else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        try press(back)
        try await settle()
    }

    private func screenTimeRoot() async throws -> AXUIElement {
        let root = try application
        if (try? passcodeSwitch(in: root)) != nil { return root }
        try await goBack()
        let previous = try application
        _ = try passcodeSwitch(in: previous)
        return previous
    }

    private func webFilter() throws -> AXUIElement {
        try unique(try application) {
            guard role($0) == kAXPopUpButtonRole, let container = parent(of: $0) else {
                return false
            }
            return nodes(container).contains { role($0) == kAXButtonRole }
        }
    }

    private func webFilterChoices() async throws -> [(AXUIElement, String)] {
        try press(try webFilter())
        try await settle()
        let items = nodes(try application).filter { role($0) == kAXMenuItemRole }
        guard items.count >= 3 else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        return items.prefix(3).map { ($0, text($0, kAXTitleAttribute)) }
    }

    private func webFilterLevel() async throws -> Int {
        let popup = try webFilter()
        let current = text(popup, kAXValueAttribute)
        var pid: pid_t = 0
        guard AXUIElementGetPid(popup, &pid) == .success, pid > 0 else {
            throw AppleScreenTimeAutomationError.unsupportedScreen
        }
        let choices = try await webFilterChoices()
        let level = choices.firstIndex(where: { $0.1 == current })
        try postKey(53, character: nil, into: pid)
        try await settle()
        guard let level, level < 3 else {
            throw AppleScreenTimeAutomationError.unsupportedScreen
        }
        return level
    }

    private func selectWebFilter(_ level: Int, passcode: String?) async throws {
        let choices = try await webFilterChoices()
        guard choices.indices.contains(level) else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        try press(choices[level].0)
        try await settle()
        if let passcode { try await authorizeWebsiteChange(passcode: passcode) }
        guard text(try webFilter(), kAXValueAttribute) == choices[level].1 else {
            throw AppleScreenTimeAutomationError.verificationRequired
        }
    }

    private func passcodeSwitch(in root: AXUIElement) throws -> AXUIElement {
        let switches = nodes(root).filter { role($0) == kAXCheckBoxRole }
        let withAction = switches.filter { node in
            guard let group = parent(of: node) else { return false }
            return nodes(group).contains { role($0) == kAXButtonRole && enabled($0) }
        }
        if withAction.count == 1 { return withAction[0] }
        // When no code exists, Settings has no Change button beside the switch.
        let unnamed = switches.filter { text($0, kAXIdentifierAttribute).isEmpty }
        guard unnamed.count == 1 else { throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow }
        return unnamed[0]
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

    private func parent(of node: AXUIElement) -> AXUIElement? {
        element(node, kAXParentAttribute)
    }

    private func element(_ node: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(node, key), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func isSettable(_ node: AXUIElement, _ key: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(node, key as CFString, &settable) == .success && settable.boolValue
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
