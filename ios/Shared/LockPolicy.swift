import FamilyControls
import Foundation
import ManagedSettings

struct LockPolicy: Codable, Equatable {
    static let maximumManagedWebDomains = 50

    var selection = FamilyActivitySelection()
    var manualDomains: [String] = []
    var blocksAdultWebsites = true
    var waitDuration: TimeInterval = 3_600
    // Nil is the v1 representation: full unlock used the same delay as a timeout.
    var fullUnlockDelay: TimeInterval?
    var breakDuration: TimeInterval = 900
    var fixedDuration: TimeInterval?
    var preventsAppRemoval = false
    var requiresAutomaticDateAndTime = true

    var selectedItemCount: Int {
        selection.applicationTokens.count
            + selection.categoryTokens.count
            + selection.webDomainTokens.count
            + manualDomains.count
    }

    var hasBlockingTarget: Bool {
        selectedItemCount > 0 || blocksAdultWebsites
    }

    mutating func normalize() {
        manualDomains = Self.normalizedDomains(manualDomains)
        waitDuration = max(3_600, waitDuration)
        fullUnlockDelay = max(3_600, fullUnlockDelay ?? waitDuration)
        breakDuration = max(900, breakDuration)
        if let fixedDuration {
            self.fixedDuration = max(3_600, fixedDuration)
        }
    }

    func validateManagedSettingsLimits() throws {
        try Self.validateManagedSettingsDomainCounts(
            manual: manualDomains.count,
            selected: selection.webDomainTokens.count
        )
    }

    static func validateManagedSettingsDomainCounts(manual: Int, selected: Int) throws {
        guard manual <= maximumManagedWebDomains else {
            throw LockStateError.tooManyManualDomains
        }
        guard selected <= maximumManagedWebDomains else {
            throw LockStateError.tooManySelectedWebDomains
        }
    }

    static func normalizedDomain(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var host = URLComponents(string: candidate)?.host else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }

        guard host.contains("."), !host.contains(" ") else { return nil }
        return host
    }

    static func normalizedDomains(_ inputs: [String]) -> [String] {
        Array(Set(inputs.compactMap(normalizedDomain))).sorted()
    }
}

extension TimeInterval {
    var hardPauseDurationLabel: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = self >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: self) ?? "\(Int(self)) sec"
    }
}
