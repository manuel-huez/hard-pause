import AppKit
import ApplicationServices
import Carbon
import Foundation
import OSAKit

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
        if identifier == "org.mozilla.firefox" {
            firefox.requestPermission()
            statuses[identifier] =
                AXIsProcessTrusted() ? "Connected" : "Allow Hard Pause Worker in Accessibility."
            return
        }
        if await worker.wasDenied(identifier) {
            openAutomationSettings()
            statuses[identifier] =
                "In System Settings, allow this browser under Hard Pause Worker → Automation."
            return
        }
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
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first else {
            statuses[identifier] = "The browser closed before access could be requested. Try Allow access again."
            return
        }
        NSApp.activate()
        let result = await worker.requestPermission(identifier, processIdentifier: application.processIdentifier)
        if result == errAEEventNotPermitted { openAutomationSettings() }
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

    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func permissionStatus(for identifier: String, processIdentifier: pid_t) async -> OSStatus {
        guard Self.browsers.contains(where: { $0.id == identifier }) else { return OSStatus(paramErr) }
        if identifier == "org.mozilla.firefox" {
            // This queries permission itself, not the success of a tab read.
            return AXIsProcessTrusted() ? noErr : OSStatus(errAEEventNotPermitted)
        }
        return await worker.permission(identifier, processIdentifier: processIdentifier)
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
            } else if let application = NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).first
            {
                permission = await worker.readinessPermission(
                    browser.id, processIdentifier: application.processIdentifier)
            } else {
                permission = await worker.closedPermission(browser.id)
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
            guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).first
            else {
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
            let permission = await worker.permission(browser.id, processIdentifier: application.processIdentifier)
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
                browser.id, processIdentifier: application.processIdentifier, rules: rules, page: page,
                adultDomains: database,
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
    private var lastPermissionResults: [String: OSStatus] = [:]

    private func approvalKey(_ identifier: String) -> String {
        let workerPath =
            Bundle.main.bundleIdentifier == BrowserWorkerIdentity.bundleIdentifier
            ? "\(Bundle.main.bundleURL.standardizedFileURL.path)." : ""
        return "browserPreviouslyApproved.\(workerPath)\(identifier)"
    }

    func permission(_ identifier: String, processIdentifier: pid_t) -> OSStatus {
        let target = NSAppleEventDescriptor(processIdentifier: processIdentifier)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        recordPermission(status, for: identifier)
        return status
    }

    func requestPermission(_ identifier: String, processIdentifier: pid_t) async -> OSStatus {
        // A consent dialog can stay open indefinitely; it must not block normal tab checks.
        let status = await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(processIdentifier: processIdentifier)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
        }.value
        recordPermission(status, for: identifier)
        return status
    }

    private func recordPermission(_ status: OSStatus, for identifier: String) {
        lastPermissionResults[identifier] = status
        let key = approvalKey(identifier)
        if status == noErr {
            defaults.set(true, forKey: key)
        } else if status == errAEEventNotPermitted || status == errAEEventWouldRequireUserConsent {
            defaults.removeObject(forKey: key)
        }
    }

    func wasDenied(_ identifier: String) -> Bool {
        lastPermissionResults[identifier] == OSStatus(errAEEventNotPermitted)
    }

    func closedPermission(_ identifier: String) -> BrowserPermissionState {
        if wasDenied(identifier) { return .denied }
        return defaults.bool(forKey: approvalKey(identifier)) ? .previouslyGranted : .unknown
    }

    func readinessPermission(_ identifier: String, processIdentifier: pid_t) -> BrowserPermissionState {
        let status = permission(identifier, processIdentifier: processIdentifier)
        if status == noErr { return .granted }
        // macOS cannot query a closed browser. This remembers setup only, never tab access.
        if status == procNotFound && defaults.bool(forKey: approvalKey(identifier)) {
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
            let application = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
        else { return false }
        let source = """
            var results = [];
            var windows = app.windows({ timeout: 10 });
            for (var i = 0; i < windows.length; i++) {
                var tabs = windows[i].tabs({ timeout: 10 });
                for (var j = 0; j < tabs.length; j++) {
                    try {
                        if (tabs[j].url({ timeout: 10 }) === \(Self.literal(oldPage.absoluteString))) {
                            results.push([windows[i].id({ timeout: 10 }), j + 1]);
                        }
                    } catch (error) { return -1; }
                }
            }
            return results;
            """
        let pid = application.processIdentifier
        guard let matches = Self.execute(source, processIdentifier: pid), matches.descriptorType == typeAEList else {
            return false
        }
        for index in 0..<matches.numberOfItems {
            guard let item = matches.atIndex(index + 1), item.numberOfItems == 2,
                let windowID = item.atIndex(1),
                let tabIndex = item.atIndex(2)?.int32Value, tabIndex > 0,
                Self.setURL(
                    newPage.absoluteString, ifCurrentURL: oldPage.absoluteString,
                    in: identifier, processIdentifier: pid,
                    windowID: windowID, tabIndex: tabIndex)
            else { return false }
        }
        guard let remaining = Self.execute(source, processIdentifier: pid) else { return false }
        return remaining.descriptorType == typeAEList && remaining.numberOfItems == 0
    }

    func check(
        _ identifier: String, processIdentifier: pid_t, rules: [ProtectedRules], page: URL,
        adultDomains: AdultDomainDatabase?,
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
            var results = [];
            var windows = app.windows({ timeout: 2 });
            for (var i = 0; i < windows.length; i++) {
                var tabs = windows[i].tabs({ timeout: 2 });
                for (var j = 0; j < tabs.length; j++) {
                    try {
                        results.push([windows[i].id({ timeout: 2 }), j + 1, tabs[j].url({ timeout: 2 })]);
                    }
                    catch (error) { /* A tab closed during the scan. */ }
                }
            }
            return results;
            """
        guard let result = Self.execute(source, processIdentifier: processIdentifier),
            result.descriptorType == typeAEList
        else {
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
                let command =
                    identifier == "com.google.Chrome"
                    ? "app.execute(t, { javascript: \(Self.literal(AdultPageRating.script)) }, { timeout: 2 })"
                    : "app.doJavaScript(\(Self.literal(AdultPageRating.script)), { in: t }, { timeout: 2 })"
                let inspect = """
                    var t = app.windows.byId(\(windowReference)).tabs[\(tabIndex - 1)];
                    if (t.url({ timeout: 2 }) !== \(Self.literal(raw))) return false;
                    var adultRating = \(command);
                    return t.url({ timeout: 2 }) === \(Self.literal(raw)) ? adultRating : false;
                    """
                if let rating = Self.execute(inspect, processIdentifier: processIdentifier) {
                    ratedAdult = rating.booleanValue
                } else {
                    rtaUnavailable = true
                }
            }
            guard matched || ratedAdult, await authorize(url, ratedAdult) else { continue }
            mayHaveRedirected = true
            guard let windowID = item.atIndex(1),
                Self.setURL(
                    page.absoluteString, ifCurrentURL: raw,
                    in: identifier, processIdentifier: processIdentifier,
                    windowID: windowID, tabIndex: tabIndex)
            else {
                return CheckOutcome(
                    success: false, rtaUnavailable: rtaUnavailable,
                    mayHaveRedirected: mayHaveRedirected)
            }
        }
        return CheckOutcome(
            success: true, rtaUnavailable: rtaUnavailable, mayHaveRedirected: mayHaveRedirected)
    }

    private static func execute(_ body: String, processIdentifier: pid_t) -> NSAppleEventDescriptor? {
        // A process target cannot relaunch a browser that quits between tab operations.
        let source = """
            function run() {
                var app = Application(\(processIdentifier));
                if (!app.running()) throw new Error("Browser closed");
                \(body)
            }
            """
        guard let language = OSALanguage(forName: "JavaScript") else { return nil }
        var error: NSDictionary?
        let result = OSAScript(source: source, language: language).executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private static func setURL(
        _ url: String, ifCurrentURL expectedURL: String, in identifier: String, processIdentifier: pid_t,
        windowID: NSAppleEventDescriptor, tabIndex: Int32
    ) -> Bool {
        func object(
            _ desiredClass: DescType, in container: NSAppleEventDescriptor,
            form: DescType, key: NSAppleEventDescriptor
        ) -> NSAppleEventDescriptor? {
            var containerDesc = container.aeDesc!.pointee
            var keyDesc = key.aeDesc!.pointee
            var output = AEDesc()
            guard CreateObjSpecifier(desiredClass, &containerDesc, form, &keyDesc, false, &output) == noErr else {
                return nil
            }
            return NSAppleEventDescriptor(aeDescNoCopy: &output)
        }
        let tabClass: DescType = identifier == "com.google.Chrome" ? 0x4372_5462 : 0x6254_6162  // CrTb, bTab
        let urlProperty: OSType = identifier == "com.google.Chrome" ? 0x5552_4c20 : 0x7055_524c  // URL , pURL
        let root = NSAppleEventDescriptor(descriptorType: typeNull, data: nil)!
        guard let window = object(cWindow, in: root, form: DescType(formUniqueID), key: windowID),
            let tab = object(
                tabClass, in: window, form: DescType(formAbsolutePosition),
                key: NSAppleEventDescriptor(int32: tabIndex)),
            let property = object(
                cProperty, in: tab, form: DescType(formPropertyID),
                key: NSAppleEventDescriptor(typeCode: urlProperty))
        else { return false }
        let target = NSAppleEventDescriptor(processIdentifier: processIdentifier)
        let getEvent = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        getEvent.setParam(property, forKeyword: keyDirectObject)
        do {
            let reply = try getEvent.sendEvent(options: [.waitForReply], timeout: 2)
            guard reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0 == 0,
                let currentURL = reply.paramDescriptor(forKeyword: keyDirectObject)?.stringValue
            else { return false }
            if currentURL != expectedURL { return true }
        } catch { return false }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAESetData),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(property, forKeyword: keyDirectObject)
        event.setParam(NSAppleEventDescriptor(string: url), forKeyword: keyAEData)
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: 2)
            return reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0 == 0
        } catch { return false }
    }

    private static func literal(_ string: String) -> String {
        "\""
            + string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
