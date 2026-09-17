import FamilyControls
import Foundation
import ManagedSettings

struct LockPolicy: Codable, Equatable {
    static let maximumManagedWebDomains = 50

    var protectionMode: ProtectionMode = .softLock
    var selection = FamilyActivitySelection()
    var manualDomains: [String] = []
    var blocksAdultWebsites = true
    var waitDuration: TimeInterval = 3_600
    // Nil is the v1 representation: full unlock used the same delay as a timeout.
    var fullUnlockDelay: TimeInterval?
    var breakDuration: TimeInterval = 900
    var fixedDuration: TimeInterval?
    var preventsAppRemoval = true
    var requiresAutomaticDateAndTime = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case protectionMode
        case selection
        case manualDomains
        case blocksAdultWebsites
        case waitDuration
        case fullUnlockDelay
        case breakDuration
        case fixedDuration
        case preventsAppRemoval
        case requiresAutomaticDateAndTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.protectionMode) {
            protectionMode = try container.decode(ProtectionMode.self, forKey: .protectionMode)
        } else {
            protectionMode = .softLock
        }
        selection = try container.decode(FamilyActivitySelection.self, forKey: .selection)
        manualDomains = try container.decode([String].self, forKey: .manualDomains)
        blocksAdultWebsites = try container.decode(Bool.self, forKey: .blocksAdultWebsites)
        waitDuration = try container.decode(TimeInterval.self, forKey: .waitDuration)
        fullUnlockDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .fullUnlockDelay)
        breakDuration = try container.decode(TimeInterval.self, forKey: .breakDuration)
        fixedDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .fixedDuration)
        preventsAppRemoval = try container.decode(Bool.self, forKey: .preventsAppRemoval)
        requiresAutomaticDateAndTime = try container.decode(
            Bool.self,
            forKey: .requiresAutomaticDateAndTime
        )

        do {
            try validateDurations()
            try validateStoredModeRequirements()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .protectionMode,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protectionMode, forKey: .protectionMode)
        try container.encode(selection, forKey: .selection)
        try container.encode(manualDomains, forKey: .manualDomains)
        try container.encode(blocksAdultWebsites, forKey: .blocksAdultWebsites)
        try container.encode(waitDuration, forKey: .waitDuration)
        try container.encodeIfPresent(fullUnlockDelay, forKey: .fullUnlockDelay)
        try container.encode(breakDuration, forKey: .breakDuration)
        try container.encodeIfPresent(fixedDuration, forKey: .fixedDuration)
        try container.encode(preventsAppRemoval, forKey: .preventsAppRemoval)
        try container.encode(requiresAutomaticDateAndTime, forKey: .requiresAutomaticDateAndTime)
    }

    var selectedItemCount: Int {
        selection.applicationTokens.count
            + selection.categoryTokens.count
            + selection.webDomainTokens.count
            + manualDomains.count
    }

    var hasBlockingTarget: Bool {
        selectedItemCount > 0 || blocksAdultWebsites
    }

    func validateDurations() throws {
        let durations = [waitDuration, breakDuration, fullUnlockDelay, fixedDuration].compactMap { $0 }
        guard durations.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < Double(Int.max) / 2 }) else {
            throw LockPolicyError.invalidDuration
        }
        guard protectionMode.allowsBreaks || fixedDuration == nil else {
            throw LockPolicyError.fixedDurationUnavailableInLockdown
        }
    }

    mutating func normalize() {
        manualDomains = Self.normalizedDomains(manualDomains)
        waitDuration = max(3_600, waitDuration)
        fullUnlockDelay = max(3_600, fullUnlockDelay ?? waitDuration)
        breakDuration = max(900, breakDuration)
        if let fixedDuration {
            self.fixedDuration = max(3_600, fixedDuration)
        }
        if protectionMode == .lockdown {
            preventsAppRemoval = true
            requiresAutomaticDateAndTime = true
        }
    }

    private func validateStoredModeRequirements() throws {
        guard protectionMode != .lockdown || (preventsAppRemoval && requiresAutomaticDateAndTime) else {
            throw LockPolicyError.lockdownRequiresDeviceProtection
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

    /// New entries must describe a whole domain. Keep legacy normalization unchanged.
    static func newManualDomain(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
            components.scheme == "https" || components.scheme == "http",
            components.user == nil, components.password == nil, components.port == nil,
            components.path.isEmpty || components.path == "/",
            components.query == nil, components.fragment == nil,
            !trimmed.contains("*"),
            let domain = normalizedDomain(trimmed), domain.utf8.count <= 253
        else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard
            labels.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                    && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
            })
        else { return nil }
        return domain
    }

    static func normalizedDomains(_ inputs: [String]) -> [String] {
        Array(Set(inputs.compactMap(normalizedDomain))).sorted()
    }
}

enum LockPolicyError: LocalizedError, Equatable {
    case invalidDuration
    case fixedDurationUnavailableInLockdown
    case lockdownRequiresDeviceProtection

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            "Enter a valid waiting period and break length."
        case .fixedDurationUnavailableInLockdown:
            "Hard Pause cannot end automatically. Request a full unlock and complete its wait."
        case .lockdownRequiresDeviceProtection:
            "Hard Pause must prevent app deletion and require automatic date and time."
        }
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
