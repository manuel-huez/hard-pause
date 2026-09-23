import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Shared browser checks for the app and its user-session worker. URLs are never persisted or logged.
@MainActor
final class BrowserProtection: ObservableObject {
    @Published private(set) var statuses: [String: String] = [:]
    @Published private(set) var isChecking = false
    private let pageServer = LocalPausePageServer()
    private let firefox = FirefoxBrowserProtection()
    private let worker = BrowserAutomationWorker()
    private let adultDatabase = AdultWebsiteDatabase()
    private let adultRatings = AdultRatingStore()
    private(set) var adultDatabaseStatus = "Loading local adult website list…"
    var isPausePageReady: Bool { pageServer.pageURL != nil }
    var pausePageURL: URL? { pageServer.pageURL }
    private var browsersWithLocalPauseTabs = Set<String>()
    private var possibleFirefoxPauseTabs = 0
    private var isMigratingLocalPauseTabs = false
    var mayHaveLocalPauseTabs: Bool {
        !browsersWithLocalPauseTabs.isEmpty || possibleFirefoxPauseTabs > 0
    }

    /// Move pages served by this process before it exits. A browser we cannot inspect keeps handoff closed.
    func migrateLocalPauseTabs(to newPage: URL) async -> Bool {
        guard !isMigratingLocalPauseTabs else { return false }
        isMigratingLocalPauseTabs = true
        defer { isMigratingLocalPauseTabs = false }
        guard let oldPage = pageServer.pageURL, oldPage != newPage else { return !mayHaveLocalPauseTabs }
        for _ in 0..<200 {
            if !isChecking { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard !isChecking else { return false }
        for identifier in browsersWithLocalPauseTabs {
            if await worker.migratePausePage(identifier, from: oldPage, to: newPage) {
                browsersWithLocalPauseTabs.remove(identifier)
            }
        }
        while possibleFirefoxPauseTabs > 0 {
            guard await firefox.migratePausePage(from: oldPage, to: newPage) else { break }
            possibleFirefoxPauseTabs -= 1
        }
        return !mayHaveLocalPauseTabs
    }

    func hasAdultDatabase() async -> Bool { await adultDatabase.current() != nil }

    func refreshAdultDatabase(force: Bool = true) async {
        await adultDatabase.refreshIfNeeded(force: force)
        adultDatabaseStatus = await adultDatabase.status
        if adultRatings.saveFailed { adultDatabaseStatus += " · RTA cache could not be saved" }
    }

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
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
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
        NSApp.activate()
        let result = await worker.permission(identifier, prompt: true)
        if result == errAEEventNotPermitted,
            let settings = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            )
        {
            NSWorkspace.shared.open(settings)
        }
        switch result {
        case noErr:
            statuses[identifier] = "Connected"
        case OSStatus(errAEEventNotPermitted):
            statuses[identifier] =
                "In System Settings, open Privacy & Security → Automation and allow this browser under Hard Pause."
        default:
            statuses[identifier] =
                "macOS could not confirm browser access (\(result)). Keep the browser open and try again."
        }
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
                permission = await worker.readinessPermission(browser.id)
            }
            result.append(
                BrowserSetupState(id: browser.id, name: browser.name, isInstalled: installed, permission: permission))
        }
        return result
    }

    func check(
        snapshot: ProtectedServiceSnapshot?,
        currentSnapshot: @escaping @MainActor @Sendable () async -> ProtectedServiceSnapshot?
    ) async {
        adultRatings.pruneIfNeeded()
        guard !isChecking, !isMigratingLocalPauseTabs else { return }
        isChecking = true
        defer { isChecking = false }
        await refreshAdultDatabase(force: false)
        guard let snapshot else {
            for browser in Self.browsers { statuses[browser.id] = "Waiting for the protection service." }
            return
        }
        let rules = BrowserURLMatcher.rules(from: snapshot)
        let database = await adultDatabase.current()
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
                let currentRules = await currentSnapshot().map(BrowserURLMatcher.rules) ?? []
                statuses[browser.id] = firefox.check(rules: currentRules, page: page, adultDomains: database) {
                    self.adultRatings.contains($0)
                }
                if statuses[browser.id] == "Redirected blocked page."
                    || statuses[browser.id] == "Cannot open the local pause page in Firefox."
                {
                    possibleFirefoxPauseTabs += 1
                }
                continue
            }
            let permission = await worker.permission(browser.id, prompt: false)
            guard permission == noErr else {
                statuses[browser.id] = "Connect this browser to enable page redirects."
                continue
            }
            if rules.allSatisfy({
                $0.allBlockedDomains.isEmpty && $0.blockedURLPatterns.isEmpty && !$0.blocksAdultWebsites
            }) {
                statuses[browser.id] = "Connected · no website rules apply."
                continue
            }
            let outcome = await worker.check(
                browser.id, rules: rules, page: page, adultDomains: database,
                cachedRating: { self.adultRatings.contains($0) },
                authorize: { url, ratedAdult in
                    guard let latest = await currentSnapshot() else { return false }
                    let active = BrowserURLMatcher.rules(from: latest)
                    if ratedAdult && active.contains(where: \.blocksAdultWebsites) { self.adultRatings.record(url) }
                    return BrowserURLMatcher.matches(
                        url, rules: active, adultDomains: database, hasAdultRating: ratedAdult)
                }
            )
            if outcome.mayHaveRedirected { browsersWithLocalPauseTabs.insert(browser.id) }
            if !outcome.success {
                statuses[browser.id] = "Cannot check tabs. Check Automation permission."
            } else if database == nil && rules.contains(where: \.blocksAdultWebsites) {
                statuses[browser.id] = "Adult website list unavailable · check Settings"
            } else if outcome.rtaUnavailable {
                statuses[browser.id] =
                    "Website list active · RTA unavailable. Enable Allow JavaScript from Apple Events in this browser."
            } else {
                statuses[browser.id] =
                    rules.contains(where: \.blocksAdultWebsites)
                    ? "Checking tabs · local list and RTA tags" : "Checking tabs"
            }
        }
    }
}

