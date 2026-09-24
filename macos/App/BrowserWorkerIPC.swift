import Foundation

/// The LaunchAgent owns this per-user Mach service. Both peers pin the other's signing identity.
enum BrowserWorkerIdentity {
    static let machService = "org.hardpause.browser-worker"
    static let bundleIdentifier = "org.hardpause.browser-worker"
    static let workerRequirement =
        #"anchor apple generic and identifier "org.hardpause.browser-worker" and certificate leaf[subject.OU] = "ZBX6C7BJ5X""#
    static let appRequirement =
        #"anchor apple generic and identifier "org.hardpause.app" and certificate leaf[subject.OU] = "ZBX6C7BJ5X""#
    static let clientRequirement = "(\(appRequirement)) or (\(workerRequirement))"

    static func acceptsMachService(_ name: String) -> Bool {
        if name == machService { return true }
        let prefix = machService + ".v"
        guard name.hasPrefix(prefix) else { return false }
        let version = name.dropFirst(prefix.count).utf8
        return (1...10).contains(version.count) && version.allSatisfy { (48...57).contains($0) }
    }

    static func isLocalPausePage(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1"
            && url.port.map { (1...65_535).contains($0) } == true
            && url.path == "/BlockedPage/index.html"
            && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
    }
}

@objc protocol BrowserWorkerXPC {
    func readiness(_ challenge: NSString, withReply reply: @escaping (NSData) -> Void)
    func requestPermission(
        _ identifier: NSString, challenge: NSString, withReply reply: @escaping (NSData) -> Void)
    func migratePausePages(
        _ newPage: NSString, challenge: NSString, withReply reply: @escaping (NSData) -> Void)
}

struct BrowserWorkerAccess: Codable, Equatable {
    let identifier: String
    let installed: Bool
    let running: Bool
    let permission: String

    var ready: Bool {
        !installed || permission == "granted" || (!running && permission == "previouslyGranted")
    }

    var verifiedForRetirement: Bool {
        !installed || permission == "granted"
    }
}

struct BrowserWorkerReadiness: Codable, Equatable {
    let observedAt: Date
    let serviceReady: Bool
    let serviceReachable: Bool
    let standbyReady: Bool
    let cachedActiveRestrictions: Bool
    let pausePageReady: Bool
    let adultDatabaseReady: Bool
    let pausePageURL: URL?
    let browserAccess: [BrowserWorkerAccess]
    let browserStatuses: [String: String]

    var readyForHandoff: Bool {
        serviceReady && pausePageReady && adultDatabaseReady && pausePageURL != nil
            && browserAccess.count == 3
            && Set(browserAccess.map(\.identifier))
                == Set([
                    "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
                ])
            && browserAccess.allSatisfy(\.ready)
    }

    var readyForRetirement: Bool {
        readyForHandoff && browserAccess.allSatisfy(\.verifiedForRetirement)
    }

    func isFresh(at date: Date = Date()) -> Bool {
        abs(date.timeIntervalSince(observedAt)) <= 5
    }
}

protocol BrowserWorkerChallengeReply: Decodable {
    var challenge: String { get }
}

struct BrowserWorkerReply: Codable, BrowserWorkerChallengeReply {
    let challenge: String
    let readiness: BrowserWorkerReadiness
}

struct BrowserWorkerMigrationReply: Codable, BrowserWorkerChallengeReply {
    let challenge: String
    let migrated: Bool
}
