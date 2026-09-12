import DeviceActivity
import Foundation
import ManagedSettings

enum HardPauseConstants {
    static let appGroupIdentifier = "group.com.hardpause.shared"
    static let settingsStorePrefix = "hard-pause.slot."
    static let transitionActivityPrefix = "hard-pause.transition."
    static let legacyBlockID = UUID(uuidString: "6e53b98b-6e3d-5bf4-9ab0-9ce21997b37f")!
    static var legacySettingsStoreName: ManagedSettingsStore.Name { .init("hard-pause") }

    static func settingsStoreName(for slot: Int) -> ManagedSettingsStore.Name {
        .init(settingsStorePrefix + String(slot))
    }

    static func transitionActivity(for blockID: UUID) -> DeviceActivityName {
        .init(transitionActivityPrefix + blockID.uuidString.lowercased())
    }

    static func isTransitionActivity(_ activity: DeviceActivityName) -> Bool {
        activity.rawValue.hasPrefix(transitionActivityPrefix)
    }

    static func blockID(for activity: DeviceActivityName) -> UUID? {
        guard isTransitionActivity(activity) else { return nil }
        return UUID(uuidString: String(activity.rawValue.dropFirst(transitionActivityPrefix.count)))
    }
}
