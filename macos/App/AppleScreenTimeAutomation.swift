import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum ScreenTimePasscodeStage: Hashable {
    case authenticateChange, authenticate, create, confirm, recovery
}

/// Match the installed system's translations, including a language set only for Settings.
/// Values read from the AX tree are never retained in this catalog.
struct ScreenTimeUIStrings {
    private let values: [String: Set<String>]

    init(values: [String: Set<String>]) { self.values = values }

    init() {
        let paths = [
            "/System/Library/ExtensionKit/Extensions/ScreenTimePreferencesExtension.appex",
            "/System/Library/PrivateFrameworks/ScreenTimeSettingsServicesUI.framework",
            "/System/Library/PrivateFrameworks/ScreenTimeSettingsUI.framework",
            "/System/Library/PrivateFrameworks/ScreenTimeUI.framework",
            "/System/Library/PrivateFrameworks/ScreenTimeServiceUI.framework/Versions/A/XPCServices/ScreenTimeViewService.xpc",
        ]
        var result: [String: Set<String>] = [:]
        for path in paths {
            guard let bundle = Bundle(path: path) else { continue }
            for table in ["Localizable", "Restrictions"] {
                if let url = bundle.url(forResource: table, withExtension: "loctable"),
                    let data = try? Data(contentsOf: url),
                    let locales = try? PropertyListSerialization.propertyList(from: data, format: nil)
                        as? [String: [String: Any]]
                {
                    for translations in locales.values { Self.collect(translations, into: &result) }
                }
                for locale in bundle.localizations {
                    guard
                        let url = bundle.url(
                            forResource: table, withExtension: "strings", subdirectory: nil, localization: locale),
                        let data = try? Data(contentsOf: url),
                        let translations = try? PropertyListSerialization.propertyList(from: data, format: nil)
                            as? [String: Any]
                    else { continue }
                    Self.collect(translations, into: &result)
                }
            }
        }
        values = result
    }

