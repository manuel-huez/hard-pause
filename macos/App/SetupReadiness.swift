import Foundation

enum SetupState: Equatable {
    case checking
    case incomplete
    case ready
}

enum BrowserPermissionState: Equatable, Sendable {
    case unavailable
    case unknown
    case denied
    case granted
    case previouslyGranted
}

struct BrowserSetupState: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isInstalled: Bool
    let permission: BrowserPermissionState

    var isReady: Bool { !isInstalled || permission == .granted || permission == .previouslyGranted }
}

struct SetupAccessState: Equatable, Sendable {
    let browsers: [BrowserSetupState]
    let startsAtLogin: Bool
}

/// Closed browsers can retain setup completion; tab access always needs a fresh OS check.
enum SetupReadiness {
    static func ready(serviceReady: Bool, access: SetupAccessState) -> Bool {
        serviceReady && access.startsAtLogin && access.browsers.allSatisfy(\.isReady)
    }
}