private actor BrowserAutomationWorker {
    private let defaults = UserDefaults.standard

    func permission(_ identifier: String, prompt: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: identifier)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, prompt)
        let key = "browserPreviouslyApproved.\(identifier)"
        if status == noErr {
            defaults.set(true, forKey: key)
        } else if status == errAEEventNotPermitted || status == errAEEventWouldRequireUserConsent {
            defaults.removeObject(forKey: key)
        }
        return status
    }

    func readinessPermission(_ identifier: String) -> BrowserPermissionState {
        let status = permission(identifier, prompt: false)
        if status == noErr { return .granted }
        // macOS cannot query a closed browser. This remembers setup only, never tab access.
        if status == procNotFound && defaults.bool(forKey: "browserPreviouslyApproved.\(identifier)") {
            return .previouslyGranted
        }
        return status == errAEEventNotPermitted ? .denied : .unknown
    }

    struct CheckOutcome {
        let success: Bool
        let rtaUnavailable: Bool
        let mayHaveRedirected: Bool
    }

    func migratePausePage(_ identifier: String, from oldPage: URL, to newPage: URL) -> Bool {
        guard ["com.google.Chrome", "com.apple.Safari"].contains(identifier),
            !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
        else { return false }
        let source = """
            with timeout of 10 seconds
                tell application id "\(identifier)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                if URL of t is \(Self.literal(oldPage.absoluteString)) then
                                    set URL of t to \(Self.literal(newPage.absoluteString))
                                end if
                            on error
                                return -1
                            end try
                        end repeat
                    end repeat
                    set remaining to 0
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                if URL of t is \(Self.literal(oldPage.absoluteString)) then
                                    set remaining to remaining + 1
                                end if
                            on error
                                return -1
                            end try
                        end repeat
                    end repeat
                    return remaining
                end tell
            end timeout
            """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && result?.int32Value == 0
    }

    func check(
        _ identifier: String, rules: [ProtectedRules], page: URL, adultDomains: AdultDomainDatabase?,
        cachedRating: @escaping @MainActor @Sendable (URL) -> Bool,
        authorize: @escaping @MainActor @Sendable (URL, Bool) async -> Bool
    ) async -> CheckOutcome {
        var rtaUnavailable = false
        var mayHaveRedirected = false
        // Only fixed, allowlisted application IDs enter the scripts. Tab URLs and the
        // destination are escaped as data, and the tab URL is checked again before a redirect.
        guard BrowserProtection.browsers.contains(where: { $0.id == identifier }) else {
            return CheckOutcome(success: false, rtaUnavailable: rtaUnavailable, mayHaveRedirected: false)
        }
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
        guard let script = NSAppleScript(source: source) else {
            return CheckOutcome(success: false, rtaUnavailable: rtaUnavailable, mayHaveRedirected: false)
        }
        let result = script.executeAndReturnError(&error)
        guard error == nil else {
            return CheckOutcome(success: false, rtaUnavailable: rtaUnavailable, mayHaveRedirected: false)
        }
        if result.numberOfItems == 0 {
            return CheckOutcome(success: true, rtaUnavailable: rtaUnavailable, mayHaveRedirected: false)
        }
        for index in 1...result.numberOfItems {
            guard let item = result.atIndex(index), item.numberOfItems == 3,
                let raw = item.atIndex(3)?.stringValue,
                let url = URL(string: raw), url != page, ["http", "https"].contains(url.scheme?.lowercased() ?? "")
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
            let matched = BrowserURLMatcher.matches(url, rules: rules, adultDomains: adultDomains)
            let categoryActive = rules.contains(where: \.blocksAdultWebsites)
            var ratedAdult = categoryActive ? await cachedRating(url) : false
            if !matched && !ratedAdult && categoryActive && !rtaUnavailable {
                let execution =
                    identifier == "com.google.Chrome"
                    ? "execute t javascript " : "do JavaScript "
                let command =
                    identifier == "com.google.Chrome"
                    ? execution + Self.literal(AdultPageRating.script)
                    : execution + Self.literal(AdultPageRating.script) + " in t"
                let inspect = """
                    with timeout of 2 seconds
                        tell application id "\(identifier)"
                            set t to tab \(tabIndex) of window id \(windowReference)
                            if URL of t is not \(Self.literal(raw)) then return false
                            set adultRating to (\(command))
                            if URL of t is \(Self.literal(raw)) then return adultRating
                            return false
                        end tell
                    end timeout
                    """
                error = nil
                if let ratingScript = NSAppleScript(source: inspect) {
                    let rating = ratingScript.executeAndReturnError(&error)
                    if error == nil { ratedAdult = rating.booleanValue } else { rtaUnavailable = true }
                } else {
                    rtaUnavailable = true
                }
            }
            guard matched || ratedAdult, await authorize(url, ratedAdult) else { continue }
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
            mayHaveRedirected = true
            NSAppleScript(source: redirect)?.executeAndReturnError(&error)
            if error != nil {
                return CheckOutcome(
                    success: false, rtaUnavailable: rtaUnavailable,
                    mayHaveRedirected: mayHaveRedirected)
            }
        }
        return CheckOutcome(
            success: true, rtaUnavailable: rtaUnavailable, mayHaveRedirected: mayHaveRedirected)
    }

    private static func literal(_ string: String) -> String {
        "\""
            + string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
