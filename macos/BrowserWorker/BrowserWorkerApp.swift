import AppKit
import Foundation

@MainActor
private final class BrowserWorkerRuntime {
    private let service = ProtectedServiceClient()
    private let protection = BrowserProtection()
    private var cachedSnapshot: ProtectedServiceSnapshot?
    private var lastSuccessfulCheck: Date?
    private var retryServiceAfter = Date.distantPast
    private var drainingUntil: Date?

    func run() async {
        while !Task.isCancelled {
            if let drainingUntil, Date() < drainingUntil {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            drainingUntil = nil
            let snapshot = await latestSnapshot()
            await protection.check(snapshot: snapshot) { [self] in await latestSnapshot() }
            if snapshot != nil { lastSuccessfulCheck = Date() }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func readiness() async -> BrowserWorkerReadiness {
        let live: ProtectedServiceSnapshot?
        if Date() >= retryServiceAfter {
            live = try? await service.list()
            if live == nil { retryServiceAfter = Date().addingTimeInterval(5) }
        } else {
            live = nil
        }
        let standby = live == nil ? await validatedStandbySnapshot() : nil
        if let current = live ?? standby {
            cachedSnapshot = current
            retryServiceAfter = .distantPast
        }
        let cachedActive = cachedSnapshot.map(Self.hasActiveBrowserRestrictions) == true
        let adultRulesActive =
            cachedSnapshot.map {
                BrowserURLMatcher.rules(from: $0).contains(where: \.blocksAdultWebsites)
            } == true
        let adultDatabaseReady: Bool
        if adultRulesActive {
            adultDatabaseReady = await protection.hasAdultDatabase()
        } else {
            adultDatabaseReady = true
        }
        let serviceReady =
            (live != nil || standby != nil || cachedActive)
            && lastSuccessfulCheck.map { Date().timeIntervalSince($0) < 8 } == true
        let browsers = await protection.readiness()
        return BrowserWorkerReadiness(
            observedAt: Date(),
            serviceReady: serviceReady,
            serviceReachable: live != nil,
            standbyReady: standby != nil,
            cachedActiveRestrictions: cachedActive,
            pausePageReady: protection.isPausePageReady,
            adultDatabaseReady: adultDatabaseReady,
            pausePageURL: protection.pausePageURL,
            browserAccess: browsers.map { browser in
                BrowserWorkerAccess(
                    identifier: browser.id,
                    installed: browser.isInstalled,
                    running: !NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).isEmpty,
                    permission: Self.permissionName(browser.permission))
            },
            browserStatuses: protection.statuses)
    }

    private func latestSnapshot() async -> ProtectedServiceSnapshot? {
        guard Date() >= retryServiceAfter else { return cachedSnapshot }
        if let live = try? await service.list() {
            cachedSnapshot = live
            return live
        }
        retryServiceAfter = Date().addingTimeInterval(5)
        if let standby = await validatedStandbySnapshot() {
            cachedSnapshot = standby
            return standby
        }
        return cachedSnapshot.map(Self.hasActiveBrowserRestrictions) == true ? cachedSnapshot : nil
    }

    private func validatedStandbySnapshot() async -> ProtectedServiceSnapshot? {
        guard let snapshot = try? await service.listStandby(),
            snapshot.protection.isEnforcing,
            snapshot.protection.lastAppliedAt != nil
        else { return nil }
        return snapshot
    }

    private static func hasActiveBrowserRestrictions(_ snapshot: ProtectedServiceSnapshot) -> Bool {
        BrowserURLMatcher.rules(from: snapshot).contains {
            !$0.allBlockedDomains.isEmpty || !$0.blockedURLPatterns.isEmpty || $0.blocksAdultWebsites
        }
    }

    func requestPermission(for identifier: String) async -> BrowserWorkerReadiness {
        await protection.requestPermission(for: identifier)
        return await readiness()
    }

    func migratePausePages(to newPage: URL) async -> Bool {
        guard BrowserWorkerIdentity.isLocalPausePage(newPage), protection.isPausePageReady else {
            return false
        }
        guard await protection.migrateLocalPauseTabs(to: newPage) else { return false }
        // The replacement already checks tabs. Resume if its installer cannot retire this worker.
        drainingUntil = Date().addingTimeInterval(15)
        return true
    }

    private static func permissionName(_ permission: BrowserPermissionState) -> String {
        switch permission {
        case .unavailable: "unavailable"
        case .unknown: "unknown"
        case .denied: "denied"
        case .granted: "granted"
        case .previouslyGranted: "previouslyGranted"
        }
    }
}

private final class BrowserWorkerServer: NSObject, NSXPCListenerDelegate, BrowserWorkerXPC {
    private let runtime: BrowserWorkerRuntime

    init(runtime: BrowserWorkerRuntime) { self.runtime = runtime }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(BrowserWorkerIdentity.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: BrowserWorkerXPC.self)
        connection.exportedObject = self
        connection.activate()
        return true
    }

    func readiness(_ challenge: NSString, withReply reply: @escaping (NSData) -> Void) {
        respond(to: challenge, withReply: reply) { await $0.readiness() }
    }

    func requestPermission(
        _ identifier: NSString, challenge: NSString, withReply reply: @escaping (NSData) -> Void
    ) {
        guard BrowserProtection.browsers.contains(where: { $0.id == identifier as String }) else {
            reply(NSData())
            return
        }
        respond(to: challenge, withReply: reply) {
            await $0.requestPermission(for: identifier as String)
        }
    }

    func migratePausePages(
        _ newPage: NSString, challenge: NSString, withReply reply: @escaping (NSData) -> Void
    ) {
        guard challenge.length == 36,
            let url = URL(string: newPage as String), BrowserWorkerIdentity.isLocalPausePage(url)
        else {
            reply(NSData())
            return
        }
        Task { @MainActor [runtime] in
            let response = BrowserWorkerMigrationReply(
                challenge: challenge as String, migrated: await runtime.migratePausePages(to: url))
            reply((try? JSONEncoder().encode(response)) as NSData? ?? NSData())
        }
    }

    private func respond(
        to challenge: NSString, withReply reply: @escaping (NSData) -> Void,
        read: @escaping @MainActor (BrowserWorkerRuntime) async -> BrowserWorkerReadiness
    ) {
        guard challenge.length == 36 else {
            reply(NSData())
            return
        }
        Task { @MainActor [runtime] in
            let response = BrowserWorkerReply(challenge: challenge as String, readiness: await read(runtime))
            reply((try? JSONEncoder().encode(response)) as NSData? ?? NSData())
        }
    }
}

@main
enum BrowserWorkerMain {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--probe" {
            let name =
                arguments.count == 1
                ? BrowserWorkerIdentity.machService
                : arguments.count == 2 ? arguments[1] : ""
            guard let client = BrowserWorkerClient(machServiceName: name) else { exit(EX_USAGE) }
            Task { @MainActor in
                let report = await client.readiness()
                let ready = report?.readyForHandoff == true
                if ready, let report, let data = try? JSONEncoder().encode(report),
                    let json = String(data: data, encoding: .utf8)
                {
                    print(json)
                }
                if !ready { fputs("Hard Pause Browser Worker is not ready.\n", stderr) }
                exit(ready ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            RunLoop.main.run()
            return
        }
        if arguments.count == 3, arguments[0] == "--migrate",
            let old = BrowserWorkerClient(machServiceName: arguments[1]),
            let new = BrowserWorkerClient(machServiceName: arguments[2]),
            old.machServiceName != new.machServiceName
        {
            Task { @MainActor in
                guard let report = await new.readiness(), report.readyForHandoff,
                    let page = report.pausePageURL, await old.migratePausePages(to: page)
                else {
                    fputs("Hard Pause browser page migration did not finish.\n", stderr)
                    exit(EXIT_FAILURE)
                }
                exit(EXIT_SUCCESS)
            }
            RunLoop.main.run()
            return
        }
        let name =
            arguments.isEmpty
            ? BrowserWorkerIdentity.machService
            : arguments.count == 2 && arguments[0] == "--serve" ? arguments[1] : ""
        guard BrowserWorkerIdentity.acceptsMachService(name) else { exit(EX_USAGE) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runtime = BrowserWorkerRuntime()
        let server = BrowserWorkerServer(runtime: runtime)
        let listener = NSXPCListener(machServiceName: name)
        listener.delegate = server
        listener.resume()
        Task { await runtime.run() }
        withExtendedLifetime((listener, server)) { app.run() }
    }
}
