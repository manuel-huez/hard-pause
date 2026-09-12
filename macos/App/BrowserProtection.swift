import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Polling stays in the user's app session. No browser URLs are persisted or logged.
@MainActor
final class BrowserProtection: ObservableObject {
    @Published private(set) var statuses: [String: String] = [:]
    @Published private(set) var isChecking = false
    private let pageServer = LocalPausePageServer()
    private let firefox = FirefoxBrowserProtection()
    private let worker = BrowserAutomationWorker()

    nonisolated static let browsers = [
        (id: "com.google.Chrome", name: "Chrome"),
        (id: "com.apple.Safari", name: "Safari"),
        (id: "org.mozilla.firefox", name: "Firefox"),
    ]

    func requestPermission(for identifier: String) async {
        guard Self.browsers.contains(where: { $0.id == identifier }) else { return }
        if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                statuses[identifier] = "This browser is not installed."
                return
            }
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            } catch {
                statuses[identifier] = "Open this browser, then allow access."
                return
            }
        }
        if identifier == "org.mozilla.firefox" {
            firefox.requestPermission()
            statuses[identifier] = AXIsProcessTrusted() ? "Connected" : "Allow Hard Pause in Accessibility."
            return
        }
        let result = await worker.permission(identifier, prompt: true)
        if result == errAEEventNotPermitted,
            let settings = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            )
        {
            NSWorkspace.shared.open(settings)
        }
        statuses[identifier] = result == noErr ? "Connected" : "Automation permission is needed."
    }

    func readiness() async -> [BrowserSetupState] {
        var result: [BrowserSetupState] = []
        for browser in Self.browsers {
            let installed =
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.id) != nil
                || !NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).isEmpty
            let permission: BrowserPermissionState
            if !installed {
                permission = .unavailable
            } else if browser.id == "org.mozilla.firefox" {
                permission = AXIsProcessTrusted() ? .granted : .denied
            } else {
                let status = await worker.permission(browser.id, prompt: false)
                permission = status == noErr ? .granted : (status == errAEEventNotPermitted ? .denied : .unknown)
            }
            result.append(
                BrowserSetupState(id: browser.id, name: browser.name, isInstalled: installed, permission: permission))
        }
        return result
    }

    func check(snapshot: ProtectedServiceSnapshot?) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        guard let snapshot else {
            for browser in Self.browsers { statuses[browser.id] = "Waiting for the protection service." }
            return
        }
        let rules = BrowserURLMatcher.rules(from: snapshot)
        pageServer.start()
        guard let page = pageServer.pageURL else {
            for browser in Self.browsers {
                statuses[browser.id] = pageServer.failure ?? "Preparing the local pause page…"
            }
            return
        }
        for browser in Self.browsers {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).isEmpty else {
                statuses[browser.id] = "Browser is closed."
                continue
            }
            if browser.id == "org.mozilla.firefox" {
                statuses[browser.id] = firefox.check(rules: rules, page: page)
                continue
            }
            let permission = await worker.permission(browser.id, prompt: false)
            guard permission == noErr else {
                statuses[browser.id] = "Connect this browser to enable page redirects."
                continue
            }
            if rules.allSatisfy({ $0.allBlockedDomains.isEmpty && $0.blockedURLPatterns.isEmpty }) {
                statuses[browser.id] = "Connected · no website rules apply."
                continue
            }
            let success = await worker.check(browser.id, rules: rules, page: page)
            statuses[browser.id] = success ? "Checking tabs" : "Cannot check tabs. Check Automation permission."
        }
    }
}

private actor BrowserAutomationWorker {
    func permission(_ identifier: String, prompt: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: identifier)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, prompt)
    }

    func check(_ identifier: String, rules: [ProtectedRules], page: URL) -> Bool {
        // Only fixed, allowlisted application IDs enter the scripts. Tab URLs and the
        // destination are escaped as data, and the tab URL is checked again before a redirect.
        guard BrowserProtection.browsers.contains(where: { $0.id == identifier }) else { return false }
        let source = """
            with timeout of 2 seconds
                tell application id "\(identifier)"
                    set results to {}
                    repeat with w in windows
                        set tabPosition to 0
                        repeat with t in tabs of w
                            set tabPosition to tabPosition + 1
                            try
                                set end of results to {id of w, tabPosition, URL of t}
                            end try
                        end repeat
                    end repeat
                    return results
                end tell
            end timeout
            """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return false }
        if result.numberOfItems == 0 { return true }
        for index in 1...result.numberOfItems {
            guard let item = result.atIndex(index), item.numberOfItems == 3,
                let raw = item.atIndex(3)?.stringValue,
                let url = URL(string: raw), url != page, BrowserURLMatcher.matches(url, rules: rules)
            else { continue }
            let windowReference: String
            if identifier == "com.google.Chrome" {
                guard let windowID = item.atIndex(1)?.stringValue, !windowID.isEmpty else { continue }
                windowReference = Self.literal(windowID)
            } else {
                let windowID = item.atIndex(1)?.int32Value ?? 0
                guard windowID > 0 else { continue }
                windowReference = String(windowID)
            }
            let tabIndex = item.atIndex(2)?.int32Value ?? 0
            guard tabIndex > 0 else { continue }
            let redirect = """
                with timeout of 2 seconds
                    tell application id "\(identifier)"
                        try
                            set t to tab \(tabIndex) of window id \(windowReference)
                            if URL of t is \(Self.literal(raw)) then set URL of t to \(Self.literal(page.absoluteString))
                        end try
                    end tell
                end timeout
                """
            error = nil
            NSAppleScript(source: redirect)?.executeAndReturnError(&error)
            if error != nil { return false }
        }
        return true
    }

    private static func literal(_ string: String) -> String {
        "\""
            + string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
