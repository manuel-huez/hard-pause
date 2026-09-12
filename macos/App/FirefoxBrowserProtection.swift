import AppKit
import ApplicationServices
import Foundation

/// Redirects the current Firefox tab without Apple events, the clipboard, or global input.
@MainActor
final class FirefoxBrowserProtection {
    private static let firefoxBundleIdentifier = "org.mozilla.firefox"
    private static let scanLimit = 192
    private static let returnKeyCode: CGKeyCode = 36
    private static let webAreaRole = "AXWebArea"

    func requestPermission() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        guard !AXIsProcessTrusted(),
            let settings = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        else { return }
        NSWorkspace.shared.open(settings)
    }

    func check(rules: [ProtectedRules], page: URL) -> String {
        guard AXIsProcessTrusted() else {
            return "Allow Hard Pause in Accessibility."
        }
        guard let firefox = NSWorkspace.shared.frontmostApplication,
            firefox.bundleIdentifier == Self.firefoxBundleIdentifier
        else {
            return "Connected · activate Firefox to check its current tab."
        }
        guard rules.contains(where: { !$0.allBlockedDomains.isEmpty || !$0.blockedURLPatterns.isEmpty })
        else {
            return "Connected · no website rules apply."
        }

        let pid = firefox.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        guard let window = Self.element(Self.attribute(application, kAXFocusedWindowAttribute)),
            Self.belongsToProcess(window, pid: pid),
            let target = Self.scan(window: window, pid: pid),
            let observedURL = Self.url(from: Self.attribute(target.document, kAXURLAttribute))
        else {
            return "Cannot read the current Firefox tab."
        }
        guard observedURL != page, BrowserURLMatcher.matches(observedURL, rules: rules) else {
            return "Checking current tab"
        }
        guard !Self.isBeingEdited(target.address, application: application) else {
            return "Finish editing the Firefox address field to resume checks."
        }

        // Re-read every mutable reference immediately before changing Firefox. A tab switch,
        // navigation, window change, or focus change makes this check a no-op until the next poll.
        guard let currentFirefox = NSWorkspace.shared.frontmostApplication,
            currentFirefox.bundleIdentifier == Self.firefoxBundleIdentifier,
            currentFirefox.processIdentifier == pid,
            let currentWindow = Self.element(Self.attribute(application, kAXFocusedWindowAttribute)),
            CFEqual(currentWindow, window),
            let current = Self.scan(window: currentWindow, pid: pid),
            CFEqual(current.document, target.document),
            CFEqual(current.address, target.address),
            let currentURL = Self.url(from: Self.attribute(current.document, kAXURLAttribute)),
            currentURL.absoluteString == observedURL.absoluteString,
            currentURL != page,
            BrowserURLMatcher.matches(currentURL, rules: rules),
            !Self.isBeingEdited(current.address, application: application),
            Self.focusAndSet(current.address, value: page.absoluteString)
        else {
            return "Firefox changed before the blocked page could be redirected."
        }

        return Self.submit(current.address, pid: pid)
            ? "Redirected blocked page."
            : "Cannot open the local pause page in Firefox."
    }

    private struct Target {
        let document: AXUIElement
        let address: AXUIElement
    }

    private static func scan(window: AXUIElement, pid: pid_t) -> Target? {
        var queue = [window]
        var next = 0
        var scanned = 0
        var visited = Set<CFHashCode>()
        var document: AXUIElement?
        var address: AXUIElement?

        while next < queue.count, scanned < scanLimit {
            let element = queue[next]
            next += 1
            scanned += 1
            let hash = CFHash(element)
            guard visited.insert(hash).inserted, belongsToProcess(element, pid: pid) else { continue }

            let role = string(attribute(element, kAXRoleAttribute))
            if role == webAreaRole {
                if document == nil, url(from: attribute(element, kAXURLAttribute)) != nil {
                    document = element
                }
                // Page content is large and cannot contain the browser toolbar address field.
                continue
            }
            if address == nil, role == kAXComboBoxRole, isAddressField(element) {
                address = element
            }
            if let document, let address { return Target(document: document, address: address) }

            if let children = elements(attribute(element, kAXChildrenAttribute)) {
                queue.append(contentsOf: children)
            }
        }
        guard let document, let address else { return nil }
        return Target(document: document, address: address)
    }

    private static func isAddressField(_ element: AXUIElement) -> Bool {
        let text = [
            string(attribute(element, kAXIdentifierAttribute)),
            string(attribute(element, kAXTitleAttribute)),
            string(attribute(element, kAXDescriptionAttribute)),
            string(attribute(element, kAXHelpAttribute)),
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        return ["address", "location", "urlbar", "url bar", "enter address"].contains {
            text.contains($0)
        }
    }

    private static func isBeingEdited(
        _ address: AXUIElement,
        application: AXUIElement
    ) -> Bool {
        if (attribute(address, kAXFocusedAttribute) as? Bool) == true { return true }
        guard let focused = element(attribute(application, kAXFocusedUIElementAttribute)) else {
            return false
        }
        if CFEqual(focused, address) { return true }

        // Firefox can report a text child of the combo box as the focused element.
        var queue = elements(attribute(address, kAXChildrenAttribute)) ?? []
        var next = 0
        var visited = Set<CFHashCode>()
        while next < queue.count, visited.count < 16 {
            let element = queue[next]
            next += 1
            guard visited.insert(CFHash(element)).inserted else { continue }
            if CFEqual(element, focused) { return true }
            if string(attribute(element, kAXRoleAttribute)) != webAreaRole,
                let children = elements(attribute(element, kAXChildrenAttribute))
            {
                queue.append(contentsOf: children)
            }
        }
        return false
    }

    private static func focusAndSet(_ element: AXUIElement, value: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
            settable.boolValue,
            AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            ) == .success,
            AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                value as CFString
            ) == .success
        else {
            return false
        }
        return true
    }

    private static func submit(_ element: AXUIElement, pid: pid_t) -> Bool {
        var rawActions: CFArray?
        if AXUIElementCopyActionNames(element, &rawActions) == .success,
            let actions = rawActions as? [String],
            actions.contains(kAXConfirmAction)
        {
            return AXUIElementPerformAction(element, kAXConfirmAction as CFString) == .success
        }

        guard
            let keyDown = CGEvent(
                keyboardEventSource: nil,
                virtualKey: returnKeyCode,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: nil,
                virtualKey: returnKeyCode,
                keyDown: false
            )
        else {
            return false
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func elements(_ value: CFTypeRef?) -> [AXUIElement]? {
        guard let values = value as? [Any] else { return nil }
        return values.compactMap { element($0 as CFTypeRef) }
    }

    private static func string(_ value: CFTypeRef?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? URL { return value.absoluteString }
        return nil
    }

    private static func url(from value: CFTypeRef?) -> URL? {
        if let value = value as? URL { return value }
        guard let value = value as? String else { return nil }
        return URL(string: value)
    }

    private static func belongsToProcess(_ element: AXUIElement, pid: pid_t) -> Bool {
        var owner = pid_t()
        return AXUIElementGetPid(element, &owner) == .success && owner == pid
    }
}