    func matches(_ text: String, keys: [String]) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && keys.contains { values[$0]?.contains(text) == true }
    }

    func passcodeStage(
        labels: [String], expected: ScreenTimePasscodeStage? = nil
    ) -> ScreenTimePasscodeStage? {
        let meanings = labels.map { label in
            Set(Self.stageKeys.filter { matches(label, keys: $0.value) }.map(\.key))
        }.filter { !$0.isEmpty }
        guard let first = meanings.first else { return nil }
        var stages = meanings.dropFirst().reduce(first) { $0.intersection($1) }
        if let expected { stages.formIntersection([expected]) }
        return stages.count == 1 ? stages.first : nil
    }

    func webFilterLevel(_ label: String) -> Int? {
        let levels = Self.filterKeys.indices.filter { matches(label, keys: Self.filterKeys[$0]) }
        return levels.count == 1 ? levels[0] : nil
    }

    private static let stageKeys: [ScreenTimePasscodeStage: [String]] = [
        .authenticateChange: ["AuthenticateToUpdatePasscodeHelpText", "Enter old Screen Time passcode"],
        .authenticate: ["AuthenticateToSetOrRemovePasscodeHelpText", "Enter Screen Time Passcode"],
        .create: [
            "SetPasscodeHelpText", "UpdatePasscodeHelpText", "Set a Screen Time Passcode",
            "Enter new Screen Time passcode",
        ],
        .confirm: [
            "VerifySetPasscodeHelpText", "VerifyUpdatePasscodeHelpText", "Re-enter Screen Time Passcode",
            "Re-enter new Screen Time passcode",
        ],
        .recovery: ["RecoveryAppleIDAlertTitle", "Screen Time Passcode Recovery"],
    ]
    private static let filterKeys = [
        ["UnrestrictedAccessSpecifierName", "Unrestricted"],
        ["LimitAdultWebsitesSpecifierName", "Limit Adult Websites"],
        ["AllowedWebsitesSpecifierName", "Approved Websites Only"],
    ]
    private static let controlKeys = [
        "Lock Screen Time Settings", "Use a passcode to secure Screen Time settings.",
        "Content & Privacy", "ContentPrivacyTitle",
        "ContentRestrictionsTitle", "ContentRestrictionsTitle_GreyMatterAlternate", "AADC_ContentRestrictionsTitle",
        "WebContentSpecifierName", "RestrictedTitle", "Allowed", "DoneButton", "Done",
        "Access to Web Content", "Customize…", "Change Passcode…", "Add", "Remove", "Add Website",
        "Restrict explicit content, purchases, downloads, and privacy settings.",
        "Family Member",
    ]

    private static func collect(_ translations: [String: Any], into result: inout [String: Set<String>]) {
        for key in controlKeys + stageKeys.values.flatMap({ $0 }) + filterKeys.flatMap({ $0 }) {
            if let value = translations[key] as? String, !value.isEmpty {
                result[key, default: []].insert(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

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
    case contentRestrictionsRequired
    case unsupportedWebsitePolicy
    case personalSettingsRequired
    case settingsNotResponding
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Screen Time is in use by another Hard Pause operation. Wait for it to finish, then try again."
        case .accessibilityRequired:
            return "Allow Hard Pause in System Settings → Privacy & Security → Accessibility, then try again."
        case .unsupportedScreen:
            return
                "Screen Time controls were not recognized. Keep System Settings open and try again. Any saved code is retained."
        case .unsupportedPasscodeFlow:
            return
                "Hard Pause cannot find a usable Screen Time passcode control on this macOS version. Automatic setup is unavailable here. Your plans stay active."
        case .existingPasscodeRequired:
            return
                "Enter the current four-digit Screen Time code to replace it. Hard Pause will not remove an unknown code."
        case .recoveryRequired:
            return
                "Finish Apple's passcode recovery step in System Settings, then choose Verify setup. The new code is saved securely."
        case .verificationRequired:
            return
                "The saved code could not be verified. Protection is not confirmed. Keep System Settings open and choose Verify setup."
        case .websiteSyncUnavailable:
            return
                "Screen Time website sync could not be verified. Check Content & Privacy in System Settings, then retry."
        case .contentRestrictionsRequired:
            return
                "For website sync, turn on Content & Privacy in Screen Time first. Review Apple's settings before you turn it on. You can also set up Hard Pause without website sync."
        case .unsupportedWebsitePolicy:
            return
                "Screen Time uses an allowed websites only policy. Hard Pause cannot sync website rules with this policy. You can set up Hard Pause without website sync."
        case .settingsNotResponding:
            return "System Settings did not respond. Wait until it is ready, then try again."
        case .personalSettingsRequired:
            return
                "Hard Pause cannot confirm whose Screen Time settings are selected in this family layout. Automatic setup is unavailable here."
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

    nonisolated static func validCode(_ value: String) -> Bool {
        value.utf8.count == 4 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

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
        try await openScreenTime()
        return try await worker.updateWebsites(
            passcode: passcode, addRestricted: addRestricted, removeRestricted: removeRestricted,
            addAllowed: addAllowed, removeAllowed: removeAllowed)
    }

    private func openScreenTime() async throws {
        guard AXIsProcessTrusted() else { throw AppleScreenTimeAutomationError.accessibilityRequired }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension"),
            NSWorkspace.shared.open(url)
        else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        try await worker.waitForScreenTime()
    }
}

/// AX calls can wait on another process; keep them off the app's main thread.
private actor ScreenTimeAccessibilityWorker {
    private lazy var strings = ScreenTimeUIStrings()
    private var readDeadline: ContinuousClock.Instant?

    func waitForScreenTime() async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        readDeadline = deadline
        defer { readDeadline = nil }
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                _ = try passcodeSwitch(in: application)
                return
            } catch AppleScreenTimeAutomationError.personalSettingsRequired {
                throw AppleScreenTimeAutomationError.personalSettingsRequired
            } catch AppleScreenTimeAutomationError.settingsNotResponding {
                throw AppleScreenTimeAutomationError.settingsNotResponding
            } catch {}
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AppleScreenTimeAutomationError.unsupportedScreen
    }
    private var application: AXUIElement {
        get throws {
            guard
                let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                    .first(where: { isScreenTimeProcess($0.processIdentifier) })
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
            throw AppleScreenTimeAutomationError.contentRestrictionsRequired
        }
        let level = try await webFilterLevel()
        try await closeWebSettings()
        guard level != 2 else { throw AppleScreenTimeAutomationError.unsupportedWebsitePolicy }
        return AppleScreenTimeInspection(hasPasscode: hasPasscode, adultFilterEnabled: level == 1)
    }

    func install(passcode: String, replacing old: String?, enableAdultFilter: Bool) async throws {
        guard AppleScreenTimeAutomation.validCode(passcode) else {
            throw AppleScreenTimeAutomationError.unsupportedScreen
        }
        if enableAdultFilter {
            guard try await openWebSettings(passcode: old) else {
                try await goBack()
                throw AppleScreenTimeAutomationError.contentRestrictionsRequired
            }
            let level = try await webFilterLevel()
            guard level != 2 else { throw AppleScreenTimeAutomationError.unsupportedWebsitePolicy }
            if level == 0 { try await selectWebFilter(1, passcode: old) }
            try await closeWebSettings()
        }
        let lock = try passcodeSwitch(in: application)
        if try boolValue(lock) {
            guard let old, AppleScreenTimeAutomation.validCode(old) else {
                throw AppleScreenTimeAutomationError.existingPasscodeRequired
            }
            try await openChangePasscode()
            try await enterCode(old, from: .authenticateChange, expecting: .prompt(.create))
        } else {
            try press(lock)
            try await settle()
        }
        try await enterCode(passcode, from: .create, expecting: .prompt(.confirm))
        try await enterCode(passcode, from: .confirm, expecting: .closed)
        guard try credentialPrompt() == nil else { throw AppleScreenTimeAutomationError.recoveryRequired }
        // Code acceptance must be proved by a separate native authentication, not a toggle alone.
    }

    func verify(passcode: String, requiresAdultFilter: Bool) async throws {
        let inspection = try await inspect(checkAdultFilter: requiresAdultFilter, passcode: passcode)
        guard inspection.hasPasscode, !requiresAdultFilter || inspection.adultFilterEnabled
        else { throw AppleScreenTimeAutomationError.verificationRequired }
        try await openChangePasscode()
        try await enterCode(passcode, from: .authenticateChange, expecting: .prompt(.create))
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
            try await enterCode(passcode, from: .authenticate, expecting: .closed)
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
        for domain in addRestricted { try await addWebsite(domain, to: .restricted, passcode: passcode) }
        for raw in removeRestricted { try await removeWebsite(raw, from: .restricted, passcode: passcode) }
        for domain in addAllowed { try await addWebsite(domain, to: .allowed, passcode: passcode) }
        let final = try websiteLists().websites
        try await closeWebsiteList()
        try await closeWebSettings()
        return final
    }

    private func closeWebsiteList() async throws {
        _ = try websiteLists()
        guard let sheet = try credentialPrompt() else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
        let done = try unique(sheet) { role($0) == kAXButtonRole && matches($0, keys: ["DoneButton", "Done"]) }
        try press(done)
        try await settle()
    }

    private enum WebsiteKind { case allowed, restricted }

    private func addWebsite(_ domain: String, to kind: WebsiteKind, passcode: String) async throws {
        let list = try websiteLists()
        if (kind == .allowed ? list.websites.allowed : list.websites.restricted).contains(domain) { return }
        try press(kind == .allowed ? list.allowedAdd : list.restrictedAdd)
        try await settle()
        if (try? codePrompt(expecting: .authenticate)) != nil {
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
        guard let done = element(sheet, kAXDefaultButtonAttribute),
            element(sheet, kAXCancelButtonAttribute).map({ !CFEqual($0, done) }) ?? true
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
            for other in rows where other.raw != raw {
                guard let selected = try readAttribute(other.element, kAXSelectedAttribute) as? NSNumber else {
                    throw AppleScreenTimeAutomationError.websiteSyncUnavailable
                }
                if selected.boolValue {
                    guard
                        AXUIElementSetAttributeValue(
                            other.element, kAXSelectedAttribute as CFString, kCFBooleanFalse) == .success
                    else { throw AppleScreenTimeAutomationError.websiteSyncUnavailable }
                }
            }
            let selected =
                AXUIElementSetAttributeValue(
                    row.element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
            if !selected { try press(row.element) }
            let current = try websiteLists()
            let currentRows = kind == .allowed ? current.allowedRows : current.restrictedRows
            let selectedRows = try currentRows.filter {
                guard let selected = try readAttribute($0.element, kAXSelectedAttribute) as? NSNumber else {
                    throw AppleScreenTimeAutomationError.websiteSyncUnavailable
                }
                return selected.boolValue
            }
            guard selectedRows.count == 1, selectedRows[0].raw == raw else {
                throw AppleScreenTimeAutomationError.websiteSyncUnavailable
            }
            try press(kind == .allowed ? current.allowedRemove : current.restrictedRemove)
            try await settle()
            if (try? codePrompt(expecting: .authenticate)) != nil {
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
            try nodes(sheet).contains(where: { matches($0, keys: ["Add Website"]) }),
            (try? unique(sheet) { role($0) == kAXTextFieldRole && text($0, kAXSubroleAttribute).isEmpty }) != nil
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
        let customize = try unique(try application) {
            role($0) == kAXButtonRole && matches($0, keys: ["Customize…"])
        }
        try press(customize)
        try await settle()
        try await authorizeWebsiteChange(passcode: passcode)
        _ = try websiteLists()
    }

    private func authorizeWebsiteChange(passcode: String) async throws {
        if (try? codePrompt(expecting: .authenticate)) != nil {
            try await enterCode(passcode, from: .authenticate, expecting: .authenticated)
        }
    }

    private func websiteLists() throws -> WebsiteLists {
        guard let sheet = try credentialPrompt() else {
            throw AppleScreenTimeAutomationError.websiteSyncUnavailable
        }
        let headings = try nodes(sheet).filter { role($0) == "AXHeading" }
        let allowedHeading = headings.filter { matches($0, keys: ["Allowed"]) }
        let restrictedHeading = headings.filter { matches($0, keys: ["RestrictedTitle"]) }
        guard allowedHeading.count == 1, restrictedHeading.count == 1 else {
            throw AppleScreenTimeAutomationError.websiteSyncUnavailable
        }
        let allowedSection = try websiteSection(after: allowedHeading[0])
        let restrictedSection = try websiteSection(after: restrictedHeading[0])
        let restrictedRows = try websiteRows(in: restrictedSection)
        let allowedRows = try websiteRows(in: allowedSection)
        return WebsiteLists(
            websites: AppleScreenTimeWebsites(
                restricted: Set(restrictedRows.compactMap(\.domain)),
                allowed: Set(allowedRows.compactMap(\.domain)),
                restrictedEntries: restrictedRows.map(\.raw),
                allowedEntries: allowedRows.map(\.raw)),
            allowedRows: allowedRows,
            restrictedRows: restrictedRows,
            allowedAdd: try unique(allowedSection) { role($0) == kAXButtonRole && matches($0, keys: ["Add"]) },
            allowedRemove: try unique(allowedSection) { role($0) == kAXButtonRole && matches($0, keys: ["Remove"]) },
            restrictedAdd: try unique(restrictedSection) { role($0) == kAXButtonRole && matches($0, keys: ["Add"]) },
            restrictedRemove: try unique(restrictedSection) {
                role($0) == kAXButtonRole && matches($0, keys: ["Remove"])
            }
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
        guard try readAttribute(list, kAXChildrenAttribute) is [AXUIElement] else {
            throw AppleScreenTimeAutomationError.websiteSyncUnavailable
        }
        return try nodes(list).filter {
            guard let role = try readAttribute($0, kAXRoleAttribute) as? String else {
                throw AppleScreenTimeAutomationError.websiteSyncUnavailable
            }
            return role == kAXRowRole
        }.map { row in
            var value = try [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
                .compactMap { try readAttribute(row, $0) as? String }.first { !$0.isEmpty }
            if value == nil {
                value = try nodes(row).filter {
                    guard let role = try readAttribute($0, kAXRoleAttribute) as? String else {
                        throw AppleScreenTimeAutomationError.websiteSyncUnavailable
                    }
                    return role == kAXStaticTextRole
                }.compactMap { try readAttribute($0, kAXValueAttribute) as? String }.first { !$0.isEmpty }
            }
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
        try press(try unique(group) { role($0) == kAXButtonRole && matches($0, keys: ["Change Passcode…"]) })
        try await settle()
        _ = try codePrompt()
    }

    private func credentialPrompt() throws -> AXUIElement? {
        let all = try nodes(application)
        let sheets = try all.filter {
            guard let role = try readAttribute($0, kAXRoleAttribute) as? String else {
                throw AppleScreenTimeAutomationError.unsupportedScreen
            }
            return role == kAXSheetRole
        }
        if sheets.count == 1 { return sheets[0] }
        guard sheets.isEmpty else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        let dialogs = try all.filter { try readAttribute($0, kAXSubroleAttribute) as? String == kAXDialogSubrole }
        guard dialogs.count <= 1 else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        return dialogs.first
    }

    private enum CodeTransition: Equatable {
        case prompt(ScreenTimePasscodeStage)
        case authenticated, closed
    }

    private struct CodePrompt {
        let stage: ScreenTimePasscodeStage
        let fields: [AXUIElement]
        let focusedField: AXUIElement?
        let processID: pid_t
    }

    private func codePrompt(expecting stage: ScreenTimePasscodeStage? = nil) throws -> CodePrompt {
        guard let prompt = try credentialPrompt() else {
            throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow
        }
        return try codePrompt(children: nodes(prompt), expecting: stage)
    }

    private func codePrompt(
        children: [AXUIElement], expecting expected: ScreenTimePasscodeStage? = nil
    ) throws -> CodePrompt {
        let fields = children.filter {
            enabled($0)
                && (role($0) == "AXSecureTextField"
                    || ["AXPasscodeBox", kAXSecureTextFieldSubrole].contains(text($0, kAXSubroleAttribute)))
        }
        guard [1, 4].contains(fields.count), let stage = promptStage(in: children, expecting: expected),
            stage != .recovery
        else {
            throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow
        }
        let focused = fields.first { (attribute($0, kAXFocusedAttribute) as? NSNumber)?.boolValue == true }
        var processID: pid_t = 0
        guard AXUIElementGetPid(focused ?? fields[0], &processID) == .success, isScreenTimeProcess(processID) else {
            throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow
        }
        guard
            fields.allSatisfy({ field in
                var owner: pid_t = 0
                return AXUIElementGetPid(field, &owner) == .success && owner == processID
            })
        else { throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow }
        return CodePrompt(
            stage: stage, fields: fields, focusedField: focused, processID: processID)
    }

    private func promptStage(
        in children: [AXUIElement], expecting stage: ScreenTimePasscodeStage? = nil
    ) -> ScreenTimePasscodeStage? {
        let labels = children.filter {
            [kAXStaticTextRole, "AXHeading"].contains(role($0))
                && !["AXPasscodeBox", kAXSecureTextFieldSubrole].contains(text($0, kAXSubroleAttribute))
        }.flatMap { [text($0, kAXValueAttribute), text($0, kAXTitleAttribute)] }
        return strings.passcodeStage(labels: labels, expected: stage)
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

    private func enterCode(
        _ code: String, from stage: ScreenTimePasscodeStage, expecting transition: CodeTransition
    ) async throws {
        guard AppleScreenTimeAutomation.validCode(code) else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        let start = try codePrompt(expecting: stage)
        switch transition {
        case .prompt(.create):
            guard start.stage == .authenticateChange else { throw AppleScreenTimeAutomationError.verificationRequired }
        case .prompt(.confirm):
            guard start.stage == .create else { throw AppleScreenTimeAutomationError.verificationRequired }
        case .authenticated:
            guard start.stage == .authenticate else { throw AppleScreenTimeAutomationError.verificationRequired }
        case .closed:
            guard [.authenticate, .confirm].contains(start.stage) else {
                throw AppleScreenTimeAutomationError.verificationRequired
            }
        default:
            throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow
        }
        if start.fields.allSatisfy({ isSettable($0, kAXValueAttribute) }) {
            guard start.fields.count == 1 || start.fields.count == code.utf8.count else {
                throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow
            }
            for (field, value) in zip(start.fields, start.fields.count == 1 ? [code] : code.map(String.init)) {
                guard isScreenTimeProcess(start.processID),
                    AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString) == .success
                else { throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow }
            }
        } else {
            guard start.focusedField != nil else { throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow }
            for digit in code.utf8 {
                let current = try codePrompt(expecting: stage)
                guard current.stage == start.stage, current.focusedField != nil,
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
                if [.closed, .authenticated].contains(transition), closedSamples >= 5 { return }
                continue
            }
            closedSamples = 0
            let children = try nodes(prompt)
            if promptStage(in: children) == .recovery {
                throw AppleScreenTimeAutomationError.recoveryRequired
            }
            let samePrompt = try? codePrompt(children: children, expecting: stage)
            if case .prompt(let expected) = transition,
                (try? codePrompt(children: children, expecting: expected)) != nil,
                promptStage(in: children, expecting: stage) == nil
            {
                return
            }
            if transition == .authenticated, samePrompt == nil,
                (try? webFilter(in: prompt)) != nil || (try? websiteLists()) != nil || (try? websiteEntrySheet()) != nil
            {
                return
            }
            if sample == 6, samePrompt?.processID == start.processID,
                let button = element(prompt, kAXDefaultButtonAttribute)
            {
                let cancel = element(prompt, kAXCancelButtonAttribute)
                if cancel.map({ !CFEqual(button, $0) }) ?? true { try press(button) }
            }
        }
        throw AppleScreenTimeAutomationError.verificationRequired
    }

    private func isScreenTimeProcess(_ processID: pid_t) -> Bool {
        let bundles = [
            "com.apple.systempreferences": "/System/Applications/System Settings.app",
            "com.apple.Screen-Time-Settings.extension":
                "/System/Library/ExtensionKit/Extensions/ScreenTimePreferencesExtension.appex",
            "com.apple.ScreenTimeViewService":
                "/System/Library/PrivateFrameworks/ScreenTimeServiceUI.framework/Versions/A/XPCServices/ScreenTimeViewService.xpc",
        ]
        guard processID > 0, let app = NSRunningApplication(processIdentifier: processID),
            let identifier = app.bundleIdentifier, let path = bundles[identifier],
            let expected = Bundle(path: path)?.executableURL,
            let actual = app.executableURL
        else { return false }
        return actual.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath()
    }

    private func typeDigit(_ digit: UInt8, into processID: pid_t) throws {
        guard let key = Self.keypadCode(for: digit) else {
            throw AppleScreenTimeAutomationError.unsupportedScreen
        }
        try postKey(key, character: UniChar(digit), into: processID)
    }

    private func postKey(_ key: CGKeyCode, character: UniChar?, into processID: pid_t) throws {
        guard isScreenTimeProcess(processID), let source = CGEventSource(stateID: .privateState),
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

    private func openWebSettings(passcode: String? = nil) async throws -> Bool {
        let root = try application
        _ = try passcodeSwitch(in: root)
        try press(try unique(root) { role($0) == kAXButtonRole && matches($0, keys: ["Content & Privacy"]) })
        try await settle()
        if let passcode { try await authorizeWebsiteChange(passcode: passcode) }
        let toggle = try unique(try application) {
            role($0) == kAXCheckBoxRole
                && matches(
                    $0,
                    keys: [
                        "Restrict explicit content, purchases, downloads, and privacy settings.", "ContentPrivacyTitle",
                    ])
        }
        if try !boolValue(toggle) {
            return false
        }
        let content = try unique(try application) {
            role($0) == kAXButtonRole
                && matches(
                    $0,
                    keys: [
                        "ContentRestrictionsTitle", "ContentRestrictionsTitle_GreyMatterAlternate",
                        "AADC_ContentRestrictionsTitle",
                    ])
        }
        try press(content)
        try await settle()
        if let passcode { try await authorizeWebsiteChange(passcode: passcode) }
        return true
    }

    private func closeWebSettings() async throws {
        _ = try webFilter()
        guard let sheet = try credentialPrompt() else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        let done = try unique(sheet) { role($0) == kAXButtonRole && matches($0, keys: ["DoneButton", "Done"]) }
        try press(done)
        try await settle()
        try await goBack()
    }

    private func goBack() async throws {
        let toolbar = try unique(try application) { role($0) == kAXToolbarRole }
        let back = try unique(toolbar) {
            [kAXButtonRole, kAXMenuButtonRole].contains(role($0))
                && text($0, kAXIdentifierAttribute) == "chevron.backward"
        }
        try press(back)
        try await settle()
    }

    private func screenTimeRoot() async throws -> AXUIElement {
        let root = try application
        _ = try passcodeSwitch(in: root)
        return root
    }

    private func webFilter(in root: AXUIElement? = nil) throws -> AXUIElement {
        try unique(try root ?? application) {
            role($0) == kAXPopUpButtonRole && matches($0, keys: ["Access to Web Content", "WebContentSpecifierName"])
        }
    }

    private func webFilterChoices() async throws -> [(AXUIElement, String)] {
        try press(try webFilter())
        try await settle()
        let choices = try nodes(application).filter { role($0) == kAXMenuItemRole }.compactMap { item in
            let title = text(item, kAXTitleAttribute)
            return strings.webFilterLevel(title).map { ($0, item, title) }
        }
        guard choices.count == 3, Set(choices.map { $0.0 }) == Set(0..<3) else {
            throw AppleScreenTimeAutomationError.unsupportedScreen
        }
        return choices.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }

    private func webFilterLevel() async throws -> Int {
        guard let level = strings.webFilterLevel(text(try webFilter(), kAXValueAttribute)) else {
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
        let controls = try nodes(root)
        guard
            try !controls.contains(where: { node in
                try matchingLabels(node).contains { strings.matches($0, keys: ["Family Member"]) }
            })
        else {
            throw AppleScreenTimeAutomationError.personalSettingsRequired
        }
        let switches = controls.filter {
            role($0) == kAXCheckBoxRole
                && matches($0, keys: ["Lock Screen Time Settings", "Use a passcode to secure Screen Time settings."])
        }
        guard switches.count == 1 else { throw AppleScreenTimeAutomationError.unsupportedPasscodeFlow }
        return switches[0]
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }

    private func press(_ node: AXUIElement) throws {
        guard enabled(node), AXUIElementPerformAction(node, kAXPressAction as CFString) == .success else {
            throw AppleScreenTimeAutomationError.unsupportedScreen
        }
    }

    private func unique(_ root: AXUIElement, matching predicate: (AXUIElement) -> Bool) throws -> AXUIElement {
        let matches = try nodes(root).filter(predicate)
        guard matches.count == 1 else { throw AppleScreenTimeAutomationError.unsupportedScreen }
        return matches[0]
    }

    private func nodes(_ root: AXUIElement) throws -> [AXUIElement] {
        var result: [AXUIElement] = []
        var pending = [(root, 0)]
        while let (node, depth) = pending.popLast() {
            guard result.count < 1_500 else { throw AppleScreenTimeAutomationError.unsupportedScreen }
            result.append(node)
            if let value = try readAttribute(node, kAXChildrenAttribute) {
                guard let children = value as? [AXUIElement] else {
                    throw AppleScreenTimeAutomationError.unsupportedScreen
                }
                if !children.isEmpty {
                    guard depth < 20 else { throw AppleScreenTimeAutomationError.unsupportedScreen }
                    pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
                }
            }
        }
        return result
    }

    private func readAttribute(_ node: AXUIElement, _ key: String) throws -> CFTypeRef? {
        try Task.checkCancellation()
        if let readDeadline, ContinuousClock.now >= readDeadline {
            throw AppleScreenTimeAutomationError.settingsNotResponding
        }
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(node, key as CFString, &value) {
        case .success: return value
        case .attributeUnsupported, .noValue: return nil
        case .cannotComplete: throw AppleScreenTimeAutomationError.settingsNotResponding
        default: throw AppleScreenTimeAutomationError.unsupportedScreen
        }
    }

    private func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        try? readAttribute(node, key)
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
    private func matches(_ node: AXUIElement, keys: [String]) -> Bool {
        (try? matchingLabels(node).contains { strings.matches($0, keys: keys) }) == true
    }

    private func matchingLabels(_ node: AXUIElement) throws -> [String] {
        var labels = try [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { try readAttribute(node, $0) as? String }
        guard let role = try readAttribute(node, kAXRoleAttribute) as? String else {
            throw AppleScreenTimeAutomationError.unsupportedScreen
        }
        if [kAXStaticTextRole, "AXHeading"].contains(role),
            try readAttribute(node, kAXSubroleAttribute) as? String != "AXPasscodeBox",
            let value = try readAttribute(node, kAXValueAttribute) as? String
        {
            labels.append(value)
        }
        if let title = try readAttribute(node, kAXTitleUIElementAttribute),
            CFGetTypeID(title) == AXUIElementGetTypeID(),
            let value = try readAttribute(title as! AXUIElement, kAXValueAttribute) as? String
        {
            labels.append(value)
        }
        return labels
    }
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
